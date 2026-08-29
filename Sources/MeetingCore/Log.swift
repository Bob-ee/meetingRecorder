import Foundation
#if canImport(os)
import os
#endif

/// Thin logging facade shared by the app, the engine and the hub.
/// On Apple platforms it is os_log — query with
/// `/usr/bin/log show --last 10m --info --predicate 'subsystem == "local.meetingrecorder.app"'`.
/// Set `Log.mirrorToStderr = true` (the hub does) to also print every line to stderr.
public struct LogChannel: Sendable {
    public let category: String
    #if canImport(os)
    private let logger: Logger
    #endif

    init(_ category: String) {
        self.category = category
        #if canImport(os)
        logger = Logger(subsystem: Log.subsystem, category: category)
        #endif
    }

    public func info(_ message: String) {
        #if canImport(os)
        logger.info("\(message, privacy: .public)")
        #endif
        Log.emit("INFO", category, message)
    }

    public func warning(_ message: String) {
        #if canImport(os)
        logger.warning("\(message, privacy: .public)")
        #endif
        Log.emit("WARN", category, message)
    }

    public func error(_ message: String) {
        #if canImport(os)
        logger.error("\(message, privacy: .public)")
        #endif
        Log.emit("ERROR", category, message)
    }
}

public enum Log {
    public static let subsystem = "local.meetingrecorder.app"
    public static let capture = LogChannel("capture")
    public static let pipeline = LogChannel("pipeline")
    public static let summarizer = LogChannel("summarizer")
    public static let hub = LogChannel("hub")

    /// Also write to stderr (always on where os_log is unavailable).
    nonisolated(unsafe) public static var mirrorToStderr = false

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func emit(_ level: String, _ category: String, _ message: String) {
        #if canImport(os)
        guard mirrorToStderr else { return }
        #endif
        let line = "\(stamp.string(from: Date())) [\(level)] \(category): \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
