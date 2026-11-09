// Main split view controller
import AppKit

final class MainViewController: NSSplitViewController {
    let store: ConfigStore

    private var sidebarVC: SidebarViewController!
    private var detailContainerVC: NSViewController!
    private var importVC: ImportViewController!
    private var gamesVC: GamesViewController!
    private var fixesVC: FixesViewController!
    private var cloudSavesVC: CloudSavesViewController!
    private var configVC: ConfigViewController!
    private var installVC: InstallViewController!

    private let titleLabel: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular), weight: .semibold)
        field.textColor = .labelColor
        field.alignment = .natural
        return field
    }()

    enum Item: Equatable {
        case install
        case importZip
        case store
        case fixes
        case cloudSaves
        case config(ConfigViewController.Section)
    }

    private var activeItem: Item?

    init(store: ConfigStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        importVC = ImportViewController(store: store, onConfigChanged: { [weak self] in
            self?.configVC.reloadFromStore()
        })
        gamesVC = GamesViewController(store: store, onConfigChanged: { [weak self] in
            self?.configVC.reloadFromStore()
            self?.gamesVC.reloadFromStore()
        })
        fixesVC = FixesViewController(store: store, onConfigChanged: { [weak self] in
            self?.configVC.reloadFromStore()
            self?.fixesVC.refreshAfterInstall()
        })
        cloudSavesVC = CloudSavesViewController(store: store)
        configVC = ConfigViewController(store: store)
        installVC = InstallViewController()

        detailContainerVC = NSViewController()
        detailContainerVC.view = NSView()
        detailContainerVC.addChild(installVC)
        detailContainerVC.addChild(importVC)
        detailContainerVC.addChild(gamesVC)
        detailContainerVC.addChild(fixesVC)
        detailContainerVC.addChild(cloudSavesVC)
        detailContainerVC.addChild(configVC)

        sidebarVC = SidebarViewController(onSelect: { [weak self] item in
            self?.show(item)
        })

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 240
        sidebarItem.canCollapse = false

        let detailItem = NSSplitViewItem(viewController: detailContainerVC)
        detailItem.minimumThickness = 420

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)

        super.loadView()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.delegate = self
        sidebarVC.selectDefault()
    }

    // MARK: - Detail routing

    private func show(_ item: Item) {
        activeItem = item
        let child: NSViewController
        let title: String
        switch item {
        case .install:
            child = installVC
            title = "Install"
        case .importZip:
            child = importVC
            title = "Import Apps"
        case .store:
            child = gamesVC
            title = "Store"
        case .fixes:
            child = fixesVC
            title = "Fixes"
        case .cloudSaves:
            child = cloudSavesVC
            title = "Cloud Saves"
        case .config(let section):
            configVC.select(section: section)
            child = configVC
            title = section.title
        }
        titleLabel.stringValue = title
        swapDetail(to: child.view)
    }

    private func swapDetail(to newView: NSView) {
        let host = detailContainerVC.view
        guard newView.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        newView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(newView)
        NSLayoutConstraint.activate([
            newView.topAnchor.constraint(equalTo: host.topAnchor),
            newView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            newView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            newView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    // MARK: - Menu / toolbar actions (routed via first responder / nil target)

    @objc func importZip() {
        sidebarVC.select(.importZip)
        importVC.pickZip()
    }

    func reloadAfterExternalConfigChange() {
        guard isViewLoaded else { return }
        configVC.reloadFromStore()
        gamesVC.reloadFromStore()
    }
}

// MARK: - Window

extension MainViewController: NSWindowDelegate {
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        activeItem == .importZip ? importVC.reviewUndoManager : nil
    }
}

// MARK: - Toolbar

extension MainViewController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .sectionTitle]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == .sectionTitle else { return nil }
        let item = NSToolbarItem(itemIdentifier: .sectionTitle)
        item.view = titleLabel
        return item
    }
}

private extension NSToolbarItem.Identifier {
    static let sectionTitle = NSToolbarItem.Identifier("sectionTitle")
}
