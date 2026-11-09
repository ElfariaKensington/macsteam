// Find a Steam game's install folder from appmanifest files.
import Foundation

enum SteamLibrary {
    private static let pathRe = try! NSRegularExpression(pattern: #""path"\s+"([^"]+)""#)
    private static let installDirRe = try! NSRegularExpression(pattern: #""installdir"\s+"([^"]+)""#)

    static func installDir(appID: Int,
                           steamRoot: URL = Paths.steamRoot,
                           fm: FileManager = .default) -> URL? {
        for root in libraryRoots(steamRoot: steamRoot, fm: fm) {
            let steamapps = root.appendingPathComponent("steamapps", isDirectory: true)
            let manifest = steamapps.appendingPathComponent("appmanifest_\(appID).acf")
            guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { continue }
            let ns = text as NSString
            guard let match = installDirRe.firstMatch(
                in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
            let dir = ns.substring(with: match.range(at: 1))
                .replacingOccurrences(of: "\\\\", with: "/")
            guard !dir.isEmpty else { continue }
            let url = steamapps.appendingPathComponent("common", isDirectory: true)
                .appendingPathComponent(dir, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        return nil
    }

    static func libraryRoots(steamRoot: URL = Paths.steamRoot,
                             fm: FileManager = .default) -> [URL] {
        var roots: [URL] = [steamRoot]
        var seen = Set<String>([steamRoot.standardizedFileURL.path])
        let vdfs = [
            steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf"),
            steamRoot.appendingPathComponent("config/libraryfolders.vdf"),
        ]
        for vdf in vdfs {
            guard let text = try? String(contentsOf: vdf, encoding: .utf8) else { continue }
            let ns = text as NSString
            for match in pathRe.matches(in: text,
                                        range: NSRange(location: 0, length: ns.length)) {
                let raw = ns.substring(with: match.range(at: 1))
                    .replacingOccurrences(of: "\\\\", with: "/")
                let url = URL(fileURLWithPath: raw, isDirectory: true)
                    .standardizedFileURL
                guard seen.insert(url.path).inserted else { continue }
                roots.append(url)
            }
        }
        return roots
    }
}
