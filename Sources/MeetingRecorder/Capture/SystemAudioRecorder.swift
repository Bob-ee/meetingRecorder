import Foundation
import MeetingCore
import MeetingEngine
import AVFoundation
import CoreAudio
import AudioToolbox

/// Captures everything the system plays (Zoom, Meet in Chrome, Slack huddles…)
/// with a Core Audio process tap (macOS 14.2+). No virtual audio drivers needed.
/// The tap may deliver nothing while no app is playing audio; `TimelineWriter` fills those
/// stretches with silence so the track stays aligned with the microphone track.
///
/// Because silence is normal here, a dead tap can't be spotted from the buffers alone — ask
/// `isDeviceRunning`, which reports whether the aggregate's IO thread is still alive. CoreAudio stops
/// that thread whenever it rebuilds the output device's streams and does not always manage to start it
/// again, at which point the rest of the recording would be silence.
final class SystemAudioRecorder {
    private(set) var isRunning = false
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: TimelineWriter?
    private let queue = DispatchQueue(label: "meetingrecorder.systemaudio", qos: .userInitiated)
    let delivery = DeliveryMonitor()
    var levelHandler: ((Float) -> Void)?

    func start(writingTo url: URL, clock: RecordingClock) throws {
        guard !isRunning else { return }
        let format = try openTap()
        let writer = try TimelineWriter(url: url, sampleRate: format.sampleRate, clock: clock)
        do {
            try startIO(format: format, writing: writer)
        } catch {
            teardown()
            writer.finish(totalSeconds: 0)
            throw error
        }
        self.writer = writer
        isRunning = true
    }

    /// True while the aggregate device's IO thread is alive. A tap that is running but quiet is normal;
    /// one that has stopped is not, and nothing will be captured until it is rebuilt.
    var isDeviceRunning: Bool {
        guard isRunning, aggregateID != kAudioObjectUnknown else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunning,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    /// Rebuilds the tap and aggregate around the track already being written, so the recording keeps its
    /// place on the clock and the missed stretch shows up as silence.
    @discardableResult
    func restart() -> Bool {
        guard isRunning, let writer else { return false }
        teardown()
        do {
            let format = try openTap()
            if format.sampleRate != writer.sampleRate {
                Log.capture.notice("system tap came back at \(format.sampleRate) Hz — resampling to the track's \(writer.sampleRate) Hz")
            }
            try startIO(format: format, writing: writer)
            Log.capture.notice("system audio capture restarted")
            return true
        } catch {
            Log.capture.error("system audio restart failed: \(error.localizedDescription)")
            teardown()
            return false
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

    /// Creates the process tap and the aggregate device that carries it, and returns the tap's format.
    private func openTap() throws -> AVAudioFormat {
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
            Log.capture.notice("system tap format: \(format.sampleRate) Hz, \(format.channelCount) ch, float=\(format.commonFormat == .pcmFormatFloat32), interleaved=\(format.isInterleaved)")
            return format
        } catch {
            teardown()
            throw error
        }
    }

    private func startIO(format: AVAudioFormat, writing writer: TimelineWriter) throws {
        let levelHandler = self.levelHandler
        let delivery = self.delivery
        delivery.begin()
        var procID: AudioDeviceIOProcID?
        try CoreAudioUtil.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inInputData, inInputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else { return }
            delivery.mark()
            let ts = inInputTime.pointee
            let hostTime = ts.mFlags.contains(.hostTimeValid) ? ts.mHostTime : 0
            writer.write(buffer, hostTime: hostTime)
            if let levelHandler { levelHandler(AudioMix.rms(buffer)) }
        }, "create IO proc")
        ioProcID = procID
        try CoreAudioUtil.check(AudioDeviceStart(aggregateID, procID), "start aggregate device")
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
