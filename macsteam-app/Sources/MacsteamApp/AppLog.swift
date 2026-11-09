// One append-only log for the whole app. The dylib already writes macsteam.log;
// this adds Swift-side entries with a category tag.
import AppKit
import Darwin
import Foundation

enum AppLog {
    private static let lock = NSLock()

    static func write(_ message: String, category: String?) {
        lock.lock()
        defer { lock.unlock() }
        try? Paths.ensureDir(Paths.configDir)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let tag = category.map { " [\($0)]" } ?? ""
        guard let data = "[\(stamp)]\(tag) \(message)\n".data(using: .utf8) else { return }
        let fd = open(Paths.appLog.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.write(fd, base, remaining)
                if n <= 0 { break }
                base = base.advanced(by: n)
                remaining -= n
            }
        }
    }

    static func revealInFinder() {
        try? Paths.ensureDir(Paths.configDir)
        if !FileManager.default.fileExists(atPath: Paths.appLog.path) {
            write("Log created.", category: "app")
        }
        NSWorkspace.shared.activateFileViewerSelecting([Paths.appLog])
    }
}
