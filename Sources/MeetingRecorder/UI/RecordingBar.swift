import MeetingCore
import SwiftUI

struct RecordingBar: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            bar
            if let warning = recorder.captureWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
        }
        .background(.red.opacity(0.08))
    }

    private var bar: some View {
        HStack(spacing: 14) {
            Circle().fill(.red).frame(width: 10, height: 10)
                .opacity(Int(recorder.elapsed * 2) % 2 == 0 ? 1 : 0.35)
            Text("Recording")
                .fontWeight(.semibold)
            if let m = recorder.current, let p = store.project(m.projectID) {
                Text("into \(p.name)").foregroundStyle(.secondary)
            }
            Text(Fmt.duration(recorder.elapsed)).monospacedDigit()
            Spacer()
            LevelMeter(label: "Mic", level: recorder.micLevel, active: recorder.micActive)
            LevelMeter(label: "System", level: recorder.systemLevel, active: recorder.systemActive)
            Button {
                recorder.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

struct LevelMeter: View {
    let label: String
    let level: Float
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(active ? Color.green : Color.gray)
                        .frame(width: geo.size.width * CGFloat(min(1, Double(level) * 6)))
                }
            }
            .frame(width: 70, height: 8)
            if !active { Image(systemName: "xmark.circle").foregroundStyle(.secondary).help("\(label) not being captured") }
        }
    }
}
