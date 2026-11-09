// Mac-friendly editor for config.yaml.

import AppKit
import Combine

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class ConfigViewController: NSViewController {
    let store: ConfigStore

    private var detailContainer: NSView!
    private var currentSection: Section = .settings

    var hideWhatsNewSwitch: NSSwitch!
    private var notProtonSwitch: NSSwitch!
    private var allowUpdatesSwitch: NSSwitch!
    private var checkUpdateButton: NSButton?
    private var autoUpdateSwitch: NSSwitch?
    private var updaterSub: AnyCancellable?
    private var hubcapKeyField: NSSecureTextField?
    private var luaToolsAccountLabel: NSTextField?
    private var luaToolsButton: NSButton?
    private var luaToolsBusy = false

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

        let togglesCard = SettingsCard(rows: [
            SettingRow(title: "Hide What's New shelf",
                       subtitle: nil,
                       control: hideWhatsNewSwitch),
        ])

        let notProtonSwitch = NSSwitch()
        notProtonSwitch.state = NotProtonMode.isEnabled() ? .on : .off
        notProtonSwitch.target = self
        notProtonSwitch.action = #selector(notProtonModeChanged)
        notProtonSwitch.setAccessibilityLabel("NotProton compatibility mode")
        self.notProtonSwitch = notProtonSwitch

        let compatibilityCard = SettingsCard(rows: [
            SettingRow(
                title: "NotProton Mode",
                subtitle: "Keeps Steam.app as the launcher and loads macSteam next to "
                    + "NotProton. Off uses the macSteam launcher app when NotProton is "
                    + "installed. Applies on the next Install or Update.",
                control: notProtonSwitch),
        ])
        let compatibilityHeader = settingsGroupLabel("Compatibility")

        // Hubcap API key (used by the Steam store button).
        let keyField = NSSecureTextField()
        keyField.placeholderString = "smm_…"
        keyField.stringValue = HubcapCredentialStore.apiKey ?? ""
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        keyField.setAccessibilityLabel("Hubcap API key")
        hubcapKeyField = keyField

        let saveKeyButton = makeButton(title: "Save", target: self,
                                       action: #selector(saveHubcapKey))
        let clearKeyButton = makeButton(title: "Clear", target: self,
                                        action: #selector(clearHubcapKey))
        let keyButtons = NSStackView(views: [keyField, saveKeyButton, clearKeyButton])
        keyButtons.orientation = .horizontal
        keyButtons.spacing = 6
        keyButtons.alignment = .centerY

        let luaToolsLabel = NSTextField(labelWithString: "Not signed in")
        luaToolsLabel.font = Typography.caption
        luaToolsLabel.textColor = Colors.secondaryText
        luaToolsLabel.lineBreakMode = .byTruncatingTail
        luaToolsLabel.translatesAutoresizingMaskIntoConstraints = false
        luaToolsLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        luaToolsAccountLabel = luaToolsLabel

        let luaToolsButton = makeButton(title: "Sign in with Discord", target: self,
                                        action: #selector(toggleLuaTools))
        self.luaToolsButton = luaToolsButton
        let luaToolsControls = NSStackView(views: [luaToolsLabel, luaToolsButton])
        luaToolsControls.orientation = .horizontal
        luaToolsControls.spacing = 8
        luaToolsControls.alignment = .centerY

        let accountsCard = SettingsCard(rows: [
            SettingRow(title: "Hubcap API key",
                       subtitle: "Used by the Add via macSteam button on Steam store pages.",
                       control: keyButtons),
            SettingRow(title: "LuaTools / Discord",
                       subtitle: "Used by Store add and Fixes manifest downloads.",
                       control: luaToolsControls),
        ])
        let accountsHeader = settingsGroupLabel("Accounts")

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

        let allowUpdatesSwitch = NSSwitch()
        allowUpdatesSwitch.state = UpdateMode.allowsUpdates() ? .on : .off
        allowUpdatesSwitch.target = self
        allowUpdatesSwitch.action = #selector(allowUpdatesChanged)
        allowUpdatesSwitch.setAccessibilityLabel("Allow Steam client updates")
        self.allowUpdatesSwitch = allowUpdatesSwitch

        let updatesCard = SettingsCard(rows: [
            SettingRow(title: "Allow Steam updates",
                       subtitle: "Off keeps Steam pinned to the build macSteam supports. "
                           + "On lets Steam update and may break macSteam until it catches up.",
                       control: allowUpdatesSwitch),
            SettingRow(title: "Automatically check for updates",
                       subtitle: nil,
                       control: autoSwitch),
            SettingRow(title: "Check for Updates",
                       subtitle: nil,
                       control: btn),
        ])

        updaterSub = updater.$canCheckForUpdates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] can in self?.checkUpdateButton?.isEnabled = can }

        let generalHeader = settingsGroupLabel("General")
        let updatesHeader = settingsGroupLabel("Updates")

        let logButton = makeButton(title: "Open Log", target: self,
                                   action: #selector(openGeneralLog))
        let logCard = SettingsCard(rows: [
            SettingRow(title: "macSteam log",
                       subtitle: "App, store bridge, Cloud Saves, and LuaTools activity.",
                       control: logButton),
        ])
        let loggingHeader = settingsGroupLabel("Logging")

        let stack = NSStackView(views: [accountsHeader, accountsCard,
                                        generalHeader, togglesCard,
                                        compatibilityHeader, compatibilityCard,
                                        updatesHeader, updatesCard,
                                        loggingHeader, logCard])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(18, after: accountsCard)
        stack.setCustomSpacing(18, after: togglesCard)
        stack.setCustomSpacing(18, after: compatibilityCard)
        stack.setCustomSpacing(18, after: updatesCard)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for card in [accountsCard, togglesCard, compatibilityCard, updatesCard, logCard] {
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let document = SettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = makeScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        let m = Metrics.paneMargin
        let preferredWidth = stack.widthAnchor.constraint(equalToConstant: 820)
        preferredWidth.priority = NSLayoutConstraint.Priority(751)
        let fillWidth = stack.widthAnchor.constraint(equalTo: document.widthAnchor,
                                                     constant: -2 * m)
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),

            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: m),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -m),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor,
                                           constant: m),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 820),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor,
                                          constant: -m),
            preferredWidth,
            fillWidth,
        ])

        refreshLuaToolsAuth()
        return root
    }

    @objc private func saveHubcapKey() {
        do {
            try HubcapCredentialStore.save(hubcapKeyField?.stringValue ?? "")
            presentAlert("Hubcap key saved",
                         "The Steam store button will use this key when LuaTools is unavailable.",
                         style: .informational)
        } catch {
            presentAlert("Invalid Hubcap API key", error.localizedDescription, style: .warning)
        }
    }

    @objc private func clearHubcapKey() {
        HubcapCredentialStore.clear()
        hubcapKeyField?.stringValue = ""
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

    @objc private func openGeneralLog() {
        AppLog.revealInFinder()
    }

    @objc private func settingsChanged() {
        persisting { try store.setHideWhatsNew(hideWhatsNewSwitch.state == .on) }
    }

    @objc private func notProtonModeChanged() {
        NotProtonMode.setEnabled(notProtonSwitch.state == .on)
    }

    @objc private func allowUpdatesChanged() {
        let desired = allowUpdatesSwitch.state == .on
        let previous = UpdateMode.allowsUpdates()
        UpdateMode.setAllowsUpdates(desired)
        do {
            try UpdateMode.apply()
            AppLog.write("update mode: \(desired ? "allowed" : "blocked")",
                         category: "install")
        } catch {
            UpdateMode.setAllowsUpdates(previous)
            allowUpdatesSwitch.state = previous ? .on : .off
            presentAlert("Couldn’t change update mode",
                         error.localizedDescription, style: .warning)
        }
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
