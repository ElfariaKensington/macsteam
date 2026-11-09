// One Store tab for every Lua source. The picker mirrors Settings → Lua source and
// swaps the content between the LuaTools search and the Hubcap catalog.
import AppKit

final class StoreViewController: NSViewController {
    private let luaToolsVC: GamesViewController
    private let hubcapVC: HubcapViewController
    private let picker = NSSegmentedControl()
    private let content = NSView()
    private var shown: NSViewController?
    private var observer: NSObjectProtocol?

    init(luaTools: GamesViewController, hubcap: HubcapViewController) {
        self.luaToolsVC = luaTools
        self.hubcapVC = hubcap
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        picker.segmentCount = LuaProvider.allCases.count
        for (i, provider) in LuaProvider.allCases.enumerated() {
            picker.setLabel(provider.title, forSegment: i)
        }
        picker.segmentStyle = .rounded
        picker.trackingMode = .selectOne
        picker.target = self
        picker.action = #selector(pickerChanged)
        picker.setAccessibilityLabel("Lua source")
        picker.translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(labelWithString: "Source")
        caption.font = Typography.caption
        caption.textColor = Colors.secondaryText
        caption.translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(caption)
        root.addSubview(picker)
        root.addSubview(content)
        let m = Metrics.paneMargin
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            picker.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            caption.centerYAnchor.constraint(equalTo: picker.centerYAnchor),
            caption.trailingAnchor.constraint(equalTo: picker.leadingAnchor, constant: -8),
            content.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 4),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root

        addChild(luaToolsVC)
        addChild(hubcapVC)
        observer = NotificationCenter.default.addObserver(
            forName: LuaProvider.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncWithProvider() }
        }
        syncWithProvider()
    }

    func reloadFromStore() {
        luaToolsVC.reloadFromStore()
    }

    @objc private func pickerChanged() {
        // The setter posts didChange, which swaps the content.
        LuaProvider.current = LuaProvider.allCases[picker.selectedSegment]
    }

    private func syncWithProvider() {
        let provider = LuaProvider.current
        picker.selectedSegment = LuaProvider.allCases.firstIndex(of: provider) ?? 0
        let next: NSViewController = provider == .luaTools ? luaToolsVC : hubcapVC
        guard next !== shown else { return }
        shown?.view.removeFromSuperview()
        shown = next
        next.view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: content.topAnchor),
            next.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            next.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }
}
