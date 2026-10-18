// Import pane
import AppKit
import UniformTypeIdentifiers

private extension ImportPlan {
    var title: String { luaTitle ?? sourceZip.deletingPathExtension().lastPathComponent }
    var isImportable: Bool { mainAppID != nil }

    var summary: String {
        guard let app = mainAppID else {
            return "No app id in the file, can't import"
        }
        var parts = ["App \(app)"]
        if dlcAppIDs.count == 1 { parts.append("1 DLC") }
        else if dlcAppIDs.count > 1 { parts.append("\(dlcAppIDs.count) DLC") }
        let keys = depotKeys.count
        if keys > 0 { parts.append("\(keys) depot key\(keys == 1 ? "" : "s")") }
        return parts.joined(separator: "  ·  ")
    }
}

final class ImportViewController: NSViewController {
    let store: ConfigStore
    let onConfigChanged: () -> Void

    private var dropView: DropZoneView!
    private var statusLabel: NSTextField!
    private var reviewTable: DeletingTableView!
    private var applyButton: NSButton!
    private var sizeSlider: ResettableSlider!
    private var pickButton: NSButton!
    private var spinner: NSProgressIndicator!

    // Hidden until a batch loads; the drop well already prompts.
    private var reviewCaption: NSTextField!
    private var addButton: NSButton!
    private var reviewCard: PaneDropView!
    private var listBar: NSView!

    private var successView: NSView!
    private var successTitle: NSTextField!
    private var successDetail: NSTextField!

    private var footerDivider: NSBox!

    private var emptyStateConstraints: [NSLayoutConstraint] = []
    private var reviewStateConstraints: [NSLayoutConstraint] = []
    private var successStateConstraints: [NSLayoutConstraint] = []

    private let art = StoreArtLoader()

    let reviewUndoManager = UndoManager()

    private static let minRowHeight: CGFloat = 48
    private static let maxRowHeight: CGFloat = 160
    private static let defaultRowHeight: CGFloat = 104
    private static let snapDistance: CGFloat = 3
    private static let rowHeightDefaultsKey = "ImportRowHeight"
    private var rowHeight: CGFloat = ImportViewController.loadRowHeight()

    private var tileArtWidth: CGFloat {
        ((Self.maxRowHeight - 2 * GameReviewCell.artInset) * GameReviewCell.artAspect * 2).rounded()
    }

    private static func loadRowHeight() -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: rowHeightDefaultsKey)
        guard stored > 0 else { return defaultRowHeight }
        return min(max(CGFloat(stored), minRowHeight), maxRowHeight)
    }

    private var items: [ImportPlan] = []
    private var isBusy = false
    private var batchGeneration = 0

    private enum Col {
        static let game = NSUserInterfaceItemIdentifier("game")
    }

    init(store: ConfigStore, onConfigChanged: @escaping () -> Void) {
        self.store = store
        self.onConfigChanged = onConfigChanged
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 690, height: 520))

        dropView = DropZoneView()
        dropView.translatesAutoresizingMaskIntoConstraints = false
        dropView.onDrop = { [weak self] urls in self?.loadPlans(from: urls) }
        dropView.onActivate = { [weak self] in self?.pickZipAction() }

        pickButton = makeButton(title: "Choose Files…", target: self, action: #selector(pickZipAction))

        spinner = NSProgressIndicator()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Working")

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        statusLabel.textColor = .labelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1

        reviewCaption = settingsGroupLabel("Review")
        reviewCaption.translatesAutoresizingMaskIntoConstraints = false

        addButton = makeButton(title: "Add Zips…", target: self, action: #selector(pickZipAction))

        listBar = makeListBar()

        let scroll = makeScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false

        reviewCard = PaneDropView()
        reviewCard.translatesAutoresizingMaskIntoConstraints = false
        reviewCard.onDrop = { [weak self] urls in self?.loadPlans(from: urls) }

        reviewTable = DeletingTableView()
        reviewTable.onDeleteKey = { [weak self] in self?.removeSelected() }
        reviewTable.usesAlternatingRowBackgroundColors = false
        reviewTable.rowHeight = rowHeight
        reviewTable.allowsMultipleSelection = false
        reviewTable.allowsEmptySelection = true
        reviewTable.style = .inset
        reviewTable.selectionHighlightStyle = .regular
        reviewTable.backgroundColor = .clear
        reviewTable.dataSource = self
        reviewTable.delegate = self
        reviewTable.headerView = nil

        let rowMenu = NSMenu()
        rowMenu.delegate = self
        reviewTable.menu = rowMenu

        let gameCol = NSTableColumn(identifier: Col.game)
        gameCol.resizingMask = .autoresizingMask
        reviewTable.addTableColumn(gameCol)
        reviewTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        scroll.documentView = reviewTable
        reviewCard.addSubview(scroll)
        reviewCard.addSubview(listBar)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: reviewCard.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: reviewCard.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: reviewCard.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: listBar.topAnchor, constant: -6),

            listBar.leadingAnchor.constraint(equalTo: reviewCard.leadingAnchor),
            listBar.trailingAnchor.constraint(equalTo: reviewCard.trailingAnchor),
            listBar.bottomAnchor.constraint(equalTo: reviewCard.bottomAnchor),
        ])

        applyButton = makeButton(title: "Import", target: self, action: #selector(applyAction))
        applyButton.keyEquivalent = "\r"
        applyButton.isEnabled = false

        successView = makeSuccessView()
        successView.translatesAutoresizingMaskIntoConstraints = false
        successView.isHidden = true

        footerDivider = NSBox()
        footerDivider.boxType = .separator
        footerDivider.translatesAutoresizingMaskIntoConstraints = false

        let M: CGFloat = Metrics.paneMargin

        root.addSubview(dropView)
        root.addSubview(pickButton)
        root.addSubview(spinner)
        root.addSubview(statusLabel)
        root.addSubview(reviewCaption)
        root.addSubview(addButton)
        root.addSubview(reviewCard)
        root.addSubview(successView)
        root.addSubview(footerDivider)
        root.addSubview(applyButton)

        NSLayoutConstraint.activate([
            dropView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: M),
            dropView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -M),

            footerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: applyButton.topAnchor, constant: -12),

            applyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -M),
            applyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -M),
        ])

        emptyStateConstraints = [
            dropView.topAnchor.constraint(equalTo: root.topAnchor, constant: M),
            dropView.bottomAnchor.constraint(equalTo: footerDivider.topAnchor, constant: -20),

            pickButton.centerXAnchor.constraint(equalTo: dropView.centerXAnchor),
            pickButton.topAnchor.constraint(equalTo: dropView.centerYAnchor, constant: 44),

            statusLabel.topAnchor.constraint(equalTo: pickButton.bottomAnchor, constant: 8),
            statusLabel.centerXAnchor.constraint(equalTo: dropView.centerXAnchor),

            spinner.centerYAnchor.constraint(equalTo: pickButton.centerYAnchor),
            spinner.leadingAnchor.constraint(equalTo: pickButton.trailingAnchor, constant: 12),
        ]

        reviewStateConstraints = [
            addButton.topAnchor.constraint(equalTo: root.topAnchor, constant: M),
            addButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -M),

            reviewCaption.firstBaselineAnchor.constraint(equalTo: addButton.firstBaselineAnchor),
            reviewCaption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: M),

            statusLabel.firstBaselineAnchor.constraint(equalTo: addButton.firstBaselineAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: reviewCaption.trailingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: addButton.leadingAnchor, constant: -12),

            spinner.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -8),

            reviewCard.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 12),
            reviewCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: M),
            reviewCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -M),
            reviewCard.bottomAnchor.constraint(equalTo: footerDivider.topAnchor, constant: -20),
        ]

        successStateConstraints = [
            successView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            successView.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -20),
            successView.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: M),
            successView.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -M),
        ]

        setState(.empty)
        view = root
    }

    private func makeSuccessView() -> NSView {
        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                              accessibilityDescription: nil)
        glyph.symbolConfiguration = .init(pointSize: 44, weight: .regular)
        glyph.contentTintColor = .systemGreen
        glyph.setAccessibilityElement(false)

        successTitle = NSTextField(labelWithString: "")
        successTitle.font = Typography.largeTitle
        successTitle.textColor = .labelColor
        successTitle.alignment = .center

        successDetail = NSTextField(labelWithString: "")
        successDetail.font = Typography.body
        successDetail.textColor = Colors.secondaryText
        successDetail.alignment = .center

        let importMore = makeButton(title: "Import More", target: self,
                                    action: #selector(successImportMore))
        importMore.keyEquivalent = "\r"

        let stack = NSStackView(views: [glyph, successTitle, successDetail, importMore])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: glyph)
        stack.setCustomSpacing(20, after: successDetail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    @objc private func successImportMore() { setState(.empty) }

    func pickZip() { pickZipAction() }

    @objc private func pickZipAction() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        let types = ["zip", "lua"].compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty { panel.allowedContentTypes = types }
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            loadPlans(from: panel.urls)
        }
    }

    private func loadPlans(from urls: [URL]) {
        guard !isBusy, !urls.isEmpty else { return }
        let sources = urls.filter {
            ["zip", "lua"].contains($0.pathExtension.lowercased()) || $0.hasDirectoryPath
        }
        guard !sources.isEmpty else { return }

        if items.isEmpty { ZipImporter.sweepStaleExtractDirs() }

        let noun = sources.count == 1 ? "file" : "\(sources.count) files"
        setBusy(true, status: "Reading \(noun)…")

        let generation = batchGeneration

        Task {
            var loaded: [ImportPlan] = []
            var failures: [String] = []
            for src in sources {
                do {
                    let ext = src.pathExtension.lowercased()
                    let plans = try await Task.detached {
                        if ext == "lua" {
                            return [try ZipImporter.buildPlan(fromLua: src)]
                        } else if src.hasDirectoryPath {
                            return try ZipImporter.buildPlans(fromFolder: src)
                        } else {
                            return try ZipImporter.buildPlans(from: src)
                        }
                    }.value
                    loaded.append(contentsOf: plans)
                } catch {
                    failures.append("\(src.lastPathComponent): \(error.localizedDescription)")
                }
            }
            self.setBusy(false, status: nil)
            if self.batchGeneration != generation {
                for plan in loaded { ZipImporter.cleanup(plan.extractDir) }
                return
            }
            self.appendLoadedPlans(loaded, failures: failures)
        }
    }

    private func appendLoadedPlans(_ plans: [ImportPlan], failures: [String]) {
        var existingApps = Set(items.compactMap(\.mainAppID))
        for plan in plans {
            if let app = plan.mainAppID, !existingApps.insert(app).inserted {
                continue
            }
            items.append(plan)
        }
        reviewTable.reloadData()
        repushCachedArt()
        refreshActionBar()
        setState(items.isEmpty ? .empty : .review)
        resolveArt(for: plans)

        let importable = items.filter { $0.isImportable }.count
        let skipped = items.count - importable
        var status = importable == 1 ? "1 game ready to import" : "\(importable) games ready to import"
        if skipped > 0 { status += "  ·  \(skipped) skipped (no app id)" }
        setStatus(status, tint: .labelColor)
        announce(status)

        if !failures.isEmpty {
            presentAlert("Couldn’t read some files",
                         failures.joined(separator: "\n"), style: .warning)
        }
    }

    private func resolveArt(for plans: [ImportPlan]) {
        let ids = plans.compactMap { $0.mainAppID }.filter { $0 > 0 }
        guard !ids.isEmpty else { return }
        art.load(ids, artWidth: tileArtWidth,
                 onName: { [weak self] id, name in self?.applyToRows(appID: id) { $0.setName(name) } },
                 onArt:  { [weak self] id, image in self?.applyToRows(appID: id) { $0.setArt(image) } })
    }

    private func applyToRows(appID: Int, _ apply: (GameReviewCell) -> Void) {
        for row in items.indices where items[row].mainAppID == appID {
            guard row < reviewTable.numberOfRows,
                  let cell = reviewTable.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? GameReviewCell else { continue }
            apply(cell)
        }
    }

    private func repushCachedArt() {
        for row in items.indices {
            guard let id = items[row].mainAppID,
                  row < reviewTable.numberOfRows,
                  let cell = reviewTable.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? GameReviewCell else { continue }
            if let name = art.name(for: id) { cell.setName(name) }
            if let image = art.image(for: id) { cell.setArt(image) }
        }
    }

    private func setBusy(_ busy: Bool, status: String?) {
        isBusy = busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        pickButton.isEnabled = !busy
        dropView.isEnabled = !busy
        if busy { applyButton.isEnabled = false }
        sizeSlider.isEnabled = !busy
        if let status { setStatus(status, tint: .secondaryLabelColor); announce(status) }
    }

    private func setStatus(_ text: String, tint: NSColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = tint
    }

    private func announce(_ text: String) {
        NSAccessibility.post(
            element: statusLabel as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private enum Pane { case empty, review, success }

    private func setState(_ newPane: Pane) {
        let review = newPane == .review
        let success = newPane == .success

        reviewCaption.isHidden = !review
        reviewCard.isHidden = !review
        addButton.isHidden = !review
        dropView.isHidden = !(newPane == .empty)
        pickButton.isHidden = !(newPane == .empty)
        successView.isHidden = !success
        footerDivider.isHidden = success
        applyButton.isHidden = success

        let apply = {
            NSLayoutConstraint.deactivate(self.emptyStateConstraints
                + self.reviewStateConstraints + self.successStateConstraints)
            let set: [NSLayoutConstraint]
            switch newPane {
            case .empty:   set = self.emptyStateConstraints
            case .review:  set = self.reviewStateConstraints
            case .success: set = self.successStateConstraints
            }
            NSLayoutConstraint.activate(set)
        }

        guard isViewLoaded else { apply(); return }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            apply()
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.allowsImplicitAnimation = true
            apply()
            view.layoutSubtreeIfNeeded()
        }
    }

    private func refreshActionBar() {
        applyButton.isEnabled = items.contains { $0.isImportable } && !isBusy
    }

    private func showSuccess(games: Int, dlc: Int) {
        let headline = "Imported \(games) game\(games == 1 ? "" : "s")"
        successTitle.stringValue = headline
        successTitle.setAccessibilityLabel(headline)
        if dlc > 0 {
            successDetail.stringValue = "\(dlc) DLC added"
            successDetail.isHidden = false
        } else {
            successDetail.stringValue = ""
            successDetail.isHidden = true
        }
        setStatus("", tint: .secondaryLabelColor)
        setState(.success)
        announce(dlc > 0 ? "\(headline), \(dlc) DLC added" : headline)
    }

    // MARK: list bottom-bar

    private func makeListBar() -> NSView {
        sizeSlider = ResettableSlider()
        let sizeGroup = makeSizeSliderBar(
            slider: sizeSlider,
            min: Self.minRowHeight, max: Self.maxRowHeight,
            defaultValue: Self.defaultRowHeight,
            currentValue: rowHeight,
            accessibilityLabel: "Review row size")
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeSliderChanged)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [sizeGroup, spacer])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 6
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }

    @objc private func sizeSliderChanged() {
        let h = sizeSlider.snappedValue(min: Self.minRowHeight, max: Self.maxRowHeight,
                                        snapDistance: Self.snapDistance)
        guard h != rowHeight else { return }
        applyRowHeight(h)
    }

    private func applyRowHeight(_ h: CGFloat) {
        rowHeight = h
        reviewTable.rowHeight = rowHeight
        reviewTable.reloadData()
        repushCachedArt()
        UserDefaults.standard.set(Double(rowHeight), forKey: Self.rowHeightDefaultsKey)
    }

    @objc private func useSizeInApps() {
        UserDefaults.standard.set(Double(rowHeight), forKey: AppCardListView.rowHeightDefaultsKey)
        NotificationCenter.default.post(name: AppCardListView.rowHeightChanged, object: nil)
    }

    override func cancelOperation(_ sender: Any?) {
        guard !isBusy, !items.isEmpty else { return }
        batchGeneration += 1
        for item in items { ZipImporter.cleanup(item.extractDir) }
        items.removeAll()
        reviewUndoManager.removeAllActions()
        reviewTable.reloadData()
        refreshActionBar()
        setState(.empty)
        setStatus("Cleared.", tint: .secondaryLabelColor)
        announce("Cleared")
    }

    @objc private func applyAction() {
        guard !isBusy else { return }
        let selected = items.filter { $0.isImportable }
        guard !selected.isEmpty else { return }

        setBusy(true, status: "Applying import…")

        let allManifests = selected.flatMap(\.manifestFiles)
        let plans = selected
        Task {
            let copyResult: Result<Int, Error>
            do {
                copyResult = .success(
                    try await Task.detached { try ZipImporter.copyManifests(allManifests) }.value)
            } catch {
                copyResult = .failure(error)
            }

            self.setBusy(false, status: nil)

            switch copyResult {
            case .failure(let error):
                self.refreshActionBar()
                presentAlert("Import failed", error.localizedDescription, style: .warning)
            case .success:
                do {
                    var dlcTotal = 0
                    try self.store.mutate { cfg in
                        for plan in plans {
                            _ = ZipImporter.merge(plan, into: &cfg)
                            dlcTotal += plan.dlcAppIDs.count
                        }
                    }
                    self.onConfigChanged()

                    let g = plans.count
                    self.batchGeneration += 1
                    for item in self.items { ZipImporter.cleanup(item.extractDir) }
                    self.items.removeAll()
                    self.reviewUndoManager.removeAllActions()
                    self.reviewTable.reloadData()
                    self.refreshActionBar()
                    self.showSuccess(games: g, dlc: dlcTotal)
                } catch {
                    Task.detached { ZipImporter.removeCopiedManifests(allManifests) }
                    self.refreshActionBar()
                    presentAlert("Import failed", error.localizedDescription, style: .warning)
                }
            }
        }
    }

    // MARK: remove

    private func removeRow(_ row: Int) {
        guard row >= 0, row < items.count else { return }
        let removed = items[row]
        items.remove(at: row)

        reviewUndoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.insertItem(removed, at: min(row, target.items.count))
            }
        }
        reviewUndoManager.setActionName("Remove Game")

        reloadReviewKeepingArt()
        if items.isEmpty { setStatus("", tint: .secondaryLabelColor) }
    }

    private func insertItem(_ item: ImportPlan, at row: Int) {
        items.insert(item, at: row)

        reviewUndoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                guard let back = target.items.firstIndex(where: {
                    $0.planID == item.planID
                }) else { return }
                target.items.remove(at: back)
                target.reloadReviewKeepingArt()
            }
        }
        reviewUndoManager.setActionName("Remove Game")

        reloadReviewKeepingArt()
        resolveArt(for: [item])
    }

    private func reloadReviewKeepingArt() {
        reviewTable.reloadData()
        repushCachedArt()
        refreshActionBar()
        setState(items.isEmpty ? .empty : .review)
    }

    @objc private func ctxRemove(_ sender: NSMenuItem) {
        removeRow(sender.tag)
    }

    private func removeItem(withPlanID id: UUID) {
        guard let row = items.firstIndex(where: { $0.planID == id }) else { return }
        removeRow(row)
    }

    @objc private func removeSelected() {
        removeRow(reviewTable.selectedRow)
    }

}

// MARK: - Review table data source / delegate

extension ImportViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]

        let id = GameReviewCell.reuseID(for: rowHeight)
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? GameReviewCell)
            ?? GameReviewCell(identifier: id, rowHeight: rowHeight)
        let cachedImage = item.mainAppID.flatMap { art.image(for: $0) }
        let cachedName = item.mainAppID.flatMap { art.name(for: $0) }
        cell.configure(
            appID: item.mainAppID,
            title: item.title,
            summary: item.summary,
            importable: item.isImportable,
            cachedName: cachedName,
            cachedImage: cachedImage)
        let planID = item.planID
        cell.onRemove = { [weak self] in self?.removeItem(withPlanID: planID) }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row >= 0 && row < items.count
    }

}

// MARK: - Row context menu

extension ImportViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = reviewTable.clickedRow
        if row >= 0, row < items.count {
            let remove = NSMenuItem(title: "Remove",
                                    action: #selector(ctxRemove(_:)), keyEquivalent: "")
            remove.tag = row
            remove.target = self
            menu.addItem(remove)
            menu.addItem(.separator())
        }
        let match = NSMenuItem(title: "Use This Size in the Apps List",
                               action: #selector(useSizeInApps), keyEquivalent: "")
        match.target = self
        menu.addItem(match)
    }
}
