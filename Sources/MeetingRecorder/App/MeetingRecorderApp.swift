import MeetingCore
import SwiftUI

@main
struct MeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState.shared

    var body: some Scene {
        WindowGroup("Meeting Recorder", id: "main") {
            MainView()
                .environmentObject(app)
                .environmentObject(app.store)
                .environmentObject(app.recorder)
                .environmentObject(app.pipeline)
                .environmentObject(app.settings)
                .frame(minWidth: 980, minHeight: 600)
        }
        .handlesExternalEvents(matching: ["open"])
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { app.requestNewProject = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Import Audio File…") { app.importAudio() }
                    .keyboardShortcut("i", modifiers: [.command])
            }
            CommandMenu("Recording") {
                if app.recorder.isRecording {
                    Button("Stop Recording") { app.recorder.stop() }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                } else {
                    Button("Start Recording") { app.startRecording(projectID: nil) }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                }
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(app)
                .environmentObject(app.store)
                .environmentObject(app.recorder)
        } label: {
            Image(systemName: app.recorder.isRecording ? "record.circle.fill" : "waveform.circle")
        }

        Settings {
            SettingsView()
                .environmentObject(app)
                .environmentObject(app.store)
                .environmentObject(app.settings)
        }
    }
}
