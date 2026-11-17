// Reads Steam's achievement schema and builds the right-click picker.
import AppKit

struct AchievementDefinition: Equatable, Identifiable {
    let id: String
    let statID: UInt32
    let bit: Int
    let name: String
    let detail: String
    let hidden: Bool
    let permission: Int
}

enum AchievementCatalogError: LocalizedError {
    case schemaMissing
    case schemaUnreadable
    case noAchievements

    var errorDescription: String? {
        switch self {
        case .schemaMissing:
            return "Steam has not saved this game's achievement schema yet. "
                + "macSteam tried Steam's own schema source. Restart Steam and try again; "
                + "if it still fails, launch the game once."
        case .schemaUnreadable:
            return "Steam's achievement schema for this game could not be read."
        case .noAchievements:
            return "This game's schema does not define any achievements."
        }
    }
}

enum AchievementCatalog {
    static func schemaURL(appID: Int) -> URL {
        Paths.steamRoot.appendingPathComponent("appcache/stats/UserGameStatsSchema_\(appID).bin")
    }

    static func load(appID: Int) throws -> [AchievementDefinition] {
        guard let data = try? Data(contentsOf: schemaURL(appID: appID)) else {
            throw AchievementCatalogError.schemaMissing
        }
        let root: BKVNode
        do {
            root = try BKV.parse(data)
        } catch {
            throw AchievementCatalogError.schemaUnreadable
        }
        let definitions = parse(root)
        guard !definitions.isEmpty else { throw AchievementCatalogError.noAchievements }
        return definitions
    }

    static func parse(_ root: BKVNode) -> [AchievementDefinition] {
        guard let stats = root.child("stats")?.children else { return [] }
        var definitions: [AchievementDefinition] = []

        for (statName, statNode) in stats {
            guard let statID = UInt32(statName), isAchievementStat(statNode) else { continue }
            var nextBit = 0

            for (childName, childNode) in statNode.children ?? [] {
                guard childName == "bits", let bits = childNode.children else { continue }
                for (bitName, bitNode) in bits {
                    let bit = Int(bitName) ?? nextBit
                    nextBit += 1

                    guard bit < 32,
                          let id = bitNode.child("name")?.stringValue,
                          !id.isEmpty else { continue }

                    let display = bitNode.child("display")
                    let name = localized(display?.child("name")) ?? id
                    let detail = localized(display?.child("desc")) ?? ""
                    let hidden = (display?.child("hidden")?.intValue ?? 0) != 0
                    let permission = Int(bitNode.child("permission")?.intValue ?? 0)

                    definitions.append(AchievementDefinition(
                        id: id,
                        statID: statID,
                        bit: bit,
                        name: name,
                        detail: detail,
                        hidden: hidden,
                        permission: permission))
                }
            }
        }
        return definitions.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func isAchievementStat(_ stat: BKVNode) -> Bool {
        if let type = stat.child("type") {
            if let text = type.stringValue {
                return text.caseInsensitiveCompare("ACHIEVEMENTS") == .orderedSame ||
                    text.caseInsensitiveCompare("GROUPACHIEVEMENTS") == .orderedSame
            }
            if let raw = type.intValue {
                return raw == 4 || raw == 5
            }
        }
        if let raw = stat.child("type_int")?.intValue {
            return raw == 4 || raw == 5
        }
        return false
    }

    private static func localized(_ node: BKVNode?) -> String? {
        guard let node else { return nil }
        if let value = node.stringValue, !value.isEmpty { return value }
        if let value = node.child("english")?.stringValue, !value.isEmpty { return value }
        if let value = node.child("token")?.stringValue, !value.isEmpty { return value }
        return nil
    }
}

@MainActor
final class AchievementRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("macsteam-achievement-row")

    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        checkbox.controlSize = .regular

        titleLabel.font = Typography.body
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        detailLabel.font = Typography.caption
        detailLabel.textColor = Colors.secondaryText
        detailLabel.alignment = .left
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1

        addSubview(checkbox)
        addSubview(titleLabel)
        addSubview(detailLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()

        let checkboxSize: CGFloat = 20
        checkbox.frame = NSRect(x: 6,
                                y: (bounds.height - checkboxSize) / 2,
                                width: checkboxSize,
                                height: checkboxSize)

        let textX = checkbox.frame.maxX + 8
        let textWidth = max(0, bounds.width - textX - 6)
        if detailLabel.isHidden {
            titleLabel.frame = NSRect(x: textX,
                                      y: (bounds.height - 18) / 2,
                                      width: textWidth,
                                      height: 18)
        } else {
            titleLabel.frame = NSRect(x: textX,
                                      y: bounds.height - 7 - 18,
                                      width: textWidth,
                                      height: 18)
            detailLabel.frame = NSRect(x: textX,
                                       y: 5,
                                       width: textWidth,
                                       height: 16)
        }
    }

    func configure(definition: AchievementDefinition, selected: Bool, tag: Int,
                   target: AnyObject, action: Selector) {
        checkbox.state = selected ? .on : .off
        checkbox.tag = tag
        checkbox.target = target
        checkbox.action = action
        checkbox.setAccessibilityLabel(definition.name)
        checkbox.setAccessibilityHelp(definition.detail)

        titleLabel.stringValue = definition.name
        var detail = definition.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if definition.hidden {
            detail = detail.isEmpty ? "Hidden achievement" : detail + "  ·  Hidden achievement"
        }
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
        needsLayout = true
        toolTip = detail.isEmpty ? definition.name : definition.name + "\n" + detail
    }
}

/// The accessory view used by the Achievements context-menu dialog.
/// AppKit can batch precise (trackpad) scroll events inside NSAlert's modal loop,
/// which makes the achievement list jump instead of tracking the gesture. Wheel
/// events keep the native path; trackpad deltas are applied directly per event.
final class AchievementScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, let documentView else {
            super.scrollWheel(with: event)
            return
        }
        let clip = contentView
        let maxY = max(0, documentView.frame.height - clip.bounds.height)
        var origin = clip.bounds.origin
        origin.y = min(max(origin.y - event.scrollingDeltaY, 0), maxY)
        clip.scroll(to: origin)
        reflectScrolledClipView(clip)
    }
}

@MainActor
final class AchievementPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view: NSView

    private let definitions: [AchievementDefinition]
    private var selected: Set<String>
    private let countLabel = NSTextField(labelWithString: "")
    private let uploadCheckbox = NSButton(
        checkboxWithTitle: "Sync selection to Steam profile (owned games only)",
        target: nil, action: nil)
    private let tableView = NSTableView()

    init(definitions: [AchievementDefinition], selected: Set<String>) {
        self.definitions = definitions
        self.selected = selected
        view = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 392))
        super.init()

        let listBackground = NSColor.controlBackgroundColor
        let scroll = AchievementScrollView(frame: NSRect(x: 0, y: 24, width: 470, height: 340))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = listBackground
        scroll.contentView.drawsBackground = true
        scroll.contentView.backgroundColor = listBackground
        scroll.scrollerStyle = .overlay
        scroll.wantsLayer = true

        tableView.headerView = nil
        tableView.rowHeight = 46
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = listBackground
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.usesAutomaticRowHeights = false
        tableView.style = .plain
        tableView.wantsLayer = true
        tableView.dataSource = self
        tableView.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("achievement"))
        column.width = 450
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.frame = NSRect(x: 0, y: 0, width: 450,
                                 height: max(CGFloat(definitions.count) * 46, 340))
        tableView.autoresizingMask = [.width]
        scroll.documentView = tableView
        tableView.reloadData()

        let selectAll = NSButton(title: "Select All", target: self, action: #selector(selectAll))
        selectAll.bezelStyle = .rounded
        selectAll.controlSize = .small
        selectAll.frame = NSRect(x: 0, y: 364, width: 84, height: 24)

        let selectNone = NSButton(title: "Select None", target: self, action: #selector(selectNone))
        selectNone.bezelStyle = .rounded
        selectNone.controlSize = .small
        selectNone.frame = NSRect(x: 88, y: 364, width: 92, height: 24)

        countLabel.frame = NSRect(x: 190, y: 368, width: 280, height: 18)
        countLabel.alignment = .right
        countLabel.font = Typography.caption
        countLabel.textColor = Colors.secondaryText

        uploadCheckbox.frame = NSRect(x: 2, y: 2, width: 456, height: 18)
        uploadCheckbox.font = Typography.caption
        uploadCheckbox.toolTip = "Sets the selected achievements on your Steam account and locks "
            + "the ones you leave unselected. Only games you own can be published."

        view.addSubview(scroll)
        view.addSubview(uploadCheckbox)
        view.addSubview(selectAll)
        view.addSubview(selectNone)
        view.addSubview(countLabel)
        updateCount()
    }

    var selectedIDs: [String] {
        definitions.filter { selected.contains($0.id) }.map(\.id)
    }

    var uploadToProfile: Bool {
        uploadCheckbox.state == .on
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        definitions.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: AchievementRowCell.identifier, owner: self)
            as? AchievementRowCell ?? AchievementRowCell(frame: .zero)
        cell.identifier = AchievementRowCell.identifier
        cell.configure(definition: definitions[row],
                       selected: selected.contains(definitions[row].id),
                       tag: row, target: self, action: #selector(toggled(_:)))
        return cell
    }

    @objc private func toggled(_ sender: NSButton) {
        guard definitions.indices.contains(sender.tag) else { return }
        let definition = definitions[sender.tag]
        if sender.state == .on {
            selected.insert(definition.id)
        } else {
            selected.remove(definition.id)
        }
        updateCount()
    }

    @objc private func selectAll() {
        selected = Set(definitions.map(\.id))
        tableView.reloadData()
        updateCount()
    }

    @objc private func selectNone() {
        selected.removeAll()
        tableView.reloadData()
        updateCount()
    }

    private func updateCount() {
        countLabel.stringValue = "\(selected.count) of \(definitions.count) selected"
    }
}
