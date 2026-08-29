import Foundation
import CoreAudio
import AudioToolbox

struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let what: String
    var errorDescription: String? { "\(what) failed (OSStatus \(status))" }
}

enum CoreAudioUtil {
    static func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw CoreAudioError(status: status, what: what) }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) throws -> AudioObjectID {
        var addr = address(selector)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device), "get default device")
        guard device != kAudioObjectUnknown else { throw CoreAudioError(status: -1, what: "no default device") }
        return device
    }

    static func deviceUID(_ device: AudioObjectID) throws -> String {
        var addr = address(kAudioDevicePropertyDeviceUID)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        try withUnsafeMutablePointer(to: &uid) { ptr in
            try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr), "read device UID")
        }
        return uid as String
    }

    static func defaultOutputDeviceUID() throws -> String {
        try deviceUID(try defaultDevice(kAudioHardwarePropertyDefaultOutputDevice))
    }

    static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var addr = address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd), "read tap format")
        return asbd
    }

    static func processObject(forPID pid: pid_t) throws -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pidValue = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                             UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &object), "translate pid")
        return object
    }

    /// True when any process (including ours) has the default input device running.
    static func defaultInputIsInUse() -> Bool {
        guard let device = try? defaultDevice(kAudioHardwarePropertyDefaultInputDevice) else { return false }
        var addr = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}
