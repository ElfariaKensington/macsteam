import Foundation

@main
struct OnlineFixConfigProbe {
    static func main() throws {
        let text = """
        HideWhatsNew: yes
        Apps:
          - 105600  # Terraria
          - 413150
        PackageIds:
          - 20200
        OnlineFix:
          105600:
            KeepRealAppID: yes
            StartupAppID: no
            StatsAppID: no
        DepotKeys:
          105600:
            105601: abcdef
        """
        let config = MacsteamConfig.parse(text)
        precondition(config.apps == [105600, 413150] && config.hideWhatsNew)
        precondition(config.packageIds == [20200] && config.depotKeyGroups.count == 1)
        precondition(config.onlineFixGames.count == 1)
        precondition(config.onlineFixGames[105600]?.keepRealAppID == true)
        precondition(config.onlineFixGames[105600]?.startupAppID == false)
        precondition(config.onlineFixGames[105600]?.overlayAppID == true)
        precondition(config.onlineFixGames[105600]?.inputAppID == true)
        precondition(config.onlineFixGames[105600]?.statsAppID == false)
        precondition(MacsteamConfig.parse(config.serialize()) == config)
        var removed = config
        removed.removeApps([105600])
        precondition(removed.onlineFixGames.isEmpty && removed.apps == [413150])
        precondition(MacsteamConfig.parse("Apps:\n  - 105600\n").onlineFixGames.isEmpty)
        precondition(MacsteamConfig.parse("OnlineFix:\n  480:\n  0:\n  16777216:\n").onlineFixGames.isEmpty)
        if CommandLine.arguments.count > 1 {
            try config.serialize().write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
        }
        print("OnlineFix Swift config checks passed")
    }
}
