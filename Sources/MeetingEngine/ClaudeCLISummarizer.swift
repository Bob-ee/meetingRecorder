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

    public func complete(_ request: CompletionRequest) async throws -> String {
        guard let exe = Self.locateClaude(override: claudePath) else { throw SummarizerError.claudeNotFound }

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        if !oauthToken.isEmpty { env["CLAUDE_CODE_OAUTH_TOKEN"] = oauthToken }
        let home = NSHomeDirectory()
        let extraPath = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (extraPath + [(env["PATH"] ?? "")]).joined(separator: ":")

        let workingDirectory = request.debugDirectory ?? FileManager.default.temporaryDirectory
        // `--setting-sources ""` skips hooks/plugins/project settings but keeps the subscription login
        // (`--bare` would also drop the login, so don't use it). `--json-schema` makes the CLI enforce the
        // shape and hand back a parsed `structured_output`, so stray newlines inside strings can't break us.
        let base = ["-p", "--model", model, "--output-format", "json", "--no-session-persistence",
                    "--system-prompt", request.system]
        var optional: [[String]] = [["--setting-sources", ""]]
        if let schema = request.schema { optional.append(["--json-schema", schema]) }
        var result: ProcessResult
        while true {
            let args = base + optional.flatMap { $0 } + [request.instruction]
            result = try await ProcessRunner.run(executable: exe, arguments: args, stdin: request.user,
                                                 environment: env, currentDirectory: workingDirectory, timeout: 600)
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
        return try Self.unwrap(result.stdout)
    }

    /// Pull the model's reply out of the CLI's JSON envelope. A schema-checked reply comes back as
    /// `structured_output`, which is handed on as JSON text; anything else is the plain `result` string.
    public static func unwrap(_ stdout: String) throws -> String {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return trimmed
        }
        if envelope["is_error"] as? Bool == true {
            let text = (envelope["result"] as? String) ?? (envelope["subtype"] as? String) ?? "unknown error"
            if text.localizedCaseInsensitiveContains("not logged in") {
                throw SummarizerError.notConfigured("claude isn't logged in on this machine. Paste a token from `claude setup-token` into the summarizer settings.")
            }
            throw SummarizerError.failed(text)
        }
        // Preferred: the CLI already validated this against our schema.
        if let structured = envelope["structured_output"],
           let structuredData = try? JSONSerialization.data(withJSONObject: structured) {
            return String(decoding: structuredData, as: UTF8.self)
        }
        return (envelope["result"] as? String) ?? trimmed
    }
}
