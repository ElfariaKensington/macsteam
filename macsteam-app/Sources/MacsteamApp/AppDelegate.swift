import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appName = "macSteam Config"
    let store = ConfigStore()
    private let updaterManager = UpdaterManager.shared
    var window: NSWindow!
    var mainVC: MainViewController!

    private var bridgeHelper = false
    private var launchComplete = false
    private var configObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        bridgeHelper = CommandLine.arguments.contains("--hubcap-store-bridge")
        if bridgeHelper {
            NSApp.setActivationPolicy(.accessory)
            NotProtonSupport.clearQuarantine()
            store.load()
            launchComplete = true
            CloudSavesRunner.shared.start(store: store)
            if !HubcapStoreBridge.shared.start(store: store, waitForMainApp: true) {
                NSApp.terminate(nil)
            }
            SteamCloudBridge.shared.start(store: store)
            return
        }

        if enforceSingleInstance() { return }
        startNormalUI()
        launchComplete = true
    }

    // A helper started by the dylib has no window. If the user opens macSteam Config
    // while Steam is running, LaunchServices reopens that helper process instead of
    // launching a second copy, so promote it into the normal UI.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        guard launchComplete else { return false }
        if bridgeHelper || window == nil {
            startNormalUI()
            return false
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard launchComplete else { return false }
        if bridgeHelper || window == nil {
            startNormalUI()
            return true
        }
        return false
    }

    private func startNormalUI() {
        bridgeHelper = false
        if mainVC != nil, window != nil {
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        NSApp.setActivationPolicy(.regular)

        store.load()
        updaterManager.start()
        NotProtonSupport.clearQuarantine()
        if SteamInstaller.status() != .steamMissing {
            UpdateMode.applyAndLog()
        }

        CloudSavesRunner.shared.start(store: store)

        // The store button is useful even when this window is closed, so keep the bridge
        // alive for the life of the config app too.
        _ = HubcapStoreBridge.shared.start(store: store)
        SteamCloudBridge.shared.start(store: store)
        if configObserver == nil {
            configObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.macsteam.configChanged"),
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.store.load()
                    self.mainVC.reloadAfterExternalConfigChange()
                }
            }
        }

        buildMenu()

        mainVC = MainViewController(store: store)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = appName
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.contentViewController = mainVC

        window.isRestorable = false
        window.contentMinSize = NSSize(width: 720, height: 480)

        window.autorecalculatesKeyViewLoop = true
        window.identifier = NSUserInterfaceItemIdentifier("MacsteamMainWindow")

        let toolbar = NSToolbar(identifier: "MacsteamMainToolbar")
        toolbar.delegate = mainVC
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.setFrameAutosaveName("MacsteamMainWindow.v2")
        if !window.setFrameUsingName(window.frameAutosaveName) {
            window.setContentSize(NSSize(width: 820, height: 560))
            window.center()
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !bridgeHelper
    }

    func applicationWillTerminate(_ notification: Notification) {
        let active = HubcapStoreBridge.shared.isActive
        let steam = NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.valvesoftware.steam"
        })
        HubcapLog.write("app: terminate helper=\(bridgeHelper) bridge=\(active) steam=\(steam)")
        guard !bridgeHelper, active, steam else { return }
        spawnBridgeHelper()
    }

    private func spawnBridgeHelper() {
        guard let executable = Bundle.main.executableURL else {
            HubcapLog.write("app: helper spawn failed: no executable")
            return
        }
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = ["--hubcap-store-bridge"]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
        env.removeValue(forKey: "STEAM_APP_BUNDLE_PATH")
        helper.environment = env
        do {
            try helper.run()
            HubcapLog.write("app: spawned helper pid \(helper.processIdentifier)")
        } catch {
            HubcapLog.write("app: helper spawn failed: \(error.localizedDescription)")
        }
    }

    @objc private func checkForUpdatesMenu() {
        updaterManager.checkForUpdates()
    }

    private func enforceSingleInstance() -> Bool {
        guard let me = Bundle.main.bundleIdentifier else { return false }
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == me && $0.processIdentifier != getpid()
        }
        guard !others.isEmpty else { return false }

        if let existing = others.first(where: { $0.activationPolicy == .regular }) {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return true
        }

        // The dylib may have left a headless helper running. Stop it before opening
        // the window so we never run two Cloud Saves runners or two bridge owners.
        if let helper = others.first {
            HubcapLog.write("app: stopping helper pid \(helper.processIdentifier) before opening UI")
            helper.terminate()
            let deadline = Date().addingTimeInterval(3)
            while !helper.isTerminated && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            if !helper.isTerminated {
                helper.forceTerminate()
                let finalDeadline = Date().addingTimeInterval(1)
                while !helper.isTerminated && Date() < finalDeadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
            }
        }
        return false
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Check for Updates…",
                        action: #selector(checkForUpdatesMenu),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let servicesMenu = NSMenu()
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                        action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Import Zip…",
                         action: #selector(MainViewController.importZip), keyEquivalent: "i").target = nil
        fileMenu.addItem(.separator())
        let removeItem = fileMenu.addItem(
            withTitle: "Remove",
            action: #selector(DeletingOutlineView.removeApps(_:)),
            keyEquivalent: String(UnicodeScalar(NSDeleteCharacter)!))
        removeItem.keyEquivalentModifierMask = [.command]
        removeItem.target = nil
        fileMenuItem.submenu = fileMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApplication.shared.mainMenu = mainMenu
    }
}
