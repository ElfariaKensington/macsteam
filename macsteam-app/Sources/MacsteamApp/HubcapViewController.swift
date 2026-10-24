import AppKit

@MainActor
final class HubcapViewController: NSViewController {
    let store: ConfigStore
    let onConfigChanged: () -> Void

    // Keep all Hubcap API behavior in HubcapClient. This view only orchestrates UI state.
    private let client = HubcapClient()
    private var apiStatusIcon: NSImageView!
    private var apiStatusTitle: NSTextField!
    private var apiStatusDetail: NSTextField!
    private var apiSettingsButton: NSButton!

    private var searchField: NSSearchField!
    private var refreshButton: NSButton!
    private var loadMoreButton: NSButton!
    private var tableView: NSTableView!
    private var resultCountLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var copyStatusButton: NSButton!
    private var spinner: NSProgressIndicator!
    private var emptyState: EmptyStateView!
    private var installedCountLabel: NSTextField!
    private var usageTask: Task<Void, Never>?

    private var allGames: [HubcapGame] = []
    private var games: [HubcapGame] = []
    private var totalCount = 0
    private var loadedOffset = 0
    private var isBusy = false
    private var isSearching = false
    private var searchGeneration = 0
    private var searchTask: Task<Void, Never>?

    init(store: ConfigStore, onConfigChanged: @escaping () -> Void) {
        self.store = store
        self.onConfigChanged = onConfigChanged
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 680))
        root.translatesAutoresizingMaskIntoConstraints = false

        // MARK: Header

        let heroIcon = NSImageView()
        heroIcon.image = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: "Hubcap")
        heroIcon.symbolConfiguration = .init(pointSize: 26, weight: .semibold)
        heroIcon.contentTintColor = .controlAccentColor
        heroIcon.translatesAutoresizingMaskIntoConstraints = false
        heroIcon.setAccessibilityElement(false)

        let title = NSTextField(labelWithString: "Find games in Hubcap")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString:
            "Browse 100 games at a time and install Lua manifests directly into macSteam."
        )
        subtitle.font = Typography.body
        subtitle.textColor = Colors.secondaryText
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let heroText = NSStackView(views: [title, subtitle])
        heroText.orientation = .vertical
        heroText.alignment = .leading
        heroText.spacing = 4
        heroText.translatesAutoresizingMaskIntoConstraints = false

        let hero = NSStackView(views: [heroIcon, heroText])
        hero.orientation = .horizontal
        hero.alignment = .top
        hero.spacing = 12
        hero.translatesAutoresizingMaskIntoConstraints = false

        installedCountLabel = makeMetricLabel("0 installed")
        installedCountLabel.alignment = .right

        let heroStats = NSStackView(views: [installedCountLabel])
        heroStats.orientation = .vertical
        heroStats.alignment = .trailing
        heroStats.translatesAutoresizingMaskIntoConstraints = false

        let heroRow = NSStackView(views: [hero, heroStats])
        heroRow.orientation = .horizontal
        heroRow.alignment = .top
        heroRow.spacing = 16
        heroRow.translatesAutoresizingMaskIntoConstraints = false
        hero.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hero.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // MARK: Connection

        let apiHeader = settingsGroupLabel("Connection")

        apiStatusIcon = NSImageView()
        apiStatusIcon.translatesAutoresizingMaskIntoConstraints = false
        apiStatusIcon.setAccessibilityElement(false)

        apiStatusTitle = NSTextField(labelWithString: "Not connected")
        apiStatusTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        apiStatusTitle.textColor = .labelColor
        apiStatusTitle.translatesAutoresizingMaskIntoConstraints = false

        apiStatusDetail = NSTextField(labelWithString: "Add an access key to use Hubcap.")
        apiStatusDetail.font = Typography.caption
        apiStatusDetail.textColor = Colors.secondaryText
        apiStatusDetail.lineBreakMode = .byTruncatingTail
        apiStatusDetail.translatesAutoresizingMaskIntoConstraints = false
        apiStatusDetail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let apiText = NSStackView(views: [apiStatusTitle, apiStatusDetail])
        apiText.orientation = .vertical
        apiText.alignment = .leading
        apiText.spacing = 3
        apiText.translatesAutoresizingMaskIntoConstraints = false
        apiText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        apiSettingsButton = makeButton(
            title: "Settings",
            target: self,
            action: #selector(openHubcapSettings)
        )
        styleSecondaryButton(apiSettingsButton)
        apiSettingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        apiSettingsButton.imagePosition = .imageLeading

        let apiCard = makeCard()
        apiCard.addSubview(apiStatusIcon)
        apiCard.addSubview(apiText)
        apiCard.addSubview(apiSettingsButton)

        NSLayoutConstraint.activate([
            apiStatusIcon.leadingAnchor.constraint(equalTo: apiCard.leadingAnchor, constant: 16),
            apiStatusIcon.centerYAnchor.constraint(equalTo: apiCard.centerYAnchor),
            apiStatusIcon.widthAnchor.constraint(equalToConstant: 12),
            apiStatusIcon.heightAnchor.constraint(equalToConstant: 12),

            apiText.leadingAnchor.constraint(equalTo: apiStatusIcon.trailingAnchor, constant: 10),
            apiText.topAnchor.constraint(equalTo: apiCard.topAnchor, constant: 12),
            apiText.bottomAnchor.constraint(equalTo: apiCard.bottomAnchor, constant: -12),
            apiText.trailingAnchor.constraint(lessThanOrEqualTo: apiSettingsButton.leadingAnchor, constant: -16),

            apiSettingsButton.trailingAnchor.constraint(equalTo: apiCard.trailingAnchor, constant: -16),
            apiSettingsButton.centerYAnchor.constraint(equalTo: apiCard.centerYAnchor),
            apiSettingsButton.widthAnchor.constraint(equalToConstant: 104),
            apiSettingsButton.heightAnchor.constraint(equalToConstant: 30),
        ])

        // MARK: Library controls

        let libraryHeader = settingsGroupLabel("Library")

        searchField = NSSearchField()
        searchField.placeholderString = "Search Hubcap by title or App ID"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityLabel("Search Hubcap games by title or App ID")
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldSubmitted)
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: 15)

        refreshButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!,
            target: self,
            action: #selector(refreshLibrary)
        )
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .large
        refreshButton.toolTip = "Reload the first 100 games"
        refreshButton.setAccessibilityLabel("Reload first 100 Hubcap games")
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        styleIconButton(refreshButton)

        let searchBar = NSStackView(views: [searchField, refreshButton])
        searchBar.orientation = .horizontal
        searchBar.alignment = .centerY
        searchBar.spacing = 8
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        resultCountLabel = NSTextField(labelWithString: "Ready to load")
        resultCountLabel.font = .systemFont(ofSize: 12, weight: .medium)
        resultCountLabel.textColor = Colors.secondaryText
        resultCountLabel.translatesAutoresizingMaskIntoConstraints = false
        resultCountLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let resultsHeader = NSStackView(views: [resultCountLabel])
        resultsHeader.orientation = .horizontal
        resultsHeader.alignment = .centerY
        resultsHeader.translatesAutoresizingMaskIntoConstraints = false

        // MARK: Results

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 82
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self

        let gameColumn = NSTableColumn(identifier: .init("game"))
        gameColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(gameColumn)

        let scroll = makeScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = tableView

        emptyState = EmptyStateView(
            symbol: "books.vertical",
            prompt: "Browse the Hubcap library",
            hint: "Load a page to start browsing."
        )
        emptyState.isHidden = true

        let listCard = makeCard()
        listCard.addSubview(scroll)
        listCard.addSubview(emptyState)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: listCard.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: listCard.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: listCard.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: listCard.bottomAnchor),

            emptyState.centerXAnchor.constraint(equalTo: listCard.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: listCard.centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: listCard.leadingAnchor, constant: 20),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: listCard.trailingAnchor, constant: -20),
        ])

        // MARK: Footer actions

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(wrappingLabelWithString: "Enter your Hubcap API key to load the library.")
        statusLabel.font = Typography.caption
        statusLabel.textColor = Colors.secondaryText
        statusLabel.isSelectable = true
        statusLabel.allowsEditingTextAttributes = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        copyStatusButton = NSButton(
            image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy status")!,
            target: self,
            action: #selector(copyStatus)
        )
        copyStatusButton.bezelStyle = .rounded
        copyStatusButton.controlSize = .small
        copyStatusButton.toolTip = "Copy status"
        copyStatusButton.setAccessibilityLabel("Copy status")
        copyStatusButton.translatesAutoresizingMaskIntoConstraints = false
        styleIconButton(copyStatusButton)

        loadMoreButton = makeButton(
            title: "Load 100 More",
            target: self,
            action: #selector(loadMoreLibrary)
        )
        loadMoreButton.controlSize = .regular
        stylePrimaryButton(loadMoreButton)

        let footerStatus = NSStackView(views: [spinner, statusLabel, copyStatusButton])
        footerStatus.orientation = .horizontal
        footerStatus.alignment = .centerY
        footerStatus.spacing = 8
        footerStatus.translatesAutoresizingMaskIntoConstraints = false
        footerStatus.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [footerStatus, loadMoreButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        footerStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // MARK: Root

        let stack = NSStackView(views: [
            heroRow,
            apiHeader, apiCard,
            libraryHeader, searchBar,
            resultsHeader, listCard,
            footer
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(12, after: heroRow)
        stack.setCustomSpacing(5, after: apiHeader)
        stack.setCustomSpacing(14, after: apiCard)
        stack.setCustomSpacing(5, after: libraryHeader)
        stack.setCustomSpacing(8, after: searchBar)
        stack.setCustomSpacing(7, after: resultsHeader)
        stack.setCustomSpacing(8, after: listCard)

        root.addSubview(stack)

        let m = Metrics.paneMargin
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: m),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -m),

            heroRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            apiCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            searchBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resultsHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),

            refreshButton.widthAnchor.constraint(equalToConstant: 34),
            refreshButton.heightAnchor.constraint(equalToConstant: 34),
            copyStatusButton.widthAnchor.constraint(equalToConstant: 30),
            copyStatusButton.heightAnchor.constraint(equalToConstant: 26),
            loadMoreButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 124),
            loadMoreButton.heightAnchor.constraint(equalToConstant: 30),
        ])

        updateInstalledMetric()
        updateAPIStatus()
        updateEmptyState()
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        updateInstalledMetric()
        updateAPIStatus()

        if !isBusy && allGames.isEmpty {
            loadLibrary(reset: true)
        }
    }

    deinit {
        searchTask?.cancel()
        usageTask?.cancel()
    }

    // MARK: Hubcap settings

    @objc private func openHubcapSettings() {
        let dialog = HubcapSettingsDialogController(
            apiKey: HubcapCredentialStore.apiKey,
            openAPIKeys: { [weak self] in
                self?.openAPIKeys()
            }
        )

        switch dialog.run() {
        case .connect(let key):
            connectHubcap(rawKey: key)

        case .disconnect:
            do {
                searchTask?.cancel()
                searchGeneration += 1
                isSearching = false
                updateActivityIndicator()
                searchField.stringValue = ""
                try HubcapCredentialStore.remove()
                updateAPIStatus()
                allGames.removeAll()
                games.removeAll()
                totalCount = 0
                loadedOffset = 0
                tableView.reloadData()
                emptyState.configure(
                    symbol: "key",
                    prompt: "Connect to Hubcap",
                    hint: "Add an API key in Hubcap Settings to search the catalog."
                )
                updateEmptyState()
                loadMoreButton.isEnabled = false
                resultCountLabel.stringValue = "Ready to connect"
                setStatus("Hubcap disconnected.", tone: .neutral)
            } catch {
                setStatus("Could not remove the Hubcap API key: \\(error.localizedDescription)", tone: .bad)
            }

        case .cancel:
            break
        }
    }

    @objc private func openAPIKeys() {
        NSWorkspace.shared.open(HubcapClient.apiKeysURL)
    }

    private func validateHubcapKey(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.range(
            of: #"^smm_[0-9a-f]{96}$"#,
            options: .regularExpression
        ) != nil else {
            throw HubcapClientError.invalidAPIKey
        }
        return key
    }

    private func connectHubcap(rawKey: String) {
        guard !isBusy else { return }

        let key: String
        do {
            key = try validateHubcapKey(rawKey)
        } catch {
            setStatus(error.localizedDescription, tone: .bad)
            return
        }

        setBusy(true, status: "Validating Hubcap API key…")

        Task {
            do {
                _ = try await client.userStats(apiKey: key)
                try HubcapCredentialStore.save(key)

                updateAPIStatus()
                searchField.stringValue = ""
                allGames.removeAll()
                games.removeAll()
                totalCount = 0
                loadedOffset = 0
                tableView.reloadData()
                updateEmptyState()

                setBusy(false)
                loadLibrary(reset: true)
            } catch {
                setBusy(false)
                setStatus(error.localizedDescription, tone: .bad)
            }
        }
    }

    // MARK: Search

    @objc private func searchFieldSubmitted() {
        scheduleSearch()
    }

    @objc private func refreshLibrary() {
        guard !isBusy else { return }
        if searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchTask?.cancel()
            searchGeneration += 1
            isSearching = false
            updateActivityIndicator()
            loadLibrary(reset: true)
        } else {
            scheduleSearch(immediate: true)
        }
    }

    @objc private func loadMoreLibrary() {
        guard !isBusy else { return }
        guard searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        loadLibrary(reset: false)
    }

    func controlTextDidChange(_ obj: Notification) {
        scheduleSearch()
    }

    private func scheduleSearch(immediate: Bool = false) {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = false
        updateActivityIndicator()

        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if query.isEmpty {
            games = deduplicateAndSort(allGames)
            tableView.reloadData()
            resultCountLabel.stringValue = games.isEmpty ? "No games" : "\(games.count) shown"
            emptyState.configure(
                symbol: "books.vertical",
                prompt: "Browse the Hubcap library",
                hint: "Search the full Hubcap catalog by title or App ID."
            )
            updateEmptyState()
            updateCatalogStatus()
            return
        }

        loadMoreButton.isEnabled = false

        guard query.count >= 3 else {
            games.removeAll()
            tableView.reloadData()
            resultCountLabel.stringValue = "Keep typing…"
            emptyState.configure(
                symbol: "text.magnifyingglass",
                prompt: "Search needs 3 characters",
                hint: "Enter at least 3 characters to search Hubcap by title or App ID."
            )
            emptyState.isHidden = false
            setStatus("Enter at least 3 characters to search Hubcap.", tone: .neutral)
            return
        }

        guard let key = currentKey() else {
            games.removeAll()
            tableView.reloadData()
            resultCountLabel.stringValue = "Hubcap not connected"
            emptyState.configure(
                symbol: "key",
                prompt: "Connect to Hubcap to search",
                hint: "Add a valid API key in Hubcap Settings."
            )
            updateEmptyState()
            loadMoreButton.isEnabled = false
            return
        }

        resultCountLabel.stringValue = "Searching…"
        emptyState.configure(
            symbol: "magnifyingglass",
            prompt: "Searching Hubcap…",
            hint: "Looking across the Hubcap catalog."
        )
        emptyState.isHidden = false
        setStatus("Searching Hubcap for “\(query)”…", tone: .neutral)

        searchTask = Task { [weak self] in
            do {
                if !immediate {
                    try await Task.sleep(for: .milliseconds(250))
                }
                guard let self, !Task.isCancelled else { return }
                await self.performHubcapSearch(query: query, apiKey: key, generation: generation)
            } catch {
                // Cancellation during the debounce interval is expected.
            }
        }
    }

    private func performHubcapSearch(query: String, apiKey: String, generation: Int) async {
        guard generation == searchGeneration, !Task.isCancelled else { return }
        isSearching = true
        updateActivityIndicator()

        do {
            let results = try await client.searchGames(
                query: query,
                apiKey: apiKey,
                appID: query.allSatisfy { $0.isNumber }
            )

            guard
                !Task.isCancelled,
                generation == searchGeneration,
                query == searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                HubcapCredentialStore.apiKey == apiKey
            else { return }

            isSearching = false
            updateActivityIndicator()
            games = deduplicateAndSort(results)
            tableView.reloadData()
            resultCountLabel.stringValue = games.isEmpty
                ? "No matches"
                : "\(games.count) result\(games.count == 1 ? "" : "s")"

            emptyState.configure(
                symbol: "magnifyingglass",
                prompt: "No games found",
                hint: "Try another title or App ID."
            )
            updateEmptyState()
            setStatus(
                games.isEmpty
                    ? "No Hubcap games matched “\(query)”."
                    : "Found \(games.count) Hubcap result(s) for “\(query)”.",
                tone: games.isEmpty ? .neutral : .ok
            )
        } catch {
            guard
                !Task.isCancelled,
                generation == searchGeneration,
                query == searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                HubcapCredentialStore.apiKey == apiKey
            else { return }

            isSearching = false
            updateActivityIndicator()
            games.removeAll()
            tableView.reloadData()
            resultCountLabel.stringValue = "Search failed"
            emptyState.configure(
                symbol: "exclamationmark.triangle",
                prompt: "Hubcap search failed",
                hint: error.localizedDescription
            )
            updateEmptyState()
            setStatus(error.localizedDescription, tone: .bad)
        }
    }

    private func applyLibraryRows() {
        games = deduplicateAndSort(allGames)
        tableView.reloadData()
        resultCountLabel.stringValue = games.isEmpty ? "No games" : "\(games.count) shown"
        emptyState.configure(
            symbol: "books.vertical",
            prompt: "Browse the Hubcap library",
            hint: "Search for a game or scroll through the catalog."
        )
        updateEmptyState()
        loadMoreButton.isEnabled =
            !isBusy &&
            searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            loadedOffset < totalCount
    }

    private func loadLibrary(reset: Bool) {
        guard !isBusy, let key = currentKey() else { return }

        let offset = reset ? 0 : loadedOffset
        setBusy(true, status: reset ? "Loading first 100 games…" : "Loading 100 more games…")

        Task {
            do {
                // Keep foreground pagination at 100 items so the first screen stays responsive.
                let page = try await client.libraryPage(
                    apiKey: key,
                    limit: 100,
                    offset: offset
                )

                let merged: [HubcapGame] = reset ? page.games : (allGames + page.games)
                allGames = deduplicateAndSort(merged)
                loadedOffset = offset + page.games.count
                totalCount = page.totalCount

                updateInstalledMetric()
                applyLibraryRows()
                updateCatalogStatus()
                setBusy(false)
            } catch {
                setBusy(false)
                setStatus(error.localizedDescription, tone: .bad)
            }
        }
    }

    private func updateCatalogStatus() {
        if allGames.isEmpty {
            setStatus("Hubcap returned no games.", tone: .neutral)
            resultCountLabel.stringValue = "No games"
        } else if loadedOffset < totalCount {
            setStatus(
                "Showing \(allGames.count) of \(totalCount) games. Load 100 more to continue.",
                tone: .ok
            )
            resultCountLabel.stringValue = "\(games.count) shown"
        } else {
            setStatus("Showing all \(allGames.count) Hubcap games.", tone: .ok)
            resultCountLabel.stringValue = "\(games.count) shown"
        }

        loadMoreButton.isEnabled =
            !isBusy &&
            searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            loadedOffset < totalCount
    }

    // MARK: Install

    private func deduplicateAndSort(_ input: [HubcapGame]) -> [HubcapGame] {
        var seen = Set<String>()
        return input
            .filter { seen.insert($0.id).inserted }
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                if order == .orderedSame {
                    return $0.id.localizedStandardCompare($1.id) == .orderedAscending
                }
                return order == .orderedAscending
            }
    }

    private func install(game: HubcapGame) {
        guard !isBusy, let appID = game.appID, let key = currentKey() else { return }
        guard !isInstalled(game) else {
            refreshInstalledState()
            return
        }

        setBusy(true, status: "Downloading Lua for \(game.name)…")

        Task {
            do {
                let luaText = try await client.downloadLuaText(appID: appID, apiKey: key)

                setStatus("Installing \(game.name)…", tone: .neutral)
                let plan = try await Task.detached(priority: .userInitiated) {
                    try ZipImporter.buildPlan(
                        fromLuaText: luaText,
                        source: URL(fileURLWithPath: "hubcap-\(appID).lua")
                    )
                }.value

                guard plan.mainAppID == appID else {
                    throw HubcapInstallError.appIDMismatch(requested: appID)
                }

                try store.mutate { cfg in
                    _ = ZipImporter.merge(plan, into: &cfg)
                }

                ZipImporter.cleanup(plan.extractDir)
                refreshInstalledState()
                onConfigChanged()
                setBusy(false)
                setStatus("Installed \(game.name) into macSteam.", tone: .ok)
            } catch {
                setBusy(false)
                setStatus(error.localizedDescription, tone: .bad)
            }
        }
    }

    // MARK: Helpers

    private func currentKey() -> String? {
        guard let key = HubcapCredentialStore.apiKey else {
            setStatus("Open Hubcap Settings to add your access key.", tone: .neutral)
            return nil
        }

        do {
            return try validateHubcapKey(key)
        } catch {
            if !isBusy {
                setStatus(error.localizedDescription, tone: .bad)
            }
            return nil
        }
    }

    private func isInstalled(_ game: HubcapGame) -> Bool {
        guard let appID = game.appID else { return false }
        return store.config.apps.contains(appID)
    }

    private func refreshInstalledState() {
        updateInstalledMetric()
        tableView.reloadData()
    }

    private func updateInstalledMetric() {
        let installed = Set(store.config.apps).count
        installedCountLabel?.stringValue = "\(installed) installed"
    }

    private func updateAPIStatus() {
        usageTask?.cancel()

        guard let key = HubcapCredentialStore.apiKey else {
            apiStatusIcon?.image = NSImage(
                systemSymbolName: "circle",
                accessibilityDescription: "Not connected"
            )
            apiStatusIcon?.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
            apiStatusIcon?.contentTintColor = Colors.secondaryText
            apiStatusTitle?.stringValue = "Not connected"
            apiStatusDetail?.stringValue = "Add an access key in Settings."
            return
        }

        apiStatusIcon?.image = NSImage(
            systemSymbolName: "circle.fill",
            accessibilityDescription: "Connected"
        )
        apiStatusIcon?.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        apiStatusIcon?.contentTintColor = .systemGreen
        apiStatusTitle?.stringValue = "Connected"
        apiStatusDetail?.stringValue = "Hubcap access is ready."

        let hubcapClient = client
        usageTask = Task { [weak self, hubcapClient] in
            do {
                let stats = try await hubcapClient.userStats(apiKey: key)
                guard !Task.isCancelled else { return }
                guard HubcapCredentialStore.apiKey == key else { return }
                self?.apiStatusTitle?.stringValue =
                    "Connected • \(stats.dailyUsage)/\(stats.dailyLimit)"
            } catch {
                // Keep the connected state visible if daily usage statistics are unavailable.
            }
        }
    }

    private func resultSummary(count: Int, search: String) -> String {
        guard search.isEmpty == false else { return "\(count) shown" }
        return "\(count) result(s)"
    }

    private func updateEmptyState() {
        emptyState.isHidden = !games.isEmpty
    }

    private func makeMetricLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = Typography.caption
        field.textColor = Colors.secondaryText
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func makeCard() -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.applyCardSurface()
        return card
    }

    private enum ButtonRole {
        case primary
        case secondary
        case destructive
    }

    private func styleButton(_ button: NSButton, role: ButtonRole = .secondary) {
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 13, weight: role == .primary ? .semibold : .medium)
        button.alignment = .center
        button.contentTintColor = role == .destructive ? .systemRed : .labelColor
    }

    private func stylePrimaryButton(_ button: NSButton) {
        styleButton(button, role: .primary)
        button.contentTintColor = .controlAccentColor
    }

    private func styleSecondaryButton(_ button: NSButton) {
        styleButton(button, role: .secondary)
    }

    private func styleIconButton(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.contentTintColor = .secondaryLabelColor
        button.imageScaling = .scaleProportionallyDown
    }

    @objc private func copyStatus() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(statusLabel.stringValue, forType: .string)
    }

    private func setBusy(_ busy: Bool, status: String? = nil) {
        if busy {
            searchTask?.cancel()
            searchGeneration += 1
            isSearching = false
        }
        isBusy = busy
        updateActivityIndicator()

        apiSettingsButton.isEnabled = !busy
        searchField.isEnabled = !busy
        refreshButton.isEnabled = !busy
        tableView.isEnabled = !busy

        loadMoreButton.isEnabled =
            !busy &&
            searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            loadedOffset < totalCount

        if let status {
            setStatus(status, tone: .neutral)
        }
    }

    private func updateActivityIndicator() {
        let active = isBusy || isSearching
        spinner.isHidden = !active
        if active {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    private func setStatus(_ text: String, tone: StatusTone) {
        statusLabel.stringValue = text
        statusLabel.textColor = tone.color
    }
}

extension HubcapViewController: NSSearchFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        scheduleSearch()
    }
}

extension HubcapViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        games.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row >= 0, row < games.count else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("HubcapGameCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? HubcapGameCell)
            ?? HubcapGameCell(identifier: identifier)

        let game = games[row]
        cell.isInstalled = isInstalled(game)
        cell.configure(game: game)
        cell.onInstall = { [weak self] in
            self?.install(game: game)
        }
        return cell
    }

    func tableView(
        _ tableView: NSTableView,
        heightOfRow row: Int
    ) -> CGFloat {
        82
    }
}

@MainActor
private final class HubcapGameCell: NSTableCellView {
    private static let imageCache = NSCache<NSURL, NSImage>()

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let availabilityLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "Install", target: nil, action: nil)
    private let installedIcon = NSImageView()
    private let installedLabel = NSTextField(labelWithString: "Installed")

    private var imageTask: Task<Void, Never>?
    private var representedID = ""

    var onInstall: (() -> Void)?
    var isInstalled = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageAlignment = .alignCenter
        iconView.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        iconView.contentTintColor = Colors.quiet
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 7
        iconView.layer?.masksToBounds = true
        iconView.layer?.backgroundColor = Colors.quiet.withAlphaComponent(0.08).cgColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        metaLabel.font = Typography.caption
        metaLabel.textColor = Colors.secondaryText
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        availabilityLabel.font = Typography.caption
        availabilityLabel.alignment = .right
        availabilityLabel.translatesAutoresizingMaskIntoConstraints = false

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .regular
        actionButton.font = .systemFont(ofSize: 13, weight: .semibold)
        actionButton.contentTintColor = .controlAccentColor
        actionButton.target = self
        actionButton.action = #selector(installPressed)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.setAccessibilityLabel("Install game")

        installedIcon.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: "Installed"
        )
        installedIcon.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        installedIcon.contentTintColor = .systemGreen
        installedIcon.translatesAutoresizingMaskIntoConstraints = false
        installedIcon.setAccessibilityElement(false)

        installedLabel.font = .systemFont(ofSize: 12, weight: .medium)
        installedLabel.textColor = .systemGreen
        installedLabel.translatesAutoresizingMaskIntoConstraints = false
        installedLabel.setAccessibilityElement(false)

        let installedStack = NSStackView(views: [installedIcon, installedLabel])
        installedStack.orientation = .horizontal
        installedStack.alignment = .centerY
        installedStack.spacing = 5
        installedStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(metaLabel)
        addSubview(availabilityLabel)
        addSubview(actionButton)
        addSubview(installedStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 96),
            iconView.heightAnchor.constraint(equalToConstant: 56),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: availabilityLabel.leadingAnchor, constant: -12),

            metaLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            metaLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -12),

            availabilityLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            availabilityLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            actionButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            installedStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            installedStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        installedStack.setContentHuggingPriority(.required, for: .horizontal)
        installedStack.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        imageTask?.cancel()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        representedID = ""
        isInstalled = false
        actionButton.isHidden = false
        installedIcon.isHidden = true
        installedLabel.isHidden = true
    }

    func configure(game: HubcapGame) {
        imageTask?.cancel()
        representedID = game.id

        nameLabel.stringValue = game.name
        let type = game.appType?.capitalized ?? "App"
        metaLabel.stringValue = "App ID \(game.id)  •  \(type)"

        availabilityLabel.stringValue = game.manifestAvailable ? "Manifest available" : "No manifest"
        availabilityLabel.textColor = game.manifestAvailable ? Colors.secondaryText : Colors.quiet

        if isInstalled {
            actionButton.isHidden = true
            installedIcon.isHidden = false
            installedLabel.isHidden = false
        } else {
            actionButton.isHidden = false
            installedIcon.isHidden = true
            installedLabel.isHidden = true
            actionButton.isEnabled = game.appID != nil && game.manifestAvailable
        }

        iconView.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        iconView.contentTintColor = Colors.quiet

        guard let url = game.headerImageURL else { return }

        // Never block first-paint on remote Steam art. Use memory cache immediately;
        // fetch uncached art only after the row has rendered.
        if let cached = Self.imageCache.object(forKey: url as NSURL) {
            iconView.image = cached
            return
        }

        imageTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = NSImage(data: data), !Task.isCancelled else { return }
                Self.imageCache.setObject(image, forKey: url as NSURL)
                guard let self, self.representedID == game.id else { return }
                self.iconView.image = image
            } catch {
                // Keep the lightweight built-in icon if Steam art is unavailable.
            }
        }
    }

    @objc private func installPressed() {
        onInstall?()
    }
}

private extension EmptyStateView {
    func configure(symbol: String, prompt: String, hint: String) {
        // Rebuild only the text/glyph state of the lightweight empty state view.
        subviews.forEach { $0.removeFromSuperview() }

        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        glyph.symbolConfiguration = .init(pointSize: 34, weight: .regular)
        glyph.contentTintColor = Colors.quiet
        glyph.setAccessibilityElement(false)

        let promptLabel = NSTextField(labelWithString: prompt)
        promptLabel.font = Typography.body
        promptLabel.textColor = Colors.secondaryText
        promptLabel.alignment = .center

        let hintLabel = NSTextField(labelWithString: hint)
        hintLabel.font = Typography.caption
        hintLabel.textColor = Colors.quiet
        hintLabel.alignment = .center

        orientation = .vertical
        alignment = .centerX
        spacing = 4
        setViews([glyph, promptLabel, hintLabel], in: .center)
        setCustomSpacing(8, after: glyph)
    }
}

@MainActor
private final class HubcapSettingsDialogController: NSObject {
    enum Result {
        case connect(String)
        case disconnect
        case cancel
    }

    private let openAPIKeys: () -> Void
    private let keyField = NSSecureTextField()
    private let alert = NSAlert()
    private var connectButton: NSButton!
    private var disconnectButton: NSButton!
    private var cancelButton: NSButton!
    private var accessoryView: NSView!

    init(apiKey: String?, openAPIKeys: @escaping () -> Void) {
        self.openAPIKeys = openAPIKeys
        super.init()

        alert.alertStyle = .informational
        alert.messageText = "Connect to Hubcap"
        alert.informativeText = "Enter your Hubcap API key to browse and install manifests."

        keyField.stringValue = apiKey ?? ""
        keyField.placeholderString = "Hubcap API key"
        keyField.font = .systemFont(ofSize: 13)
        keyField.controlSize = .large
        keyField.usesSingleLineMode = false
        keyField.maximumNumberOfLines = 0
        keyField.lineBreakMode = .byWordWrapping
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.setAccessibilityLabel("Hubcap API key")

        let getKeyButton = NSButton(
            title: "Get API key",
            target: self,
            action: #selector(openAPIKeysPressed)
        )
        getKeyButton.translatesAutoresizingMaskIntoConstraints = false

        let helper = NSTextField(labelWithString: "Stored locally by macSteam.")
        helper.font = .systemFont(ofSize: 11)
        helper.textColor = .secondaryLabelColor
        helper.translatesAutoresizingMaskIntoConstraints = false

        accessoryView = NSView(
            frame: NSRect(x: 0, y: 0, width: 260, height: 128)
        )
        accessoryView.addSubview(keyField)
        accessoryView.addSubview(helper)
        accessoryView.addSubview(getKeyButton)

        NSLayoutConstraint.activate([
            keyField.topAnchor.constraint(equalTo: accessoryView.topAnchor),
            keyField.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
            keyField.trailingAnchor.constraint(equalTo: accessoryView.trailingAnchor),
            keyField.heightAnchor.constraint(equalToConstant: 72),

            helper.topAnchor.constraint(equalTo: keyField.bottomAnchor, constant: 8),
            helper.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
            helper.trailingAnchor.constraint(equalTo: accessoryView.trailingAnchor),

            getKeyButton.topAnchor.constraint(equalTo: helper.bottomAnchor, constant: 8),
            getKeyButton.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
            getKeyButton.bottomAnchor.constraint(equalTo: accessoryView.bottomAnchor),
        ])

        alert.accessoryView = accessoryView

        // NSAlert places the first-added native button on the trailing edge.
        // Add in reverse visual order to get: Connect | Disconnect | Cancel.
        cancelButton = alert.addButton(withTitle: "Cancel")
        disconnectButton = alert.addButton(withTitle: "Disconnect")
        connectButton = alert.addButton(withTitle: "Connect")

        disconnectButton.isEnabled = apiKey != nil && !(apiKey?.isEmpty ?? true)
        connectButton.keyEquivalent = "\r"
    }

    func run() -> Result {
        alert.window.initialFirstResponder = keyField
        alert.layout()

        // Keep the native NSAlert response buttons exactly as AppKit creates them.
        // Match the multiline API input to the width of their response container.
        var responseContainer: NSView? = connectButton
        while let parent = responseContainer?.superview {
            if parent is NSStackView {
                responseContainer = parent
                break
            }
            responseContainer = parent
        }

        let responseWidth = responseContainer?.bounds.width
            ?? max(
                connectButton.frame.width,
                max(disconnectButton.frame.width, cancelButton.frame.width)
            )

        if responseWidth > 0 {
            var frame = accessoryView.frame
            frame.size.width = responseWidth
            accessoryView.frame = frame
            alert.layout()
        }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .cancel
        case .alertSecondButtonReturn:
            return .disconnect
        case .alertThirdButtonReturn:
            return .connect(keyField.stringValue)
        default:
            return .cancel
        }
    }

    @objc private func openAPIKeysPressed() {
        openAPIKeys()
    }
}


private enum HubcapInstallError: LocalizedError {
    case appIDMismatch(requested: Int)
    case downloadEmpty

    var errorDescription: String? {
        switch self {
        case .appIDMismatch(let id):
            return "Hubcap returned Lua that does not contain App \(id)."
        case .downloadEmpty:
            return "Hubcap returned an empty Lua download."
        }
    }
}
