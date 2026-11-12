// Browse the public LuaTools Denuvo fix catalog. Downloads stay on lua.tools
// because they require a lua.tools/Discord session.
import AppKit
import Foundation

@MainActor
final class FixesViewController: NSViewController {
    private let store: ConfigStore
    private let onConfigChanged: () -> Void
    private let client = LuaToolsFixesClient.shared

    private var statusIcon: NSImageView!
    private var statusLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var refreshButton: NSButton!
    private var openWebButton: NSButton!
    private var searchField: NSSearchField!
    private var tagPopup: NSPopUpButton!
    private var myGamesButton: NSButton!
    private var countLabel: NSTextField!
    private var tableView: NSTableView!
    private var tableScroll: NSScrollView!
    private var emptyLabel: NSTextField!

    private var allGames: [LuaToolsFixGame] = []
    private var tags: [LuaToolsFixTag] = []
    private var games: [LuaToolsFixGame] = []
    private var isLoading = false
    private var isLoadingDetail = false
    private var loadTask: Task<Void, Never>?

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

        statusLabel = NSTextField(labelWithString: "Loading LuaTools fixes…")
        statusLabel.font = Typography.body
        statusLabel.textColor = Colors.secondaryText
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        openWebButton = makeButton(title: "Open lua.tools", target: self,
                                   action: #selector(openLuaTools))
        refreshButton = makeButton(title: "Refresh", target: self, action: #selector(refresh))

        let statusRow = NSStackView(views: [statusIcon, statusLabel, spinner,
                                            NSView(), openWebButton, refreshButton])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true

        searchField = NSSearchField()
        searchField.placeholderString = "Search fixes by game name or App ID"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityLabel("Search LuaTools fixes")

        tagPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        tagPopup.translatesAutoresizingMaskIntoConstraints = false
        tagPopup.widthAnchor.constraint(equalToConstant: 190).isActive = true
        tagPopup.target = self
        tagPopup.action = #selector(filterChanged)
        tagPopup.addItem(withTitle: "All tags")
        tagPopup.lastItem?.representedObject = nil

        myGamesButton = NSButton(checkboxWithTitle: "My games", target: self,
                                 action: #selector(filterChanged))
        myGamesButton.font = Typography.caption
        myGamesButton.toolTip = "Only show games added to macSteam."
        myGamesButton.translatesAutoresizingMaskIntoConstraints = false

        countLabel = NSTextField(labelWithString: "")
        countLabel.font = Typography.caption
        countLabel.textColor = Colors.secondaryText
        countLabel.alignment = .right
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let filterRow = NSStackView(views: [tagPopup, myGamesButton, NSView(), countLabel])
        filterRow.orientation = .horizontal
        filterRow.alignment = .centerY
        filterRow.spacing = 10
        filterRow.translatesAutoresizingMaskIntoConstraints = false

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 64
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        let column = NSTableColumn(identifier: .init("fixes"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        tableScroll = makeScrollView()
        tableScroll.documentView = tableView
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel = NSTextField(labelWithString: "Loading LuaTools fixes…")
        emptyLabel.font = Typography.body
        emptyLabel.textColor = Colors.secondaryText
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(statusRow)
        root.addSubview(searchField)
        root.addSubview(filterRow)
        root.addSubview(tableScroll)
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            statusRow.topAnchor.constraint(equalTo: root.topAnchor, constant: m),
            statusRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            statusRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),

            searchField.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),

            filterRow.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            filterRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            filterRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),

            tableScroll.topAnchor.constraint(equalTo: filterRow.bottomAnchor, constant: 10),
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
        if allGames.isEmpty, !isLoading {
            load(force: false)
        } else if myGamesButton.state == .on {
            applyFilter()
        }
    }

    // MARK: - Loading

    @objc private func refresh() {
        load(force: true)
    }

    private func load(force: Bool) {
        guard !isLoading else { return }
        loadTask?.cancel()
        setBusy(true)
        showEmpty("Loading LuaTools fixes…")
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let listings = try await client.listings(force: force)
                guard !Task.isCancelled else { return }
                self.allGames = listings.games
                self.tags = listings.tags
                self.rebuildTagMenu()
                self.store.reloadFromDisk()
                self.applyFilter()
                self.setBusy(false)
            } catch {
                guard !Task.isCancelled else { return }
                self.setBusy(false)
                self.updateStatus(error: error.localizedDescription)
                self.showEmpty(error.localizedDescription)
            }
        }
    }

    private func rebuildTagMenu() {
        let selected = tagPopup.selectedItem?.representedObject as? String
        tagPopup.removeAllItems()
        tagPopup.addItem(withTitle: "All tags")
        tagPopup.lastItem?.representedObject = nil
        for tag in tags {
            tagPopup.addItem(withTitle: tag.name)
            tagPopup.lastItem?.representedObject = tag.id
        }
        if let selected,
           let index = tagPopup.itemArray.firstIndex(where: {
               ($0.representedObject as? String) == selected
           }) {
            tagPopup.selectItem(at: index)
        } else {
            tagPopup.selectItem(at: 0)
        }
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedTag = tagPopup.selectedItem?.representedObject as? String
        var shown = allGames
        if let selectedTag {
            shown = shown.filter { game in
                game.tags.contains { $0.id == selectedTag }
            }
        }
        if myGamesButton.state == .on {
            let apps = Set(store.config.apps)
            shown = shown.filter { game in
                guard let appID = game.numericAppID else { return false }
                return apps.contains(appID)
            }
        }
        if !query.isEmpty {
            shown = shown.filter { game in
                game.name.localizedCaseInsensitiveContains(query)
                    || game.appID.contains(query)
            }
        }
        games = shown
        tableView.reloadData()
        if games.isEmpty {
            if allGames.isEmpty {
                showEmpty("LuaTools returned no fixes.")
            } else {
                showEmpty("No LuaTools fixes matched this filter.")
            }
        } else {
            emptyLabel.isHidden = true
        }
        updateCount()
        updateStatus()
    }

    private func updateCount() {
        let totalFixes = allGames.reduce(0) { $0 + $1.fixCount }
        if games.count == allGames.count {
            countLabel.stringValue = "\(allGames.count) games · \(totalFixes) fixes"
        } else {
            countLabel.stringValue = "\(games.count) of \(allGames.count) games"
        }
    }

    private func updateStatus(error: String? = nil) {
        if let error {
            setStatus(error, tone: .bad)
            return
        }
        if isLoading {
            setStatus("Loading LuaTools fixes…", tone: .neutral)
        } else if allGames.isEmpty {
            setStatus("LuaTools fixes unavailable.", tone: .warn)
        } else if games.count == allGames.count {
            setStatus("LuaTools fix catalog", tone: .ok)
        } else {
            setStatus("Filtered LuaTools fixes", tone: .ok)
        }
    }

    private func setStatus(_ text: String, tone: StatusTone) {
        statusIcon.image = NSImage(systemSymbolName: tone.symbol,
                                   accessibilityDescription: nil)
        statusIcon.contentTintColor = tone.color
        statusLabel.stringValue = text
    }

    private func setBusy(_ busy: Bool) {
        isLoading = busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        refreshButton.isEnabled = !busy
        openWebButton.isEnabled = !busy
        searchField.isEnabled = !busy
        tagPopup.isEnabled = !busy
        myGamesButton.isEnabled = !busy
        updateStatus()
    }

    private func showEmpty(_ text: String) {
        emptyLabel.stringValue = text
        emptyLabel.isHidden = false
    }

    // MARK: - Actions

    @objc private func openLuaTools() {
        NSWorkspace.shared.open(LuaToolsFixesClient.webURL)
    }

    @objc private func filterChanged() {
        store.reloadFromDisk()
        applyFilter()
    }

    func refreshAfterInstall() {
        store.reloadFromDisk()
        if myGamesButton.state == .on {
            applyFilter()
        }
    }

    private func showFixes(for game: LuaToolsFixGame) {
        guard !isLoadingDetail else { return }
        isLoadingDetail = true
        setStatus("Loading fixes for \(game.name)…", tone: .neutral)
        spinner.startAnimation(nil)
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isLoadingDetail = false
                self.spinner.stopAnimation(nil)
            }
            do {
                let detail = try await client.fixes(appID: game.appID)
                let appID = game.numericAppID ?? 0
                let installDir = await Task.detached {
                    SteamLibrary.installDir(appID: appID)
                }.value
                let controller = LuaToolsFixDetailViewController(
                    game: game,
                    detail: detail,
                    installDir: installDir,
                    store: self.store,
                    onConfigChanged: self.onConfigChanged)
                self.presentAsSheet(controller)
                self.updateStatus()
            } catch {
                self.updateStatus(error: error.localizedDescription)
                presentAlert("Couldn’t load fixes", error.localizedDescription, style: .warning)
            }
        }
    }
}

// MARK: - Search

extension FixesViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }
}

// MARK: - Table

extension FixesViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { games.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < games.count else { return nil }
        let game = games[row]
        let id = NSUserInterfaceItemIdentifier("luatools-fix-game")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? LuaToolsFixGameCell)
            ?? LuaToolsFixGameCell(identifier: id)
        cell.configure(game: game) { [weak self] in
            self?.showFixes(for: game)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

// MARK: - Game row

@MainActor
final class LuaToolsFixGameCell: NSTableCellView {
    private let art = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let viewButton = NSButton()
    private var onView: (() -> Void)?
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

        detailLabel.font = Typography.caption
        detailLabel.textColor = Colors.secondaryText
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        viewButton.title = "View"
        viewButton.bezelStyle = .rounded
        viewButton.controlSize = .small
        viewButton.target = self
        viewButton.action = #selector(viewPressed)
        viewButton.translatesAutoresizingMaskIntoConstraints = false
        viewButton.setContentHuggingPriority(.required, for: .horizontal)
        viewButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(art)
        addSubview(nameLabel)
        addSubview(detailLabel)
        addSubview(viewButton)

        NSLayoutConstraint.activate([
            art.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            art.centerYAnchor.constraint(equalTo: centerYAnchor),
            art.widthAnchor.constraint(equalToConstant: 96),
            art.heightAnchor.constraint(equalToConstant: 36),

            nameLabel.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: viewButton.leadingAnchor, constant: -12),
            nameLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: viewButton.leadingAnchor,
                                                  constant: -12),
            detailLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),

            viewButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            viewButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            viewButton.widthAnchor.constraint(equalToConstant: 64),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(game: LuaToolsFixGame, onView: @escaping () -> Void) {
        nameLabel.stringValue = game.name
        let tagNames = game.tags.prefix(3).map(\.name).joined(separator: " · ")
        var detail = "\(game.fixCount) fix\(game.fixCount == 1 ? "" : "es") · App \(game.appID)"
        if !tagNames.isEmpty { detail += " · \(tagNames)" }
        detailLabel.stringValue = detail
        self.onView = onView

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

    @objc private func viewPressed() {
        onView?()
    }
}

// MARK: - Detail sheet

private final class FixesDetailDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class LuaToolsFixDetailViewController: NSViewController {
    private let game: LuaToolsFixGame
    private let detail: LuaToolsFixDetail
    private var installDir: URL?
    private let store: ConfigStore
    private let onConfigChanged: () -> Void
    private var activationObserver: NSObjectProtocol?
    private let art = NSImageView()
    private var artTask: Task<Void, Never>?
    private var cards: [LuaToolsFixCardView] = []
    private var appliedFixes: [String: SteamAppliedFix] = [:]
    private var undoAllButton: NSButton!
    private var statusLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var isInstalling = false

    init(game: LuaToolsFixGame,
         detail: LuaToolsFixDetail,
         installDir: URL?,
         store: ConfigStore,
         onConfigChanged: @escaping () -> Void) {
        self.game = game
        self.detail = detail
        self.installDir = installDir
        self.store = store
        self.onConfigChanged = onConfigChanged
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard activationObserver == nil else { return }
        // The game may be updated, uninstalled or wiped while this window is open; re-read the
        // folder whenever the user comes back to macSteam so Undo/Install reflect the disk.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadFromDisk() }
        }
        reloadFromDisk()
    }

    private func reloadFromDisk() {
        guard !isInstalling, let appID = Int(detail.appID) else { return }
        installDir = SteamLibrary.installDir(appID: appID)
        cards.forEach { $0.setInstalled(installDir != nil) }
        refreshAppliedFixes()
    }

    override func loadView() {
        let sheetSize = NSSize(width: 820, height: 640)
        let root = NSView(frame: NSRect(origin: .zero, size: sheetSize))
        let m = Metrics.paneMargin
        let contentWidth = sheetSize.width - 2 * m

        let title = NSTextField(labelWithString: detail.name)
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString:
            "App \(detail.appID) · \(detail.fixes.count) LuaTools fix"
            + (detail.fixes.count == 1 ? "" : "es"))
        subtitle.font = Typography.caption
        subtitle.textColor = Colors.secondaryText
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let tagNames = Set(detail.fixes.flatMap { $0.tags.map(\.name) })
            .sorted().joined(separator: " · ")
        let tagsLabel = NSTextField(labelWithString: tagNames)
        tagsLabel.font = Typography.caption
        tagsLabel.textColor = Colors.quiet
        tagsLabel.lineBreakMode = .byTruncatingTail
        tagsLabel.translatesAutoresizingMaskIntoConstraints = false

        art.translatesAutoresizingMaskIntoConstraints = false
        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true
        art.layer?.cornerRadius = 6
        art.layer?.masksToBounds = true

        if let installDir {
            appliedFixes = Dictionary(uniqueKeysWithValues:
                SteamFixInstaller.appliedFixes(installDir: installDir)
                    .map { ($0.fixID, $0) })
        }

        let closeButton = makeButton(title: "Close", target: self, action: #selector(close))
        let webButton = makeButton(title: "Open on lua.tools", target: self,
                                   action: #selector(openWebPage))
        let copyButton = makeButton(title: "Copy App ID", target: self,
                                    action: #selector(copyAppID))
        undoAllButton = makeButton(title: "Undo All Fixes…", target: self,
                                   action: #selector(undoAllFixes))
        undoAllButton.isHidden = appliedFixes.isEmpty
        undoAllButton.isEnabled = !appliedFixes.isEmpty

        let buttons = NSStackView(views: [undoAllButton!, copyButton, webButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [title, subtitle, tagsLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [art, textStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 16
        header.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(labelWithString:
            "Manifest installs the force-locked Lua and depot manifests into macSteam. "
            + "Install Fix copies the fix's game files into the installed game folder, "
            + "backing up originals under .macsteam-fix. Use Undo to restore those "
            + "originals. Both actions need a lua.tools/Discord account and count toward "
            + "the lua.tools daily download limit.")
        note.font = Typography.caption
        note.textColor = Colors.secondaryText
        note.maximumNumberOfLines = 0
        note.lineBreakMode = .byWordWrapping
        note.preferredMaxLayoutWidth = contentWidth
        note.translatesAutoresizingMaskIntoConstraints = false

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString:
            "Click Manifest on a fix to sign in and download its Lua + manifests.")
        statusLabel.font = Typography.caption
        statusLabel.textColor = Colors.secondaryText
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        for fix in detail.fixes {
            let card = LuaToolsFixCardView(
                fix: fix,
                installed: installDir != nil,
                state: cardState(for: fix.id),
                onManifest: { [weak self] in self?.installManifest(fix: fix) },
                onFix: { [weak self] in self?.installFix(fix: fix) },
                onUndo: { [weak self] in self?.undoFix(fix: fix) })
            cards.append(card)
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if detail.fixes.isEmpty {
            let empty = NSTextField(labelWithString: "No fixes are listed for this game.")
            empty.font = Typography.body
            empty.textColor = Colors.secondaryText
            stack.addArrangedSubview(empty)
        }

        let document = FixesDetailDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = makeScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        root.addSubview(header)
        root.addSubview(note)
        root.addSubview(statusRow)
        root.addSubview(scroll)
        root.addSubview(buttons)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: sheetSize.width),
            root.heightAnchor.constraint(equalToConstant: sheetSize.height),

            header.topAnchor.constraint(equalTo: root.topAnchor, constant: m),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            header.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor,
                                             constant: -16),
            art.widthAnchor.constraint(equalToConstant: 220),
            art.heightAnchor.constraint(equalToConstant: 86),

            buttons.topAnchor.constraint(equalTo: root.topAnchor, constant: m),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),

            note.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            note.widthAnchor.constraint(equalToConstant: contentWidth),

            statusRow.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 8),
            statusRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            statusRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),

            scroll.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            scroll.widthAnchor.constraint(equalToConstant: contentWidth),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -m),

            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
        ])

        view = root
        preferredContentSize = sheetSize
        loadArt()
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss(self)
    }

    @objc private func close() {
        dismiss(self)
    }

    @objc private func openWebPage() {
        NSWorkspace.shared.open(LuaToolsFixesClient.webURL(appID: detail.appID))
    }

    @objc private func copyAppID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(detail.appID, forType: .string)
    }

    private func loadArt() {
        guard let header = detail.headerImage ?? game.headerImage else { return }
        artTask = Task { [weak self] in
            let data = await SteamStoreClient.shared.imageData(for: header)
            guard !Task.isCancelled, let self, let data else { return }
            self.art.image = StoreArtLoader.decode(data, targetWidth: 480)
        }
    }

    private func installManifest(fix: LuaToolsFix) {
        guard !isInstalling else { return }
        guard let appID = Int(detail.appID) else { return }
        isInstalling = true
        cards.forEach { $0.setBusy(true) }
        spinner.startAnimation(nil)
        statusLabel.stringValue = "Preparing download…"

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isInstalling = false
                self.cards.forEach { $0.setBusy(false) }
                self.spinner.stopAnimation(nil)
            }
            do {
                if !(await LuaToolsAuth.shared.isSignedIn()) {
                    self.statusLabel.stringValue = "Complete Discord sign-in in your browser…"
                    _ = try await LuaToolsAuth.shared.signIn()
                    NSApp.activate(ignoringOtherApps: true)
                }
                self.statusLabel.stringValue = "Downloading Lua + manifests…"
                let data = try await LuaToolsFixesClient.shared.downloadManifest(fixID: fix.id)
                self.statusLabel.stringValue = "Installing Lua + manifests…"
                let result = try LuaToolsManifestInstaller.installManifest(
                    data: data, appID: appID, store: self.store)
                self.onConfigChanged()
                _ = await HubcapActivation.requestRefresh()
                self.statusLabel.stringValue = result.manifestCount == 0
                    ? "Installed \(result.title) · Lua only"
                    : "Installed \(result.title) · \(result.manifestCount) manifest"
                        + (result.manifestCount == 1 ? "" : "s")
                let manifestText = result.manifestCount == 0
                    ? "The force-locked Lua was installed. This fix did not include separate depot manifests."
                    : "The force-locked Lua and \(result.manifestCount) depot manifest"
                        + (result.manifestCount == 1 ? "" : "s") + " were installed."
                presentAlert(
                    "Added \(result.title)",
                    manifestText + " Open the game's Steam store page and click Install with Steam.",
                    style: .informational)
            } catch {
                self.statusLabel.stringValue = error.localizedDescription
                presentAlert("Couldn’t install fix", error.localizedDescription,
                             style: .warning)
            }
        }
    }

    private func installFix(fix: LuaToolsFix) {
        guard let installDir else {
            presentAlert("Game not installed",
                         SteamFixInstallError.noInstallDir.localizedDescription,
                         style: .warning)
            return
        }
        guard !isInstalling, let appID = Int(detail.appID) else { return }
        // Ask macOS for write access first: this surfaces its own prompt where one exists and
        // saves the download when it would be refused anyway.
        do { try SteamFixInstaller.ensureWritable(installDir: installDir) } catch {
            statusLabel.stringValue = error.localizedDescription
            presentFixError("Couldn’t install fix", error)
            return
        }
        isInstalling = true
        cards.forEach { $0.setBusy(true) }
        spinner.startAnimation(nil)
        statusLabel.stringValue = "Preparing fix download…"

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isInstalling = false
                self.cards.forEach { $0.setBusy(false) }
                self.spinner.stopAnimation(nil)
            }
            do {
                if !(await LuaToolsAuth.shared.isSignedIn()) {
                    self.statusLabel.stringValue = "Complete Discord sign-in in your browser…"
                    _ = try await LuaToolsAuth.shared.signIn()
                    NSApp.activate(ignoringOtherApps: true)
                }
                self.statusLabel.stringValue = "Downloading fix files…"
                let data = try await LuaToolsFixesClient.shared.downloadFix(fixID: fix.id)
                self.statusLabel.stringValue = "Installing fix files into the game folder…"
                let target = installDir
                let fixID = fix.id
                let result = try await Task.detached {
                    try SteamFixInstaller.apply(
                        zipData: data, appID: appID, fixID: fixID, installDir: target)
                }.value
                self.refreshAppliedFixes()
                self.statusLabel.stringValue =
                    "Installed fix · \(result.modified) replaced · \(result.added) added"
                presentAlert(
                    "Fix installed",
                    "\(result.modified) file\(result.modified == 1 ? "" : "s") replaced and "
                    + "\(result.added) added. Originals are backed up in the game's "
                    + "`.macsteam-fix` folder. Use Undo on the fix to restore them.",
                    style: .informational)
            } catch {
                self.statusLabel.stringValue = error.localizedDescription
                self.presentFixError("Couldn’t install fix", error)
            }
        }
    }

    private func cardState(for fixID: String) -> LuaToolsFixCardView.State {
        guard let applied = appliedFixes[fixID] else { return .notApplied }
        return applied.isDrifted ? .drifted : .applied
    }

    /// Permission problems get macOS-specific guidance; anything else is shown as is.
    private func presentFixError(_ title: String, _ error: Error) {
        if case SteamFixInstallError.permissionDenied(let path) = error {
            presentFileAccessAlert(path: path)
        } else {
            presentAlert(title, error.localizedDescription, style: .warning)
        }
    }

    private func refreshAppliedFixes() {
        guard let installDir else {
            appliedFixes = [:]
            undoAllButton?.isHidden = true
            undoAllButton?.isEnabled = false
            return
        }
        appliedFixes = Dictionary(uniqueKeysWithValues:
            SteamFixInstaller.appliedFixes(installDir: installDir)
                .map { ($0.fixID, $0) })
        for card in cards {
            card.setState(cardState(for: card.fixID))
        }
        undoAllButton?.isHidden = appliedFixes.isEmpty
        undoAllButton?.isEnabled = !appliedFixes.isEmpty && !isInstalling
    }

    private func undoFix(fix: LuaToolsFix) {
        guard let installDir, !isInstalling, let applied = appliedFixes[fix.id] else {
            return
        }
        let alert = NSAlert()
        if case .drifted(let changed, let missing) = applied.health {
            alert.messageText = "Remove \(fix.title)?"
            let touched = changed.count + missing.count
            alert.informativeText = "\(touched) of this fix's files changed or are missing, "
                + "probably because the game was updated. macSteam will remove or restore only "
                + "the files that are still exactly what the fix installed and leave the rest "
                + "alone. Afterwards you can install the fix again."
        } else {
            alert.messageText = "Undo \(fix.title)?"
            alert.informativeText = "macSteam will restore \(applied.modified) replaced "
                + "file\(applied.modified == 1 ? "" : "s") and remove \(applied.added) added "
                + "file\(applied.added == 1 ? "" : "s") from the game folder."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: applied.isDrifted ? "Remove" : "Undo")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isInstalling = true
        cards.forEach { $0.setBusy(true) }
        spinner.startAnimation(nil)
        statusLabel.stringValue = "Restoring original files…"

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isInstalling = false
                self.cards.forEach { $0.setBusy(false) }
                self.undoAllButton?.isEnabled =
                    !self.appliedFixes.isEmpty && !self.isInstalling
                self.spinner.stopAnimation(nil)
            }
            do {
                let target = installDir
                let fixID = fix.id
                let safely = applied.isDrifted
                let result = try await Task.detached {
                    safely
                        ? try SteamFixInstaller.revertSafely(installDir: target, fixID: fixID)
                        : try SteamFixInstaller.revert(installDir: target, fixID: fixID)
                }.value
                self.refreshAppliedFixes()
                self.statusLabel.stringValue =
                    "Undid fix · \(result.restored) restored · \(result.removed) removed"
                let left = result.skipped.isEmpty ? "" : " \(result.skipped.count) changed "
                    + "file\(result.skipped.count == 1 ? " was" : "s were") left as the game has them."
                presentAlert(
                    "Fix removed",
                    "\(result.restored) file\(result.restored == 1 ? "" : "s") restored and "
                    + "\(result.removed) added file\(result.removed == 1 ? "" : "s") removed." + left,
                    style: .informational)
            } catch SteamFixInstallError.modifiedSinceApply(let paths) {
                // Changed between the preflight and now (or the card was stale): offer the safe undo.
                self.statusLabel.stringValue = SteamFixInstallError.modifiedSinceApply(paths).localizedDescription
                self.refreshAppliedFixes()
            } catch {
                self.statusLabel.stringValue = error.localizedDescription
                self.presentFixError("Couldn’t undo fix", error)
            }
        }
    }

    @objc private func undoAllFixes() {
        guard let installDir, !isInstalling, !appliedFixes.isEmpty else { return }
        let fixes = appliedFixes.values.sorted {
            ($0.appliedAt ?? .distantPast) > ($1.appliedAt ?? .distantPast)
        }
        let files = fixes.reduce(0) { $0 + $1.fileCount }
        let alert = NSAlert()
        alert.messageText = "Undo all installed fixes?"
        alert.informativeText = "macSteam will undo \(fixes.count) fix"
            + (fixes.count == 1 ? "" : "es") + " and restore \(files) file"
            + (files == 1 ? "" : "s") + ". Files that changed after a fix was installed "
            + "(for example by a game update) are left as the game has them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Undo All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isInstalling = true
        cards.forEach { $0.setBusy(true) }
        spinner.startAnimation(nil)
        statusLabel.stringValue = "Restoring original files…"

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isInstalling = false
                self.cards.forEach { $0.setBusy(false) }
                self.undoAllButton?.isEnabled =
                    !self.appliedFixes.isEmpty && !self.isInstalling
                self.spinner.stopAnimation(nil)
            }
            do {
                let target = installDir
                let result = try await Task.detached {
                    try SteamFixInstaller.revertAll(installDir: target)
                }.value
                self.refreshAppliedFixes()
                self.statusLabel.stringValue =
                    "Undid \(result.fixes) fix\(result.fixes == 1 ? "" : "es") · "
                    + "\(result.restored) restored · \(result.removed) removed"
                presentAlert(
                    "Fixes removed",
                    "\(result.fixes) fix\(result.fixes == 1 ? "" : "es") undone. "
                    + "\(result.restored) file\(result.restored == 1 ? "" : "s") restored and "
                    + "\(result.removed) added file\(result.removed == 1 ? "" : "s") removed.",
                    style: .informational)
            } catch {
                self.statusLabel.stringValue = error.localizedDescription
                self.presentFixError("Couldn’t undo fixes", error)
            }
        }
    }
}

@MainActor
final class LuaToolsFixCardView: NSView {
    private let fix: LuaToolsFix
    enum State { case notApplied, applied, drifted }
    private var installed: Bool
    private let onManifest: () -> Void
    private let onFix: () -> Void
    private let onUndo: () -> Void
    private var state: State
    private var driftLabel: NSTextField?
    private var manifestButton: NSButton?
    private var fixButton: NSButton?
    private var undoButton: NSButton?

    var fixID: String { fix.id }

    init(fix: LuaToolsFix,
         installed: Bool,
         state: State,
         onManifest: @escaping () -> Void,
         onFix: @escaping () -> Void,
         onUndo: @escaping () -> Void) {
        self.fix = fix
        self.installed = installed
        self.state = state
        self.onManifest = onManifest
        self.onFix = onFix
        self.onUndo = onUndo
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        applyCardSurface()

        let title = NSTextField(labelWithString: fix.title)
        title.font = .systemFont(ofSize: 13.5, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        var metaParts = [fix.availability]
        if !fix.dateLabel.isEmpty { metaParts.append(fix.dateLabel) }
        if !fix.tags.isEmpty {
            metaParts.append(fix.tags.map(\.name).joined(separator: " · "))
        }
        let meta = NSTextField(labelWithString: metaParts.joined(separator: " · "))
        meta.font = Typography.caption
        meta.textColor = Colors.secondaryText
        meta.lineBreakMode = .byTruncatingTail
        meta.translatesAutoresizingMaskIntoConstraints = false

        let body = NSTextField(wrappingLabelWithString:
            Self.plainDescription(fix.description ?? ""))
        body.font = Typography.caption
        body.textColor = Colors.secondaryText
        body.maximumNumberOfLines = 0
        body.isHidden = (fix.description ?? "").isEmpty
        body.translatesAutoresizingMaskIntoConstraints = false

        let drift = NSTextField(wrappingLabelWithString:
            "Some of this fix's files changed since it was installed (a game update?). "
            + "Reinstall it, or remove what is left.")
        drift.font = Typography.caption
        drift.textColor = .systemOrange
        drift.maximumNumberOfLines = 0
        drift.isHidden = true
        drift.translatesAutoresizingMaskIntoConstraints = false
        driftLabel = drift

        var views: [NSView] = [title, meta, body, drift]
        var actions: [NSView] = []
        if fix.hasManifest {
            let button = NSButton(title: "Manifest", target: self,
                                  action: #selector(manifestPressed))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.translatesAutoresizingMaskIntoConstraints = false
            button.toolTip = "Download and install this fix's Lua + depot manifests."
            button.widthAnchor.constraint(equalToConstant: 80).isActive = true
            manifestButton = button
            actions.append(button)
        }
        if fix.hasFix {
            let button = NSButton(title: "Install Fix", target: self,
                                  action: #selector(fixPressed))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.translatesAutoresizingMaskIntoConstraints = false
            button.toolTip = installed
                ? "Download this fix's game files and copy them into the installed game folder. "
                    + "Originals are backed up under .macsteam-fix."
                : "Install this game in Steam first, then reopen this fix."
            button.isEnabled = installed
            button.widthAnchor.constraint(equalToConstant: 90).isActive = true
            fixButton = button
            actions.append(button)

            let undo = NSButton(title: "Undo", target: self,
                                action: #selector(undoPressed))
            undo.bezelStyle = .rounded
            undo.controlSize = .small
            undo.translatesAutoresizingMaskIntoConstraints = false
            undo.toolTip = "Restore the files this fix replaced and remove the files it added."
            undo.widthAnchor.constraint(equalToConstant: 90).isActive = true
            undoButton = undo
            actions.append(undo)
        }
        if !actions.isEmpty {
            let row = NSStackView(views: actions + [NSView()])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            views.append(row)
        }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let last = views.last!
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
            drift.widthAnchor.constraint(equalTo: stack.widthAnchor),
            last.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        updateApplyState()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setState(_ state: State) {
        self.state = state
        updateApplyState()
    }

    func setInstalled(_ installed: Bool) {
        self.installed = installed
        fixButton?.isEnabled = installed
        fixButton?.toolTip = installed
            ? "Download this fix's game files and copy them into the installed game folder. "
                + "Originals are backed up under .macsteam-fix."
            : "Install this game in Steam first, then reopen this fix."
    }

    func setBusy(_ busy: Bool) {
        manifestButton?.isEnabled = !busy
        fixButton?.isEnabled = !busy && installed
        undoButton?.isEnabled = !busy && state != .notApplied
    }

    private func updateApplyState() {
        // Drifted: Reinstall and Remove are both offered; applied: only Undo; otherwise Install.
        fixButton?.isHidden = state == .applied
        fixButton?.title = state == .drifted ? "Reinstall" : "Install Fix"
        undoButton?.isHidden = state == .notApplied
        undoButton?.title = state == .drifted ? "Remove" : "Undo"
        driftLabel?.isHidden = state != .drifted
    }

    @objc private func manifestPressed() {
        onManifest()
    }

    @objc private func fixPressed() {
        onFix()
    }

    @objc private func undoPressed() {
        onUndo()
    }

    private static func plainDescription(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        return s
    }
}
