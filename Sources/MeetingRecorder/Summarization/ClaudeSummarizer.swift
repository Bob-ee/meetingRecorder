import Foundation

enum SummarizerError: LocalizedError {
    case claudeNotFound
    case failed(String)
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return "Couldn't find the `claude` command. Set its path in Settings (run `which claude` in Terminal)."
        case .failed(let s): return "claude exited with an error: \(s)"
        case .badOutput(let s): return "Couldn't parse Claude's response: \(s)"
        }
    }
}

/// Summarizes through `claude -p` (Claude Code headless mode) so it runs on the user's subscription — no API key.
struct ClaudeSummarizer {
    let claudePath: String
    let model: String

    static let candidatePaths = [
        "~/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "~/.npm-global/bin/claude",
        "~/.claude/local/claude",
        "~/.volta/bin/claude",
    ]

    static func locateClaude(override: String) -> String? {
        var candidates = candidatePaths
        if !override.isEmpty { candidates.insert(override, at: 0) }
        for c in candidates {
            let path = (c as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        // Ask the login shell as a last resort (picks up nvm/volta/etc).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
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

    func summarize(transcript: String, projectName: String?, projectContext: String,
                   meeting: Meeting, userName: String, workingDirectory: URL) async throws -> MeetingSummary {
        guard let exe = Self.locateClaude(override: claudePath) else { throw SummarizerError.claudeNotFound }

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        let home = NSHomeDirectory()
        let extraPath = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (extraPath + [(env["PATH"] ?? "")]).joined(separator: ":")

        let stdin = Prompts.user(transcript: transcript, projectName: projectName, projectContext: projectContext,
                                 meeting: meeting, userName: userName)
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
                Log.summarizer.warning("claude doesn't support \(optional[bad][0], privacy: .public); retrying without it")
                optional.remove(at: bad)
                continue
            }
            break
        }
        guard result.exitCode == 0 else {
            let msg = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SummarizerError.failed(String(msg.suffix(600)))
        }
        do {
            return try Self.parse(result.stdout)
        } catch {
            // Keep the raw reply next to the meeting so a parse failure is debuggable (and nothing is lost).
            let raw = workingDirectory.appendingPathComponent("claude-raw.json")
            try? result.stdout.write(to: raw, atomically: true, encoding: .utf8)
            Log.summarizer.error("couldn't parse claude output; saved to \(raw.path, privacy: .public)")
            throw error
        }
    }

    static func parse(_ stdout: String) throws -> MeetingSummary {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload = trimmed
        if let data = trimmed.data(using: .utf8),
           let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if envelope["is_error"] as? Bool == true {
                throw SummarizerError.failed((envelope["result"] as? String) ?? (envelope["subtype"] as? String) ?? "unknown error")
            }
            // Preferred: the CLI already validated this against our schema.
            if let structured = envelope["structured_output"] as? [String: Any],
               let structuredData = try? JSONSerialization.data(withJSONObject: structured),
               let summary = try? JSONDecoder().decode(MeetingSummary.self, from: structuredData) {
                return summary
            }
            payload = (envelope["result"] as? String) ?? ""
        }
        // Fallback: the model's text, repaired (fences, raw newlines in strings, trailing commas).
        let repaired = JSONRepair.repair(payload)
        guard let data = repaired.data(using: .utf8), repaired.hasPrefix("{") else {
            throw SummarizerError.badOutput(String(payload.prefix(400)))
        }
        do {
            return try JSONDecoder().decode(MeetingSummary.self, from: data)
        } catch {
            throw SummarizerError.badOutput("\(error.localizedDescription) — \(String(payload.prefix(300)))")
        }
    }
}
