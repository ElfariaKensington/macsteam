// Mac-friendly editor for config.yaml.

import AppKit
import Combine

final class ConfigViewController: NSViewController {
    let store: ConfigStore

    private var detailContainer: NSView!
    private var currentSection: Section = .settings

    var hideWhatsNewSwitch: NSSwitch!
    private var hideCloudErrorsSwitch: NSSwitch!
    private var providerPopup: NSPopUpButton?
    private var luaToolsAccountLabel: NSTextField?
    private var luaToolsButton: NSButton?
    private var luaToolsBusy = false
    private var checkUpdateButton: NSButton?
    private var autoUpdateSwitch: NSSwitch?
    private var updaterSub: AnyCancellable?

    private var appsCardList: AppCardListView?

    enum Section: String, CaseIterable {
        case settings = "macSteam Settings"
        case apps = "Apps"

        var symbol: String {
            switch self {
            case .settings:  return "gearshape"
            case .apps:      return "app.badge"
            }
        }

        var title: String { rawValue }
    }

    init(store: ConfigStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - View

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 520))
        root.translatesAutoresizingMaskIntoConstraints = false
        detailContainer = root
        view = root
        showDetail(for: currentSection)
    }

    func select(section: Section) {
        _ = view   // force loadView() if the pane has never been shown
        showDetail(for: section)
    }

    func reloadFromStore() {
        if isViewLoaded {
            showDetail(for: currentSection)
        }
    }

    private func persisting(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            NSSound.beep()
            presentAlert("Couldn’t save config", error.localizedDescription, style: .warning)
        }
    }

    private func confirmDestructive(_ message: String, informative: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")     // .alertFirstButtonReturn
        alert.addButton(withTitle: "Cancel")     // .alertSecondButtonReturn
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Detail routing

    private func showDetail(for section: Section) {
        currentSection = section
        appsCardList = nil

        detailContainer.subviews.forEach { $0.removeFromSuperview() }

        let content: NSView
        switch section {
        case .settings:  content = buildSettingsDetail()
        case .apps:      content = buildAppsDetail()
        }
        content.translatesAutoresizingMaskIntoConstraints = false

        detailContainer.addSubview(content)
        let m = Metrics.paneMargin
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: m),
            content.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: m),
            content.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -m),
            content.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor, constant: -m),
        ])
    }

    private func buildSettingsDetail() -> NSView {
        hideWhatsNewSwitch = NSSwitch()
        hideWhatsNewSwitch.state = store.config.hideWhatsNew ? .on : .off
        hideWhatsNewSwitch.target = self
        hideWhatsNewSwitch.action = #selector(settingsChanged)
        hideWhatsNewSwitch.setAccessibilityLabel("Hide What's New shelf")

        hideCloudErrorsSwitch = NSSwitch()
        hideCloudErrorsSwitch.state = store.config.hideCloudErrors ? .on : .off
        hideCloudErrorsSwitch.target = self
        hideCloudErrorsSwitch.action = #selector(cloudErrorsChanged)
        hideCloudErrorsSwitch.setAccessibilityLabel("Hide Steam Cloud errors")

        let togglesCard = SettingsCard(rows: [
            SettingRow(title: "Hide What's New shelf",
                       subtitle: nil,
                       control: hideWhatsNewSwitch),
            SettingRow(title: "Hide Steam Cloud errors",
                       subtitle: "Hide error indicators and notifications; skip launch warnings. Cloud sync stays on. Restart Steam to apply.",
                       control: hideCloudErrorsSwitch),
        ])

        let generalHeader = settingsGroupLabel("General")

        // Updates section
        let updater = UpdaterManager.shared

        let btn = NSButton(title: "Check for Updates…", target: self,
                           action: #selector(checkForUpdatesTapped))
        btn.bezelStyle = .rounded
        btn.controlSize = .regular
        btn.isEnabled = updater.canCheckForUpdates
        checkUpdateButton = btn

        let autoSwitch = NSSwitch()
        autoSwitch.state = updater.automaticallyChecksForUpdates ? .on : .off
        autoSwitch.target = self
        autoSwitch.action = #selector(autoUpdateChanged)
        autoSwitch.setAccessibilityLabel("Automatically check for updates")
        autoUpdateSwitch = autoSwitch

        let updatesCard = SettingsCard(rows: [
            SettingRow(title: "Automatically check for updates",
                       subtitle: nil,
                       control: autoSwitch),
            SettingRow(title: "Check for Updates",
                       subtitle: nil,
                       control: btn),
        ])

        let updatesHeader = settingsGroupLabel("Updates")

        updaterSub = updater.$canCheckForUpdates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] can in self?.checkUpdateButton?.isEnabled = can }

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: LuaProvider.allCases.map(\.title))
        popup.selectItem(at: LuaProvider.allCases.firstIndex(of: LuaProvider.current) ?? 0)
        popup.target = self
        popup.action = #selector(providerChanged)
        popup.setAccessibilityLabel("Lua source provider")
        providerPopup = popup

        let accountLabel = NSTextField(labelWithString: "Not signed in")
        accountLabel.font = Typography.caption
        accountLabel.textColor = Colors.secondaryText
        accountLabel.lineBreakMode = .byTruncatingTail
        accountLabel.translatesAutoresizingMaskIntoConstraints = false
        accountLabel.widthAnchor.constraint(equalToConstant: 130).isActive = true
        luaToolsAccountLabel = accountLabel
        let signInButton = makeButton(title: "Sign in with Discord", target: self,
                                      action: #selector(toggleLuaTools))
        luaToolsButton = signInButton
        let luaToolsControls = NSStackView(views: [accountLabel, signInButton])
        luaToolsControls.orientation = .horizontal
        luaToolsControls.spacing = 8
        luaToolsControls.alignment = .centerY

        let sourceCard = SettingsCard(rows: [
            SettingRow(title: "Lua source",
                       subtitle: "Where the Steam store button gets Lua and manifests. "
                           + "Applies immediately. Hubcap uses the API key from the Hubcap tab.",
                       control: popup),
            SettingRow(title: "LuaTools / Discord",
                       subtitle: "Required when LuaTools is the Lua source.",
                       control: luaToolsControls),
        ])
        let sourceHeader = settingsGroupLabel("Lua source")
        refreshLuaToolsAuth()

        let stack = NSStackView(views: [sourceHeader, sourceCard, generalHeader, togglesCard,
                                        updatesHeader, updatesCard])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(6, after: sourceHeader)
        stack.setCustomSpacing(20, after: sourceCard)
        stack.setCustomSpacing(6, after: generalHeader)
        stack.setCustomSpacing(20, after: togglesCard)
        stack.setCustomSpacing(6, after: updatesHeader)
        stack.translatesAutoresizingMaskIntoConstraints = false
        sourceCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        togglesCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        updatesCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        let m = Metrics.paneMargin
        let maxWidth = stack.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.formColumnWidth)
        let wantWidth = stack.widthAnchor.constraint(equalToConstant: Metrics.formColumnWidth)
        wantWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: m),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -m),
            maxWidth,
            wantWidth,
        ])
        return root
    }

    @objc private func providerChanged() {
        LuaProvider.current = LuaProvider.allCases[providerPopup?.indexOfSelectedItem ?? 0]
    }

    @objc private func toggleLuaTools() {
        guard !luaToolsBusy else { return }
        luaToolsBusy = true
        luaToolsButton?.isEnabled = false
        luaToolsButton?.title = "Waiting for Discord…"
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.luaToolsBusy = false
                self.luaToolsButton?.isEnabled = true
                self.refreshLuaToolsAuth()
            }
            if await LuaToolsAuth.shared.isSignedIn() {
                await LuaToolsAuth.shared.signOut()
                return
            }
            do {
                _ = try await LuaToolsAuth.shared.signIn()
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                presentAlert("Couldn’t sign in with Discord",
                             error.localizedDescription, style: .warning)
            }
        }
    }

    private func refreshLuaToolsAuth() {
        Task { [weak self] in
            guard let self else { return }
            let signedIn = await LuaToolsAuth.shared.isSignedIn()
            let label = await LuaToolsAuth.shared.accountLabel()
            self.luaToolsAccountLabel?.stringValue =
                label.map { "Signed in as \($0)" } ?? "Not signed in"
            self.luaToolsButton?.title = signedIn ? "Sign out" : "Sign in with Discord"
        }
    }

    @objc private func settingsChanged() {
        persisting { try store.setHideWhatsNew(hideWhatsNewSwitch.state == .on) }
    }

    @objc private func cloudErrorsChanged() {
        persisting { try store.setHideCloudErrors(hideCloudErrorsSwitch.state == .on) }
    }

    @objc private func checkForUpdatesTapped() {
        UpdaterManager.shared.checkForUpdates()
    }

    @objc private func autoUpdateChanged() {
        UpdaterManager.shared.automaticallyChecksForUpdates = (autoUpdateSwitch?.state == .on)
    }

    // MARK: Apps detail (Steam game cards)

    private func buildAppsDetail() -> NSView {
        let list = AppCardListView(store: store)
        list.performRemoval = { [weak self] ids in
            guard let self else { return false }
            var ok = true
            self.persisting {
                do { try self.store.removeApps(ids) }
                catch { ok = false; throw error }
            }
            return ok
        }
        list.confirmRemoval = { [weak self, weak list] removed in
            guard let self, let list else { return true }
            let baseGames = removed.filter { list.dlcCount(for: $0) > 0 }
            if let game = baseGames.first, removed.count > 1 {
                let n = list.dlcCount(for: game)
                return self.confirmDestructive(
                    "Remove \(list.displayName(for: game)) and its \(n) DLC?",
                    informative: "This removes the game and its DLC from the macSteam "
                        + "configuration. macSteam will no longer unlock the title.")
            }
            let names = ListFormatter.localizedString(
                byJoining: removed.map { list.displayName(for: $0) })
            let titleNoun = removed.count > 1 ? "these titles" : "the title"
            return self.confirmDestructive(
                "Remove \(names)?",
                informative: "This removes \(names) from the macSteam configuration. "
                    + "macSteam will no longer unlock \(titleNoun).")
        }
        appsCardList = list
        return list.listView
    }

}
