import Foundation
import os

/// Ring-buffer log. Remote bug reports on a display-manipulation app are
/// unactionable without one, so everything interesting goes through here.
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()

    private let logger = Logger(subsystem: "app.brightness.xdr", category: "core")
    private let lock = NSLock()
    private var entries: [String] = []
    private let capacity = 600

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ message: String) {
        logger.log("\(message, privacy: .public)")
        let line = "[\(Self.stamp.string(from: Date()))] \(message)"
        lock.lock()
        entries.append(line)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        lock.unlock()
    }

    var report: String {
        lock.lock()
        defer { lock.unlock() }
        return entries.joined(separator: "\n")
    }
}

func log(_ message: String) { Diagnostics.shared.log(message) }
