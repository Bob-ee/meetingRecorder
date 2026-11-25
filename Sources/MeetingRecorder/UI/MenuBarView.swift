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
/// In the last minute it alternates every second between its normal look and a red pill, unless you're
/// already recording.
struct MenuBarLabel: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var next: NextMeeting

    var body: some View {
        let icon = recorder.isRecording ? "record.circle.fill" : "waveform.circle"
        if let label = next.label {
            if next.flashing && !recorder.isRecording,
               let image = Self.render(icon: icon, text: label, highlighted: next.flashPhase) {
                Image(nsImage: image)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                    Text(label)
                }
            }
        } else {
            Image(systemName: icon)
        }
    }

    /// The menu bar only draws SwiftUI labels as monochrome templates, so colour has to come in as a picture.
    /// Both phases are drawn the same size, so the items beside ours don't shuffle as it flashes; the plain
    /// phase stays a template image so it still follows a light or dark menu bar.
    @MainActor
    private static func render(icon: String, text: String, highlighted: Bool) -> NSImage? {
        let content = HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(highlighted ? Color.white : Color.black)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 5).fill(highlighted ? Color.red : Color.clear))
        .fixedSize()

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = !highlighted
        return image
    }
}
