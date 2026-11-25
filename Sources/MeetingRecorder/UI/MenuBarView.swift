import MeetingCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var next: NextMeeting
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let meeting = next.upcoming {
            Text(meeting.title)
            Text("\(Fmt.time.string(from: meeting.start)) · \(MenuBarTitle.countdown(to: meeting.start, from: Date()))")
            if !recorder.isRecording {
                Button("Record this meeting") { app.startRecording(projectID: nil, title: meeting.title) }
            }
            Divider()
        } else if next.needsAccess && app.settings.showNextMeeting {
            Button("Allow Calendar access to show your next meeting…") { next.requestAccess() }
            Divider()
        }
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

/// The status item itself: the icon, plus "Design review · in 12m" when there's a meeting later today.
struct MenuBarLabel: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var next: NextMeeting

    var body: some View {
        let icon = recorder.isRecording ? "record.circle.fill" : "waveform.circle"
        if let label = next.label {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(label)
            }
        } else {
            Image(systemName: icon)
        }
    }
}
