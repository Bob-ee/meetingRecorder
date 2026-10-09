import MeetingCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var library: Library
    @Binding var selection: SidebarItem?
    @State private var showingSettings = false
    @State private var importing = false
    @State private var creating = false
    @State private var newProjectName = ""
    @State private var renaming: Project?
    @State private var renameText = ""
    @State private var editingContext: Project?
    @State private var deleting: Project?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("All Meetings", systemImage: "tray.full").tag(SidebarItem.all)
                Label("Action Items", systemImage: "checklist")
                    .badge(library.meetings.reduce(0) { $0 + $1.meeting.openActionItems.count })
                    .tag(SidebarItem.actionItems)
            }
            Section("Projects") {
                ForEach(library.projects) { detail in
                    let project = detail.project
                    Label(project.name, systemImage: "folder")
                        .badge(library.meetings(in: project.id).count)
                        .tag(SidebarItem.project(project.id))
                        .contextMenu {
                            Button("Rename…") { renameText = project.name; renaming = project }
                            Button("Edit Project Context…") { editingContext = project }
                            Divider()
                            Button("Delete", role: .destructive) { deleting = project }
                        }
                }
            }
        }
        .navigationTitle("Meeting Recorder")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { creating = true } label: { Label("New Project", systemImage: "folder.badge.plus") }
                    Button { importing = true } label: { Label("Import Recording…", systemImage: "square.and.arrow.down") }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(item: $editingContext) { ProjectInfoView(projectID: $0.id) }
        .fileImporter(isPresented: $importing, allowedContentTypes: AudioImport.contentTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let projectID: UUID? = if case .project(let id) = selection { id } else { nil }
            for url in urls { app.importRecording(url, into: projectID) }
        }
        .alert("New Project", isPresented: $creating) {
            TextField("Project name", text: $newProjectName)
            Button("Create") {
                if let project = library.createProject(name: newProjectName) { selection = .project(project.id) }
                newProjectName = ""
            }
            Button("Cancel", role: .cancel) { newProjectName = "" }
        } message: {
            Text("Projects group related meetings, like Claude projects group chats.")
        }
        .alert("Rename Project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                if let project = renaming, !name.isEmpty { library.edit(project: project.id) { $0.project.name = name } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let project = deleting {
                    if selection == .project(project.id) { selection = .all }
                    library.deleteProject(project.id)
                }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("All of its meetings, recordings and notes are deleted with it, on every device.")
        }
    }
}
