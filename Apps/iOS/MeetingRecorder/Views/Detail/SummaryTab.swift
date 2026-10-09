import MeetingCore
import SwiftUI

struct SummaryTab: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var library: Library
    @EnvironmentObject var uploader: Uploader
    let meeting: Meeting

    var body: some View {
        let content = library.content(for: meeting.id)
        if let summary = content.summary {
            let export = MeetingDocuments.summaryExport(summaryMarkdown: summary, actionItems: meeting.actionItems, events: meeting.events)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Dates the summary found, as one-tap calendar events; the same list is in the Markdown
                    // as "## Upcoming", so leave that section out of what's rendered below.
                    if !meeting.events.isEmpty { UpcomingEventsView(meeting: meeting) }
                    MarkdownView(markdown: MeetingDocuments.removingSection(export, titled: MeetingDocuments.upcomingHeading))
                }
                .padding()
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if meeting.status.isBusy {
            VStack(spacing: 10) {
                ProgressView()
                Text(app.jobProgress[meeting.id] ?? meeting.status.label).foregroundStyle(.secondary)
            }
        } else if uploader.state(for: meeting.id) != nil {
            ContentUnavailableView("Not at the hub yet", systemImage: "arrow.up.circle",
                                   description: Text("The recording is summarized once it has uploaded."))
        } else if meeting.status == .ready {
            // The hub has a summary; this device just hasn't fetched it yet.
            ProgressView("Fetching the summary…")
        } else {
            ContentUnavailableView {
                Label("No summary yet", systemImage: "text.alignleft")
            } actions: {
                Button("Summarize Now") {
                    app.reprocess(meeting.id, steps: content.transcript.isEmpty ? JobStep.allCases : [.summarize])
                }
            }
        }
    }
}
