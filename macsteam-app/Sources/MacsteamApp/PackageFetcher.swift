// Client package fetcher
import Foundation
import CryptoKit

enum PackageFetcher {

    static let cdnBase = "https://client-update.fastly.steamstatic.com"

    private struct Component {
        let name: String
        let sha2: String
        let size: Int64
    }

    static func stageFromValve(progress: (@Sendable (String) -> Void)? = nil) throws {
        let fm = FileManager.default
        try Paths.ensureDir(Paths.packageDir)
        try writePinnedManifest(fm: fm)
        let text = PinnedManifest.text

        let components = parse(text)
        guard !components.isEmpty else {
            throw StepFailure(step: "Parse manifest",
                          detail: "The client manifest listed no component files.")
        }

        let needed = components.filter { !fileValid($0, in: Paths.packageDir, fm: fm) }
        if needed.isEmpty {
            progress?("Client files already staged")
            return
        }

        let totalMB = needed.reduce(Int64(0)) { $0 + $1.size } / 1_000_000
        progress?("Downloading \(needed.count) client files from Valve (\(totalMB) MB)")
        try download(needed, into: Paths.packageDir, progress: progress)
    }

    // MARK: - Manifest

    /// Replace the on-disk client manifest with the pinned build's, so the local
    /// package server offers (and Steam installs) that build instead of the live one.
    private static func writePinnedManifest(fm: FileManager) throws {
        let data = Data(PinnedManifest.text.utf8)
        for name in ["steam_client_signed-2_osx.manifest", "steam_client_signed_osx.manifest"] {
            try? fm.removeItem(at: Paths.packageDir.appendingPathComponent(name))
        }
        // The .manifest name is what's read back for version detection;
        // the bare name is what Steam requests from -overridepackageurl.
        for name in ["steam_client_osx.manifest", "steam_client_osx"] {
            do {
                try data.write(to: Paths.packageDir.appendingPathComponent(name), options: .atomic)
            } catch {
                throw StepFailure(step: "Write manifest", detail: error.localizedDescription)
            }
        }
    }

    private static func parse(_ text: String) -> [Component] {
        var out: [Component] = []
        var depth = 0
        var blockName = ""             // header seen just before the current "{"
        var nameStack: [String] = []   // block name per open brace

        var file: String?, sha2: String?, zipvz: String?, sha2vz: String?, size: Int64 = 0
        func reset() { file = nil; sha2 = nil; zipvz = nil; sha2vz = nil; size = 0 }

        func flush(_ name: String) {
            defer { reset() }
            if name == "steamchina" { return }
            if let zipvz, let sha2vz {
                // Compressed files carry their byte size as a "_<size>" name suffix.
                let n = zipvz.split(separator: "_").last.flatMap { Int64($0) } ?? 0
                out.append(Component(name: zipvz, sha2: sha2vz, size: n))
            } else if let file, let sha2 {
                out.append(Component(name: file, sha2: sha2, size: size))
            }
        }

        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "{" {
                depth += 1
                nameStack.append(blockName)
                reset()
                continue
            }
            if line == "}" {
                let name = nameStack.popLast() ?? ""
                flush(name)
                depth -= 1
                continue
            }
            if let (key, value) = keyValue(line) {
                switch key {
                case "file": file = value
                case "sha2": sha2 = value
                case "zipvz": zipvz = value
                case "sha2vz": sha2vz = value
                case "size": size = Int64(value) ?? 0
                default: break
                }
            } else if let solo = soloToken(line) {
                blockName = solo
            }
        }
        return out
    }

    private static func soloToken(_ line: String) -> String? {
        let parts = line.components(separatedBy: "\"").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return parts.count == 1 ? parts[0] : nil
    }

    private static func keyValue(_ line: String) -> (String, String)? {
        let parts = line.components(separatedBy: "\"").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    // MARK: - Verify

    private static func fileValid(_ c: Component, in dir: URL, fm: FileManager) -> Bool {
        let url = dir.appendingPathComponent(c.name)
        guard fm.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return false
        }
        return sha256Hex(data) == c.sha2.lowercased()
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Download

    private static let chunkSize: Int64 = 4 * 1024 * 1024
    private static let maxConnections = 16

    /// One output file assembled from parallel ranged chunks.
    private final class FileJob: @unchecked Sendable {
        let component: Component
        let dest: URL
        let part: URL
        private let lock = NSLock()
        private var handle: FileHandle?
        private var remaining: Int
        init(component: Component, dest: URL, part: URL, chunks: Int, handle: FileHandle) {
            self.component = component; self.dest = dest; self.part = part
            self.remaining = chunks; self.handle = handle
        }
        func write(_ data: Data, at offset: UInt64) throws {
            lock.lock(); defer { lock.unlock() }
            try handle?.seek(toOffset: offset)
            try handle?.write(contentsOf: data)
        }
        /// True when this was the last outstanding chunk.
        func finishChunk() -> Bool {
            lock.lock(); defer { lock.unlock() }
            remaining -= 1
            if remaining == 0 { try? handle?.close(); handle = nil; return true }
            return false
        }
        func abort() {
            lock.lock(); defer { lock.unlock() }
            try? handle?.close(); handle = nil
            try? FileManager.default.removeItem(at: part)
        }
    }

    private struct Chunk {
        let job: FileJob
        let offset: Int64
        let length: Int64?   // nil = whole file, no Range header
    }

    private static func download(_ components: [Component],
                                 into dir: URL,
                                 progress: (@Sendable (String) -> Void)?) throws {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = maxConnections
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config)
        let group = DispatchGroup()
        let gate = DispatchSemaphore(value: maxConnections)
        let box = ResultBox()
        let doneFiles = Counter()
        let total = components.count
        let totalBytes = components.reduce(Int64(0)) { $0 + $1.size }
        let tracker = ByteTracker()
        let fm = FileManager.default

        let poller = DispatchQueue(label: "com.macsteam.downloadprogress")
        let timer = DispatchSource.makeTimerSource(queue: poller)
        var lastBytes: Int64 = 0
        var lastTime = Date()
        var speed = 0.0
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler {
            let got = min(tracker.total(), totalBytes > 0 ? totalBytes : .max)
            let now = Date()
            let dt = now.timeIntervalSince(lastTime)
            if dt > 0 {
                let inst = Double(got - lastBytes) / dt
                speed = speed == 0 ? inst : speed * 0.7 + inst * 0.3
            }
            lastBytes = got; lastTime = now
            var line = String(format: "Downloading client files: %.0f", Double(got) / 1e6)
            if totalBytes > 0 {
                let pct = min(100, Int(Double(got) / Double(totalBytes) * 100))
                line += String(format: " / %.0f MB (%d%%)", Double(totalBytes) / 1e6, pct)
                if speed > 1000 {
                    let eta = Double(max(0, totalBytes - got)) / speed
                    line += String(format: " · %.1f MB/s · ~%@ left", speed / 1e6, formatETA(eta))
                }
            } else {
                line += " MB"
            }
            progress?(line)
        }
        timer.resume()
        defer { timer.cancel() }

        // Build chunk list, largest files first.
        var chunks: [Chunk] = []
        for c in components.sorted(by: { $0.size > $1.size }) {
            let dest = dir.appendingPathComponent(c.name)
            let part = dir.appendingPathComponent(c.name + ".part")
            try? fm.removeItem(at: part)
            guard fm.createFile(atPath: part.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: part) else {
                throw StepFailure(step: "Write \(c.name)", detail: "couldn't create temp file")
            }
            if c.size > chunkSize {
                let n = Int((c.size + chunkSize - 1) / chunkSize)
                let job = FileJob(component: c, dest: dest, part: part, chunks: n, handle: handle)
                for i in 0..<n {
                    let off = Int64(i) * chunkSize
                    chunks.append(Chunk(job: job, offset: off, length: min(chunkSize, c.size - off)))
                }
            } else {
                let job = FileJob(component: c, dest: dest, part: part, chunks: 1, handle: handle)
                chunks.append(Chunk(job: job, offset: 0, length: nil))
            }
        }

        for chunk in chunks {
            gate.wait()
            if box.hasError { gate.signal(); break }
            group.enter()
            fetch(chunk, session: session, tracker: tracker, attempt: 1) { error in
                defer { gate.signal(); group.leave() }
                let job = chunk.job
                if let error {
                    box.record(error)
                    job.abort()
                    return
                }
                guard job.finishChunk() else { return }
                // All chunks written: verify the whole file, then move into place.
                guard let data = try? Data(contentsOf: job.part, options: .mappedIfSafe),
                      sha256Hex(data) == job.component.sha2.lowercased() else {
                    box.record(StepFailure(step: "Verify \(job.component.name)", detail: "sha2 mismatch"))
                    try? FileManager.default.removeItem(at: job.part)
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: job.dest)
                    try FileManager.default.moveItem(at: job.part, to: job.dest)
                } catch {
                    box.record(StepFailure(step: "Write \(job.component.name)", detail: error.localizedDescription))
                    return
                }
                _ = doneFiles.increment()
            }
        }

        group.wait()
        _ = total
        if let e = box.firstError {
            for c in components { try? fm.removeItem(at: dir.appendingPathComponent(c.name + ".part")) }
            throw e
        }
    }

    private static func fetch(_ chunk: Chunk,
                              session: URLSession,
                              tracker: ByteTracker,
                              attempt: Int,
                              completion: @escaping @Sendable (Error?) -> Void) {
        let name = chunk.job.component.name
        guard let url = URL(string: "\(cdnBase)/\(name)") else {
            completion(StepFailure(step: "Build URL", detail: name)); return
        }
        var req = URLRequest(url: url)
        if let len = chunk.length {
            req.setValue("bytes=\(chunk.offset)-\(chunk.offset + len - 1)", forHTTPHeaderField: "Range")
        }
        final class TaskBox: @unchecked Sendable { var task: URLSessionTask? }
        let box = TaskBox()
        let task = session.downloadTask(with: req) { tmp, response, error in
            func retryOrFail(_ e: StepFailure) {
                if let t = box.task { tracker.discount(t) }
                if attempt < 3 {
                    fetch(chunk, session: session, tracker: tracker, attempt: attempt + 1, completion: completion)
                } else {
                    completion(e)
                }
            }
            if let error {
                retryOrFail(StepFailure(step: "Download \(name)", detail: error.localizedDescription)); return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let okCode = chunk.length != nil ? (code == 206) : (code == 200)
            guard okCode else {
                retryOrFail(StepFailure(step: "Download \(name)", detail: "HTTP \(code)")); return
            }
            guard let tmp, let data = try? Data(contentsOf: tmp),
                  chunk.length == nil || Int64(data.count) == chunk.length! else {
                retryOrFail(StepFailure(step: "Download \(name)", detail: "short or empty response")); return
            }
            do {
                try chunk.job.write(data, at: UInt64(chunk.offset))
            } catch {
                completion(StepFailure(step: "Write \(name)", detail: error.localizedDescription)); return
            }
            completion(nil)
        }
        box.task = task
        tracker.add(task)
        task.resume()
    }

    private static func formatETA(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }

    private final class ByteTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [URLSessionTask] = []
        private var discounted: Int64 = 0
        func add(_ t: URLSessionTask) { lock.lock(); tasks.append(t); lock.unlock() }
        func discount(_ t: URLSessionTask) { lock.lock(); discounted += t.countOfBytesReceived; lock.unlock() }
        func total() -> Int64 {
            lock.lock(); defer { lock.unlock() }
            return max(0, tasks.reduce(Int64(0)) { $0 + $1.countOfBytesReceived } - discounted)
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?
        var hasError: Bool { lock.lock(); defer { lock.unlock() }; return error != nil }
        var firstError: Error? { lock.lock(); defer { lock.unlock() }; return error }
        func record(_ e: Error) {
            lock.lock(); defer { lock.unlock() }
            if error == nil { error = e }
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func increment() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }
}
