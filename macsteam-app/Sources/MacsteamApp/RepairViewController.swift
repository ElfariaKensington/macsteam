// Repair pane
import AppKit

final class RepairViewController: NSViewController {

    private var glyph: NSImageView!
    private var headlineLabel: NSTextField!
    private var detailLabel: NSTextField!

    private var buildLabel: NSTextField!

    private var repairButton: NSButton!
    private var openButton: NSButton!
    private var closeButton: NSButton!
    private var spinner: NSProgressIndicator!

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 460))

        glyph = NSImageView()
        glyph.symbolConfiguration = .init(pointSize: 40, weight: .regular)
        glyph.setAccessibilityElement(false)   // headline carries the meaning
        glyph.translatesAutoresizingMaskIntoConstraints = false

        headlineLabel = NSTextField(labelWithString: "")
        headlineLabel.font = Typography.largeTitle
        headlineLabel.textColor = .labelColor
        headlineLabel.alignment = .center
        headlineLabel.lineBreakMode = .byWordWrapping
        headlineLabel.maximumNumberOfLines = 0
        headlineLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel = NSTextField(labelWithString: "")
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = Typography.body
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 0

        buildLabel = NSTextField(labelWithString: "")
        buildLabel.font = Typography.sectionHeader
        buildLabel.textColor = .labelColor
        buildLabel.alignment = .center
        buildLabel.lineBreakMode = .byTruncatingTail
        buildLabel.translatesAutoresizingMaskIntoConstraints = false

        repairButton = makeButton(title: "Repair", target: self, action: #selector(doRepair))
        repairButton.keyEquivalent = "\r"
        openButton = makeButton(title: "Open Steam", target: self, action: #selector(openSteam))
        closeButton = makeButton(title: "Close", target: self, action: #selector(close))

        spinner = NSProgressIndicator()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let footerDivider = NSBox()
        footerDivider.boxType = .separator
        footerDivider.translatesAutoresizingMaskIntoConstraints = false

        let statusGroup = NSStackView(views: [glyph, headlineLabel, detailLabel, buildLabel])
        statusGroup.orientation = .vertical
        statusGroup.alignment = .centerX
        statusGroup.spacing = 6
        statusGroup.setCustomSpacing(12, after: glyph)
        statusGroup.setCustomSpacing(10, after: detailLabel)
        statusGroup.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(statusGroup)
        root.addSubview(footerDivider)
        root.addSubview(openButton)
        root.addSubview(closeButton)
        root.addSubview(repairButton)
        root.addSubview(spinner)

        let M = Metrics.paneMargin
        NSLayoutConstraint.activate([
            statusGroup.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            statusGroup.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            statusGroup.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            statusGroup.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor, constant: M),
            statusGroup.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: M),

            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            headlineLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380),

            footerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: repairButton.topAnchor, constant: -12),
            footerDivider.topAnchor.constraint(greaterThanOrEqualTo: statusGroup.bottomAnchor, constant: Metrics.headerGap),

            repairButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -M),
            repairButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -M),

            openButton.trailingAnchor.constraint(equalTo: repairButton.leadingAnchor, constant: -10),
            openButton.centerYAnchor.constraint(equalTo: repairButton.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: repairButton.centerYAnchor),

            spinner.centerYAnchor.constraint(equalTo: repairButton.centerYAnchor),
            spinner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: M),
        ])

        view = root
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refresh()
    }

    // MARK: - Rendering

    private func refresh() {
        let steamPresent = MacCrab.status() != .steamMissing

        detailLabel.isHidden = false

        if steamPresent {
            glyph.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: nil)
            glyph.contentTintColor = .secondaryLabelColor
            headlineLabel.stringValue = "Repair Steam"
            detailLabel.stringValue = ""
            detailLabel.isHidden = true
            buildLabel.stringValue = currentBuildLine()
            buildLabel.isHidden = false
        } else {
            glyph.image = NSImage(systemSymbolName: StatusTone.bad.symbol, accessibilityDescription: nil)
            glyph.contentTintColor = StatusTone.bad.color
            headlineLabel.stringValue = "Steam not found"
            detailLabel.stringValue = "Steam isn't in your Applications folder. Install it from Valve, "
                + "then come back to repair it."
            buildLabel.stringValue = ""
            buildLabel.isHidden = true
        }

        repairButton.isEnabled = steamPresent
        openButton.isEnabled = steamPresent
    }

    private func currentBuildLine() -> String {
        switch MacCrab.status() {
        case .supported, .unsupported:
            if let v = MacCrab.detectedVersion() { return "Current Steam Build: \(v)" }
            return "Current Steam Build: unknown"
        case .unknown:
            return "Current Steam Build: unreadable"
        case .steamMissing:
            return ""
        }
    }

    // MARK: - Actions

    @objc private func doRepair() {
        let alert = NSAlert()
        alert.messageText = "Reinstall Steam at the latest build?"
        alert.informativeText = "This will remove macSteam and download a clean copy of Steam. "
            + "This can take a few minutes."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Repair")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runRepair()
    }

    @objc private func openSteam() {
        NSWorkspace.shared.open(Paths.steamApp)
    }

    @objc private func close() {
        dismiss(self)
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss(self)
    }

    private func runRepair() {
        setBusy(true)
        spinner.startAnimation(nil)
        setRepairing("Getting ready to repair Steam")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<Void, Error> = Result {
                try MacCrab.repairToStock(progress: { step in
                    DispatchQueue.main.async { self?.setRepairing(step) }
                })
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.spinner.stopAnimation(nil)
                self.setBusy(false)
                switch result {
                case .success:
                    self.setSucceeded()
                case .failure(let error):
                    if error is SteamInstaller.PermissionDenied {
                        presentAppManagementAlert()
                    } else {
                        presentAlert("Couldn't repair", error.localizedDescription, style: .warning)
                    }
                    self.refresh()
                }
            }
        }
    }

    private func setRepairing(_ step: String) {
        glyph.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: nil)
        glyph.contentTintColor = .secondaryLabelColor
        headlineLabel.stringValue = step
        detailLabel.stringValue = ""
        detailLabel.isHidden = true
        buildLabel.stringValue = ""
        buildLabel.isHidden = true
    }

    private func setSucceeded() {
        glyph.image = NSImage(systemSymbolName: StatusTone.ok.symbol, accessibilityDescription: nil)
        glyph.contentTintColor = StatusTone.ok.color
        headlineLabel.stringValue = "Steam repaired"
        detailLabel.stringValue = "Steam has been restored to an unmodified client. "
            + "Run Install to patch Steam with macSteam."
        detailLabel.isHidden = false
        buildLabel.stringValue = ""
        buildLabel.isHidden = true
        repairButton.isEnabled = true
        openButton.isEnabled = true
    }

    private func setBusy(_ busy: Bool) {
        repairButton.isEnabled = !busy
        openButton.isEnabled = !busy
        closeButton.isEnabled = !busy
    }
}
