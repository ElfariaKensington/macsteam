// Reads the dylib's achievement snapshot journal.
//
// The dylib keeps the original values for every spoofed achievement until the
// next Steam start, because Steam can flush its in-memory stats over the edited
// cache on exit. While a restore is pending, Steam's own UI may still report the
// cleared or deselected achievements as unlocked. The bridges use this to hide
// them until the cache has been verified.

import Foundation

struct AchievementSpoofRecord: Equatable {
    let appID: Int
    let statID: UInt32
    let spoofedMask: UInt32
}

enum AchievementSpoofState {
    static var fileURL: URL {
        Paths.configDir.appendingPathComponent("achievement-spoof.state")
    }

    static func records() -> [AchievementSpoofRecord] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }
        return records(from: text)
    }

    static func records(from text: String) -> [AchievementSpoofRecord] {
        var records: [AchievementSpoofRecord] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            // v1 app account stat section_present data|- count [bit:time...] [mask]
            guard fields.count >= 7, fields[0] == "v1",
                  let appID = Int(fields[1]),
                  let statID = UInt32(fields[3]),
                  let count = Int(fields[6]), count >= 0,
                  fields.count > 7 + count,
                  let mask = UInt32(fields[7 + count], radix: 16),
                  mask != 0 else { continue }
            records.append(AchievementSpoofRecord(appID: appID,
                                                  statID: statID,
                                                  spoofedMask: mask))
        }
        return records
    }

    /// Achievement ids that macSteam unlocked but the current selection no
    /// longer includes, keyed by app id. Steam may still report them as
    /// unlocked from its in-memory stats until the next restart.
    @MainActor
    static func suppressedAchievements(selections: [Int: AchievementSelection]) -> [String: [String]] {
        var byApp: [Int: Set<String>] = [:]
        for record in records() {
            let definitions: [AchievementDefinition]
            if let cached = definitionCache[record.appID] {
                definitions = cached
            } else if let loaded = try? AchievementCatalog.load(appID: record.appID), !loaded.isEmpty {
                definitionCache[record.appID] = loaded
                definitions = loaded
            } else {
                continue
            }
            let selected: Set<String>
            if let selection = selections[record.appID] {
                selected = selection.all ? Set(definitions.map(\.id)) : Set(selection.ids)
            } else {
                selected = []
            }
            for definition in definitions {
                guard definition.statID == record.statID,
                      definition.bit >= 0, definition.bit < 32,
                      record.spoofedMask & (UInt32(1) << UInt32(definition.bit)) != 0,
                      !selected.contains(definition.id) else {
                    continue
                }
                byApp[record.appID, default: []].insert(definition.id)
            }
        }
        var result: [String: [String]] = [:]
        for (appID, ids) in byApp where !ids.isEmpty {
            result[String(appID)] = ids.sorted()
        }
        return result
    }

    @MainActor private static var definitionCache: [Int: [AchievementDefinition]] = [:]
}
