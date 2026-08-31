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
    "owner":{"type":["string","null"]},"task":{"type":"string"},"due":{"type":["string","null"]},\
    "due_date":{"type":["string","null"]}},"required":["owner","task","due","due_date"]}},\
    "open_questions":{"type":"array","items":{"type":"string"}},\
    "events":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{\
    "title":{"type":"string"},"start":{"type":"string"},"end":{"type":["string","null"]},"all_day":{"type":"boolean"},\
    "location":{"type":["string","null"]},"context":{"type":["string","null"]}},\
    "required":["title","start","end","all_day","location","context"]}}},\
    "required":["title","summary","decisions","action_items","open_questions","events"]}
    """

    public static var schemaObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any]) ?? [:]
    }

    public static func user(_ r: SummaryRequest) -> String {
        user(transcript: r.transcriptMarkdown, projectName: r.projectName, projectContext: r.projectContext,
             meeting: r.meeting, userName: r.userName)
    }

    /// `zone` is the zone dates in the reply are read in (`LocalDate.parse`); it must be the same one on both sides,
    /// which is why it defaults to the machine doing the summarizing.
    public static func user(transcript: String, projectName: String?, projectContext: String,
                            meeting: Meeting, userName: String, zone: TimeZone = .current) -> String {
        let context = projectContext.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        # Meeting metadata
        - Date: \(Fmt.promptDate(meeting.startedAt, in: zone))
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
            {"owner": "person's name, or null if unclear", "task": "one concrete next step, phrased as an imperative", "due": "deadline as mentioned (e.g. 'Friday', 'end of month'), or null", "due_date": "that deadline as a calendar date-time 'YYYY-MM-DDTHH:MM' (a deadline 'by Friday' or 'end of day' is 17:00 that day — see the time rules), or 'YYYY-MM-DD' only when nothing suggests a time; null when it can't be pinned to a specific day"}
          ],
          "open_questions": ["unresolved questions, blockers, or things that need follow-up"],
          "events": [
            {"title": "short name for something that will happen at a specific time (a follow-up meeting, call, demo, launch, review, appointment, trip, deadline)", "start": "'YYYY-MM-DDTHH:MM' when a time was said or implied (see the time rules), else 'YYYY-MM-DD'", "end": "'YYYY-MM-DDTHH:MM' if an end time or duration was given, else null", "all_day": "true only when nothing suggests a time of day", "location": "place, room or video link if mentioned, else null", "context": "one sentence on what was said, e.g. 'Sarah proposed reviewing the mockups next Thursday afternoon'"}
          ]
        }
        Rules:
        - Only include action items that were clearly committed to or assigned. Don't turn every idea into a task.
        - Use "\(userName)" as the owner for things the recorder committed to.
        - Keep each action item self-contained and understandable without the transcript.
        - Dates: resolve relative expressions against the meeting date above. "Friday" or "this Friday" is the next Friday after the meeting day; "tomorrow" is the next day; "next week" needs a named day to count; "end of the month" is the last day of that month; "in two weeks" is 14 days later. All dates are in the meeting's time zone. Only fill in due_date or add an event when the day is clear from what was said — if it isn't, use null and no event.
        - Times: use the time that was said. When only part of the day was named, apply the usual business convention and treat it as a time, not all-day: end of business / end of day / EOD / close of business → 17:00; a deadline "by <day>" or "before <day>" → 17:00 that day; first thing / start of day → 09:00; morning → 10:00; noon / lunch → 12:00; afternoon → 14:00; evening / tonight → 18:00. Use all_day (or a date-only due_date) only when nothing at all suggests a time — "the launch is on the 15th", "sometime Friday". Never invent a time beyond these conventions.
        - events are for things people will attend or that happen at a moment (meetings, calls, demos, launches, deadlines with a date). Don't include this meeting itself, anything that already happened, or a standing schedule ("we meet every Monday"). A deadline that belongs to an action item goes in that item's due_date, not in events, unless people will actually meet then.
        - If the transcript is too short or garbled to summarize meaningfully, still return valid JSON with a brief honest summary.
        - Output only the JSON object.
        """
    }

    /// summary.md. `actionItems` and `events` are the summary's own, already resolved (`resolvedActionItems`,
    /// `resolvedEvents`), so the file shows real dates.
    public static func renderSummary(_ s: MeetingSummary, meeting: Meeting, projectName: String?,
                                     actionItems: [ActionItem], events: [MeetingEvent]) -> String {
        var out = "# \(s.title ?? meeting.title)\n\n"
        var meta = ["\(Fmt.dateTime.string(from: meeting.startedAt))", Fmt.duration(meeting.durationSeconds)]
        if let projectName { meta.append(projectName) }
        out += "_\(meta.joined(separator: " · "))_\n\n"
        out += s.summary.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        if !s.decisions.isEmpty {
            out += "## Decisions\n\n" + s.decisions.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !actionItems.isEmpty {
            out += "## Action items\n\n" + MeetingDocuments.actionItemsMarkdown(actionItems) + "\n\n"
        }
        if !s.openQuestions.isEmpty {
            out += "## Open questions\n\n" + s.openQuestions.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !events.isEmpty {
            out += "## \(MeetingDocuments.upcomingHeading)\n\n" + MeetingDocuments.eventsMarkdown(events) + "\n"
        }
        return out
    }
}
