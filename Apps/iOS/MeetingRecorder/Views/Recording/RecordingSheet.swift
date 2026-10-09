import MeetingCore
import SwiftUI

/// What's on screen while a meeting is being recorded. Closing it doesn't stop the recording — the banner
/// that replaces it brings it back.
struct RecordingSheet: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var library: Library
    @EnvironmentObject var recorder: Recorder
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDiscard = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                if let error = recorder.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                } else {
                    Text(recorder.isPaused ? "Paused" : recorder.isRecording ? "Recording" : "Starting…")
                        .font(.headline)
                        .foregroundStyle(recorder.isPaused ? Color.secondary : Color.red)
                }
                Text(Fmt.timestamp(recorder.elapsed))
                    .font(.system(size: 64, weight: .light, design: .rounded))
                    .monospacedDigit()
                LevelMeter(level: recorder.level)
                    .frame(height: 10)
                    .padding(.horizontal, 40)
                Picker("Project", selection: $app.recordingProjectID) {
                    ForEach(library.projects) { Text($0.project.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
                Spacer()
                controls
                Text("Recording continues with the screen locked. It uploads to your hub when you stop.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .navigationTitle("New Meeting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Discard", role: .destructive) { confirmingDiscard = true }.disabled(!recorder.isRecording)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Label("Hide", systemImage: "chevron.down") }
                }
            }
            .confirmationDialog("Discard this recording?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard Recording", role: .destructive) {
                    recorder.discard()
                    dismiss()
                }
            }
        }
        .interactiveDismissDisabled(false)
    }

    private var controls: some View {
        HStack(spacing: 40) {
            Button {
                if recorder.isPaused { recorder.resume() } else { recorder.pause() }
            } label: {
                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                    .font(.title)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(Color(.secondarySystemBackground)))
            }
            .accessibilityLabel(recorder.isPaused ? "Resume" : "Pause")
            Button {
                recorder.stop()
                dismiss()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(.red))
            }
            .accessibilityLabel("Stop and upload")
        }
        .buttonStyle(.plain)
        .disabled(!recorder.isRecording)
    }
}

/// How loud the room is, so it's obvious at a glance that the microphone is hearing something.
struct LevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.secondarySystemBackground))
                Capsule().fill(level > 0.9 ? Color.orange : Color.green)
                    .frame(width: geometry.size.width * level)
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
    }
}

/// The strip across the top of the app while a recording is running out of sight.
struct RecordingBanner: View {
    @EnvironmentObject var recorder: Recorder
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: recorder.isPaused ? "pause.circle.fill" : "record.circle.fill")
                Text(recorder.isPaused ? "Recording paused" : "Recording")
                Text(Fmt.timestamp(recorder.elapsed)).monospacedDigit()
                Spacer()
                Image(systemName: "chevron.up")
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal).padding(.vertical, 8)
            .background(Color.red)
        }
        .buttonStyle(.plain)
    }
}
