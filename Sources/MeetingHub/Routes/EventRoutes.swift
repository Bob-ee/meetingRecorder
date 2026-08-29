import Foundation
import MeetingCore
import NIOCore
import Vapor

func eventRoutes(_ r: RoutesBuilder) {
    /// Server-sent events: one JSON `HubEvent` per `data:` line, a ping every 20 s.
    r.get("events") { req -> Response in
        let bus = req.application.eventBus
        let (id, stream) = await bus.subscribe()
        let response = Response(status: .ok)
        response.headers.replaceOrAdd(name: .contentType, value: "text/event-stream")
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        response.headers.replaceOrAdd(name: "X-Accel-Buffering", value: "no")
        response.body = .init(asyncStream: { writer in
            do {
                try await writer.write(.buffer(ByteBuffer(string: ": connected\n\n")))
                for await event in stream {
                    let json = try wireEncoder.encode(event)
                    var buffer = ByteBuffer()
                    buffer.writeString("data: ")
                    buffer.writeBytes(json)
                    buffer.writeString("\n\n")
                    try await writer.write(.buffer(buffer))
                }
            } catch {
                // client went away
            }
            await bus.unsubscribe(id)
            try? await writer.write(.end)
        })
        return response
    }
}
