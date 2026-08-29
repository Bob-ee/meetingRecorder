import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @EnvironmentObject var settings: AppSettings
    @State private var claudeFound: String?

    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("Meetings folder") {
                    HStack {
                        Text(settings.storageRoot).truncationMode(.middle).lineLimit(1)
                        Button("Choose…", action: chooseFolder)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([store.rootURL]) }
                    }
                }
                Text("Plain Markdown + JSON, one folder per project, one per meeting. Point Claude Code at it directly.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("You") {
                TextField("Your name (label for your mic track)", text: $settings.userName)
            }

            Section("Transcription (on-device, free)") {
                Picker("Speech model", selection: $settings.asrVersion) {
                    Text("Parakeet v3 — 25 languages").tag("v3")
                    Text("Parakeet v2 — English only, slightly better recall").tag("v2")
                }
                Toggle("Echo cancellation on the mic track", isOn: $settings.echoCancellation)
                Text("Keeps other people's voices (from your speakers) out of your mic track. Turn off if your mic sounds odd.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Download models now") { app.downloadModels() }
                        .disabled(app.modelStatus != nil)
                    if let s = app.modelStatus { Text(s).font(.callout).foregroundStyle(.secondary) }
                }
                Text("Models cache in \(TranscriptionService.modelsDirectory.path)")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Section("Summaries (Claude Code, your subscription)") {
                Picker("Model", selection: $settings.claudeModel) {
                    Text("Sonnet (recommended)").tag("sonnet")
                    Text("Opus (slower, deeper)").tag("opus")
                    Text("Haiku (fastest)").tag("haiku")
                }
                TextField("Path to `claude` (blank = auto-detect)", text: $settings.claudePath)
                HStack {
                    Button("Test") { claudeFound = ClaudeSummarizer.locateClaude(override: settings.claudePath) ?? "not found" }
                    if let f = claudeFound { Text(f).font(.callout).foregroundStyle(f == "not found" ? .red : .secondary) }
                }
            }

            Section("Meeting detection") {
                Toggle("Prompt me when another app starts using the microphone", isOn: Binding(
                    get: { settings.autoDetect }, set: { app.setAutoDetect($0) }))
                Text("Works for Zoom, Google Meet, Slack huddles, Teams, FaceTime — anything that opens the mic.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding(.vertical, 8)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.storageRoot = url.path
            store.setRoot(url)
        }
    }
}
