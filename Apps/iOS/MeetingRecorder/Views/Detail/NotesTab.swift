import SwiftUI

struct NotesTab: View {
    @EnvironmentObject var library: Library
    let meetingID: UUID
    @State private var text = ""
    @State private var pending: Task<Void, Never>?
    @FocusState private var editing: Bool

    private var saved: String { library.record(meetingID)?.notes ?? "" }

    var body: some View {
        TextEditor(text: $text)
            .focused($editing)
            .padding(.horizontal, 12)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Your own notes — saved automatically")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 17).padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { text = saved }
            .onDisappear(perform: save)
            .onChange(of: text) { _, _ in saveSoon() }
            // Notes written on another device arrive while this one is open; take them unless mid-sentence here.
            .onChange(of: saved) { _, new in if !editing, pending == nil { text = new } }
    }

    /// Typing shouldn't mean a write, and a sync, per keystroke.
    private func saveSoon() {
        guard text != saved else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled { save() }
        }
    }

    private func save() {
        pending?.cancel()
        pending = nil
        if text != saved { library.setNotes(text, for: meetingID) }
    }
}
