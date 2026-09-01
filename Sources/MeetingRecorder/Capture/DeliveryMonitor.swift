import Foundation

/// Records when a track last handed us audio. The capture callbacks run on realtime audio threads and
/// the watchdog reads this from the main actor, so it is behind a lock.
///
/// A track that stops delivering is how CoreAudio reports that it dropped us — there is no error and no
/// callback, the buffers simply stop and `TimelineWriter` pads the rest of the file with silence.
final class DeliveryMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var lastBuffer: Date?
    private var begunAt = Date()

    /// Call when capture starts or restarts, before any buffer can arrive.
    func begin() {
        lock.lock(); defer { lock.unlock() }
        lastBuffer = nil
        begunAt = Date()
    }

    /// Call from the audio thread for every buffer.
    func mark() {
        lock.lock(); defer { lock.unlock() }
        lastBuffer = Date()
    }

    /// Seconds since audio last arrived — measured from the start if none ever has.
    var silentFor: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastBuffer ?? begunAt)
    }

    var hasDelivered: Bool {
        lock.lock(); defer { lock.unlock() }
        return lastBuffer != nil
    }
}
