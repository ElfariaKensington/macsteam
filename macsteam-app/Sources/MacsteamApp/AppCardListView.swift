// Apps-pane game list
import AppKit

// Reference types so NSOutlineView can key item lookup off object identity.
@MainActor
final class AppNode: NSObject {
    let appID: Int
    var dlc: [DLCNode]
    init(appID: Int, dlc: [DLCNode] = []) { self.appID = appID; self.dlc = dlc }
}

@MainActor
final class DLCNode: NSObject {
    let appID: Int
    init(appID: Int) { self.appID = appID }
}

@MainActor
final class AppCardListView: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let listView: NSView

    private let outline = DeletingOutlineView()
    private let store: ConfigStore

    private var appIDs: [Int] { store.config.apps }
    private var nodes: [AppNode] = []

    private let art = StoreArtLoader()

    private var emptyState: EmptyStateView!

    private static let minRowHeight: CGFloat = 48
    private static let maxRowHeight: CGFloat = 160
    // 90 lands on the 4th of 9 ticks (48...160, 14 apart), the native "return to default".
    private static let defaultRowHeight: CGFloat = 90
    private static let snapDistance: CGFloat = 3
    private static let artInset: CGFloat = 8
    private static let artAspect: CGFloat = 460.0 / 215.0
    static let rowHeightDefaultsKey = "AppsRowHeight"

    // Import can push its size here; a live view already read the default at init, so
    // this notification lets it re-read now instead of at relaunch.
    static let rowHeightChanged = Notification.Name("AppsRowHeightChanged")

    private var rowHeight: CGFloat = AppCardListView.defaultRowHeight
    private var artHeight: CGFloat { rowHeight - 2 * Self.artInset }
    private var artWidth: CGFloat { (artHeight * Self.artAspect).rounded() }
    // Decode at 2x the max width so resizing up never blurs.
    private static var decodeWidth: CGFloat {
        ((maxRowHeight - 2 * artInset) * artAspect * 2).rounded()
    }

    private static let cellID = NSUserInterfaceItemIdentifier("AppRowCell")

    var performRemoval: ((_ ids: [Int]) -> Bool)?
    var confirmRemoval: ((_ removed: [Int]) -> Bool)?

    private let sizeSlider = ResettableSlider()

    deinit { NotificationCenter.default.removeObserver(self) }

    init(store: ConfigStore) {
        self.store = store
        self.rowHeight = Self.loadRowHeight()

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        outline.headerView = nil
        outline.rowHeight = rowHeight
        outline.rowSizeStyle = .custom
        outline.style = .inset
        outline.selectionHighlightStyle = .regular
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.usesAutomaticRowHeights = false
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 6
        outline.autoresizesOutlineColumn = false
        let col = NSTableColumn(identifier: .init("app"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        scroll.documentView = outline

        let list = NSView()
        list.translatesAutoresizingMaskIntoConstraints = false

        emptyState = EmptyStateView(symbol: "square.stack.3d.up",
                                    prompt: "No games yet",
                                    hint: "Import a game to add it.")
        emptyState.isHidden = !store.config.apps.isEmpty

        let sizeBar = makeSizeSliderBar(
            slider: sizeSlider,
            min: Self.minRowHeight, max: Self.maxRowHeight,
            defaultValue: Self.defaultRowHeight,
            currentValue: rowHeight,
            accessibilityLabel: "Game row size",
            smallGlyphSize: 12, largeGlyphSize: 18)

        let footerDivider = NSBox()
        footerDivider.boxType = .separator
        footerDivider.translatesAutoresizingMaskIntoConstraints = false

        list.addSubview(scroll)
        list.addSubview(footerDivider)
        list.addSubview(sizeBar)
        list.addSubview(emptyState)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: list.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),

            footerDivider.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: sizeBar.topAnchor, constant: -8),

            sizeBar.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            sizeBar.trailingAnchor.constraint(lessThanOrEqualTo: list.trailingAnchor),
            sizeBar.bottomAnchor.constraint(equalTo: list.bottomAnchor),

            emptyState.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])

        self.listView = list
        super.init()

        sizeSlider.target = self
        sizeSlider.action = #selector(sizeSliderChanged)

        NotificationCenter.default.addObserver(
            self, selector: #selector(externalRowHeightChanged),
            name: Self.rowHeightChanged, object: nil)

        outline.dataSource = self
        outline.delegate = self
        outline.doubleAction = nil
        outline.onDeleteKey = { [weak self] in self?.removeSelected() }
        outline.menu = makeContextMenu()

        reloadTree()
        resolveAll()
    }

    // MARK: - row size

    @objc private func sizeSliderChanged() {
        let h = sizeSlider.snappedValue(min: Self.minRowHeight, max: Self.maxRowHeight,
                                        snapDistance: Self.snapDistance)
        guard h != rowHeight else { return }
        rowHeight = h
        applyRowHeight()
    }

    // Import already wrote the new value to defaults, so adopt it directly (no persist).
    @objc private func externalRowHeightChanged() {
        let h = Self.loadRowHeight()
        guard h != rowHeight else { return }
        rowHeight = h
        sizeSlider.doubleValue = Double(h)
        outline.rowHeight = h
        let expanded = expandedAppIDs()
        outline.reloadData()
        for node in nodes where expanded.contains(node.appID) { outline.expandItem(node) }
    }

    private func applyRowHeight() {
        outline.rowHeight = rowHeight
        let expanded = expandedAppIDs()
        outline.reloadData()
        for node in nodes where expanded.contains(node.appID) { outline.expandItem(node) }
        UserDefaults.standard.set(Double(rowHeight), forKey: Self.rowHeightDefaultsKey)
    }

    private static func loadRowHeight() -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: rowHeightDefaultsKey)
        guard stored > 0 else { return defaultRowHeight }
        return min(max(CGFloat(stored), minRowHeight), maxRowHeight)
    }

    private func updateEmptyState() { emptyState.isHidden = !appIDs.isEmpty }

    private func reloadTree() {
        let expanded = expandedAppIDs()
        rebuildTree()
        outline.reloadData()
        for node in nodes where expanded.contains(node.appID) {
            outline.expandItem(node)
        }
        updateEmptyState()
    }

    private func expandedAppIDs() -> Set<Int> {
        var ids = Set<Int>()
        for node in nodes where outline.isItemExpanded(node) { ids.insert(node.appID) }
        return ids
    }

    // MARK: - public

    func refresh() {
        reloadTree()
        resolveAll()
    }

    // MARK: - tree model

    // A DLC nests only when its parent is also listed; an orphan stays top-level and
    // removable. List order preserved so the main app stays first.
    private func rebuildTree() {
        var nodeByID: [Int: AppNode] = [:]
        var order: [AppNode] = []

        for id in appIDs where !isNestableDLC(id) {
            let node = AppNode(appID: id)
            nodeByID[id] = node
            order.append(node)
        }
        for id in appIDs where isNestableDLC(id) {
            let parent = store.config.appParents[id]
            if let parent, let node = nodeByID[parent] {
                node.dlc.append(DLCNode(appID: id))
            } else {
                let node = AppNode(appID: id)
                nodeByID[id] = node
                order.append(node)
            }
        }
        nodes = order
    }

    private func isNestableDLC(_ id: Int) -> Bool {
        guard let parent = store.config.appParents[id] else { return false }
        return appIDs.contains(parent)
    }

    // MARK: - store resolution

    private func resolveAll() {
        art.load(appIDs, artWidth: Self.decodeWidth,
                 onName: { [weak self] id, _ in
                     guard let self else { return }
                     self.applyToRows(appID: id) { $0.setName(self.displayName(for: id)) }
                 },
                 onArt: { [weak self] id, image in
                     self?.applyToRows(appID: id) { $0.setArt(image) }
                 })
    }

    private func applyToRows(appID: Int, _ apply: (AppRowCell) -> Void) {
        for row in 0..<outline.numberOfRows {
            guard rowAppID(row) == appID,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? AppRowCell
            else { continue }
            apply(cell)
        }
    }

    private func rowAppID(_ row: Int) -> Int? {
        switch outline.item(atRow: row) {
        case let n as AppNode: return n.appID
        case let d as DLCNode: return d.appID
        default: return nil
        }
    }

    // MARK: - remove

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    // A base game takes its nested DLC with it; a DLC row goes alone. Selection can mix
    // both. The store owns the change (removeApps drops each app's depot-key group).
    private func removeSelected() {
        let rows = targetRows()
        guard !rows.isEmpty else { NSSound.beep(); return }

        var removed = Set<Int>()
        for row in rows {
            switch outline.item(atRow: row) {
            case let node as AppNode:
                removed.insert(node.appID)
                for child in node.dlc { removed.insert(child.appID) }
            case let child as DLCNode:
                removed.insert(child.appID)
            default:
                break
            }
        }
        guard !removed.isEmpty else { NSSound.beep(); return }

        let removedList = appIDs.filter { removed.contains($0) }
        if let gate = confirmRemoval, !gate(removedList) { return }

        guard performRemoval?(removedList) ?? false else { return }
        reloadTree()
    }

    // Clicked row when the right-click is outside the selection, else the whole
    // selection (Finder behavior).
    private func targetRows() -> [Int] {
        let clicked = outline.clickedRow
        let selected = outline.selectedRowIndexes
        if clicked >= 0 && !selected.contains(clicked) { return [clicked] }
        return selected.sorted()
    }

    @objc private func configureOnlineFix(_ sender: NSMenuItem) {
        let id = sender.tag
        let options = store.config.onlineFixGames[id] ?? OnlineFixOptions()
        let alert = NSAlert()
        alert.messageText = "OnlineFix — \(displayName(for: id))"
        alert.informativeText = "Routes this game's Steam session through AppID 480. Changes apply on the next game launch. Only one routed game can run at a time."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let labels = ["Enable OnlineFix", "Keep real AppID", "Restore AppID at startup",
                      "Restore overlay AppID", "Restore controller AppID", "Restore stats AppID"]
        let values = [store.config.onlineFixGames[id] != nil, options.keepRealAppID,
                      options.startupAppID, options.overlayAppID, options.inputAppID, options.statsAppID]
        let controls = zip(labels, values).map { label, value in
            let button = NSButton(checkboxWithTitle: label, target: nil, action: nil)
            button.state = value ? .on : .off
            return button
        }
        let stack = NSStackView(views: controls)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.mutate { config in
                config.onlineFixGames[id] = controls[0].state == .on ? OnlineFixOptions(
                    keepRealAppID: controls[1].state == .on,
                    startupAppID: controls[2].state == .on,
                    overlayAppID: controls[3].state == .on,
                    inputAppID: controls[4].state == .on,
                    statsAppID: controls[5].state == .on) : nil
            }
        } catch {
            let failure = NSAlert()
            failure.messageText = "Couldn’t save OnlineFix settings"
            failure.informativeText = error.localizedDescription
            failure.runModal()
        }
    }

    @objc private func removeMenuItem() { removeSelected() }

    // MARK: - naming

    // Store name, then persisted lua name, then bare id, so unresolved ids still read.
    func displayName(for appID: Int) -> String {
        if let n = art.name(for: appID) { return n }
        if let n = store.config.appNames[appID], !n.isEmpty { return n }
        return "App \(appID)"
    }

    // DLC count nested under a base game, for the removal confirmation copy.
    func dlcCount(for appID: Int) -> Int {
        nodes.first { $0.appID == appID }?.dlc.count ?? 0
    }

    // MARK: - NSOutlineView data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return nodes.count }
        if let node = item as? AppNode { return node.dlc.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return nodes[index] }
        let node = item as! AppNode
        return node.dlc[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let node = item as? AppNode { return !node.dlc.isEmpty }
        return false
    }

    // MARK: - NSOutlineView delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let artSize = NSSize(width: artWidth, height: artHeight)
        let cell = (outlineView.makeView(withIdentifier: Self.cellID, owner: self) as? AppRowCell)
            ?? AppRowCell(identifier: Self.cellID, artSize: artSize)
        // A recycled cell was built at the previous size; resize so a slider drag
        // doesn't leave stale art dimensions.
        cell.setArtSize(artSize)

        if let node = item as? AppNode {
            cell.configure(name: displayName(for: node.appID), appID: node.appID,
                           art: art.image(for: node.appID), isDLC: false)
        } else if let child = item as? DLCNode {
            cell.configure(name: displayName(for: child.appID), appID: child.appID,
                           art: art.image(for: child.appID), isDLC: true)
        }
        return cell
    }
}

// MARK: - Context menu

extension AppCardListView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let rows = targetRows()
        guard !rows.isEmpty else { return }

        if rows.count == 1, let node = outline.item(atRow: rows[0]) as? AppNode,
           (1...0xffffff).contains(node.appID), node.appID != 480 {
            let onlineFix = NSMenuItem(title: "OnlineFix…", action: #selector(configureOnlineFix(_:)), keyEquivalent: "")
            onlineFix.target = self
            onlineFix.tag = node.appID
            menu.addItem(onlineFix)
            menu.addItem(.separator())
        }

        let title = removeMenuTitle(for: rows)
        let item = NSMenuItem(title: title, action: #selector(removeMenuItem), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func removeMenuTitle(for rows: [Int]) -> String {
        if rows.count == 1, case let node as AppNode = outline.item(atRow: rows[0]) {
            let n = node.dlc.count
            if n > 0 { return "Remove \(displayName(for: node.appID)) and \(n) DLC" }
            return "Remove \(displayName(for: node.appID))"
        }
        if rows.count == 1, case let child as DLCNode = outline.item(atRow: rows[0]) {
            return "Remove \(displayName(for: child.appID))"
        }
        return "Remove \(rows.count) Items"
    }
}

// NSOutlineView beeps on Delete; this turns it into a removal.
@MainActor
final class DeletingOutlineView: NSOutlineView {
    var onDeleteKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if deleteKeyCodes.contains(event.keyCode) { onDeleteKey?(); return }
        super.keyDown(with: event)
    }

    // File > Remove (Cmd-Delete) routes here via the responder chain (target=nil).
    @objc func removeApps(_ sender: Any?) {
        onDeleteKey?()
    }

    // Grey out when nothing is selected. NSMenuValidation is informal, so not an override.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(removeApps(_:)) {
            return selectedRow >= 0
        }
        return true
    }
}

@MainActor
final class AppRowCell: NSTableCellView {
    private let art = NSImageView()
    private let placeholder = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    // Held so the row can be resized (via the size slider) after construction.
    private var artWidthConstraint: NSLayoutConstraint!
    private var artHeightConstraint: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier, artSize: NSSize) {
        super.init(frame: .zero)
        self.identifier = identifier
        build(artSize: artSize)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build(artSize: NSSize) {
        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true
        art.layer?.cornerRadius = 6
        art.layer?.masksToBounds = true
        art.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        art.translatesAutoresizingMaskIntoConstraints = false

        placeholder.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        placeholder.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        placeholder.contentTintColor = Colors.quiet
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(art)
        addSubview(placeholder)
        addSubview(nameLabel)

        artWidthConstraint = art.widthAnchor.constraint(equalToConstant: artSize.width)
        artHeightConstraint = art.heightAnchor.constraint(equalToConstant: artSize.height)

        NSLayoutConstraint.activate([
            art.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            art.centerYAnchor.constraint(equalTo: centerYAnchor),
            artWidthConstraint,
            artHeightConstraint,

            placeholder.centerXAnchor.constraint(equalTo: art.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: art.centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 14),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    func setArtSize(_ size: NSSize) {
        guard artWidthConstraint.constant != size.width
            || artHeightConstraint.constant != size.height else { return }
        artWidthConstraint.constant = size.width
        artHeightConstraint.constant = size.height
    }

    func configure(name: String, appID: Int, art image: NSImage?, isDLC: Bool) {
        nameLabel.stringValue = name.isEmpty ? "App \(appID)" : name
        nameLabel.font = .systemFont(ofSize: 14, weight: isDLC ? .regular : .semibold)

        setArt(image)
    }

    func setName(_ name: String) {
        if !name.isEmpty { nameLabel.stringValue = name }
    }

    func setArt(_ image: NSImage?) {
        art.image = image
        placeholder.isHidden = (image != nil)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        art.image = nil
        placeholder.isHidden = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { [weak self] in
            self?.art.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }
    }
}
