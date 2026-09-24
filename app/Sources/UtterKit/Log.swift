import Foundation
import os

/// App log: unified logging plus a plain file at ~/Library/Logs/Utter/utter.log
/// (evidence for latency and "model loaded once"). Transcript text is never logged.
public enum Log {
    private static let logger = Logger(subsystem: "dev.utter.mac", category: "app")
    private static let queue = DispatchQueue(label: "dev.utter.log", qos: .utility)
    nonisolated(unsafe) private static var handle: FileHandle?

    public static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Utter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("utter.log")
    }()

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append("INFO", message)
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append("ERROR", message)
    }

    private static func append(_ level: String, _ message: String) {
        let line = "\(ISO8601DateFormatter.shared.string(from: Date())) \(level) \(message)\n"
        queue.async {
            if handle == nil {
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: fileURL)
                _ = try? handle?.seekToEnd()
            }
            handle?.write(Data(line.utf8))
        }
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
