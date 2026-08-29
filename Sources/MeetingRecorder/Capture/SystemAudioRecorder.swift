import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Captures everything the system plays (Zoom, Meet in Chrome, Slack huddles…)
/// with a Core Audio process tap (macOS 14.2+). No virtual audio drivers needed.
/// The tap may deliver nothing while no app is playing audio; `TimelineWriter` fills those
/// stretches with silence so the track stays aligned with the microphone track.
final class SystemAudioRecorder {
    private(set) var isRunning = false
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: TimelineWriter?
    private let queue = DispatchQueue(label: "meetingrecorder.systemaudio", qos: .userInitiated)
    var levelHandler: ((Float) -> Void)?

    func start(writingTo url: URL, clock: RecordingClock) throws {
        guard !isRunning else { return }

        // Exclude our own process so nothing we play ends up in the file.
        var excluded: [AudioObjectID] = []
        if let me = try? CoreAudioUtil.processObject(forPID: ProcessInfo.processInfo.processIdentifier) {
            excluded = [me]
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "Meeting Recorder Tap"
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioUtil.check(AudioHardwareCreateProcessTap(description, &tap), "create process tap")
        tapID = tap

        do {
            let outputUID = try CoreAudioUtil.defaultOutputDeviceUID()
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Meeting Recorder Aggregate",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            var aggregate = AudioObjectID(kAudioObjectUnknown)
            try CoreAudioUtil.check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate), "create aggregate device")
            aggregateID = aggregate

            var asbd = try CoreAudioUtil.tapFormat(tapID)
            guard let format = AVAudioFormat(streamDescription: &asbd) else {
                throw CoreAudioError(status: -1, what: "tap format")
            }
            Log.capture.info("system tap format: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch, float=\(format.commonFormat == .pcmFormatFloat32, privacy: .public), interleaved=\(format.isInterleaved, privacy: .public)")

            let writer = try TimelineWriter(url: url, sampleRate: format.sampleRate, clock: clock)
            self.writer = writer
            let levelHandler = self.levelHandler
            var procID: AudioDeviceIOProcID?
            try CoreAudioUtil.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inInputData, inInputTime, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else { return }
                let ts = inInputTime.pointee
                let hostTime = ts.mFlags.contains(.hostTimeValid) ? ts.mHostTime : 0
                writer.write(buffer, hostTime: hostTime)
                if let levelHandler { levelHandler(AudioMix.rms(buffer)) }
            }, "create IO proc")
            ioProcID = procID
            try CoreAudioUtil.check(AudioDeviceStart(aggregateID, procID), "start aggregate device")
            isRunning = true
        } catch {
            teardown()
            throw error
        }
    }

    /// Returns seconds of audio written (including silence padding).
    @discardableResult
    func stop(totalSeconds: Double) -> Double {
        guard isRunning else { teardown(); return 0 }
        isRunning = false
        teardown()
        writer?.finish(totalSeconds: totalSeconds)
        let seconds = writer?.seconds ?? 0
        writer = nil
        return seconds
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID = ioProcID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
