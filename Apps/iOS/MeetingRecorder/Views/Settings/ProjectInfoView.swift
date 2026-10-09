import MeetingCore
import SwiftUI

/// Two notes sit behind every summary: the one the user writes, and the one the summarizer keeps for itself.
/// The first is edited here; the second is the hub's, shown so it can be checked and rewritten on request.
struct ProjectInfoView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    @State private var name = ""
    @State private var context = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Project name", text: $name)
                }
                Section {
                    TextEditor(text: $context)
                        .font(.callout.monospaced())
                        .frame(minHeight: 160)
                } header: {
                    Text("Your context")
                } footer: {
                    Text("Who's who, jargon, goals, what matters. Claude reads this before summarizing every meeting in this project. It wins wherever it disagrees with the note below.")
                }
                Section {
                    let learned = library.project(projectID)?.learnedContext ?? ""
                    if learned.isEmpty {
                        Text("Nothing yet — it gets written after the next meeting is summarized.").foregroundStyle(.secondary)
                    } else {
                        MarkdownView(markdown: learned).font(.callout)
                    }
                    Button("Rewrite Now") { app.refreshContext(of: projectID) }
                } header: {
                    Text("Written by Claude")
                } footer: {
                    Text("What Claude has worked out about this project from the meetings themselves. It rewrites this after each one, keeping only what's still true.")
                }
            }
            .navigationTitle("Project Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .onAppear {
                name = library.project(projectID)?.project.name ?? ""
                context = library.project(projectID)?.context ?? ""
            }
        }
    }

    private func save() {
        let name = name.trimmingCharacters(in: .whitespaces)
        library.edit(project: projectID) { project in
            if !name.isEmpty { project.project.name = name }
            project.context = context
        }
        dismiss()
    }
}
