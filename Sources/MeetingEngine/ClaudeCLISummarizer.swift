import Foundation
import MeetingCore

/// Summarizes through `claude -p` (Claude Code headless mode) so it runs on a Claude subscription — no API key.
/// On a headless machine, pass the token from `claude setup-token`; no interactive login is needed then.
public struct ClaudeCLISummarizer: Summarizer {
    public let claudePath: String
    public let model: String
    public let oauthToken: String

    public init(claudePath: String = "", model: String = "sonnet", oauthToken: String = "") {
        self.claudePath = claudePath
        self.model = model
        self.oauthToken = oauthToken
    }

    public var displayName: String { "Claude Code · \(model)" }

    public static let candidatePaths = [
        "~/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "~/.npm-global/bin/claude",
        "~/.claude/local/claude",
        "~/.volta/bin/claude",
    ]

    public static func locateClaude(override: String) -> String? {
        var candidates = candidatePaths
        if !override.isEmpty { candidates.insert(override, at: 0) }
        for c in candidates {
            let path = (c as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        // Ask the login shell as a last resort (picks up nvm/volta/etc).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let found = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return found.isEmpty ? nil : found
    }

    public func summarize(_ request: SummaryRequest) async throws -> MeetingSummary {
        guard let exe = Self.locateClaude(override: claudePath) else { throw SummarizerError.claudeNotFound }

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        if !oauthToken.isEmpty { env["CLAUDE_CODE_OAUTH_TOKEN"] = oauthToken }
        let home = NSHomeDirectory()
        let extraPath = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (extraPath + [(env["PATH"] ?? "")]).joined(separator: ":")

        let stdin = Prompts.user(request)
        let workingDirectory = request.debugDirectory ?? FileManager.default.temporaryDirectory
        // `--setting-sources ""` skips hooks/plugins/project settings but keeps the subscription login
        // (`--bare` would also drop the login, so don't use it). `--json-schema` makes the CLI enforce the
        // shape and hand back a parsed `structured_output`, so stray newlines inside strings can't break us.
        let base = ["-p", "--model", model, "--output-format", "json", "--no-session-persistence",
                    "--system-prompt", Prompts.system]
        var optional: [[String]] = [["--setting-sources", ""], ["--json-schema", Prompts.schema]]
        var result: ProcessResult
        while true {
            let args = base + optional.flatMap { $0 } + [Prompts.instruction]
            result = try await ProcessRunner.run(executable: exe, arguments: args, stdin: stdin, environment: env,
                                                 currentDirectory: workingDirectory, timeout: 600)
            // Older CLIs: drop whichever optional flag they don't know and try again.
            if result.exitCode != 0, result.stderr.lowercased().contains("unknown option"),
               let bad = optional.firstIndex(where: { result.stderr.contains($0[0]) }) {
                Log.summarizer.warning("claude doesn't support \(optional[bad][0]); retrying without it")
                optional.remove(at: bad)
                continue
            }
            break
        }
        guard result.exitCode == 0 else {
            let msg = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.localizedCaseInsensitiveContains("not logged in") || msg.localizedCaseInsensitiveContains("invalid api key")
                || msg.localizedCaseInsensitiveContains("authentication") {
                throw SummarizerError.notConfigured(
                    "claude isn't logged in on this machine. Run `claude setup-token` on a computer where you are, and paste the token into the summarizer settings.")
            }
            throw SummarizerError.failed(String(msg.suffix(600)))
        }
        do {
            return try Self.parse(result.stdout)
        } catch {
            // Keep the raw reply next to the meeting so a parse failure is debuggable (and nothing is lost).
            if let dir = request.debugDirectory {
                let raw = dir.appendingPathComponent("claude-raw.json")
                try? result.stdout.write(to: raw, atomically: true, encoding: .utf8)
                Log.summarizer.error("couldn't parse claude output; saved to \(raw.path)")
            }
            throw error
        }
    }

    public static func parse(_ stdout: String) throws -> MeetingSummary {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload = trimmed
        if let data = trimmed.data(using: .utf8),
           let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if envelope["is_error"] as? Bool == true {
                let text = (envelope["result"] as? String) ?? (envelope["subtype"] as? String) ?? "unknown error"
                if text.localizedCaseInsensitiveContains("not logged in") {
                    throw SummarizerError.notConfigured("claude isn't logged in on this machine. Paste a token from `claude setup-token` into the summarizer settings.")
                }
                throw SummarizerError.failed(text)
            }
            // Preferred: the CLI already validated this against our schema.
            if let structured = envelope["structured_output"] as? [String: Any],
               let structuredData = try? JSONSerialization.data(withJSONObject: structured),
               let summary = try? JSONDecoder().decode(MeetingSummary.self, from: structuredData) {
                return summary
            }
            payload = (envelope["result"] as? String) ?? ""
        }
        return try LLMOutput.parseSummary(payload)
    }
}

public enum LLMOutput {
    /// Parse a model's free-text reply into a summary, tolerating code fences, surrounding prose,
    /// raw newlines inside strings and trailing commas.
    public static func parseSummary(_ text: String) throws -> MeetingSummary {
        let repaired = JSONRepair.repair(text)
        guard let data = repaired.data(using: .utf8), repaired.hasPrefix("{") else {
            throw SummarizerError.badOutput(String(text.prefix(400)))
        }
        do {
            return try JSONDecoder().decode(MeetingSummary.self, from: data)
        } catch {
            throw SummarizerError.badOutput("\(error.localizedDescription) — \(String(text.prefix(300)))")
        }
    }
}
