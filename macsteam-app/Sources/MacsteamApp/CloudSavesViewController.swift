// Cloud Saves pane: mirrors Steam's local cloud cache into a folder or Google Drive.
import AppKit

/// Scroll content must grow from the top; AppKit's default NSView origin is bottom-left.
private final class TopAlignedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class CloudSavesViewController: NSViewController {
    private let store: ConfigStore
    private var enableSwitch: NSSwitch!
    private var providerPopup: NSPopUpButton!
    private var pathField: NSTextField!
    private var chooseButton: NSButton!
    private var connectButton: NSButton!
    private var openDriveButton: NSButton!
    private var syncButton: NSButton!
    private var statusLabel: NSTextField!
    private var statusIcon: NSImageView!
    private var spinner: NSProgressIndicator!
    private var detailLabel: NSTextField!
    private var noteLabel: NSTextField!
    private var gamesHeading: NSTextField!
    private var gamesCard: CloudSavesGamesCard!

    private var enableCard: SettingsCard!
    private var providerCard: SettingsCard!
    private var folderCard: SettingsCard!
    private var googleCard: SettingsCard!
    private var emailFetchStarted = false

    init(store: ConfigStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(syncFinished),
            name: Notification.Name("com.macsteam.cloudSavesSyncFinished"), object: nil)
    }

    @objc private func syncFinished() {
        updateStatus()
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 690, height: 520))
        let m = Metrics.paneMargin

        let heading = settingsGroupLabel("Cloud Saves")
        let subtitle = NSTextField(labelWithString:
            "Steam writes cloud saves and CrossOver game saves under userdata; macSteam "
            + "mirrors those folders for games added to macSteam into a folder or Google Drive.")
        subtitle.font = Typography.caption
        subtitle.textColor = Colors.secondaryText
        subtitle.maximumNumberOfLines = 0
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        enableSwitch = NSSwitch()
        enableSwitch.target = self
        enableSwitch.action = #selector(toggleChanged)
        enableSwitch.setAccessibilityLabel("Enable Cloud Saves")
        enableCard = SettingsCard(rows: [
            SettingRow(title: "Enable Cloud Saves",
                       subtitle: "Runs in the background while Steam is open.",
                       control: enableSwitch),
        ])

        providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        providerPopup.controlSize = .regular
        for provider in CloudSavesProvider.allCases {
            providerPopup.addItem(withTitle: provider.title)
            providerPopup.lastItem?.representedObject = provider.rawValue
        }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        providerPopup.translatesAutoresizingMaskIntoConstraints = false
        providerPopup.widthAnchor.constraint(equalToConstant: 230).isActive = true
        providerCard = SettingsCard(rows: [
            SettingRow(title: "Provider",
                       subtitle: "Folder handles iCloud Drive, Dropbox, or any synced "
                           + "folder. Google Drive signs in directly.",
                       control: providerPopup),
        ])

        pathField = NSTextField(string: "")
        pathField.placeholderString = "Choose a sync folder"
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.widthAnchor.constraint(equalToConstant: 330).isActive = true
        pathField.delegate = self

        chooseButton = makeButton(title: "Choose…", target: self,
                                  action: #selector(chooseFolder))
        let pathStack = NSStackView(views: [pathField, chooseButton])
        pathStack.orientation = .horizontal
        pathStack.spacing = 6
        pathStack.alignment = .centerY
        folderCard = SettingsCard(rows: [
            SettingRow(title: "Sync folder",
                       subtitle: "Point this at a cloud-synced folder (iCloud Drive, "
                            + "Dropbox, a NAS mount). The layout is <account>/<appid>/remote.",
                       control: pathStack),
        ])

        connectButton = makeButton(title: "Connect Google Drive…", target: self,
                                   action: #selector(connectGoogle))
        openDriveButton = makeButton(title: "Open Drive", target: self,
                                     action: #selector(openGoogleDrive))
        openDriveButton.isHidden = true
        let googleButtons = NSStackView(views: [openDriveButton, connectButton])
        googleButtons.orientation = .horizontal
        googleButtons.spacing = 6
        googleButtons.alignment = .centerY
        googleCard = SettingsCard(rows: [
            SettingRow(title: "Google Drive",
                       subtitle: "Saves are kept in sync with a macSteam Cloud Saves folder in your Drive.",
                       control: googleButtons),
        ])

        statusIcon = NSImageView()
        statusIcon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        statusIcon.setAccessibilityElement(false)
        statusIcon.image = NSImage(systemSymbolName: StatusTone.neutral.symbol,
                                   accessibilityDescription: nil)
        statusIcon.contentTintColor = StatusTone.neutral.color

        statusLabel = NSTextField(labelWithString: "Cloud Saves are off.")
        statusLabel.font = Typography.body
        statusLabel.textColor = Colors.secondaryText
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        syncButton = makeButton(title: "Sync Now", target: self, action: #selector(syncNow))

        let statusRow = NSStackView(views: [statusIcon, statusLabel, spinner,
                                            NSView(), syncButton])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true

        detailLabel = NSTextField(labelWithString: "")
        detailLabel.font = Typography.caption
        detailLabel.textColor = Colors.secondaryText
        detailLabel.maximumNumberOfLines = 0
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        noteLabel = NSTextField(labelWithString:
            "Only games added to macSteam are synced. Games removed from macSteam are "
            + "moved out of the local mirror and their Drive copies go to Trash. The "
            + "newest copy wins and the older version is backed up under .conflicts. "
            + "Deletions are not propagated automatically. See Settings → Logging for details.")
        noteLabel.font = Typography.caption
        noteLabel.textColor = Colors.quiet
        noteLabel.maximumNumberOfLines = 0
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.translatesAutoresizingMaskIntoConstraints = false

        gamesHeading = settingsGroupLabel("Synced games")
        gamesCard = CloudSavesGamesCard()

        let stack = NSStackView(views: [heading, subtitle, enableCard, providerCard,
                                        folderCard, googleCard, statusRow,
                                        detailLabel, gamesHeading, gamesCard, noteLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: heading)
        stack.setCustomSpacing(16, after: subtitle)
        stack.setCustomSpacing(12, after: enableCard)
        stack.setCustomSpacing(12, after: providerCard)
        stack.setCustomSpacing(12, after: folderCard)
        stack.setCustomSpacing(12, after: googleCard)
        stack.setCustomSpacing(14, after: detailLabel)
        stack.setCustomSpacing(6, after: gamesHeading)
        stack.setCustomSpacing(16, after: gamesCard)
        stack.translatesAutoresizingMaskIntoConstraints = false
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for card in [enableCard!, providerCard!, folderCard!, googleCard!] {
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            card.heightAnchor.constraint(equalToConstant: 66).isActive = true
            card.setContentHuggingPriority(.required, for: .vertical)
        }
        statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        gamesHeading.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        gamesCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        noteLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let scroll = makeScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = TopAlignedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document

        let preferredWidth = stack.widthAnchor.constraint(equalToConstant: 820)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: m),
            stack.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: m),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -m),
            preferredWidth,
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -m),

            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
        ])
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        loadSettings()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        loadSettings()
    }

    private func loadSettings() {
        let settings = CloudSavesSettings.load()
        enableSwitch.state = settings.enabled ? .on : .off
        if let index = CloudSavesProvider.allCases.firstIndex(of: settings.provider) {
            providerPopup.selectItem(at: index)
        }
        pathField.stringValue = settings.syncPath
        updateProviderUI(settings)
        updateStatus()
        if settings.provider == .gdrive, GoogleDriveAuth.isConnected,
           GoogleDriveAuth.cachedAccountEmail == nil, !emailFetchStarted {
            emailFetchStarted = true
            Task { [weak self] in
                await GoogleDriveAuth.refreshAccountEmail()
                self?.updateStatus()
            }
        }
    }

    private func updateProviderUI(_ settings: CloudSavesSettings) {
        let enabled = settings.enabled
        enableSwitch.state = enabled ? .on : .off
        providerPopup.isEnabled = true
        let usesFolder = settings.provider == .folder
        folderCard.isHidden = !usesFolder
        googleCard.isHidden = settings.provider != .gdrive
        pathField.isEnabled = enabled && usesFolder
        chooseButton.isEnabled = enabled && usesFolder
        connectButton.isEnabled = settings.provider == .gdrive
        openDriveButton.isHidden = !(settings.provider == .gdrive
                                     && GoogleDriveAuth.isConnected)
        syncButton.isEnabled = enabled
        if settings.provider == .gdrive {
            connectButton.title = GoogleDriveAuth.isConnected
                ? "Disconnect" : "Connect Google Drive…"
            connectButton.toolTip = GoogleDriveAuth.isConnected
                ? "Disconnect Google Drive" : "Sign in to Google Drive."
        }
    }

    private func updateStatus() {
        updateGames()
        let settings = CloudSavesSettings.load()
        if !settings.enabled {
            setStatus("Cloud Saves are off.", tone: .neutral)
            detailLabel.stringValue = ""
            return
        }
        switch settings.provider {
        case .folder:
            guard let path = settings.expandedSyncURL else {
                setStatus("Choose a sync folder.", tone: .warn)
                detailLabel.stringValue = ""
                return
            }
            setStatus("Folder: \(path.lastPathComponent)", tone: .ok)
        case .gdrive:
            if GoogleDriveAuth.isConnected {
                if let email = GoogleDriveAuth.cachedAccountEmail {
                    setStatus("Google Drive · \(email)", tone: .ok)
                } else {
                    setStatus("Google Drive connected.", tone: .ok)
                }
            } else {
                setStatus("Connect Google Drive to sync saves.", tone: .warn)
            }
        }
        if let report = CloudSavesRunner.shared.lastReport {
            var lines = [report.summary]
            lines.append(contentsOf: report.errors.prefix(4))
            if let lastSync = CloudSavesRunner.shared.lastSync {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                lines.append("Last sync: \(formatter.string(from: lastSync))")
            }
            detailLabel.stringValue = lines.joined(separator: "\n")
        } else {
            detailLabel.stringValue = "Waiting for the first sync…"
        }
    }

    private func updateGames() {
        let settings = CloudSavesSettings.load()
        let enabled = settings.enabled
        gamesHeading.isHidden = !enabled
        gamesCard.isHidden = !enabled
        guard enabled else { return }

        store.reloadFromDisk()
        let report = CloudSavesRunner.shared.lastReport
        var merged: [Int: CloudSavesGameSync] = [:]
        for game in report?.games ?? [] {
            let root = cloudRoot(for: game.appID)
            if var existing = merged[root] {
                existing.merge(game)
                merged[root] = existing
            } else {
                merged[root] = game
            }
        }

        let topLevel = Set(store.config.topLevelApps)
        var ids = Set(merged.keys)
        ids.formUnion(settings.disabledApps.intersection(topLevel))
        let items = ids.compactMap { appID -> CloudSavesGameItem? in
            guard topLevel.contains(appID) else { return nil }
            let game = merged[appID]
            let itemEnabled = !settings.disabledApps.contains(appID)
            let name = store.config.appNames[appID] ?? game?.displayName ?? "App \(appID)"
            let status: String
            let tone: CloudSavesGameTone
            if !itemEnabled {
                status = "Paused"
                tone = .paused
            } else if let game, game.files > 0 || !game.errors.isEmpty
                || game.copiedToCloud > 0 || game.copiedToLocal > 0 {
                status = game.statusText
                tone = game.isSuccess ? .ok : .warning
            } else {
                status = "No save files yet"
                tone = .empty
            }
            return CloudSavesGameItem(appID: appID, name: name, enabled: itemEnabled,
                                      status: status, tone: tone)
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        gamesCard.update(items: items,
                         lastSync: report == nil ? nil : CloudSavesRunner.shared.lastSync,
                         onToggle: { [weak self] appID, enabled in
                             self?.setCloudSync(appID: appID, enabled: enabled)
                         })
    }

    private func cloudRoot(for appID: Int) -> Int {
        var current = appID
        var seen = Set<Int>()
        while let parent = store.config.appParents[current],
              seen.insert(current).inserted {
            current = parent
        }
        return current
    }

    private func setCloudSync(appID: Int, enabled: Bool) {
        var settings = CloudSavesSettings.load()
        if enabled {
            settings.disabledApps.remove(appID)
        } else {
            settings.disabledApps.insert(appID)
        }
        do {
            try settings.save()
        } catch {
            presentAlert("Couldn’t save Cloud Saves settings",
                         error.localizedDescription, style: .warning)
            updateGames()
            return
        }
        CloudSavesRunner.shared.refreshSettings()
        updateStatus()
    }

    private func setStatus(_ text: String, tone: StatusTone) {
        statusIcon.image = NSImage(systemSymbolName: tone.symbol,
                                   accessibilityDescription: nil)
        statusIcon.contentTintColor = tone.color
        statusLabel.stringValue = text
    }

    @objc private func toggleChanged() {
        var settings = CloudSavesSettings.load()
        settings.enabled = enableSwitch.state == .on
        if settings.enabled {
            switch settings.provider {
            case .folder where settings.syncPath.isEmpty:
                if !pickFolder() {
                    settings.enabled = false
                    enableSwitch.state = .off
                    save(settings)
                }
                return
            case .gdrive where !GoogleDriveAuth.isConnected:
                connectGoogle()
                return
            default:
                break
            }
        }
        save(settings)
    }

    @objc private func providerChanged() {
        let index = providerPopup.indexOfSelectedItem
        guard index >= 0, index < CloudSavesProvider.allCases.count else { return }
        var settings = CloudSavesSettings.load()
        settings.provider = CloudSavesProvider.allCases[index]
        save(settings)
        updateProviderUI(settings)
        updateStatus()
    }

    @objc private func chooseFolder() {
        _ = pickFolder()
    }

    private func pickFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        var settings = CloudSavesSettings.load()
        settings.syncPath = url.path
        settings.provider = .folder
        settings.enabled = true
        save(settings)
        return true
    }

    @objc private func connectGoogle() {
        if GoogleDriveAuth.isConnected {
            GoogleDriveAuth.disconnect()
            var settings = CloudSavesSettings.load()
            settings.enabled = false
            save(settings)
            return
        }
        spinner.startAnimation(nil)
        connectButton.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await GoogleDriveAuth.connect()
                await GoogleDriveAuth.refreshAccountEmail()
                var settings = CloudSavesSettings.load()
                settings.provider = .gdrive
                settings.enabled = true
                try settings.save()
                self.spinner.stopAnimation(nil)
                self.connectButton.isEnabled = true
                self.updateProviderUI(settings)
                self.updateStatus()
                DistributedNotificationCenter.default().post(
                    name: Notification.Name("com.macsteam.cloudSavesChanged"), object: nil)
                CloudSavesRunner.shared.refreshSettings()
            } catch {
                self.spinner.stopAnimation(nil)
                self.connectButton.isEnabled = true
                var settings = CloudSavesSettings.load()
                if !GoogleDriveAuth.isConnected {
                    settings.enabled = false
                    try? settings.save()
                    DistributedNotificationCenter.default().post(
                        name: Notification.Name("com.macsteam.cloudSavesChanged"), object: nil)
                    CloudSavesRunner.shared.refreshSettings()
                }
                self.updateProviderUI(settings)
                self.updateStatus()
                presentAlert("Couldn’t connect Google Drive",
                             error.localizedDescription, style: .warning)
            }
        }
    }

    @objc private func openGoogleDrive() {
        NSWorkspace.shared.open(GoogleDriveAuth.driveFolderURL)
    }

    @objc private func syncNow() {
        let settings = CloudSavesSettings.load()
        guard settings.enabled, settings.expandedSyncURL != nil else {
            updateStatus()
            return
        }
        spinner.startAnimation(nil)
        syncButton.isEnabled = false
        CloudSavesRunner.shared.syncNow { [weak self] _ in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            self.syncButton.isEnabled = true
            self.updateStatus()
        }
    }

    private func save(_ settings: CloudSavesSettings) {
        do {
            try settings.save()
        } catch {
            presentAlert("Couldn’t save Cloud Saves settings", error.localizedDescription,
                         style: .warning)
            return
        }
        pathField.stringValue = settings.syncPath
        enableSwitch.state = settings.enabled ? .on : .off
        updateProviderUI(settings)
        updateStatus()
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.macsteam.cloudSavesChanged"), object: nil)
        CloudSavesRunner.shared.refreshSettings()
    }
}

extension CloudSavesViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        var settings = CloudSavesSettings.load()
        settings.syncPath = pathField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        save(settings)
    }
}

// MARK: - Synced games card

private enum CloudSavesGameTone {
    case ok
    case paused
    case warning
    case empty
}

private struct CloudSavesGameItem {
    let appID: Int
    let name: String
    let enabled: Bool
    let status: String
    let tone: CloudSavesGameTone
}

@MainActor
private final class CloudSavesGamesCard: NSView {
    private let countLabel = NSTextField(labelWithString: "")
    private let listStack = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private var onToggle: ((Int, Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        applyCardSurface()

        countLabel.font = Typography.caption
        countLabel.textColor = Colors.secondaryText
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = Typography.caption
        emptyLabel.textColor = Colors.secondaryText
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [countLabel, listStack, emptyLabel])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            listStack.widthAnchor.constraint(equalTo: content.widthAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        update(items: [], lastSync: nil, onToggle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCardSurfaceColors()
    }

    func update(items: [CloudSavesGameItem], lastSync: Date?,
                onToggle: ((Int, Bool) -> Void)?) {
        self.onToggle = onToggle
        listStack.arrangedSubviews.forEach {
            listStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let hasGames = !items.isEmpty
        countLabel.isHidden = !hasGames
        listStack.isHidden = !hasGames
        emptyLabel.isHidden = hasGames

        guard hasGames else {
            emptyLabel.stringValue = lastSync == nil
                ? "Waiting for the first sync…"
                : "No macSteam games with save data yet."
            return
        }

        let active = items.filter(\.enabled).count
        let synced = items.filter { $0.enabled && $0.tone != .warning }.count
        var text = "\(synced) of \(items.count) game\(items.count == 1 ? "" : "s") synced"
        if active < items.count { text += " · \(items.count - active) paused" }
        if let lastSync {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            text += " · \(formatter.string(from: lastSync))"
        }
        countLabel.stringValue = text

        for (index, item) in items.enumerated() {
            if index > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                listStack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            }
            let row = makeRow(item)
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    private func makeRow(_ item: CloudSavesGameItem) -> NSView {
        let icon = NSImageView()
        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        let symbol: String
        let tint: NSColor
        switch item.tone {
        case .ok:
            symbol = "checkmark.circle.fill"
            tint = .systemGreen
        case .paused:
            symbol = "pause.circle.fill"
            tint = Colors.quiet
        case .warning:
            symbol = "exclamationmark.triangle.fill"
            tint = .systemOrange
        case .empty:
            symbol = "minus.circle"
            tint = Colors.quiet
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let name = NSTextField(labelWithString: item.name)
        name.font = Typography.body
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(labelWithString: item.status)
        status.font = Typography.caption
        status.textColor = item.enabled ? Colors.secondaryText : Colors.quiet
        status.alignment = .right
        status.lineBreakMode = .byTruncatingTail
        status.maximumNumberOfLines = 1
        status.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        status.translatesAutoresizingMaskIntoConstraints = false
        status.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true

        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = item.enabled ? .on : .off
        toggle.tag = item.appID
        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))
        toggle.setAccessibilityLabel("Cloud sync for \(item.name)")
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        toggle.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [icon, name, NSView(), status, toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return row
    }

    @objc private func toggleChanged(_ sender: NSSwitch) {
        let appID = sender.tag
        let enabled = sender.state == .on
        // Rebuilding the card in the middle of the switch action can tear down
        // the sender; defer it one run-loop turn.
        DispatchQueue.main.async { [weak self] in
            self?.onToggle?(appID, enabled)
        }
    }
}
