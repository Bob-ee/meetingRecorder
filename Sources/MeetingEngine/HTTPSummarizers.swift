import Foundation
import MeetingCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum HTTP {
    static func post(_ url: URL, headers: [String: String], json: [String: Any],
                     timeout: TimeInterval = 600) async throws -> (status: Int, body: Data) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await URLSession.shared.data(for: req)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// Best-effort human-readable error out of an API error body.
    static func errorText(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
            if let msg = obj["error"] as? String { return msg }
            if let msg = obj["message"] as? String { return msg }
        }
        return String(String(data: data, encoding: .utf8)?.prefix(300) ?? "")
    }
}

/// Anthropic Messages API with a key. Uses a forced tool call so the reply is schema-validated server-side.
public struct AnthropicSummarizer: Summarizer {
    public let apiKey: String
    public let model: String
    public let baseURL: URL

    public init(apiKey: String, model: String, baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.apiKey = apiKey; self.model = model; self.baseURL = baseURL
    }

    public var displayName: String { "Anthropic API · \(model)" }

    public func summarize(_ request: SummaryRequest) async throws -> MeetingSummary {
        guard !apiKey.isEmpty else { throw SummarizerError.notConfigured("add an Anthropic API key") }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8192,
            "system": Prompts.system,
            "messages": [["role": "user", "content": Prompts.user(request)]],
            "tools": [[
                "name": "meeting_summary",
                "description": "Record the notes for this meeting.",
                "input_schema": Prompts.schemaObject,
            ]],
            "tool_choice": ["type": "tool", "name": "meeting_summary"],
        ]
        let (status, data) = try await HTTP.post(baseURL.appendingPathComponent("v1/messages"),
                                                 headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"],
                                                 json: body)
        guard (200..<300).contains(status) else {
            if status == 401 { throw SummarizerError.notConfigured("Anthropic rejected the API key") }
            throw SummarizerError.failed("HTTP \(status): \(HTTP.errorText(data))")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw SummarizerError.badOutput(String(String(data: data, encoding: .utf8)?.prefix(300) ?? ""))
        }
        if let tool = content.first(where: { $0["type"] as? String == "tool_use" }), let input = tool["input"],
           let inputData = try? JSONSerialization.data(withJSONObject: input),
           let summary = try? JSONDecoder().decode(MeetingSummary.self, from: inputData) {
            return summary
        }
        let text = content.compactMap { $0["text"] as? String }.joined()
        return try LLMOutput.parseSummary(text)
    }
}

/// Any OpenAI-style `/chat/completions` endpoint: OpenAI, Ollama, LM Studio, Groq, OpenRouter, …
public struct OpenAICompatibleSummarizer: Summarizer {
    public let baseURL: URL
    public let apiKey: String
    public let model: String

    public init(baseURL: URL, apiKey: String = "", model: String) {
        self.baseURL = baseURL; self.apiKey = apiKey; self.model = model
    }

    public var displayName: String { "\(baseURL.host ?? "OpenAI-compatible") · \(model)" }

    public func summarize(_ request: SummaryRequest) async throws -> MeetingSummary {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else {
            throw SummarizerError.notConfigured("base URL isn't valid")
        }
        var headers: [String: String] = [:]
        if !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        var body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": Prompts.system],
                ["role": "user", "content": Prompts.user(request)],
            ],
            "response_format": ["type": "json_object"],
        ]
        var (status, data) = try await HTTP.post(url, headers: headers, json: body)
        if status == 400, HTTP.errorText(data).lowercased().contains("response_format") {
            body.removeValue(forKey: "response_format")   // server doesn't support JSON mode; rely on the prompt
            (status, data) = try await HTTP.post(url, headers: headers, json: body)
        }
        guard (200..<300).contains(status) else {
            if status == 401 { throw SummarizerError.notConfigured("the server rejected the API key") }
            if status == 404 { throw SummarizerError.failed("HTTP 404 — check the base URL and that model \"\(model)\" exists (\(HTTP.errorText(data)))") }
            throw SummarizerError.failed("HTTP \(status): \(HTTP.errorText(data))")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw SummarizerError.badOutput(String(String(data: data, encoding: .utf8)?.prefix(300) ?? ""))
        }
        return try LLMOutput.parseSummary(text)
    }
}

public enum SummarizerFactory {
    public static func make(_ s: SummarizerSettings) throws -> any Summarizer {
        switch s.provider {
        case .claudeCLI:
            return ClaudeCLISummarizer(claudePath: s.claudePath, model: s.model, oauthToken: s.claudeOAuthToken)
        case .anthropic:
            guard !s.anthropicAPIKey.isEmpty else { throw SummarizerError.notConfigured("add an Anthropic API key") }
            return AnthropicSummarizer(apiKey: s.anthropicAPIKey, model: s.model)
        case .openAICompatible:
            guard let url = URL(string: s.openAIBaseURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil, url.host != nil else {
                throw SummarizerError.notConfigured("enter the server's base URL (e.g. http://localhost:11434/v1)")
            }
            return OpenAICompatibleSummarizer(baseURL: url, apiKey: s.openAIAPIKey, model: s.model)
        }
    }
}
