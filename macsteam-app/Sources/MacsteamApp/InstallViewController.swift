// Install pane
import AppKit

final class InstallViewController: NSViewController {

    private var statusGlyph: NSImageView!
    private var headlineLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var installButton: NSButton!
    private var uninstallButton: NSButton!
    private var openButton: NSButton!
    private var repairButton: NSButton!
    private var spinner: NSProgressIndicator!

    private var bundledDylib: URL? {
        Bundle.main.url(forResource: "macsteam", withExtension: "dylib")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 460))

            statusGlyph = NSImageView()
        statusGlyph.symbolConfiguration = .init(pointSize: 40, weight: .regular)
        statusGlyph.setAccessibilityElement(false)
        statusGlyph.translatesAutoresizingMaskIntoConstraints = false

        headlineLabel = NSTextField(labelWithString: "")
        headlineLabel.font = Typography.largeTitle
        headlineLabel.textColor = .labelColor
        headlineLabel.alignment = .center
        headlineLabel.lineBreakMode = .byTruncatingTail
        headlineLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel = NSTextField(labelWithString: "")
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = Typography.body
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 0

        installButton = makeButton(title: "Install", target: self, action: #selector(doInstall))
        installButton.keyEquivalent = "\r"
        uninstallButton = makeButton(title: "Uninstall", target: self, action: #selector(doUninstall))
        openButton = makeButton(title: "Open Steam", target: self, action: #selector(openSteam))
        repairButton = makeButton(title: "Repair Steam…", target: self,
                                  action: #selector(repairSteam))

        spinner = NSProgressIndicator()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let footerDivider = NSBox()
        footerDivider.boxType = .separator
        footerDivider.translatesAutoresizingMaskIntoConstraints = false

        let statusGroup = NSStackView(views: [statusGlyph, headlineLabel, detailLabel])
        statusGroup.orientation = .vertical
        statusGroup.alignment = .centerX
        statusGroup.spacing = 6
        statusGroup.setCustomSpacing(12, after: statusGlyph)
        statusGroup.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(statusGroup)
        root.addSubview(footerDivider)
        root.addSubview(openButton)
        root.addSubview(repairButton)
        root.addSubview(uninstallButton)
        root.addSubview(installButton)
        root.addSubview(spinner)

        let M = Metrics.paneMargin
        NSLayoutConstraint.activate([
            statusGroup.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            statusGroup.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            statusGroup.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            statusGroup.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor, constant: M),
            statusGroup.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: M),

            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380),

            footerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: installButton.topAnchor, constant: -12),
            footerDivider.topAnchor.constraint(greaterThanOrEqualTo: statusGroup.bottomAnchor, constant: Metrics.headerGap),

            installButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -M),
            installButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -M),

            uninstallButton.trailingAnchor.constraint(equalTo: installButton.leadingAnchor, constant: -10),
            uninstallButton.centerYAnchor.constraint(equalTo: installButton.centerYAnchor),

            openButton.trailingAnchor.constraint(equalTo: uninstallButton.leadingAnchor, constant: -10),
            openButton.centerYAnchor.constraint(equalTo: installButton.centerYAnchor),

            repairButton.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -10),
            repairButton.centerYAnchor.constraint(equalTo: installButton.centerYAnchor),

            spinner.centerYAnchor.constraint(equalTo: installButton.centerYAnchor),
            spinner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: M),
        ])

        view = root
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refresh()
    }

    // MARK: - Status rendering

    private func refresh() {
        let status = SteamInstaller.status()
        let hasPayload = (bundledDylib != nil)
        let blockOn = SteamInstaller.updateBlockEnabled()

        let summary = summarize(status: status, blockOn: blockOn)
        statusGlyph.image = NSImage(systemSymbolName: summary.tone.symbol, accessibilityDescription: nil)
        statusGlyph.contentTintColor = summary.tone.color
        headlineLabel.stringValue = summary.headline
        detailLabel.stringValue = summary.detail

        switch status {
        case .installed, .installedLauncher, .installedDirect:
            installButton.title = "Reinstall"
            uninstallButton.isEnabled = true
            openButton.isEnabled = true
            openButton.title = status == .installedLauncher ? "Open macSteam" : "Open Steam"
        case .outdated:
            installButton.title = "Update"
            uninstallButton.isEnabled = true
            openButton.isEnabled = true
        case .notInstalled:
            installButton.title = "Install"
            uninstallButton.isEnabled = false
            openButton.isEnabled = true
        case .foreign:
            installButton.title = "Install"
            uninstallButton.isEnabled = true
            openButton.isEnabled = true
        case .steamMissing:
            installButton.title = "Install"
            uninstallButton.isEnabled = false
            openButton.isEnabled = false
        }

        repairButton.isEnabled = status != .steamMissing

        installButton.isEnabled = hasPayload && status != .steamMissing
    }

    private struct Summary {
        let tone: StatusTone
        let headline: String
        let detail: String
    }

    private func summarize(status: SteamInstaller.Status, blockOn: Bool) -> Summary {
        switch status {
        case .steamMissing:
            return Summary(tone: .bad, headline: "Steam not found",
                           detail: "Steam isn't in your Applications folder. Install it from Valve, then come back.")
        case .installed:
            return blockOn
                ? Summary(tone: .ok, headline: "Installed",
                          detail: "Steam updates are blocked. Change this in Settings → Updates.")
                : Summary(tone: .warn, headline: "Installed, updates allowed",
                          detail: "Steam can update its client and may break macSteam until macSteam catches up. Change this in Settings → Updates.")
        case .installedLauncher:
            return Summary(tone: .ok, headline: "Installed (launcher)",
                           detail: "NotProton detected. Launch macSteam.app to start Steam with both dylibs loaded.")
        case .installedDirect:
            return Summary(tone: .ok, headline: "Installed (direct)",
                           detail: "NotProton and macSteam both load when you open Steam.app normally.")
        case .outdated(let bundled, let deployed):
            return Summary(tone: .warn, headline: "Update available",
                           detail: "A newer dylib is bundled (v\(bundled)). The installed version is v\(deployed). Click Update to apply it.")
        case .notInstalled, .foreign:
            return Summary(tone: .ok, headline: "Ready to install",
                           detail: "Steam is present. Click Install to patch it.")
        }
    }

    private func buildIsOlder(_ lhs: String, than rhs: String) -> Bool {
        guard let l = Int(lhs), let r = Int(rhs) else { return false }
        return l < r
    }

    // MARK: - Actions

    @objc private func doInstall() {
        guard let dylib = bundledDylib else { return }

        switch MacCrab.status() {
        case .unsupported(let version):
            promptVersionFix(currentBuild: version, dylib: dylib)
        default:
            runInstall(dylib: dylib, pinFirst: false)
        }
    }

    private func promptVersionFix(currentBuild: String, dylib: URL) {
        let tooOld = buildIsOlder(currentBuild, than: MacCrab.supportedVersion)
        let alert = NSAlert()
        alert.alertStyle = .warning
        if tooOld {
            alert.messageText = "Steam version is older than the supported version"
            alert.informativeText = "Your Steam client is on a build of Steam that is older "
                + "than the build that macSteam supports. This installer can upgrade you to the "
                + "latest supported version of Steam, or you can install on your current "
                + "build\u{2026}at your own risk."
            alert.addButton(withTitle: "Update and Install")
        } else {
            alert.messageText = "Steam version is newer than the supported version!"
            alert.informativeText = "Your Steam client is on a build of Steam that is newer "
                + "than the build that macSteam supports! This installer can downgrade you to "
                + "the latest supported version of Steam, or you can install anyway on your "
                + "current build\u{2026}at your own risk."
            alert.addButton(withTitle: "Downgrade and Install")
        }
        alert.addButton(withTitle: "Install Anyway")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:  runInstall(dylib: dylib, pinFirst: true)
        case .alertSecondButtonReturn: runInstall(dylib: dylib, pinFirst: false)
        default: return
        }
    }

    private func runInstall(dylib: URL, pinFirst: Bool) {
        runBusy(verb: "Installing") {
            let useNotProton = NotProtonMode.isEnabled()

            if SteamInstaller.notProtonPresent {
                if useNotProton {
                    try SteamInstaller.installDirectCompatibility(sourceDylib: dylib)
                } else {
                    try SteamInstaller.installNotProtonCompatibility(sourceDylib: dylib)
                }
                return
            }

            // NotProton is gone: remove any compatibility leftovers and install normally.
            SteamInstaller.removeLauncherCompatibility()
            if SteamInstaller.directModeInstalled {
                SteamInstaller.removeDirectCompatibility()
            }

            if SteamInstaller.hasForeignInsert() {
                // Keep another injector's list intact by using the direct path.
                try SteamInstaller.installDirectCompatibility(sourceDylib: dylib)
                return
            }
            switch SteamInstaller.status() {
            case .installed, .outdated:
                try SteamInstaller.install(sourceDylib: dylib)
            default:
                try MacCrab.ensurePristineBundle()
                if pinFirst { try MacCrab.pinToSupported() }
                try SteamInstaller.install(sourceDylib: dylib)
            }
        }
    }

    @objc private func doUninstall() {
        if SteamInstaller.directModeInstalled {
            let alert = NSAlert()
            alert.messageText = "Remove macSteam from Steam's direct launch?"
            alert.informativeText = "macSteam will stop injecting when you open Steam.app. "
                + "NotProton stays installed and keeps working normally."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            runBusy(verb: "Removing") { SteamInstaller.removeDirectCompatibility() }
            return
        }
        if SteamInstaller.launcherInstalled {
            let alert = NSAlert()
            alert.messageText = "Remove the macSteam launcher?"
            alert.informativeText = "Steam itself will not be modified. NotProton stays installed."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            runBusy(verb: "Removing") { SteamInstaller.removeLauncherCompatibility() }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Uninstall macSteam from Steam?"
        alert.informativeText = "This downloads a clean, Valve-signed Steam and replaces the "
            + "installed one, removing macSteam completely. Takes a few minutes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runBusy(verb: "Uninstalling") { try MacCrab.uninstallToStock() }
    }

    @objc private func repairSteam() {
        presentAsSheet(RepairViewController())
    }

    @objc private func openSteam() {
        NSWorkspace.shared.open(SteamInstaller.launcherInstalled ? Paths.launcherApp : Paths.steamApp)
    }

    private func runBusy(verb: String = "Working", _ work: @escaping @Sendable () throws -> Void) {
        statusGlyph.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                    accessibilityDescription: nil)
        statusGlyph.contentTintColor = .secondaryLabelColor
        headlineLabel.stringValue = "\(verb)…"
        detailLabel.stringValue = ""

        MacsteamApp.runBusy(spinner: spinner, setBusy: { [self] busy in
            installButton.isEnabled = !busy && bundledDylib != nil
            uninstallButton.isEnabled = !busy
            openButton.isEnabled = !busy
            repairButton.isEnabled = !busy
        }, refresh: { [self] in refresh() }, work: work)
    }
}
