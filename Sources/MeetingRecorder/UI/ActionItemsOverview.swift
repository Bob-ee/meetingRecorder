import SwiftUI

/// Every open action item across all projects, grouped by meeting.
struct ActionItemsOverview: View {
    @EnvironmentObject var store: Store
    @Binding var selectedMeetingID: UUID?
    @State private var showDone = false

    var body: some View {
        let meetings = store.meetings.filter { m in showDone ? !m.actionItems.isEmpty : !m.openActionItems.isEmpty }
        VStack(spacing: 0) {
            HStack {
                Text("Action Items").font(.headline)
                Spacer()
                Toggle("Show done", isOn: $showDone).toggleStyle(.checkbox).font(.callout)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if meetings.isEmpty {
                Text("Nothing open 🎉").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedMeetingID) {
                    ForEach(meetings) { meeting in
                        Section {
                            ForEach(showDone ? meeting.actionItems : meeting.openActionItems) { item in
                                ActionItemRow(item: item) { updated in
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
                        } header: {
                            HStack {
                                Text(meeting.title)
                                Spacer()
                                Text(Fmt.dateOnly.string(from: meeting.startedAt)).foregroundStyle(.secondary)
                                if let p = store.project(meeting.projectID) { Text("· \(p.name)").foregroundStyle(.secondary) }
                            }
                            .font(.caption)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}
