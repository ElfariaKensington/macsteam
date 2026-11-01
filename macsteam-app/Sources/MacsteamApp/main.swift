import AppKit
import Dispatch
import Darwin

if CommandLine.arguments.contains("--hubcap-store-bridge") {
    // Do not create NSApplication here: registering the invisible helper with
    // Launch Services makes it look like the config window is already open.
    let bridge = HubcapStoreBridge()
    Task { await bridge.run(); exit(EXIT_SUCCESS) }
    dispatchMain()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    if #available(macOS 14, *) {
        app.activate()
    } else {
        app.activate(ignoringOtherApps: true)
    }
    app.run()
}
