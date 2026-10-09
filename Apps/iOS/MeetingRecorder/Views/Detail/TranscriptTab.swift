import MeetingCore
import SwiftUI

struct TranscriptTab: View {
    @EnvironmentObject var library: Library
    let meeting: Meeting
    @State private var renaming: String?
    @State private var renameText = ""

    var body: some View {
        let segments = library.content(for: meeting.id).transcript
        if segments.isEmpty {
            ContentUnavailableView(meeting.status.isBusy ? "Transcribing…" : "No transcript yet", systemImage: "text.quote")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    speakers(Array(Set(segments.map(\.speaker))).sorted())
                    ForEach(segments) { segment in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(meeting.displayName(forSpeaker: segment.speaker))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(SpeakerColor.color(for: segment.speaker))
                                Text(Fmt.timestamp(segment.start))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            Text(segment.text).textSelection(.enabled)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: 800, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .alert("Rename \(renaming ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Rename") {
                    if let speaker = renaming { library.renameSpeaker(speaker, to: renameText, in: meeting.id) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                Text("Leave empty to restore the default label.")
            }
        }
    }

    /// One chip per voice; tap to say whose it is.
    private func speakers(_ speakers: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(speakers, id: \.self) { speaker in
                    Button {
                        renameText = meeting.speakerNames[speaker] ?? ""
                        renaming = speaker
                    } label: {
                        Label(meeting.displayName(forSpeaker: speaker), systemImage: "pencil")
                            .labelStyle(.titleAndIcon)
                            .font(.callout)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(SpeakerColor.color(for: speaker).opacity(0.15)))
                            .foregroundStyle(SpeakerColor.color(for: speaker))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

enum SpeakerColor {
    static let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .mint, .brown]

    static func color(for speaker: String) -> Color {
        if speaker == "You" || !speaker.hasPrefix("Speaker ") { return .accentColor }
        let n = Int(speaker.dropFirst("Speaker ".count)) ?? 0
        return palette[(max(n, 1) - 1) % palette.count]
    }
}
