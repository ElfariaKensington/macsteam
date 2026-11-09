// NotProton stores its rendering helpers under Application Support. They are
// ad-hoc signed executables and can arrive with a quarantine xattr from the
// NotProton download; Gatekeeper then asks to open "iconmaker" every time a
// shortcut icon is rendered. macSteam clears that xattr for the helpers so the
// prompt stops without changing NotProton itself.
import Foundation

enum NotProtonSupport {
    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/notproton",
                                    isDirectory: true)
    }

    @discardableResult
    static func clearQuarantine(in directory: URL = supportDirectory,
                                fm: FileManager = .default) -> [String] {
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var cleared: [String] = []
        for url in entries {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                values.isRegularFile == true,
                values.isSymbolicLink != true,
                fm.isExecutableFile(atPath: url.path) else { continue }
            guard hasQuarantine(url) else { continue }
            let result = Subprocess.run("/usr/bin/xattr",
                                        ["-d", "com.apple.quarantine", url.path])
            if result.code == 0 {
                cleared.append(url.lastPathComponent)
            }
        }
        if !cleared.isEmpty {
            AppLog.write("notproton: cleared quarantine from "
                         + cleared.joined(separator: ", "), category: "install")
        }
        return cleared
    }

    private static func hasQuarantine(_ url: URL) -> Bool {
        let result = Subprocess.run("/usr/bin/xattr",
                                    ["-p", "com.apple.quarantine", url.path])
        return result.code == 0
    }
}
