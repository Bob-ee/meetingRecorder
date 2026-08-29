import Foundation
import os

/// Query with: /usr/bin/log show --last 10m --predicate 'subsystem == "local.meetingrecorder.app"'
enum Log {
    static let subsystem = "local.meetingrecorder.app"
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    static let summarizer = Logger(subsystem: subsystem, category: "summarizer")
}
