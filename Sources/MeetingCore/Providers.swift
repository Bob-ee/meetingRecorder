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
    public var projectContext: String
    public var meeting: Meeting
    public var userName: String
    /// Where to keep the raw model reply when it can't be parsed (nil = don't keep it).
    public var debugDirectory: URL?

    public init(transcriptMarkdown: String, projectName: String?, projectContext: String,
                meeting: Meeting, userName: String, debugDirectory: URL? = nil) {
        self.transcriptMarkdown = transcriptMarkdown; self.projectName = projectName
        self.projectContext = projectContext; self.meeting = meeting; self.userName = userName
        self.debugDirectory = debugDirectory
    }
}

public protocol Summarizer: Sendable {
    var displayName: String { get }
    func summarize(_ request: SummaryRequest) async throws -> MeetingSummary
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
