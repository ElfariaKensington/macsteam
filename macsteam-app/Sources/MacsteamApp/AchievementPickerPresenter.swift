// Shared presentation for the achievement picker, used by the game context
// menu and by the Steam properties-tab URL handler.
import AppKit
import CoreFoundation

@MainActor
enum AchievementPickerPresenter {
    static func present(appID: Int, store: ConfigStore, displayName: String) {
        Task { @MainActor in
            var definitions: [AchievementDefinition]
            do {
                definitions = try AchievementCatalog.load(appID: appID)
            } catch {
                if await AchievementSchemaFetcher().ensureSchema(appID: appID),
                   let loaded = try? AchievementCatalog.load(appID: appID) {
                    definitions = loaded
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Achievements — \(displayName)"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .informational
                    alert.runModal()
                    return
                }
            }

            let current = store.config.achievementSelection(for: appID)
            var selected: Set<String>
            if current?.all == true {
                selected = Set(definitions.map(\.id))
            } else {
                selected = Set(current?.ids ?? [])
            }
            selected.formIntersection(Set(definitions.map(\.id)))

            let picker = AchievementPicker(definitions: definitions, selected: selected)
            let alert = NSAlert()
            alert.messageText = "Achievements — \(displayName)"
            alert.informativeText = "Choose the achievements to mark as unlocked. "
                + "macSteam writes them into Steam's local stats cache; restart Steam after "
                + "saving. Selecting none turns spoofing off and restores the original values."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.accessoryView = picker.view
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let ids = picker.selectedIDs
            let upload = picker.uploadToProfile
            do {
                if ids.count == definitions.count {
                    try store.setAchievementAll(appID, enabled: true)
                } else {
                    try store.setAchievementIDs(appID, ids: ids)
                }
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName(rawValue: "com.macsteam.achievements.refresh" as CFString),
                    nil, nil, true)

                if upload && !ids.isEmpty {
                    let result = await SteamAchievementUploader.upload(appID: appID, ids: ids)
                    NSApp.activate(ignoringOtherApps: true)
                    let profileAlert = NSAlert()
                    profileAlert.messageText = "Steam profile"
                    profileAlert.informativeText = result.message
                    profileAlert.alertStyle = result.ok ? .informational : .warning
                    profileAlert.runModal()
                }
            } catch {
                let failure = NSAlert()
                failure.messageText = "Couldn’t save achievement settings"
                failure.informativeText = error.localizedDescription
                failure.alertStyle = .warning
                failure.runModal()
            }
        }
    }
}
