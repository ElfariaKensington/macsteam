import AppKit

let app = NSApplication.shared
if CommandLine.arguments.contains("--hubcap-store-bridge") {
    app.setActivationPolicy(.prohibited)
    let bridge = HubcapStoreBridge()
    Task { await bridge.run(); app.terminate(nil) }
    app.run()
} else {
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
