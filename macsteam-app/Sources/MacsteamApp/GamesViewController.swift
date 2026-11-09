// Store: Steam search plus LuaTools Discord-authenticated Lua/manifest installs.
// Replaces the old Hubcap catalog tab; the Hubcap store-button key lives in Settings.
import AppKit
import Foundation

@MainActor
final class GamesViewController: NSViewController {
    private let store: ConfigStore
    private let onConfigChanged: () -> Void
    private let client = LuaToolsGamesClient.shared

    private var statusIcon: NSImageView!
    private var statusLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var usageLabel: NSTextField!
    private var searchField: NSSearchField!
    private var tableView: NSTableView!
    private var tableScroll: NSScrollView!
    private var emptyLabel: NSTextField!

    private var games: [LuaToolsSteamGame] = []
    private var isLoading = false
    private var isInstalling = false
    private var installingAppID: Int?
    private var usageRemaining: Int?
    private var searchTask: Task<Void, Never>?
    private var usageTask: Task<Void, Never>?
    private var searchGeneration = 0

    init(store: ConfigStore, onConfigChanged: @escaping () -> Void) {
        self.store = store
        self.onConfigChanged = onConfigChanged
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 690, height: 520))
        let m = Metrics.paneMargin

        statusIcon = NSImageView()
        statusIcon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        statusIcon.setAccessibilityElement(false)
        statusIcon.image = NSImage(systemSymbolName: StatusTone.neutral.symbol,
                                   accessibilityDescription: nil)
        statusIcon.contentTintColor = StatusTone.neutral.color

        statusLabel = NSTextField(labelWithString: "Search Steam to add a game")
        statusLabel.font = Typography.body
        statusLabel.textColor = Colors.secondaryText
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1

        usageLabel = NSTextField(labelWithString: "")
        usageLabel.font = Typography.caption
        usageLabel.textColor = Colors.secondaryText
        usageLabel.alignment = .right
        usageLabel.lineBreakMode = .byTruncatingTail
        usageLabel.maximumNumberOfLines = 1
        usageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        usageLabel.setContentHuggingPriority(.required, for: .horizontal)
        usageLabel.setAccessibilityLabel("LuaTools daily download limit")

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let statusRow = NSStackView(views: [statusIcon, statusLabel, spinner,
                                            NSView(), usageLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true

        searchField = NSSearchField()
        searchField.placeholderString = "Search Steam by game name or App ID"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityLabel("Search Steam games")

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 64
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        let column = NSTableColumn(identifier: .init("games"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        tableScroll = makeScrollView()
        tableScroll.documentView = tableView
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel = NSTextField(labelWithString:
            "Search Steam for a game, or enter its App ID.")
        emptyLabel.font = Typography.body
        emptyLabel.textColor = Colors.secondaryText
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(statusRow)
        root.addSubview(searchField)
        root.addSubview(tableScroll)
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            statusRow.topAnchor.constraint(equalTo: root.topAnchor, constant: m),
            statusRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            statusRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),

            searchField.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),

            tableScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            tableScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            tableScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            tableScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -m),

            emptyLabel.centerXAnchor.constraint(equalTo: tableScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableScroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: tableScroll.leadingAnchor,
                                                constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: tableScroll.trailingAnchor,
                                                 constant: -24),
        ])

        view = root
        updateStatus()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        store.reloadFromDisk()
        if games.isEmpty {
            showEmpty("Search Steam for a game, or enter its App ID.")
        }
        refreshUsage()
    }

    func reloadFromStore() {
        guard isViewLoaded else { return }
        store.reloadFromDisk()
        tableView.reloadData()
    }

    // MARK: - Search

    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            games = []
            tableView.reloadData()
            showEmpty("Search Steam for a game, or enter its App ID.")
            updateStatus()
            return
        }
        setBusy(true)
        showEmpty("Searching Steam…")
        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 380_000_000)
            guard !Task.isCancelled else { return }
            do {
                let results = try await client.search(trimmed)
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                self.games = results
                self.setBusy(false)
                self.tableView.reloadData()
                if results.isEmpty {
                    self.showEmpty("No Steam games matched that search.")
                } else {
                    self.emptyLabel.isHidden = true
                }
                self.updateStatus()
            } catch {
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                self.setBusy(false)
                self.games = []
                self.tableView.reloadData()
                self.showEmpty(error.localizedDescription)
                self.updateStatus(error: error.localizedDescription)
            }
        }
    }

    // MARK: - Add flow

    private func add(_ game: LuaToolsSteamGame) {
        guard !isInstalling else { return }
        if store.config.apps.contains(game.id) { return }
        isInstalling = true
        installingAppID = game.id
        tableView.reloadData()
        spinner.startAnimation(nil)
        setStatus("Checking LuaTools sources for \(game.name)…", tone: .neutral)

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isInstalling = false
                self.installingAppID = nil
                self.spinner.stopAnimation(nil)
                self.tableView.reloadData()
                self.refreshUsage()
            }
            do {
                self.setStatus("Checking LuaTools sources for \(game.name)…", tone: .neutral)
                let sources = try await client.sources(appID: game.id)
                guard let source = self.chooseSource(sources, for: game) else { return }

                if !(await LuaToolsAuth.shared.isSignedIn()) {
                    self.setStatus("Complete Discord sign-in in your browser…", tone: .neutral)
                    _ = try await LuaToolsAuth.shared.signIn()
                    NSApp.activate(ignoringOtherApps: true)
                }

                self.setStatus("Downloading Lua + manifests for \(game.name)…", tone: .neutral)
                let data = try await client.downloadManifest(
                    appID: game.id, source: source, gameName: game.name)
                self.setStatus("Installing Lua + manifests for \(game.name)…", tone: .neutral)
                let result = try LuaToolsManifestInstaller.installManifest(
                    data: data, appID: game.id, store: self.store)
                self.onConfigChanged()
                _ = await HubcapActivation.requestRefresh()
                self.setStatus("Added \(result.title)", tone: .ok)
                self.tableView.reloadData()
                let manifestText = result.manifestCount == 0
                    ? "The Lua was installed. This source did not include separate depot manifests."
                    : "The Lua and \(result.manifestCount) depot manifest"
                        + (result.manifestCount == 1 ? "" : "s") + " were installed."
                presentAlert(
                    "Added \(result.title)",
                    manifestText + " Open the game's Steam store page and click Install with Steam.",
                    style: .informational)
            } catch {
                self.setStatus(error.localizedDescription, tone: .bad)
                presentAlert("Couldn’t add \(game.name)", error.localizedDescription,
                             style: .warning)
            }
        }
    }

    private func chooseSource(_ sources: [String], for game: LuaToolsSteamGame) -> String? {
        guard let first = sources.first else { return nil }
        guard sources.count > 1 else { return first }
        let alert = NSAlert()
        alert.messageText = "Choose a LuaTools source"
        alert.informativeText = "Both sources have manifests for \(game.name)."
        alert.alertStyle = .informational
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26),
                                  pullsDown: false)
        popup.addItems(withTitles: sources)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return popup.titleOfSelectedItem ?? first
    }

    // MARK: - Auth

    // MARK: - UI state

    private func setBusy(_ busy: Bool) {
        isLoading = busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        updateStatus()
    }

    private func updateStatus(error: String? = nil) {
        if let error {
            setStatus(error, tone: .bad)
            return
        }
        if isLoading || isInstalling { return }
        if games.isEmpty {
            setStatus("Search Steam to add a game", tone: .neutral)
        } else {
            setStatus("\(games.count) game\(games.count == 1 ? "" : "s") found", tone: .ok)
        }
    }

    private func setStatus(_ text: String, tone: StatusTone) {
        statusIcon.image = NSImage(systemSymbolName: tone.symbol,
                                   accessibilityDescription: nil)
        statusIcon.contentTintColor = tone.color
        statusLabel.stringValue = text
    }

    private func refreshUsage() {
        usageTask?.cancel()
        usageTask = Task { [weak self] in
            guard let self else { return }
            guard await LuaToolsAuth.shared.isSignedIn() else {
                self.usageRemaining = nil
                self.usageLabel.stringValue = "LuaTools: sign in to see limit"
                self.usageLabel.textColor = Colors.secondaryText
                self.tableView.reloadData()
                return
            }
            self.usageLabel.stringValue = "LuaTools: checking limit…"
            self.usageLabel.textColor = Colors.secondaryText
            guard let usage = await self.client.usage() else {
                if !Task.isCancelled {
                    self.usageRemaining = nil
                    self.usageLabel.stringValue = "LuaTools: limit unavailable"
                    self.tableView.reloadData()
                }
                return
            }
            guard !Task.isCancelled else { return }
            self.usageRemaining = usage.remaining
            if usage.remaining > 0 {
                self.usageLabel.stringValue =
                    "LuaTools: \(usage.remaining) game\(usage.remaining == 1 ? "" : "s") left today"
                self.usageLabel.textColor = Colors.secondaryText
            } else {
                self.usageLabel.stringValue = "LuaTools: daily limit reached"
                self.usageLabel.textColor = .systemOrange
            }
            self.tableView.reloadData()
        }
    }

    private func showEmpty(_ text: String) {
        emptyLabel.stringValue = text
        emptyLabel.isHidden = false
    }
}

// MARK: - Search field

extension GamesViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        scheduleSearch(searchField.stringValue)
    }
}

// MARK: - Table

extension GamesViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { games.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < games.count else { return nil }
        let game = games[row]
        let id = NSUserInterfaceItemIdentifier("luatools-game")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? GamesGameCell)
            ?? GamesGameCell(identifier: id)
        let configured = store.config.apps.contains(game.id)
        cell.configure(game: game, configured: configured,
                       busy: installingAppID == game.id,
                       enabled: !isInstalling && (usageRemaining ?? 1) > 0) { [weak self] in
            self?.add(game)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

// MARK: - Game row

@MainActor
final class GamesGameCell: NSTableCellView {
    private let art = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let idLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton()
    private var onAdd: (() -> Void)?
    private var artTask: Task<Void, Never>?
    private var artKey: String?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        art.translatesAutoresizingMaskIntoConstraints = false
        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true
        art.layer?.cornerRadius = 4
        art.layer?.masksToBounds = true
        art.setAccessibilityElement(false)

        nameLabel.font = Typography.body
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        idLabel.font = Typography.caption
        idLabel.textColor = Colors.secondaryText
        idLabel.lineBreakMode = .byTruncatingTail
        idLabel.maximumNumberOfLines = 1
        idLabel.translatesAutoresizingMaskIntoConstraints = false

        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        addButton.target = self
        addButton.action = #selector(addPressed)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.setContentHuggingPriority(.required, for: .horizontal)
        addButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(art)
        addSubview(nameLabel)
        addSubview(idLabel)
        addSubview(addButton)

        NSLayoutConstraint.activate([
            art.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            art.centerYAnchor.constraint(equalTo: centerYAnchor),
            art.widthAnchor.constraint(equalToConstant: 96),
            art.heightAnchor.constraint(equalToConstant: 36),

            nameLabel.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -12),
            nameLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),

            idLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            idLabel.trailingAnchor.constraint(lessThanOrEqualTo: addButton.leadingAnchor,
                                              constant: -12),
            idLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),

            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 78),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(game: LuaToolsSteamGame, configured: Bool, busy: Bool,
                   enabled: Bool, onAdd: @escaping () -> Void) {
        nameLabel.stringValue = game.name
        idLabel.stringValue = "App \(game.id)"
        addButton.title = configured ? "Added" : (busy ? "Adding…" : "Add")
        addButton.isEnabled = !configured && !busy && enabled
        self.onAdd = onAdd

        guard let image = game.image, image != artKey else { return }
        artKey = image
        artTask?.cancel()
        art.image = nil
        artTask = Task { [weak self] in
            let data = await SteamStoreClient.shared.imageData(for: image)
            guard !Task.isCancelled, let self, let data else { return }
            let decoded = StoreArtLoader.decode(data, targetWidth: 192)
            guard self.artKey == image else { return }
            self.art.image = decoded
        }
    }

    @objc private func addPressed() {
        onAdd?()
    }
}
