import MeetingCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @Binding var selection: SidebarItem?
    @State private var renaming: Project?
    @State private var renameText = ""
    @State private var editingContext: Project?
    @State private var deleting: Project?
    @State private var dropTarget: UUID?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("All Meetings", systemImage: "tray.full").tag(SidebarItem.all)
                Label {
                    HStack {
                        Text("Action Items")
                        Spacer()
                        let open = store.meetings.reduce(0) { $0 + $1.openActionItems.count }
                        if open > 0 {
                            Text("\(open)").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(.quaternary))
                        }
                    }
                } icon: { Image(systemName: "checklist") }
                .tag(SidebarItem.actionItems)
            }
            Section("Projects") {
                ForEach(store.projects) { project in
                    Label {
                        HStack {
                            Text(project.name)
                            Spacer()
                            let n = store.meetings(in: project.id).count
                            if n > 0 { Text("\(n)").font(.caption2).foregroundStyle(.secondary) }
                        }
                    } icon: { Image(systemName: dropTarget == project.id ? "folder.fill.badge.plus" : "folder") }
                    .tag(SidebarItem.project(project.id))
                    .listRowBackground(dropTarget == project.id ? Color.accentColor.opacity(0.18) : nil)
                    .dropDestination(for: URL.self) { urls, _ in
                        let audio = urls.filter { AudioImporter.isAudioFile($0) }
                        guard !audio.isEmpty else { return false }
                        app.importAudio(urls: audio, into: project.id, move: false)
                        return true
                    } isTargeted: { over in
                        dropTarget = over ? project.id : (dropTarget == project.id ? nil : dropTarget)
                    }
                    .contextMenu {
                        Button("Rename…") { renameText = project.name; renaming = project }
                        Button("Edit Project Context…") { editingContext = project }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([store.rootURL.appendingPathComponent(Fmt.sanitizeFilename(project.name))])
                        }
                        Divider()
                        Button("Move to Trash", role: .destructive) { deleting = project }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { app.requestNewProject = true } label: { Label("New Project", systemImage: "plus") }
                    .help("New project (⇧⌘N)")
            }
        }
        .alert("Rename Project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let p = renaming { store.renameProject(p.id, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Move “\(deleting?.name ?? "")” to Trash?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let p = deleting {
                    if selection == .project(p.id) { selection = .all }
                    store.deleteProject(p.id)
                }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("All of its meetings, recordings and notes go to the Trash with it.")
        }
        .sheet(item: $editingContext) { project in
            ProjectContextEditor(project: project)
        }
    }
}

/// Two notes sit behind every summary: the one the user writes, and the one the summarizer keeps for itself.
/// They're separate files on purpose — the model rewrites its own after each meeting and never touches the user's.
struct ProjectContextEditor: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var pane: Pane = .yours
    @State private var text = ""
    @State private var learned = ""

    enum Pane: String, CaseIterable, Identifiable {
        case yours = "Yours", learned = "Written by Claude"
        var id: String { rawValue }
    }

    private var refreshing: Bool { pipeline.updatingContext.contains(project.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Project context — \(project.name)").font(.headline)
            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch pane {
            case .yours:
                Text("Who's who, jargon, goals, what matters. Claude reads this before summarizing every meeting in this project, like Claude project instructions. It wins wherever it disagrees with the note on the other tab.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .frame(minHeight: 240)
            case .learned:
                Text("What Claude has worked out about this project from the meetings themselves. It rewrites this after each one, keeping only what's still true. Edit it freely — your version is what the next summary reads.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $learned)
                    .font(.body.monospaced())
                    .frame(minHeight: 240)
                    .overlay {
                        if refreshing {
                            ProgressView("Rewriting from the latest meeting…")
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 8).fill(.background.opacity(0.9)))
                        }
                    }
                HStack(spacing: 12) {
                    if let note = store.learnedContextNote(project.id) {
                        Text(note).lineLimit(2).foregroundStyle(.secondary)
                    } else if learned.isEmpty {
                        Text("Nothing yet — it gets written after the next meeting is summarized.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revert") {
                        store.revertLearnedContext(project.id)
                        learned = store.learnedContext(project.id)
                    }
                    .disabled(store.previousLearnedContext(project.id) == nil)
                    .help("Put the previous version back")
                    Button("Rewrite Now") { pipeline.refreshProjectContext(project.id) }
                        .disabled(refreshing)
                        .help("Re-derive this note from the project's most recent summarized meeting")
                }
                .font(.caption)
                .buttonStyle(.link)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 620, height: 520)
        .onAppear {
            text = store.projectContext(project.id)
            learned = store.learnedContext(project.id)
        }
        // A rewrite finishing while the sheet is open should show up in it.
        .onChange(of: refreshing) { _, running in
            if !running { learned = store.learnedContext(project.id) }
        }
    }

    private func save() {
        if text != store.projectContext(project.id) { store.setProjectContext(project.id, text) }
        if learned != store.learnedContext(project.id) {
            store.setLearnedContext(project.id, learned, note: "Edited by you.")
        }
        dismiss()
    }
}
