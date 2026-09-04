import MeetingCore
import SwiftUI

/// Open action items — either every project's, or one project's. Grouping by meeting answers "what came out of
/// that call"; grouping by deadline or owner answers "what is this project waiting on", which is the question a
/// project-wide list is usually being asked.
struct ActionItemsOverview: View {
    @EnvironmentObject var store: Store
    /// nil = every project.
    var projectID: UUID?
    @Binding var selectedMeetingID: UUID?
    @State private var showDone = false
    @State private var grouping: Grouping?

    enum Grouping: String, CaseIterable, Identifiable {
        case due = "Due", owner = "Owner", meeting = "Meeting"
        var id: String { rawValue }
    }

    /// A project's list opens by deadline; the all-projects list keeps its meeting grouping.
    private var effectiveGrouping: Grouping { grouping ?? (projectID == nil ? .meeting : .due) }

    private var rows: [ActionItemGrouping.Row] {
        store.meetings(in: projectID).flatMap { meeting in
            (showDone ? meeting.actionItems : meeting.openActionItems).map { (item: $0, meeting: meeting) }
        }
    }

    var body: some View {
        let grouped = ActionItemGrouping.sections(rows, by: effectiveGrouping)
        VStack(spacing: 0) {
            HStack {
                Text("Action Items").font(.headline)
                Spacer()
                Picker("", selection: Binding(get: { effectiveGrouping }, set: { grouping = $0 })) {
                    ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("Group by")
                Toggle("Show done", isOn: $showDone).toggleStyle(.checkbox).font(.callout)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if grouped.isEmpty {
                Text(projectID == nil ? "Nothing open 🎉" : "Nothing open in this project 🎉")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedMeetingID) {
                    ForEach(grouped) { section in
                        Section {
                            ForEach(section.rows, id: \.item.id) { row in
                                self.row(row)
                            }
                        } header: {
                            header(section)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func row(_ row: ActionItemGrouping.Row) -> some View {
        let meeting = row.meeting
        let item = row.item
        return ActionItemRow(item: item, meeting: meeting, showMeeting: effectiveGrouping != .meeting) { updated in
            var m = meeting
            if let i = m.actionItems.firstIndex(where: { $0.id == item.id }) { m.actionItems[i] = updated }
            store.update(m)
        } delete: {
            var m = meeting
            m.actionItems.removeAll { $0.id == item.id }
            store.update(m)
        }
        .tag(meeting.id)
    }

    private func header(_ section: ActionItemGrouping.Section) -> some View {
        HStack {
            Text(section.title)
            Spacer()
            if let trailing = section.trailing { Text(trailing).foregroundStyle(.secondary) }
        }
        .font(.caption)
    }
}

/// Sorting open items into the sections each grouping calls for.
enum ActionItemGrouping {
    typealias Row = (item: ActionItem, meeting: Meeting)

    struct Section: Identifiable {
        var id: String
        var title: String
        var trailing: String?
        var rows: [Row]
    }

    static func sections(_ rows: [Row], by grouping: ActionItemsOverview.Grouping) -> [Section] {
        switch grouping {
        case .meeting: return byMeeting(rows)
        case .owner: return byOwner(rows)
        case .due: return byDue(rows)
        }
    }

    private static func byMeeting(_ rows: [Row]) -> [Section] {
        let groups = Dictionary(grouping: rows, by: { $0.meeting.id })
        return groups.values
            .sorted { ($0.first?.meeting.startedAt ?? .distantPast) > ($1.first?.meeting.startedAt ?? .distantPast) }
            .compactMap { group in
                guard let meeting = group.first?.meeting else { return nil }
                return Section(id: meeting.id.uuidString, title: meeting.title,
                               trailing: Fmt.dateOnly.string(from: meeting.startedAt), rows: group)
            }
    }

    private static func byOwner(_ rows: [Row]) -> [Section] {
        let groups = Dictionary(grouping: rows) { row -> String in
            let owner = row.item.owner?.trimmingCharacters(in: .whitespaces) ?? ""
            return owner.isEmpty ? "" : owner
        }
        return groups.keys
            .sorted { a, b in
                if a.isEmpty != b.isEmpty { return b.isEmpty }   // unassigned last
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
            .map { owner in
                let group = (groups[owner] ?? []).sorted(by: sortByDeadline)
                return Section(id: owner.isEmpty ? "·unassigned" : owner,
                               title: owner.isEmpty ? "Unassigned" : owner,
                               trailing: "\(group.count)", rows: group)
            }
    }

    /// Buckets relative to today, so the top of the list is what has already slipped.
    private static func byDue(_ rows: [Row]) -> [Section] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let today = cal.startOfDay(for: Date())
        let weekEnd = cal.date(byAdding: .day, value: 7, to: today) ?? today

        var buckets: [(id: String, title: String, rows: [Row])] = [
            ("overdue", "Overdue", []), ("today", "Today", []), ("week", "Next 7 days", []),
            ("later", "Later", []), ("none", "No deadline", []),
        ]
        for row in rows {
            guard let due = row.item.dueDate?.date(in: .current) else { buckets[4].rows.append(row); continue }
            let day = cal.startOfDay(for: due)
            if day < today { buckets[0].rows.append(row) }
            else if day == today { buckets[1].rows.append(row) }
            else if day < weekEnd { buckets[2].rows.append(row) }
            else { buckets[3].rows.append(row) }
        }
        return buckets.filter { !$0.rows.isEmpty }.map {
            Section(id: $0.id, title: $0.title, trailing: "\($0.rows.count)", rows: $0.rows.sorted(by: sortByDeadline))
        }
    }

    /// Soonest deadline first, undated last, then oldest meeting first so long-running items surface.
    private static func sortByDeadline(_ a: Row, _ b: Row) -> Bool {
        switch (a.item.dueDate?.date, b.item.dueDate?.date) {
        case let (x?, y?) where x != y: return x < y
        case (nil, _?): return false
        case (_?, nil): return true
        default: return a.meeting.startedAt < b.meeting.startedAt
        }
    }
}
