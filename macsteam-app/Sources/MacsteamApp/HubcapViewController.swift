// Hubcap catalog browser and API key settings.
import AppKit
import Foundation

@MainActor
final class HubcapViewController: NSViewController {
    let store: ConfigStore
    let onConfigChanged: () -> Void

    private let client = HubcapClient.shared
    private lazy var installer = HubcapStoreInstaller(store: store)

    private var statusIcon: NSImageView!
    private var statusLabel: NSTextField!
    private var settingsButton: NSButton!
    private var refreshButton: NSButton!
    private var searchField: NSSearchField!
    private var tableView: NSTableView!
    private var tableScroll: NSScrollView!
    private var emptyLabel: NSTextField!
    private var loadMoreButton: NSButton!
    private var spinner: NSProgressIndicator!

    private var games: [HubcapGame] = []
    private var totalMatches: Int?
    private var isSearching = false
    private var isLoading = false
    private var searchGeneration = 0
    private var debounceTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    private var validatedKey: String?
    private var validatedAt: Date?
    private var validatedSummary: String?
    private var validatedError: String?

    private static let libraryLimit = 100

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

        statusLabel = NSTextField(labelWithString: "Hubcap not connected")
        statusLabel.font = Typography.body
        statusLabel.textColor = Colors.secondaryText
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1

        settingsButton = makeButton(title: "Hubcap Settings…", target: self,
                                    action: #selector(openSettings))
        refreshButton = makeButton(title: "Refresh", target: self, action: #selector(refreshLibrary))

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let statusRow = NSStackView(views: [statusIcon, statusLabel, spinner,
                                            NSView(), settingsButton, refreshButton])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true

        searchField = NSSearchField()
        searchField.placeholderString = "Search Hubcap by title or App ID"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityLabel("Search Hubcap")

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 64
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        let col = NSTableColumn(identifier: .init("hubcap"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        tableScroll = makeScrollView()
        tableScroll.documentView = tableView
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel = NSTextField(labelWithString: "Connect to Hubcap to browse the catalog.")
        emptyLabel.font = Typography.body
        emptyLabel.textColor = Colors.secondaryText
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        loadMoreButton = makeButton(title: "Load More", target: self,
                                    action: #selector(loadMore))
        loadMoreButton.isHidden = true

        let bottomRow = NSStackView(views: [NSView(), loadMoreButton])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(statusRow)
        root.addSubview(searchField)
        root.addSubview(tableScroll)
        root.addSubview(emptyLabel)
        root.addSubview(bottomRow)

        NSLayoutConstraint.activate([
            statusRow.topAnchor.constraint(equalTo: root.topAnchor, constant: m),
            statusRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            statusRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),

            searchField.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),

            tableScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            tableScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            tableScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            tableScroll.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: tableScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableScroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: tableScroll.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: tableScroll.trailingAnchor, constant: -24),

            bottomRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            bottomRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            bottomRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -m),
            bottomRow.heightAnchor.constraint(equalToConstant: 28),
        ])

        view = root
        updateStatus()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if games.isEmpty, !isLoading, HubcapCredentialStore.apiKey != nil {
            refreshLibrary()
        }
    }

    // MARK: - Actions

    @objc private func openSettings() {
        let dialog = HubcapSettingsDialogController(
            apiKey: HubcapCredentialStore.apiKey,
            openAPIKeys: {
                NSWorkspace.shared.open(HubcapClient.apiKeysURL)
            })
        let result = dialog.run()
        switch result {
        case .saved(let key):
            do {
                try HubcapCredentialStore.save(key)
            } catch {
                presentAlert("Invalid API key", error.localizedDescription, style: .warning)
                return
            }
            validatedKey = nil
            validatedAt = nil
            validatedSummary = nil
            validatedError = nil
            updateStatus()
            refreshLibrary()
        case .disconnected:
            HubcapCredentialStore.clear()
            validatedKey = nil
            validatedAt = nil
            validatedSummary = nil
            validatedError = nil
            searchField.stringValue = ""
            games = []
            totalMatches = nil
            isSearching = false
            tableView.reloadData()
            loadMoreButton.isHidden = true
            updateStatus()
            showEmpty("Connect to Hubcap to browse the catalog.")
        case .cancelled:
            break
        }
    }

    @objc private func refreshLibrary() {
        guard HubcapCredentialStore.apiKey != nil else {
            games = []
            totalMatches = nil
            tableView.reloadData()
            loadMoreButton.isHidden = true
            updateStatus()
            showEmpty("Add an access key in Hubcap Settings to browse the catalog.")
            return
        }
        isSearching = false
        searchField.stringValue = ""
        searchGeneration += 1
        loadLibrary(reset: true)
    }

    @objc private func loadMore() {
        guard !isLoading, !isSearching else { return }
        loadLibrary(reset: false)
    }

    private func loadLibrary(reset: Bool) {
        guard let key = HubcapCredentialStore.apiKey else { return }
        loadTask?.cancel()
        let generation = searchGeneration
        let offset = reset ? 0 : games.count
        if reset {
            games = []
            totalMatches = nil
            tableView.reloadData()
        }
        setBusy(true)
        showEmpty("Loading Hubcap…")
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await client.libraryPage(
                    apiKey: key, limit: Self.libraryLimit, offset: offset)
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                if reset { self.games = page.games } else { self.games.append(contentsOf: page.games) }
                self.totalMatches = page.totalCount
                self.isSearching = false
                self.setBusy(false)
                self.reloadAndUpdateEmpty()
            } catch {
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                self.setBusy(false)
                self.showEmpty(error.localizedDescription)
                self.updateStatus(error: error.localizedDescription)
            }
        }
    }

    private func performSearch(_ query: String) {
        guard let key = HubcapCredentialStore.apiKey else { return }
        searchGeneration += 1
        let generation = searchGeneration
        loadTask?.cancel()
        games = []
        totalMatches = nil
        tableView.reloadData()
        setBusy(true)
        showEmpty("Searching Hubcap for “\(query)”…")
        isSearching = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await client.searchGames(query: query, apiKey: key)
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                self.games = result.results
                self.totalMatches = result.totalMatches
                self.setBusy(false)
                self.reloadAndUpdateEmpty()
            } catch {
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                self.setBusy(false)
                self.games = []
                self.reloadAndUpdateEmpty()
                self.updateStatus(error: error.localizedDescription)
            }
        }
    }

    private func install(_ game: HubcapGame) {
        guard let appID = game.appID, !isLoading else { return }
        setBusy(true)
        loadMoreButton.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await installer.install(appID: appID)
                self.onConfigChanged()
                self.setBusy(false)
                self.loadMoreButton.isEnabled = true
                self.reloadAndUpdateEmpty()
                let name = outcome.luaTitle ?? game.gameName
                presentAlert(
                    "Added \(name)",
                    outcome.activated
                        ? "The game is in macSteam's library. Open its Steam page and click Install with Steam to download it."
                        : "The game was saved. Restart Steam, then open its store page and click Install with Steam.",
                    style: .informational)
            } catch {
                self.setBusy(false)
                self.loadMoreButton.isEnabled = true
                presentAlert("Couldn't add \(game.gameName)", error.localizedDescription, style: .warning)
            }
        }
    }

    // MARK: - UI state

    private func setBusy(_ busy: Bool) {
        isLoading = busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        refreshButton.isEnabled = !busy
        settingsButton.isEnabled = !busy
        searchField.isEnabled = !busy
    }

    private func reloadAndUpdateEmpty() {
        tableView.reloadData()
        loadMoreButton.isHidden = isSearching || games.isEmpty ||
            (totalMatches.map { games.count >= $0 } ?? false)
        loadMoreButton.isEnabled = !isLoading
        if games.isEmpty {
            showEmpty(isSearching ? "No Hubcap games matched this search." : "Hubcap returned no games.")
        } else {
            emptyLabel.isHidden = true
        }
        updateStatus()
    }

    private func showEmpty(_ text: String) {
        emptyLabel.stringValue = text
        emptyLabel.isHidden = false
    }

    private func updateStatus(error: String? = nil) {
        if let error {
            statusIcon.image = NSImage(systemSymbolName: StatusTone.bad.symbol,
                                       accessibilityDescription: nil)
            statusIcon.contentTintColor = StatusTone.bad.color
            statusLabel.stringValue = error
            statusLabel.textColor = StatusTone.bad.color
            return
        }
        guard let key = HubcapCredentialStore.apiKey else {
            statusIcon.image = NSImage(systemSymbolName: StatusTone.neutral.symbol,
                                       accessibilityDescription: nil)
            statusIcon.contentTintColor = StatusTone.neutral.color
            statusLabel.stringValue = "Hubcap not connected"
            statusLabel.textColor = Colors.secondaryText
            return
        }
        guard HubcapCredentialStore.isValidFormat(key) else {
            statusIcon.image = NSImage(systemSymbolName: StatusTone.bad.symbol,
                                       accessibilityDescription: nil)
            statusIcon.contentTintColor = StatusTone.bad.color
            statusLabel.stringValue = "The saved Hubcap API key has an invalid format."
            statusLabel.textColor = StatusTone.bad.color
            return
        }
        if validatedKey == key,
           Date().timeIntervalSince(validatedAt ?? .distantPast) < 300 {
            if let summary = validatedSummary {
                statusIcon.image = NSImage(systemSymbolName: StatusTone.ok.symbol,
                                           accessibilityDescription: nil)
                statusIcon.contentTintColor = StatusTone.ok.color
                statusLabel.stringValue = summary
                statusLabel.textColor = Colors.secondaryText
                return
            }
            if let error = validatedError {
                updateStatus(error: error)
                return
            }
        }

        statusIcon.image = NSImage(systemSymbolName: StatusTone.ok.symbol,
                                   accessibilityDescription: nil)
        statusIcon.contentTintColor = StatusTone.ok.color
        statusLabel.stringValue = "Checking Hubcap…"
        statusLabel.textColor = Colors.secondaryText

        Task { [weak self] in
            guard let self else { return }
            do {
                let stats = try await client.validate(apiKey: key)
                guard HubcapCredentialStore.apiKey == key else { return }
                let who = stats.username.map { " as \($0)" } ?? ""
                let summary = "Connected\(who) · \(stats.summary)"
                self.validatedKey = key
                self.validatedAt = Date()
                self.validatedSummary = summary
                self.validatedError = nil
                self.statusLabel.stringValue = summary
                self.statusIcon.image = NSImage(systemSymbolName: StatusTone.ok.symbol,
                                                accessibilityDescription: nil)
            } catch {
                guard HubcapCredentialStore.apiKey == key else { return }
                self.validatedKey = key
                self.validatedAt = Date()
                self.validatedSummary = nil
                self.validatedError = error.localizedDescription
                self.updateStatus(error: error.localizedDescription)
            }
        }
    }

    func reloadFromStore() {
        if isViewLoaded { reloadAndUpdateEmpty() }
    }
}

// MARK: - Search field

extension HubcapViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        debounceTask?.cancel()
        if query.isEmpty {
            if isSearching {
                refreshLibrary()
            }
            return
        }
        guard query.count >= 3 else {
            showEmpty("Enter at least 3 characters to search Hubcap.")
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let self else { return }
            self.performSearch(query)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 3 else { return }
        debounceTask?.cancel()
        performSearch(query)
    }
}

// MARK: - Table

extension HubcapViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { games.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < games.count else { return nil }
        let game = games[row]
        let id = NSUserInterfaceItemIdentifier("hubcap-game")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? HubcapGameCell)
            ?? HubcapGameCell(identifier: id)
        let configured = game.appID.map { store.config.apps.contains($0) } ?? false
        cell.configure(game: game, configured: configured) { [weak self] in
            self?.install(game)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

// MARK: - Cell

@MainActor
final class HubcapGameCell: NSTableCellView {
    private let art = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let idLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private var onAction: (() -> Void)?
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
        idLabel.translatesAutoresizingMaskIntoConstraints = false

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.target = self
        actionButton.action = #selector(actionPressed)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(art)
        addSubview(nameLabel)
        addSubview(idLabel)
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            art.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            art.centerYAnchor.constraint(equalTo: centerYAnchor),
            art.widthAnchor.constraint(equalToConstant: 96),
            art.heightAnchor.constraint(equalToConstant: 36),

            nameLabel.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -12),
            nameLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),

            idLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            idLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -12),
            idLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 78),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(game: HubcapGame, configured: Bool, onAction: @escaping () -> Void) {
        nameLabel.stringValue = game.gameName
        idLabel.stringValue = game.appID.map { "App \($0)" } ?? "No app id"
        actionButton.title = configured ? "Added" : "Add"
        actionButton.isEnabled = !configured
        self.onAction = onAction

        guard let header = game.headerImage, header != artKey else { return }
        artKey = header
        artTask?.cancel()
        art.image = nil
        artTask = Task { [weak self] in
            let data = await SteamStoreClient.shared.imageData(for: header)
            guard !Task.isCancelled, let self, let data else { return }
            let image = StoreArtLoader.decode(data, targetWidth: 192)
            guard self.artKey == header else { return }
            self.art.image = image
        }
    }

    @objc private func actionPressed() {
        onAction?()
    }
}

// MARK: - Settings dialog

final class HubcapSettingsDialogController: NSObject {
    enum Result {
        case saved(String)
        case disconnected
        case cancelled
    }

    private let apiKey: String?
    private let openAPIKeys: () -> Void

    init(apiKey: String?, openAPIKeys: @escaping () -> Void) {
        self.apiKey = apiKey
        self.openAPIKeys = openAPIKeys
        super.init()
    }

    @MainActor
    func run() -> Result {
        let alert = NSAlert()
        alert.messageText = "Hubcap Settings"
        alert.informativeText =
            "macSteam uses your own Hubcap API key to fetch Lua manifests. "
            + "The key is stored locally in your user defaults."
        alert.alertStyle = .informational

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "smm_…"
        field.stringValue = apiKey ?? ""
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let hint = NSTextField(labelWithString: "Get a key at hubcapmanifest.com/api-keys")
        hint.font = Typography.caption
        hint.textColor = Colors.secondaryText
        hint.translatesAutoresizingMaskIntoConstraints = false

        let accessory = NSStackView(views: [field, hint])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 6
        accessory.frame = NSRect(x: 0, y: 0, width: 320, height: 82)
        alert.accessoryView = accessory

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Disconnect")
        alert.addButton(withTitle: "Cancel")

        let getKey = NSButton(title: "Open Hubcap API Keys…", target: self,
                              action: #selector(openKeysPressed))
        getKey.bezelStyle = .inline
        getKey.isBordered = false
        getKey.contentTintColor = .linkColor
        accessory.addArrangedSubview(getKey)

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard HubcapCredentialStore.isValidFormat(key) else {
                presentAlert("Invalid API key",
                             "Hubcap keys look like smm_ followed by 96 lowercase hex characters.",
                             style: .warning)
                return .cancelled
            }
            return .saved(key)
        case .alertSecondButtonReturn:
            return .disconnected
        default:
            return .cancelled
        }
    }

    @objc private func openKeysPressed() {
        openAPIKeys()
    }
}
