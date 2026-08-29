import MeetingCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @EnvironmentObject var recorder: Recorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if recorder.isRecording {
            Text("Recording · \(Fmt.duration(recorder.elapsed))")
            Button("Stop Recording") { recorder.stop() }
        } else {
            if let detected = app.detectedApp {
                Text("\(detected) is using the mic")
                Button("Record this meeting") { app.recordFromDetection() }
                Divider()
            }
            Button("Start Recording") { app.startRecording(projectID: nil) }
            Menu("Record into…") {
                ForEach(store.projects) { p in
                    Button(p.name) { app.startRecording(projectID: p.id) }
                }
            }
        }
        Divider()
        Button("Open Meeting Recorder") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Toggle("Detect meetings automatically", isOn: Binding(get: { app.settings.autoDetect }, set: { app.setAutoDetect($0) }))
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
