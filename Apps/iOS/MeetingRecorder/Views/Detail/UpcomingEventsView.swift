import MeetingCore
import SwiftUI

/// The "Upcoming" block at the top of the summary: one card per date the summary found.
struct UpcomingEventsView: View {
    @EnvironmentObject var library: Library
    let meeting: Meeting

    var body: some View {
        let events = meeting.upcomingEvents
        let hidden = meeting.events.count - events.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(MeetingDocuments.upcomingHeading, systemImage: "calendar").font(.headline)
                Spacer()
                if hidden > 0 {
                    Button(hidden == 1 ? "1 hidden" : "\(hidden) hidden") { library.restoreHiddenEvents(in: meeting.id) }
                        .font(.caption)
                }
            }
            ForEach(events) { event in
                EventCard(event: event, meeting: meeting)
            }
        }
    }
}

struct EventCard: View {
    @EnvironmentObject var library: Library
    let event: MeetingEvent
    let meeting: Meeting
    @State private var adding = false

    private var added: Bool { event.addedAt != nil }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DateTile(date: event.start.date, zone: event.isAllDay ? event.start.tz : .current)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).fontWeight(.medium).lineLimit(2)
                Text(Fmt.when(event.start, end: event.end))
                    .font(.callout).foregroundStyle(.secondary)
                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                if let context = event.context, !context.isEmpty {
                    Text(context).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button { adding = true } label: {
                if added {
                    Label("Added", systemImage: "checkmark").foregroundStyle(.green)
                } else {
                    Label("Add", systemImage: "plus")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemBackground)))
        .contextMenu {
            Button(added ? "Add to Calendar Again…" : "Add to Calendar…") { adding = true }
            Divider()
            Button("Hide", systemImage: "eye.slash") { var e = event; e.dismissed = true; library.update(e, in: meeting.id) }
        }
        .sheet(isPresented: $adding) {
            EventEditor(draft: EventDraft(event: event, meeting: meeting)) {
                var e = event
                e.addedAt = Date()
                library.update(e, in: meeting.id)
            }
            .ignoresSafeArea()
        }
    }
}

/// Calendar-app-style tile: month over day number.
struct DateTile: View {
    let date: Date
    var zone: TimeZone = .current

    var body: some View {
        var cal = Calendar.current
        cal.timeZone = zone
        let month = DateFormatter()
        month.timeZone = zone
        month.setLocalizedDateFormatFromTemplate("MMM")
        return VStack(spacing: 0) {
            Text(month.string(from: date).uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(Color.red)
            Text("\(cal.component(.day, from: date))")
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 40, height: 40)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary))
    }
}
