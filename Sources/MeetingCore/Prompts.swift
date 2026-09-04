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
    "due_date":{"type":["string","null"]},"source_quote":{"type":["string","null"]},\
    "duplicate_of":{"type":["string","null"]}},\
    "required":["owner","task","due","due_date","source_quote","duplicate_of"]}},\
    "completed_items":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{\
    "ref":{"type":"string"},"evidence":{"type":["string","null"]}},"required":["ref","evidence"]}},\
    "open_questions":{"type":"array","items":{"type":"string"}},\
    "events":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{\
    "title":{"type":"string"},"start":{"type":"string"},"end":{"type":["string","null"]},"all_day":{"type":"boolean"},\
    "location":{"type":["string","null"]},"context":{"type":["string","null"]}},\
    "required":["title","start","end","all_day","location","context"]}}},\
    "required":["title","summary","decisions","action_items","completed_items","open_questions","events"]}
    """

    public static var schemaObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any]) ?? [:]
    }

    public static func user(_ r: SummaryRequest) -> String {
        user(transcript: r.transcriptMarkdown, projectName: r.projectName, projectContext: r.projectContext,
             learnedContext: r.learnedContext, openProjectItems: r.openProjectItems,
             meeting: r.meeting, userName: r.userName)
    }

    /// The two context blocks, in the order the model should trust them.
    static func contextBlocks(userContext: String, learnedContext: String) -> String {
        let user = userContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let learned = learnedContext.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = """
        # Project context (written by the user — use it for names, jargon, priorities, and what matters)
        \(user.isEmpty ? "(none provided)" : user)
        """
        if !learned.isEmpty {
            out += """


            # What you have worked out about this project so far (written by you after earlier meetings)
            Treat this as background, not gospel. Where it disagrees with the user's context above or with this \
            transcript, the user's context and the transcript win.
            \(learned)
            """
        }
        return out
    }

    /// The project's other open items, listed with the short refs the reply uses to point back at them.
    static func openItemsBlock(_ items: [OpenProjectItem]) -> String {
        guard !items.isEmpty else {
            return """


            # Action items already open in this project
            None — nothing is outstanding from earlier meetings. Set every `duplicate_of` to null and return an empty `completed_items`.
            """
        }
        let lines = items.map { item -> String in
            var line = "- \(item.ref): \(item.task)"
            var bits: [String] = []
            if let owner = item.owner, !owner.isEmpty { bits.append("owner \(owner)") }
            if let due = item.dueLabel, !due.isEmpty { bits.append("due \(due)") }
            bits.append("raised \(Fmt.dateOnly.string(from: item.raisedAt)) in “\(item.meetingTitle)”")
            line += " (\(bits.joined(separator: ", ")))"
            return line
        }
        return """


        # Action items already open in this project
        These came out of earlier meetings and are not done yet. They are listed so this meeting's notes don't \
        repeat them — see the `duplicate_of` and `completed_items` rules below.
        \(lines.joined(separator: "\n"))
        """
    }

    /// `zone` is the zone dates in the reply are read in (`LocalDate.parse`); it must be the same one on both sides,
    /// which is why it defaults to the machine doing the summarizing.
    public static func user(transcript: String, projectName: String?, projectContext: String,
                            learnedContext: String = "", openProjectItems: [OpenProjectItem] = [],
                            meeting: Meeting, userName: String, zone: TimeZone = .current) -> String {
        return """
        # Meeting metadata
        - Date: \(Fmt.promptDate(meeting.startedAt, in: zone))
        - Duration: \(Fmt.duration(meeting.durationSeconds))
        - Project: \(projectName ?? "(none)")
        \(meeting.source == .imported
            ? "- This is a single recording of the whole conversation (made on a phone or another device) that \"\(userName)\" imported. Everyone, including \"\(userName)\", appears as \"Speaker 1\", \"Speaker 2\", … unless renamed. Don't assume which speaker is \"\(userName)\" unless the transcript makes it obvious."
            : "- The person who recorded this is \"\(userName)\". Their microphone track is labeled \"\(userName)\" in the transcript. Other participants are labeled \"Speaker 1\", \"Speaker 2\", … unless they have been renamed.")

        \(contextBlocks(userContext: projectContext, learnedContext: learnedContext))\(openItemsBlock(openProjectItems))

        # Transcript
        \(transcript)

        # Task
        Respond with one JSON object of exactly this shape:
        {
          "title": "short, specific meeting title (max 8 words, no date)",
          "summary": "Markdown string. Start with a 2-4 sentence overview paragraph. Then a '### Key points' section with bullets grouped by topic (use bold topic labels). Be concrete: include numbers, names, dates, and reasoning behind decisions. Length should scale with the meeting: ~120 words for a 10-minute chat, up to ~500 words for a long meeting.",
          "decisions": ["decisions that were actually made (empty array if none)"],
          "action_items": [
            {"owner": "person's name, or null if unclear", "task": "one concrete next step, phrased as an imperative", "due": "deadline as mentioned (e.g. 'Friday', 'end of month'), or null", "due_date": "that deadline as a calendar date-time 'YYYY-MM-DDTHH:MM' (a deadline 'by Friday' or 'end of day' is 17:00 that day — see the time rules), or 'YYYY-MM-DD' only when nothing suggests a time; null when it can't be pinned to a specific day", "source_quote": "the sentence from the transcript where this was assigned, quoted or lightly cleaned up (max 30 words), or null if it came from the discussion as a whole", "duplicate_of": "the ref of an already-open item this restates (e.g. 'P2'), or null when it's new work"}
          ],
          "completed_items": [
            {"ref": "the ref of an already-open item this meeting says is finished", "evidence": "the words that show it's done, e.g. 'Sarah said the spec went out Tuesday'"}
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
        - Already-open items: if this meeting restates one of the listed open items (same work, even if worded differently), still include it in action_items but set duplicate_of to its ref, and give the owner and deadline as they stand after this meeting. Don't set duplicate_of when the task is genuinely different or narrower — that's new work.
        - completed_items is only for the listed open items. Put a ref there when the meeting says the work is finished — not when it's merely progressing, reassigned or delayed. An item can't be in completed_items and be a duplicate_of target in the same reply.
        - Dates: resolve relative expressions against the meeting date above. "Friday" or "this Friday" is the next Friday after the meeting day; "tomorrow" is the next day; "next week" needs a named day to count; "end of the month" is the last day of that month; "in two weeks" is 14 days later. All dates are in the meeting's time zone. Only fill in due_date or add an event when the day is clear from what was said — if it isn't, use null and no event.
        - Times: use the time that was said. When only part of the day was named, apply the usual business convention and treat it as a time, not all-day: end of business / end of day / EOD / close of business → 17:00; a deadline "by <day>" or "before <day>" → 17:00 that day; first thing / start of day → 09:00; morning → 10:00; noon / lunch → 12:00; afternoon → 14:00; evening / tonight → 18:00. Use all_day (or a date-only due_date) only when nothing at all suggests a time — "the launch is on the 15th", "sometime Friday". Never invent a time beyond these conventions.
        - events are for things people will attend or that happen at a moment (meetings, calls, demos, launches, deadlines with a date). Don't include this meeting itself, anything that already happened, or a standing schedule ("we meet every Monday"). A deadline that belongs to an action item goes in that item's due_date, not in events, unless people will actually meet then.
        - If the transcript is too short or garbled to summarize meaningfully, still return valid JSON with a brief honest summary.
        - Output only the JSON object.
        """
    }

    // MARK: - Project context upkeep

    public static let contextSystem = """
    You maintain a short reference note about an ongoing project, so that whoever summarizes its meetings next \
    starts out knowing who's who and what matters. You write only durable facts that you can point at in the \
    material you were given, you keep the note short, and you delete what has gone stale. You never invent \
    people, systems or plans. You respond with a single JSON object and nothing else: no prose, no code fences.
    """

    public static let contextInstruction = "Read the project note and the new meeting summary from stdin, then respond with the JSON object described there."

    public static let contextSchema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "changed":{"type":"boolean"},"context":{"type":"string"},"note":{"type":["string","null"]}},\
    "required":["changed","context","note"]}
    """

    public static func contextUser(_ r: ContextUpdateRequest, zone: TimeZone = .current) -> String {
        let user = r.userContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let learned = r.learnedContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let today = Fmt.promptDate(r.meeting.startedAt, in: zone)
        return """
        # Project
        \(r.projectName)

        # The user's own notes on this project (you do not own this text and must not repeat it)
        \(user.isEmpty ? "(none provided)" : user)

        # Your current note on this project (this is what you are rewriting)
        \(learned.isEmpty ? "(empty — you're writing it for the first time)" : learned)

        # The meeting that just happened, on \(today)
        ## \(r.meeting.title)
        \(r.summaryMarkdown)

        # Task
        Rewrite your note so it reflects what is now true about this project, and respond with one JSON object:
        {
          "changed": "true if your note should be replaced with the text below, false if this meeting taught you nothing durable",
          "context": "the complete new note in Markdown — the whole thing, not a patch. Empty string when changed is false.",
          "note": "one short line for the user on what moved, e.g. 'Added Priya (design lead) and the Q4 launch date; dropped the Postgres migration, which shipped.'"
        }
        What belongs in your note:
        - People: who is involved, their role, what they own. Include how they appear in transcripts if that differs from their name.
        - Vocabulary: acronyms, code names, systems, repos, customers, and what they mean here.
        - The shape of the work: current goals, constraints, deadlines, and the decisions that still govern how things are done.
        - Standing arrangements: how the team meets, who signs off on what, where things live.
        What does not belong:
        - A retelling of individual meetings. The summaries already exist and this note is read alongside them.
        - Action items, open questions, or anything with a checkbox — those are tracked separately.
        - Anything the user already wrote in their own notes above. Don't restate or argue with it.
        - Guesses, predictions, or anything you couldn't point to a line in the material for.
        Rules:
        - Date every fact that could go stale, in parentheses, using the date of the meeting that established it: "Launch is set for 12 November (as of \(today))." That's what lets you drop it later.
        - Remove facts this meeting contradicts or completes. The note is a picture of now, not a log — it should not keep growing.
        - Keep it under 500 words. If you're near that, cut the least load-bearing facts rather than compressing everything into fragments.
        - Write plain declarative sentences under a few "## " headings of your own choosing. No preamble, no "this note describes…".
        - Set changed to false when the meeting was small talk, off-topic, or added nothing you don't already have.
        - Output only the JSON object.
        """
    }

    // MARK: - Action item advice

    public static let adviceSystem = """
    You are a sharp, experienced colleague of the person asking. They have an action item from a meeting and want \
    to know how you would handle it. You know the project, so you give specific advice about this task rather than \
    generic productivity guidance, and you say what you'd actually do first. You are brief. You never pad, never \
    restate the task back at them, and never lecture. You respond in Markdown, with no preamble.
    """

    public static func adviceUser(_ r: AdviceRequest, zone: TimeZone = .current) -> String {
        var out = """
        # The action item
        - Task: \(r.item.task)
        - Owner: \(r.item.owner?.isEmpty == false ? r.item.owner! : "unassigned")
        - Deadline: \(r.item.dueLabel ?? "none given")
        """
        if let quote = r.item.sourceQuote, !quote.isEmpty {
            out += "\n- What was said when it came up: \"\(quote)\""
        }
        out += """


        # Who's asking
        \(r.userName) — the person who recorded the meeting.\(r.item.owner.map { $0.caseInsensitiveCompare(r.userName) == .orderedSame ? " This item is theirs." : " This item is owned by \($0), so the question is how \(r.userName) should get it moving." } ?? "")

        \(contextBlocks(userContext: r.userContext, learnedContext: r.learnedContext))

        # The meeting it came from — \(r.meeting.title), \(Fmt.promptDate(r.meeting.startedAt, in: zone))
        \(r.summaryMarkdown)
        """
        if !r.otherOpenItems.isEmpty {
            let lines = r.otherOpenItems.prefix(15).map { "- \($0.task)\($0.owner.map { o in " (\(o))" } ?? "")" }
            out += """


            # Other things still open on this project
            \(lines.joined(separator: "\n"))
            """
        }
        out += """


        # Task
        Say how you'd handle this action item. Structure it as:
        - **Two to four concrete steps**, as a numbered list, in the order you'd do them. Each step is one sentence saying what to actually do — a specific person to ask, a specific thing to check, a specific decision to force. Not "gather requirements".
        - **First thing to check**, one short paragraph under a "### Before you start" heading: the assumption most likely to be wrong, the person whose answer changes the plan, or the dependency in the list above that this is really waiting on. Skip this section if there genuinely isn't one.
        - **A draft**, under a "### Draft" heading, when the task is mostly about sending something — an email, a Slack message, a meeting agenda, a ticket description. Write the actual text, ready to send, in a fenced code block. Use the real names you know from the context. Skip this section entirely when the task is not about sending something; don't invent a reason to write one.
        Rules:
        - Ground it in this project. If the context tells you who owns the system, who has to approve, or what the deadline is really driven by, use that. If it doesn't, don't pretend it does.
        - Where the transcript and context leave something genuinely unknown, say so in one clause and move on — don't hedge every sentence.
        - No preamble, no summary of the task, no closing encouragement. Start with the numbered list.
        - Under 250 words, not counting a draft.
        """
        return out
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
