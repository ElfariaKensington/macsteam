// Unlock lua parser
import Foundation

struct LuaEntry {
    var id: Int        // app id or depot id
    var key: String?   // nil if addappid had no key argument
    var name: String?  // trailing "-- comment" on this line, if any
    var heading: String?  // "-- <Name> (AppID: N)" header line immediately above
}

struct LuaManifestRef {
    var depotID: Int
    var manifestGID: String
}

struct LuaScript {
    var entries: [LuaEntry] = []   // in file order; entries[0] is the main app
    var manifests: [LuaManifestRef] = []

    var mainAppID: Int? { entries.first?.id }

    var depotKeys: [(depotID: Int, key: String)] {
        entries.compactMap { e in e.key.map { (e.id, $0) } }
    }

    var appNames: [Int: String] {
        let main = mainAppID
        var names: [Int: String] = [:]
        for e in entries {
            if e.id == main {
                if names[e.id] == nil, let n = e.name, !n.isEmpty { names[e.id] = n }
                continue
            }
            if e.key != nil { continue }                 // keyed depot: never an app name
            if names[e.id] != nil { continue }
            if let n = e.name, !n.isEmpty { names[e.id] = n }
            else if let h = e.heading, !h.isEmpty { names[e.id] = h }
        }
        return names
    }

    var parentByApp: [Int: Int] {
        guard let main = mainAppID else { return [:] }
        return Dictionary(uniqueKeysWithValues: dlcAppIDs.map { ($0, main) })
    }

    var dlcAppIDs: [Int] {
        let main = mainAppID
        var seen = Set<Int>()
        var result: [Int] = []
        for e in entries {
            if e.id == main { continue }
            if e.key != nil { continue }
            if seen.insert(e.id).inserted { result.append(e.id) }
        }
        return result
    }

    var depotOwner: [Int: Int] {
        guard let main = mainAppID else { return [:] }
        var owner: [Int: Int] = [:]
        var current = main
        for e in entries {
            if e.key == nil {
                if e.id != main { current = e.id }
                continue
            }
            owner[e.id] = current
        }
        return owner
    }
}

enum LuaManifestParser {
    static func containsAddApp(_ rawText: String) -> Bool {
        let pattern = #"(?m)^\s*addappid\s*\(\s*\d+"#
        return rawText.range(of: pattern, options: .regularExpression) != nil
    }

    private static let addAppRe = try! NSRegularExpression(
        pattern: #"addappid\s*\(\s*(\d+)\s*(?:,\s*\d+\s*(?:,\s*"([0-9a-fA-F]+)"\s*)?)?\)"#
    )
    private static let setManifestRe = try! NSRegularExpression(
        pattern: #"setManifestid\s*\(\s*(\d+)\s*,\s*"(\d+)"\s*(?:,\s*\d+\s*)?\)"#
    )

    private static let headingRe = try! NSRegularExpression(
        pattern: #"^(.*?)\s*\(AppID:\s*(\d+)\s*\)\s*$"#
    )

    static func parse(_ rawText: String) -> LuaScript {
        var script = LuaScript()

        var pendingHeading: (id: Int, name: String)? = nil

        for rawLine in rawText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let code: String
            var comment: String? = nil
            if let r = line.range(of: "--") {
                code = String(line[line.startIndex..<r.lowerBound])
                let c = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                comment = c.isEmpty ? nil : c
            } else {
                code = line
            }

            if code.trimmingCharacters(in: .whitespaces).isEmpty {
                if let c = comment {
                    let cns = c as NSString
                    if let hm = headingRe.firstMatch(in: c, range: NSRange(location: 0, length: cns.length)),
                       let hid = Int(cns.substring(with: hm.range(at: 2))) {
                        let name = cns.substring(with: hm.range(at: 1)).trimmingCharacters(in: .whitespaces)
                        pendingHeading = name.isEmpty ? nil : (hid, name)
                    } else {
                        pendingHeading = nil
                    }
                }
                continue
            }

            let ns = code as NSString
            let full = NSRange(location: 0, length: ns.length)

            if let m = addAppRe.firstMatch(in: code, range: full),
               let id = Int(ns.substring(with: m.range(at: 1))) {
                var key: String? = nil
                let kr = m.range(at: 2)
                if kr.location != NSNotFound {
                    let k = ns.substring(with: kr)
                    if !k.isEmpty { key = k.lowercased() }
                }
                var heading: String? = nil
                if key == nil, let p = pendingHeading, p.id == id { heading = p.name }
                pendingHeading = nil
                script.entries.append(LuaEntry(id: id, key: key, name: comment, heading: heading))
                continue
            }
            pendingHeading = nil

            if let m = setManifestRe.firstMatch(in: code, range: full),
               let depot = Int(ns.substring(with: m.range(at: 1))) {
                let gid = ns.substring(with: m.range(at: 2))
                script.manifests.append(LuaManifestRef(depotID: depot, manifestGID: gid))
            }
        }

        return script
    }
}
