// Steam.app installer
import Foundation

enum SteamInstaller {

    enum Status: Equatable {
        case notInstalled          // pristine Valve bundle
        case installed             // macsteam injected, runtime stripped
        case installedLauncher     // macSteam.app launcher (NotProton compatibility)
        case installedDirect       // direct Steam launch, two dylibs in LSEnvironment
        case outdated(bundled: String, deployed: String) // dylib needs update
        case steamMissing          // /Applications/Steam.app absent
        case foreign               // patched by something else (unknown state)
    }

    struct PermissionDenied: Error {}

    // MARK: - Status

    static func status() -> Status {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.steamApp.path) else { return .steamMissing }

        if launcherInstalled {
            return .installedLauncher
        }
        if directModeInstalled {
            let bundled = bundledDylibVersion()
            let deployed = deployedDylibVersion()
            if let bundled, let deployed, bundled != deployed {
                return .outdated(bundled: bundled, deployed: deployed)
            }
            return .installedDirect
        }

        let dylibPresent = fm.fileExists(atPath: Paths.steamAppInjectedDylib.path)
        let insertsUs = insertedLibraries().contains(Paths.steamAppInjectedDylib.path)

        if dylibPresent && insertsUs {
            let bundled = bundledDylibVersion()
            let deployed = deployedDylibVersion()
            if let bundled, let deployed, bundled != deployed {
                return .outdated(bundled: bundled, deployed: deployed)
            }
            return .installed
        }
        if lsEnvironmentInsert() != nil { return .foreign }
        return .notInstalled
    }

    static func bundledDylibVersion() -> String? {
        guard let url = Bundle.main.url(forResource: "macsteam.dylib", withExtension: "version") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func deployedDylibVersion() -> String? {
        let url = Paths.configDir.appendingPathComponent("dylib.version")
        return try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func updateBlockEnabled() -> Bool {
        FileManager.default.fileExists(atPath: Paths.steamCfgRoot.path)
    }

    static var launcherInstalled: Bool {
        FileManager.default.fileExists(atPath: Paths.launcherApp.path)
    }

    static var directModeInstalled: Bool {
        insertedLibraries().contains(Paths.notProtonCompatibleDylib.path)
            && FileManager.default.fileExists(atPath: Paths.notProtonCompatibleDylib.path)
    }

    static var notProtonInstalled: Bool {
        insertedLibraries().contains {
            URL(fileURLWithPath: $0).lastPathComponent == "notproton.dylib"
        }
    }

    /// True when the real NotProton dylib is present, as opposed to macSteam's own
    /// compatibility copy (which also uses the `notproton.dylib` basename).
    static var notProtonPresent: Bool {
        let realPath = Paths.steamApp
            .appendingPathComponent("Contents/MacOS/notproton.dylib")
        if FileManager.default.fileExists(atPath: realPath.path) { return true }
        let compat = Paths.notProtonCompatibleDylib.standardizedFileURL.path
        return insertedLibraries().contains { path in
            URL(fileURLWithPath: path).lastPathComponent == "notproton.dylib"
                && URL(fileURLWithPath: path).standardizedFileURL.path != compat
        }
    }

    static func hasForeignInsert() -> Bool {
        let ours = Paths.steamAppInjectedDylib.path
        return insertedLibraries().contains {
            let name = URL(fileURLWithPath: $0).lastPathComponent
            return $0 != ours && name != "macsteam.dylib" && name != "notproton.dylib"
        }
    }

    /// NotProton owns Steam's DYLD_INSERT slot. Remove macSteam from it, leave
    /// NotProton alone, and deploy the launcher that injects both dylibs.
    static func installNotProtonCompatibility(sourceDylib: URL) throws {
        guard let launcher = Bundle.main.resourceURL?
            .appendingPathComponent("macSteamLauncher.app"),
              FileManager.default.fileExists(atPath: launcher.path) else {
            throw StepFailure(step: "Install launcher",
                              detail: "The bundled macSteam launcher is missing.")
        }
        try ensureModifiable()
        let fm = FileManager.default
        Subprocess.killSteam()

        let plist = Paths.steamAppInfoPlist
        let originalPlist = try? Data(contentsOf: plist)
        do {
            let ours = Paths.steamAppInjectedDylib.path
            let compat = Paths.notProtonCompatibleDylib.path
            let remaining = Self.launcherInsertComponents(
                existing: insertedLibraries(), ours: ours, compat: compat)
            if remaining.isEmpty {
                let out = Subprocess.run("/usr/libexec/PlistBuddy",
                                         ["-c", "Delete :LSEnvironment:DYLD_INSERT_LIBRARIES",
                                          plist.path])
                if out.code != 0 {
                    throw StepFailure(step: "Patch Info.plist",
                                      detail: out.stderr.isEmpty ? "PlistBuddy failed." : out.stderr)
                }
            } else {
                try plistSet(":LSEnvironment:DYLD_INSERT_LIBRARIES", remaining.joined(separator: ":"))
            }
            try adhocSign(Paths.steamApp)
        } catch {
            if let originalPlist { try? originalPlist.write(to: plist) }
            try? adhocSign(Paths.steamApp)
            throw error
        }

        do {
            if fm.fileExists(atPath: Paths.launcherApp.path) {
                try fm.removeItem(at: Paths.launcherApp)
            }
            try fm.copyItem(at: launcher, to: Paths.launcherApp)
            try adhocSign(Paths.launcherApp)
            // Direct mode's copy is no longer injected; the launcher carries macSteam.
            try? fm.removeItem(at: Paths.notProtonCompatibleDylib)
        } catch {
            if let originalPlist { try? originalPlist.write(to: plist) }
            try? adhocSign(Paths.steamApp)
            throw error
        }

        try UpdateMode.apply()
        registerBundle()
        _ = sourceDylib // version is carried inside the bundled launcher
        NotProtonSupport.clearQuarantine()
    }

    /// Put macSteam in LSEnvironment under the filename `notproton.dylib` alongside
    /// the real NotProton path. NotProton ignores paths with that basename, so
    /// launching Steam.app directly loads both dylibs; no separate launcher needed.
    static func installDirectCompatibility(sourceDylib: URL) throws {
        try ensureModifiable()
        let fm = FileManager.default
        Subprocess.killSteam()

        let plist = Paths.steamAppInfoPlist
        let originalPlist = try? Data(contentsOf: plist)
        do {
            try Paths.ensureDir(Paths.configDir)
            if fm.fileExists(atPath: Paths.notProtonCompatibleDylib.path) {
                try fm.removeItem(at: Paths.notProtonCompatibleDylib)
            }
            try fm.copyItem(at: sourceDylib, to: Paths.notProtonCompatibleDylib)
            try adhocSign(Paths.notProtonCompatibleDylib)
            if let version = bundledDylibVersion() {
                try version.write(to: Paths.configDir.appendingPathComponent("dylib.version"),
                                  atomically: true, encoding: .utf8)
            }

            let ours = Paths.steamAppInjectedDylib.path
            let compat = Paths.notProtonCompatibleDylib.path
            let components = Self.directInsertComponents(existing: insertedLibraries(),
                                                         ours: ours, compat: compat)
            try plistSet(":LSEnvironment:DYLD_INSERT_LIBRARIES",
                         components.joined(separator: ":"))
            try adhocSign(Paths.steamApp)
        } catch {
            if let originalPlist { try? originalPlist.write(to: plist) }
            try? adhocSign(Paths.steamApp)
            throw error
        }

        try? fm.removeItem(at: Paths.launcherApp)
        try UpdateMode.apply()
        registerBundle()
        NotProtonSupport.clearQuarantine()
    }

    static func removeDirectCompatibility() {
        let fm = FileManager.default
        let compat = Paths.notProtonCompatibleDylib.path
        let remaining = insertedLibraries().filter { $0 != compat }
        if remaining.isEmpty {
            _ = Subprocess.run("/usr/libexec/PlistBuddy",
                               ["-c", "Delete :LSEnvironment:DYLD_INSERT_LIBRARIES",
                                Paths.steamAppInfoPlist.path])
        } else {
            try? plistSet(":LSEnvironment:DYLD_INSERT_LIBRARIES",
                          remaining.joined(separator: ":"))
        }
        try? fm.removeItem(at: Paths.notProtonCompatibleDylib)
        try? adhocSign(Paths.steamApp)
    }

    static func removeLauncherCompatibility() {
        try? FileManager.default.removeItem(at: Paths.launcherApp)
    }

    // MARK: - Install

    static func install(sourceDylib: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.steamApp.path) else {
            throw StepFailure(step: "Locate Steam", detail: "/Applications/Steam.app not found. Install Steam first.")
        }
        guard fm.fileExists(atPath: sourceDylib.path) else {
            throw StepFailure(step: "Locate payload", detail: "Bundled macsteam.dylib is missing.")
        }
        try ensureModifiable()

        Subprocess.killSteam()

        do {
            if fm.fileExists(atPath: Paths.steamAppInjectedDylib.path) {
                try fm.removeItem(at: Paths.steamAppInjectedDylib)
            }
            try fm.copyItem(at: sourceDylib, to: Paths.steamAppInjectedDylib)

            // Write the deployed version so update checks can compare against it.
            if let version = bundledDylibVersion() {
                try? Paths.ensureDir(Paths.configDir)
                let versionFile = Paths.configDir.appendingPathComponent("dylib.version")
                try? version.write(to: versionFile, atomically: true, encoding: .utf8)
            }
        } catch {
            throw StepFailure(step: "Copy payload", detail: error.localizedDescription)
        }

        try deploySignatures()
        deployCEFDebugMarker()

        try plistSet(":LSEnvironment:DYLD_INSERT_LIBRARIES", mergedInsertList())

        // Sign inner-to-outer so each seal covers the one below.
        try adhocSign(Paths.steamAppInjectedDylib)
        try adhocSign(Paths.steamAppExecutable)
        try adhocSign(Paths.steamApp)

        try UpdateMode.apply()

        registerBundle()
    }

    // MARK: - Update block (steam.cfg)

    static func writeUpdateBlock() throws {
        let body = "BootStrapperInhibitUpdateOnLaunch=enable\n"
        for url in [Paths.steamCfgRoot, Paths.steamCfgInner] {
            do {
                try Paths.ensureDir(url.deletingLastPathComponent())
                try body.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                if url == Paths.steamCfgRoot {
                    throw StepFailure(step: "Write steam.cfg", detail: error.localizedDescription)
                }
            }
        }
    }

    static func enableUpdateBlock() throws {
        try writeUpdateBlock()
    }

    static func disableUpdateBlock() throws {
        let fm = FileManager.default
        for url in [Paths.steamCfgRoot, Paths.steamCfgInner] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    // MARK: - LSEnvironment read

    static func lsEnvironmentInsert() -> String? {
        let out = Subprocess.run("/usr/libexec/PlistBuddy",
                      ["-c", "Print :LSEnvironment:DYLD_INSERT_LIBRARIES", Paths.steamAppInfoPlist.path])
        guard out.code == 0 else { return nil }
        let v = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    private static func insertedLibraries() -> [String] {
        lsEnvironmentInsert()?.split(separator: ":").map(String.init) ?? []
    }

    private static func mergedInsertList() -> String {
        let ours = Paths.steamAppInjectedDylib.path
        let existing = insertedLibraries().filter {
            $0 != ours && FileManager.default.fileExists(atPath: $0)
        }
        return ([ours] + existing).joined(separator: ":")
    }

    /// macSteam's WhatsNew interpose uses raw syscalls. Loading it after NotProton
    /// would swallow SteamUI file reads and NotProton's webpatch would never see
    /// them, so the compatibility copy must be first and NotProton last.
    static func directInsertComponents(existing: [String], ours: String,
                                       compat: String) -> [String] {
        var components = existing.filter {
            $0 != ours && $0 != compat
                && URL(fileURLWithPath: $0).lastPathComponent != "macsteam.dylib"
        }
        components.insert(compat, at: 0)
        return components
    }

    /// Launcher mode keeps only the real NotProton entry; both macSteam copies
    /// are removed because the launcher injects macSteam itself.
    static func launcherInsertComponents(existing: [String], ours: String,
                                         compat: String) -> [String] {
        existing.filter {
            $0 != ours && $0 != compat
                && URL(fileURLWithPath: $0).lastPathComponent != "macsteam.dylib"
        }
    }

    // MARK: - Shell primitives

    private static func plistSet(_ keyPath: String, _ value: String) throws {
        let set = Subprocess.run("/usr/libexec/PlistBuddy",
                      ["-c", "Set \(keyPath) \(value)", Paths.steamAppInfoPlist.path])
        if set.code != 0 {
            let add = Subprocess.run("/usr/libexec/PlistBuddy",
                          ["-c", "Add \(keyPath) string \(value)", Paths.steamAppInfoPlist.path])
            if add.code != 0 {
                throw StepFailure(step: "Patch Info.plist", detail: add.stderr.isEmpty ? set.stderr : add.stderr)
            }
        }
    }

    private static func adhocSign(_ url: URL) throws {
        let out = Subprocess.run("/usr/bin/codesign", ["-f", "-s", "-", url.path])
        if out.code != 0 {
            throw StepFailure(step: "Sign \(url.lastPathComponent)", detail: out.stderr)
        }
    }

    private static func registerBundle() {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
            + "LaunchServices.framework/Support/lsregister"
        _ = Subprocess.run(lsregister, ["-f", Paths.steamApp.path])
    }

    // MARK: - CEF store bridge

    // Steam only opens its CEF debugging port when this marker exists at launch.
    // Creating it here means the first launch after Install can inject the store button.
    static func deployCEFDebugMarker() {
        try? Paths.ensureDir(Paths.cefDebugMarker.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: Paths.cefDebugMarker.path) {
            FileManager.default.createFile(atPath: Paths.cefDebugMarker.path, contents: Data())
        }
    }

    // MARK: - Signatures

    private static func deploySignatures() throws {
        guard let bundledSigs = Bundle.main.url(forResource: "signatures", withExtension: nil) else {
            throw StepFailure(step: "Deploy signatures", detail: "Bundled signatures missing from app.")
        }
        let dest = Paths.signaturesDir
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try Paths.ensureDir(dest)
        let enumerator = fm.enumerator(at: bundledSigs, includingPropertiesForKeys: nil)
        while let src = enumerator?.nextObject() as? URL {
            guard src.hasDirectoryPath == false else { continue }
            let rel = src.path.replacingOccurrences(of: bundledSigs.path + "/", with: "")
            let target = dest.appendingPathComponent(rel)
            try Paths.ensureDir(target.deletingLastPathComponent())
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: src, to: target)
        }
    }

    // MARK: - Preflight

    static func ensureModifiable() throws {
        let probe = Paths.steamApp
            .appendingPathComponent("Contents/MacOS/.macsteam-write-probe")
        let fm = FileManager.default
        do {
            try Data().write(to: probe, options: .atomic)
            try? fm.removeItem(at: probe)
        } catch let e as NSError
            where e.domain == NSCocoaErrorDomain
               && (e.code == NSFileWriteNoPermissionError || e.code == NSFileWriteVolumeReadOnlyError) {
            throw PermissionDenied()
        } catch {
            throw StepFailure(step: "Check Steam.app access", detail: error.localizedDescription)
        }
    }
}
