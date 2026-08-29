import Foundation

/// The prompts every summarizer uses, so the notes read the same whichever model wrote them.
public enum Prompts {
    public static let system = """
    You are an expert meeting note-taker. You read raw, auto-generated meeting transcripts (they may contain \
    transcription errors, missing words, and imperfect speaker labels) and produce accurate, concise, useful notes. \
    Never invent facts that are not supported by the transcript. When something is ambiguous, say so briefly rather \
    than guessing. You respond with a single JSON object and nothing else: no prose, no markdown code fences.
    """

    public static let instruction = "Read the meeting metadata, project context and transcript from stdin, then respond with the JSON object described there."

    /// JSON Schema for the reply. Passed to `claude --json-schema`, Anthropic tool input, etc.
    public static let schema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "title":{"type":"string"},\
    "summary":{"type":"string"},\
    "decisions":{"type":"array","items":{"type":"string"}},\
    "action_items":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{\
    "owner":{"type":["string","null"]},"task":{"type":"string"},"due":{"type":["string","null"]}},"required":["owner","task","due"]}},\
    "open_questions":{"type":"array","items":{"type":"string"}}},\
    "required":["title","summary","decisions","action_items","open_questions"]}
    """

    public static var schemaObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any]) ?? [:]
    }

    public static func user(_ r: SummaryRequest) -> String {
        user(transcript: r.transcriptMarkdown, projectName: r.projectName, projectContext: r.projectContext,
             meeting: r.meeting, userName: r.userName)
    }

    public static func user(transcript: String, projectName: String?, projectContext: String,
                            meeting: Meeting, userName: String) -> String {
        let context = projectContext.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        # Meeting metadata
        - Date: \(Fmt.dateTime.string(from: meeting.startedAt))
        - Duration: \(Fmt.duration(meeting.durationSeconds))
        - Project: \(projectName ?? "(none)")
        \(meeting.source == .imported
            ? "- This is a single recording of the whole conversation (made on a phone or another device) that \"\(userName)\" imported. Everyone, including \"\(userName)\", appears as \"Speaker 1\", \"Speaker 2\", … unless renamed. Don't assume which speaker is \"\(userName)\" unless the transcript makes it obvious."
            : "- The person who recorded this is \"\(userName)\". Their microphone track is labeled \"\(userName)\" in the transcript. Other participants are labeled \"Speaker 1\", \"Speaker 2\", … unless they have been renamed.")

        # Project context (written by the user — use it for names, jargon, priorities, and what matters)
        \(context.isEmpty ? "(none provided)" : context)

        # Transcript
        \(transcript)

        # Task
        Respond with one JSON object of exactly this shape:
        {
          "title": "short, specific meeting title (max 8 words, no date)",
          "summary": "Markdown string. Start with a 2-4 sentence overview paragraph. Then a '### Key points' section with bullets grouped by topic (use bold topic labels). Be concrete: include numbers, names, dates, and reasoning behind decisions. Length should scale with the meeting: ~120 words for a 10-minute chat, up to ~500 words for a long meeting.",
          "decisions": ["decisions that were actually made (empty array if none)"],
          "action_items": [
            {"owner": "person's name, or null if unclear", "task": "one concrete next step, phrased as an imperative", "due": "deadline as mentioned (e.g. 'Friday', 'end of month'), or null"}
          ],
          "open_questions": ["unresolved questions, blockers, or things that need follow-up"]
        }
        Rules:
        - Only include action items that were clearly committed to or assigned. Don't turn every idea into a task.
        - Use "\(userName)" as the owner for things the recorder committed to.
        - Keep each action item self-contained and understandable without the transcript.
        - If the transcript is too short or garbled to summarize meaningfully, still return valid JSON with a brief honest summary.
        - Output only the JSON object.
        """
    }

    public static func renderSummary(_ s: MeetingSummary, meeting: Meeting, projectName: String?) -> String {
        var out = "# \(s.title ?? meeting.title)\n\n"
        var meta = ["\(Fmt.dateTime.string(from: meeting.startedAt))", Fmt.duration(meeting.durationSeconds)]
        if let projectName { meta.append(projectName) }
        out += "_\(meta.joined(separator: " · "))_\n\n"
        out += s.summary.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        if !s.decisions.isEmpty {
            out += "## Decisions\n\n" + s.decisions.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !s.actionItems.isEmpty {
            out += "## Action items\n\n"
            for item in s.actionItems {
                var line = "- [ ] "
                if let owner = item.owner, !owner.isEmpty { line += "**\(owner)** — " }
                line += item.task
                if let due = item.due, !due.isEmpty { line += " _(due \(due))_" }
                out += line + "\n"
            }
            out += "\n"
        }
        if !s.openQuestions.isEmpty {
            out += "## Open questions\n\n" + s.openQuestions.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        return out
    }
}
