import Foundation
import MeetingCore

/// Fan-out of hub events to server-sent-event subscribers.
actor EventBus {
    private var subscribers: [UUID: AsyncStream<HubEvent>.Continuation] = [:]
    private var keepalive: Task<Void, Never>?

    func subscribe() -> (id: UUID, stream: AsyncStream<HubEvent>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<HubEvent>.makeStream(bufferingPolicy: .bufferingNewest(200))
        subscribers[id] = continuation
        return (id, stream)
    }

    func unsubscribe(_ id: UUID) {
        subscribers[id]?.finish()
        subscribers[id] = nil
    }

    var subscriberCount: Int { subscribers.count }

    func publish(_ event: HubEvent) {
        for c in subscribers.values { c.yield(event) }
    }

    nonisolated func post(_ event: HubEvent) {
        Task { await publish(event) }
    }

    func startKeepalive(every seconds: Double = 20) {
        keepalive?.cancel()
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await self?.publish(HubEvent(kind: .ping))
            }
        }
    }
}
