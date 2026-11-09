// Safe reader for the ZIP Hubcap serves alongside a game's Lua file.
import Darwin
import Foundation

enum HubcapArchiveError: LocalizedError {
    case damaged
    case tooLarge
    case unsafeName(String)
    case duplicateName(String)
    case noLua
    case missingManifest(String)
    case extractionFailed(String)
    case invalidLua

    var errorDescription: String? {
        switch self {
        case .damaged:
            return "Hubcap's manifest ZIP is damaged."
        case .tooLarge:
            return "Hubcap's manifest ZIP exceeds the extraction limit."
        case .unsafeName:
            return "Hubcap's manifest ZIP contains an unsafe filename."
        case .duplicateName(let name):
            return "Hubcap's manifest ZIP contains a duplicate filename: \(name)"
        case .noLua:
            return "Hubcap's manifest ZIP has no readable directory."
        case .missingManifest(let name):
            return "Hubcap's ZIP is missing manifests referenced by this game's Lua: \(name)"
        case .extractionFailed(let detail):
            return "Couldn't unpack Hubcap's manifest ZIP: \(detail)"
        case .invalidLua:
            return "Hubcap returned invalid Lua for this game."
        }
    }
}

struct HubcapManifestArchive {
    struct Contents {
        let directory: URL
        let luaText: String
        // Hubcap's Lua often has no setManifestid lines; the ZIP itself is the list of
        // manifests to stage. Keep every manifest, not just the referenced subset.
        let manifestFiles: [URL]
    }

    private struct Entry {
        let name: String
        let compressedSize: UInt64
        let uncompressedSize: UInt64
    }

    private static let maximumEntries = 256
    private static let maximumUncompressedBytes: UInt64 = 512 * 1024 * 1024
    private static let manifestPattern = try! NSRegularExpression(
        pattern: #"^([1-9][0-9]*)_([1-9][0-9]*)\.manifest$"#)

    static func unpack(_ data: Data, references: [LuaManifestRef],
                       expectedAppID: Int) throws -> Contents {
        let entries = try listEntries(data)
        guard entries.count > 0, entries.count <= maximumEntries else {
            throw entries.isEmpty ? HubcapArchiveError.damaged : HubcapArchiveError.tooLarge
        }

        var total: UInt64 = 0
        var names = Set<String>()
        var luaEntry: Entry?
        var manifestNames = Set<String>()
        for entry in entries {
            guard names.insert(entry.name).inserted else {
                throw HubcapArchiveError.duplicateName(entry.name)
            }
            guard entry.uncompressedSize <= maximumUncompressedBytes - total else {
                throw HubcapArchiveError.tooLarge
            }
            total += entry.uncompressedSize
            guard isSafeBaseName(entry.name) else {
                throw HubcapArchiveError.unsafeName(entry.name)
            }

            if entry.name.lowercased().hasSuffix(".lua") {
                guard luaEntry == nil else { throw HubcapArchiveError.duplicateName(entry.name) }
                guard entry.name == "\(expectedAppID).lua" else {
                    throw HubcapArchiveError.unsafeName(entry.name)
                }
                luaEntry = entry
            } else if isManifestName(entry.name) {
                manifestNames.insert(entry.name)
            } else {
                throw HubcapArchiveError.unsafeName(entry.name)
            }
        }

        guard luaEntry != nil else { throw HubcapArchiveError.noLua }
        let wanted = Set(references.map(\.fileName))
        for name in wanted where !manifestNames.contains(name) {
            throw HubcapArchiveError.missingManifest(name)
        }

        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("macsteam-hubcap-\(UUID().uuidString)", isDirectory: true)
        let zipURL = base.deletingLastPathComponent()
            .appendingPathComponent("\(base.lastPathComponent).zip")
        let extractDir = base
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        do {
            try data.write(to: zipURL, options: .atomic)
            let unzip = Subprocess.run("/usr/bin/unzip", ["-q", "-o", zipURL.path, "-d", extractDir.path])
            guard unzip.code == 0 else {
                throw HubcapArchiveError.extractionFailed(
                    unzip.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "unzip exit \(unzip.code)" : unzip.stderr)
            }
            try? fm.removeItem(at: zipURL)

            var manifestURLs: [URL] = []
            for entry in entries where isManifestName(entry.name) {
                let url = extractDir.appendingPathComponent(entry.name)
                guard regularFile(url),
                      let size = fileSize(url),
                      size == entry.uncompressedSize else {
                    throw HubcapArchiveError.missingManifest(entry.name)
                }
                manifestURLs.append(url)
            }
            for ref in references where !manifestURLs.contains(where: {
                $0.lastPathComponent == ref.fileName
            }) {
                throw HubcapArchiveError.missingManifest(ref.fileName)
            }

            let luaURL = extractDir.appendingPathComponent("\(expectedAppID).lua")
            guard regularFile(luaURL), let luaData = try? Data(contentsOf: luaURL),
                  let luaText = String(data: luaData, encoding: .utf8) else {
                throw HubcapArchiveError.noLua
            }
            let script = LuaManifestParser.parse(luaText)
            guard script.mainAppID == expectedAppID else {
                throw HubcapArchiveError.invalidLua
            }

            return Contents(directory: extractDir, luaText: luaText,
                            manifestFiles: manifestURLs)
        } catch {
            try? fm.removeItem(at: zipURL)
            try? fm.removeItem(at: extractDir)
            throw error
        }
    }

    static func cleanup(_ contents: Contents?) {
        guard let directory = contents?.directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Central directory

    private static func listEntries(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw HubcapArchiveError.damaged }
        let bytes = [UInt8](data)

        // End of central directory: scan no further than the maximum ZIP comment.
        var eocd = -1
        let lower = max(0, bytes.count - 22 - 65535)
        var i = bytes.count - 22
        while i >= lower {
            if u32(bytes, i) == 0x0605_4b50 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw HubcapArchiveError.damaged }

        let disk = u16(bytes, eocd + 4)
        let cdDisk = u16(bytes, eocd + 6)
        let entriesOnDisk = u16(bytes, eocd + 8)
        let entryCount = u16(bytes, eocd + 10)
        let cdSize = u32(bytes, eocd + 12)
        let cdOffset = u32(bytes, eocd + 16)
        guard disk == 0, cdDisk == 0, entriesOnDisk == entryCount,
              entryCount > 0, entryCount <= maximumEntries else {
            throw HubcapArchiveError.damaged
        }
        guard UInt64(cdOffset) + UInt64(cdSize) <= UInt64(bytes.count) else {
            throw HubcapArchiveError.damaged
        }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(entryCount))
        var p = Int(cdOffset)
        for _ in 0..<Int(entryCount) {
            guard p + 46 <= bytes.count, u32(bytes, p) == 0x0201_4b50 else {
                throw HubcapArchiveError.damaged
            }
            let compressed = u32(bytes, p + 20)
            let uncompressed = u32(bytes, p + 24)
            let nameLen = Int(u16(bytes, p + 28))
            let extraLen = Int(u16(bytes, p + 30))
            let commentLen = Int(u16(bytes, p + 32))
            guard compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF else {
                throw HubcapArchiveError.tooLarge
            }
            let nameStart = p + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= bytes.count else { throw HubcapArchiveError.damaged }
            guard let name = String(bytes: bytes[nameStart..<nameEnd], encoding: .utf8) else {
                throw HubcapArchiveError.unsafeName("<non-UTF-8>")
            }
            entries.append(Entry(name: name,
                                 compressedSize: UInt64(compressed),
                                 uncompressedSize: UInt64(uncompressed)))
            p = nameEnd + extraLen + commentLen
        }
        return entries
    }

    private static func isSafeBaseName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
        !name.contains("/") && !name.contains("\\") && !name.contains("\0") &&
        !name.hasPrefix(".")
    }

    private static func isManifestName(_ name: String) -> Bool {
        let ns = name as NSString
        return manifestPattern.firstMatch(in: name,
                                          range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func regularFile(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    private static func fileSize(_ url: URL) -> UInt64? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return UInt64(st.st_size)
    }

    private static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        guard at >= 0, at + 1 < bytes.count else { return 0 }
        return UInt16(bytes[at]) | (UInt16(bytes[at + 1]) << 8)
    }

    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at >= 0, at + 3 < bytes.count else { return 0 }
        return UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8) |
               (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
    }
}
