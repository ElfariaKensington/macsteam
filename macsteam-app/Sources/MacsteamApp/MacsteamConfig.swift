// config.yaml model
import Foundation

struct DepotKeyGroup: Equatable {
    var appID: Int
    var depots: [(depotID: Int, key: String)]   // order preserved for stable diffs

    static func == (lhs: DepotKeyGroup, rhs: DepotKeyGroup) -> Bool {
        lhs.appID == rhs.appID &&
        lhs.depots.count == rhs.depots.count &&
        zip(lhs.depots, rhs.depots).allSatisfy { $0.depotID == $1.depotID && $0.key == $1.key }
    }
}

struct MacsteamConfig: Equatable {
    var apps: [Int] = []
    var packageIds: [Int] = []
    var depotKeyGroups: [DepotKeyGroup] = []

    var appNames: [Int: String] = [:]

    var appParents: [Int: Int] = [:]

    var hideWhatsNew = false
    var hideCloudErrors = false
}

// MARK: - Helpers

extension MacsteamConfig {
    mutating func depotGroupIndex(for appID: Int) -> Int {
        if let i = depotKeyGroups.firstIndex(where: { $0.appID == appID }) { return i }
        depotKeyGroups.append(DepotKeyGroup(appID: appID, depots: []))
        return depotKeyGroups.count - 1
    }

    @discardableResult
    mutating func upsertDepotKey(appID: Int, depotID: Int, key: String) -> Bool {
        let gi = depotGroupIndex(for: appID)
        if let di = depotKeyGroups[gi].depots.firstIndex(where: { $0.depotID == depotID }) {
            if depotKeyGroups[gi].depots[di].key == key { return false }
            depotKeyGroups[gi].depots[di].key = key
            return true
        }
        depotKeyGroups[gi].depots.append((depotID: depotID, key: key))
        return true
    }

    @discardableResult
    mutating func addApp(_ appID: Int) -> Bool {
        guard !apps.contains(appID) else { return false }
        apps.append(appID)
        return true
    }

    mutating func removeApps(_ ids: [Int]) {
        var drop = Set(ids)
        guard !drop.isEmpty else { return }
        while true {
            let next = drop.union(appParents.filter { drop.contains($0.value) }.keys)
            if next.count == drop.count { break }
            drop = next
        }
        apps.removeAll { drop.contains($0) }
        depotKeyGroups.removeAll { drop.contains($0.appID) }
        for id in drop {
            appNames[id] = nil
            appParents[id] = nil
        }
    }

    func children(of appID: Int) -> [Int] {
        apps.filter { appParents[$0] == appID }
    }

    var topLevelApps: [Int] {
        apps.filter { appParents[$0] == nil }
    }

    @discardableResult
    mutating func addPackage(_ pkgID: Int) -> Bool {
        guard !packageIds.contains(pkgID) else { return false }
        packageIds.append(pkgID)
        return true
    }
}

// MARK: - Parse (lenient reader of the config.c subset)

extension MacsteamConfig {
    enum Section { case none, apps, packages, depotKeys }

    static func parse(_ text: String) -> MacsteamConfig {
        var cfg = MacsteamConfig()
        var section: Section = .none
        var currentDKApp: Int? = nil

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).replacingOccurrences(of: "\r", with: "")
            let indent = line.prefix(while: { $0 == " " }).count
            let trimmed = line.drop(while: { $0 == " " })
            if trimmed.isEmpty || trimmed.first == "#" { continue }
            let t = String(trimmed)

            if indent == 0 {
                section = .none
                currentDKApp = nil

                if t.hasPrefix("Apps:")           { section = .apps; continue }
                if t.hasPrefix("PackageIds:")     { section = .packages; continue }
                if t.hasPrefix("DepotKeys:")      { section = .depotKeys; continue }

                if let (k, v) = Self.splitKV(t) {
                    switch k {
                    case "HideWhatsNew": cfg.hideWhatsNew = Self.parseBool(v)
                    case "HideCloudErrors": cfg.hideCloudErrors = Self.parseBool(v)
                    default: break
                    }
                }
                continue
            }

            if indent == 2 {
                if t.first == "-" {
                    let item = t.dropFirst().drop(while: { $0 == " " })
                    let token = item.prefix { $0 != " " && $0 != "#" }
                    guard let n = Int(token) else { continue }
                    switch section {
                    case .apps:
                        if !cfg.apps.contains(n) { cfg.apps.append(n) }
                        if let h = item.firstIndex(of: "#") {
                            var comment = item[item.index(after: h)...].trimmingCharacters(in: .whitespaces)
                            if let at = comment.range(of: #"@\d+"#, options: .regularExpression) {
                                if let parent = Int(comment[comment.index(after: at.lowerBound)..<at.upperBound]) {
                                    cfg.appParents[n] = parent
                                }
                                comment.removeSubrange(at)
                                comment = comment.trimmingCharacters(in: .whitespaces)
                            }
                            if !comment.isEmpty { cfg.appNames[n] = comment }
                        }
                    case .packages: if !cfg.packageIds.contains(n) { cfg.packageIds.append(n) }
                    default: break
                    }
                    continue
                }
                if section == .depotKeys, let (k, _) = Self.splitKV(t), let app = Int(k) {
                    currentDKApp = app
                    _ = cfg.depotGroupIndex(for: app)
                    continue
                }
                continue
            }

            if indent == 4, section == .depotKeys, let app = currentDKApp,
               let (k, v) = Self.splitKV(t), let depot = Int(k) {
                cfg.upsertDepotKey(appID: app, depotID: depot, key: Self.stripQuotes(v))
            }
        }
        return cfg
    }

    private static func splitKV(_ s: String) -> (String, String)? {
        guard let idx = s.firstIndex(of: ":") else { return nil }
        let key = s[s.startIndex..<idx].trimmingCharacters(in: .whitespaces)
        let val = s[s.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        if key.isEmpty { return nil }
        return (key, val)
    }

    private static func parseBool(_ s: String) -> Bool {
        let l = s.lowercased()
        return l == "yes" || l == "true" || l == "1"
    }

    private static func stripQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let f = s.first!, l = s.last!
        if (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}

// MARK: - Serialize (emit the exact layout config.c expects)

extension MacsteamConfig {
    func serialize(header: String? = nil) -> String {
        var out = ""
        if let header {
            for line in header.split(separator: "\n", omittingEmptySubsequences: false) {
                out += "# \(line)\n"
            }
            out += "\n"
        }

        out += "HideWhatsNew: \(hideWhatsNew ? "yes" : "no")\n"
        out += "HideCloudErrors: \(hideCloudErrors ? "yes" : "no")\n"
        out += "\n"

        if !apps.isEmpty {
            out += "Apps:\n"
            for a in apps {
                let name = appNames[a] ?? ""
                let parent = appParents[a]
                var comment = name
                if let parent { comment += (comment.isEmpty ? "" : " ") + "@\(parent)" }
                if comment.isEmpty {
                    out += "  - \(a)\n"
                } else {
                    out += "  - \(a)  # \(comment)\n"
                }
            }
            out += "\n"
        }

        if !packageIds.isEmpty {
            out += "PackageIds:\n"
            for p in packageIds { out += "  - \(p)\n" }
            out += "\n"
        }

        if !depotKeyGroups.isEmpty {
            out += "DepotKeys:\n"
            for group in depotKeyGroups {
                out += "  \(group.appID):\n"
                for d in group.depots {
                    out += "    \(d.depotID): \(d.key)\n"
                }
            }
            out += "\n"
        }

        while out.hasSuffix("\n\n") { out.removeLast() }
        return out
    }
}
