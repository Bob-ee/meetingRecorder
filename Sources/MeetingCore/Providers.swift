import Foundation

// MARK: - Transcription

public protocol Transcriber: Sendable {
    /// Load models (downloading on first use). `status` receives human-readable progress.
    func prepare(status: @escaping @Sendable (String) -> Void) async throws
    /// `micURL` is the recorder's own voice (labeled `userLabel`); `remoteURL` is everyone else
    /// (diarized into "Speaker 1", "Speaker 2", …). Either may be nil.
    func transcribe(micURL: URL?, remoteURL: URL?, userLabel: String,
                    status: @escaping @Sendable (String) -> Void) async throws -> [TranscriptSegment]
}

public enum TranscriptionError: LocalizedError, Sendable {
    case notReady
    case noSpeech(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notReady: return "Speech models are not loaded"
        case .noSpeech(let detail): return "No speech was detected in the recording (\(detail))"
        case .unavailable(let why): return "Transcription isn't available here: \(why)"
        }
    }
}

// MARK: - Summarization

public struct SummaryRequest: Sendable {
    public var transcriptMarkdown: String
    public var projectName: String?
    /// What the user wrote about the project. Authoritative — it wins over anything the model learned itself.
    public var projectContext: String
    /// What the model has worked out about the project from earlier meetings.
    public var learnedContext: String
    /// Action items still open in other meetings of this project, so the reply can carry them forward.
    public var openProjectItems: [OpenProjectItem]
    public var meeting: Meeting
    public var userName: String
    /// Where to keep the raw model reply when it can't be parsed (nil = don't keep it).
    public var debugDirectory: URL?

    public init(transcriptMarkdown: String, projectName: String?, projectContext: String, learnedContext: String = "",
                openProjectItems: [OpenProjectItem] = [], meeting: Meeting, userName: String,
                debugDirectory: URL? = nil) {
        self.transcriptMarkdown = transcriptMarkdown; self.projectName = projectName
        self.projectContext = projectContext; self.learnedContext = learnedContext
        self.openProjectItems = openProjectItems; self.meeting = meeting; self.userName = userName
        self.debugDirectory = debugDirectory
    }
}

/// One model round-trip, whatever the prompt is for. Every provider implements this; summarizing, keeping a
/// project's context current and writing advice for an action item are all callers of it.
public struct CompletionRequest: Sendable {
    public var system: String
    /// The body of the request. Providers that take a prompt on the command line send this on stdin instead.
    public var user: String
    /// JSON Schema for the reply. When set, the provider asks its API to enforce that shape and the returned
    /// string is a JSON object; when nil the reply is free text.
    public var schema: String?
    /// What to tell a CLI provider to do with the text arriving on stdin.
    public var instruction: String
    public var maxTokens: Int
    /// Short name for logs and for the file an unparseable reply is dumped to.
    public var label: String
    /// Where to keep the raw model reply when it can't be parsed (nil = don't keep it).
    public var debugDirectory: URL?

    public init(system: String, user: String, schema: String? = nil,
                instruction: String = "Read the input from stdin and respond exactly as it asks.",
                maxTokens: Int = 8192, label: String = "reply", debugDirectory: URL? = nil) {
        self.system = system; self.user = user; self.schema = schema; self.instruction = instruction
        self.maxTokens = maxTokens; self.label = label; self.debugDirectory = debugDirectory
    }
}

public protocol Summarizer: Sendable {
    var displayName: String { get }
    func complete(_ request: CompletionRequest) async throws -> String
}

public extension Summarizer {
    /// The meeting notes. Every provider gets this for free once it can `complete`.
    func summarize(_ request: SummaryRequest) async throws -> MeetingSummary {
        let reply = try await complete(CompletionRequest(
            system: Prompts.system, user: Prompts.user(request), schema: Prompts.schema,
            instruction: Prompts.instruction, label: "summary", debugDirectory: request.debugDirectory))
        return try LLMOutput.decode(MeetingSummary.self, from: reply,
                                    saveFailureTo: request.debugDirectory, label: "summary")
    }

    /// Rewrite what the model knows about a project after a meeting. Returns nil when nothing durable changed.
    func updateContext(_ request: ContextUpdateRequest) async throws -> ContextUpdate? {
        let reply = try await complete(CompletionRequest(
            system: Prompts.contextSystem, user: Prompts.contextUser(request), schema: Prompts.contextSchema,
            instruction: Prompts.contextInstruction, maxTokens: 4096, label: "context",
            debugDirectory: request.debugDirectory))
        let update = try LLMOutput.decode(ContextUpdate.self, from: reply,
                                          saveFailureTo: request.debugDirectory, label: "context")
        guard update.changed, !update.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return update
    }

    /// "How would I handle this?" for one action item — Markdown, on request only.
    func advise(_ request: AdviceRequest) async throws -> String {
        let reply = try await complete(CompletionRequest(
            system: Prompts.adviceSystem, user: Prompts.adviceUser(request), maxTokens: 2048,
            label: "advice", debugDirectory: request.debugDirectory))
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SummarizerError.badOutput("the model returned nothing") }
        return text
    }
}

/// Everything needed to bring a project's learned context up to date after one meeting.
public struct ContextUpdateRequest: Sendable {
    public var projectName: String
    /// The user's own CONTEXT.md — quoted so the model doesn't repeat or contradict it.
    public var userContext: String
    /// The current learned context, which the reply replaces wholesale.
    public var learnedContext: String
    public var meeting: Meeting
    public var summaryMarkdown: String
    public var debugDirectory: URL?

    public init(projectName: String, userContext: String, learnedContext: String, meeting: Meeting,
                summaryMarkdown: String, debugDirectory: URL? = nil) {
        self.projectName = projectName; self.userContext = userContext; self.learnedContext = learnedContext
        self.meeting = meeting; self.summaryMarkdown = summaryMarkdown; self.debugDirectory = debugDirectory
    }
}

/// Everything needed to suggest how to handle one action item.
public struct AdviceRequest: Sendable {
    public var item: ActionItem
    public var meeting: Meeting
    public var projectName: String
    public var userContext: String
    public var learnedContext: String
    public var summaryMarkdown: String
    /// The project's other open items, so the advice can point at what this depends on or blocks.
    public var otherOpenItems: [OpenProjectItem]
    public var userName: String
    public var debugDirectory: URL?

    public init(item: ActionItem, meeting: Meeting, projectName: String, userContext: String, learnedContext: String,
                summaryMarkdown: String, otherOpenItems: [OpenProjectItem] = [], userName: String,
                debugDirectory: URL? = nil) {
        self.item = item; self.meeting = meeting; self.projectName = projectName; self.userContext = userContext
        self.learnedContext = learnedContext; self.summaryMarkdown = summaryMarkdown
        self.otherOpenItems = otherOpenItems; self.userName = userName; self.debugDirectory = debugDirectory
    }
}

public enum SummarizerError: LocalizedError, Sendable {
    case notConfigured(String)
    case claudeNotFound
    case failed(String)
    case badOutput(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let what): return "Summarizer isn't set up: \(what)"
        case .claudeNotFound:
            return "Couldn't find the `claude` command. Set its path in Settings (run `which claude` in Terminal)."
        case .failed(let s): return "The model request failed: \(s)"
        case .badOutput(let s): return "Couldn't parse the model's response: \(s)"
        }
    }
}

/// Which service writes the summaries. Stored per workspace on the hub, or in the app for local mode.
public enum SummarizerProvider: String, Codable, CaseIterable, Sendable {
    /// `claude -p` on a Claude subscription — no API key.
    case claudeCLI = "claude-cli"
    /// Anthropic API with a key (pay per token).
    case anthropic
    /// Any OpenAI-compatible endpoint: OpenAI, Ollama, LM Studio, Groq, OpenRouter, …
    case openAICompatible = "openai-compatible"

    public var displayName: String {
        switch self {
        case .claudeCLI: return "Claude Code (subscription)"
        case .anthropic: return "Anthropic API"
        case .openAICompatible: return "OpenAI-compatible (OpenAI, Ollama, LM Studio…)"
        }
    }

    public var defaultModel: String {
        switch self {
        case .claudeCLI: return "sonnet"
        case .anthropic: return "claude-sonnet-5"
        case .openAICompatible: return "gpt-4o-mini"
        }
    }
}

public struct SummarizerSettings: Codable, Equatable, Sendable {
    public var provider: SummarizerProvider
    public var model: String
    /// Path to the `claude` binary (empty = search the usual places).
    public var claudePath: String
    /// From `claude setup-token`; lets a headless machine use the subscription. Empty = use the local login.
    public var claudeOAuthToken: String
    public var anthropicAPIKey: String
    public var openAIBaseURL: String
    public var openAIAPIKey: String

    public init(provider: SummarizerProvider = .claudeCLI, model: String? = nil, claudePath: String = "",
                claudeOAuthToken: String = "", anthropicAPIKey: String = "",
                openAIBaseURL: String = "http://localhost:11434/v1", openAIAPIKey: String = "") {
        self.provider = provider
        self.model = model ?? provider.defaultModel
        self.claudePath = claudePath
        self.claudeOAuthToken = claudeOAuthToken
        self.anthropicAPIKey = anthropicAPIKey
        self.openAIBaseURL = openAIBaseURL
        self.openAIAPIKey = openAIAPIKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let provider = try c.decodeIfPresent(SummarizerProvider.self, forKey: .provider) ?? .claudeCLI
        self.provider = provider
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? provider.defaultModel
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? ""
        claudeOAuthToken = try c.decodeIfPresent(String.self, forKey: .claudeOAuthToken) ?? ""
        anthropicAPIKey = try c.decodeIfPresent(String.self, forKey: .anthropicAPIKey) ?? ""
        openAIBaseURL = try c.decodeIfPresent(String.self, forKey: .openAIBaseURL) ?? "http://localhost:11434/v1"
        openAIAPIKey = try c.decodeIfPresent(String.self, forKey: .openAIAPIKey) ?? ""
    }

    /// Copy with secrets replaced by a placeholder, for sending to clients.
    public func redacted() -> SummarizerSettings {
        var s = self
        if !s.claudeOAuthToken.isEmpty { s.claudeOAuthToken = SummarizerSettings.redactedMarker }
        if !s.anthropicAPIKey.isEmpty { s.anthropicAPIKey = SummarizerSettings.redactedMarker }
        if !s.openAIAPIKey.isEmpty { s.openAIAPIKey = SummarizerSettings.redactedMarker }
        return s
    }

    /// Apply an update from a client: fields still holding the placeholder keep their stored value.
    public func merging(update: SummarizerSettings) -> SummarizerSettings {
        var s = update
        if s.claudeOAuthToken == SummarizerSettings.redactedMarker { s.claudeOAuthToken = claudeOAuthToken }
        if s.anthropicAPIKey == SummarizerSettings.redactedMarker { s.anthropicAPIKey = anthropicAPIKey }
        if s.openAIAPIKey == SummarizerSettings.redactedMarker { s.openAIAPIKey = openAIAPIKey }
        return s
    }

    public static let redactedMarker = "••••••••"
}

/// Describes a provider's configuration fields so a client can render a settings form without knowing the provider.
public struct ProviderField: Codable, Sendable, Identifiable {
    public var key: String
    public var label: String
    public var help: String
    public var secret: Bool
    public var placeholder: String
    public var id: String { key }

    public init(key: String, label: String, help: String = "", secret: Bool = false, placeholder: String = "") {
        self.key = key; self.label = label; self.help = help; self.secret = secret; self.placeholder = placeholder
    }
}

public struct ProviderDescription: Codable, Sendable, Identifiable {
    public var id: SummarizerProvider
    public var name: String
    public var fields: [ProviderField]
    public var suggestedModels: [String]

    public init(id: SummarizerProvider, name: String, fields: [ProviderField], suggestedModels: [String]) {
        self.id = id; self.name = name; self.fields = fields; self.suggestedModels = suggestedModels
    }

    public static let all: [ProviderDescription] = [
        ProviderDescription(
            id: .claudeCLI, name: SummarizerProvider.claudeCLI.displayName,
            fields: [
                ProviderField(key: "claudeOAuthToken", label: "Subscription token",
                              help: "Run `claude setup-token` on any computer where you're logged in to Claude Code and paste the result. Leave empty if this machine is already logged in.",
                              secret: true, placeholder: "sk-ant-oat01-…"),
                ProviderField(key: "claudePath", label: "claude path", help: "Only needed if `claude` isn't on the PATH.", placeholder: "~/.local/bin/claude"),
            ],
            suggestedModels: ["sonnet", "opus", "haiku"]),
        ProviderDescription(
            id: .anthropic, name: SummarizerProvider.anthropic.displayName,
            fields: [
                ProviderField(key: "anthropicAPIKey", label: "API key", help: "From console.anthropic.com. Billed per token (a one-hour meeting is a few cents).", secret: true, placeholder: "sk-ant-api03-…"),
            ],
            suggestedModels: ["claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5-20251001"]),
        ProviderDescription(
            id: .openAICompatible, name: SummarizerProvider.openAICompatible.displayName,
            fields: [
                ProviderField(key: "openAIBaseURL", label: "Base URL", help: "OpenAI: https://api.openai.com/v1 · Ollama: http://localhost:11434/v1 · LM Studio: http://localhost:1234/v1", placeholder: "http://localhost:11434/v1"),
                ProviderField(key: "openAIAPIKey", label: "API key", help: "Leave empty for a local server.", secret: true, placeholder: "sk-…"),
            ],
            suggestedModels: ["gpt-4o-mini", "gpt-4o", "llama3.1:8b", "qwen2.5:7b"]),
    ]
}

public enum LLMOutput {
    /// Decode a model's reply, tolerating code fences, surrounding prose, raw newlines inside strings and trailing
    /// commas. A reply that can't be decoded is kept next to the meeting so the failure is debuggable.
    public static func decode<T: Decodable>(_ type: T.Type, from text: String, saveFailureTo directory: URL? = nil,
                                            label: String = "reply") throws -> T {
        let repaired = JSONRepair.repair(text)
        func fail(_ detail: String) -> SummarizerError {
            if let directory {
                let raw = directory.appendingPathComponent("\(label)-raw.txt")
                try? text.write(to: raw, atomically: true, encoding: .utf8)
                Log.summarizer.error("couldn't parse the \(label) reply; saved to \(raw.path)")
            }
            return SummarizerError.badOutput(detail)
        }
        guard let data = repaired.data(using: .utf8), repaired.hasPrefix("{") else {
            throw fail(String(text.prefix(400)))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw fail("\(error.localizedDescription) — \(String(text.prefix(300)))")
        }
    }
}
