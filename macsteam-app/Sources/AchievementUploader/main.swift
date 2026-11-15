// Standalone uploader: loads the game's own Steamworks shim and stores the
// selected achievements on the account. Only works for apps the account owns.
import Darwin
import Foundation

typealias SteamAPI_Init_t = @convention(c) () -> Bool
typealias SteamAPI_Shutdown_t = @convention(c) () -> Void
typealias SteamAPI_RunCallbacks_t = @convention(c) () -> Void
typealias SteamUserStats_t = @convention(c) () -> UnsafeMutableRawPointer?
typealias SteamApps_t = @convention(c) () -> UnsafeMutableRawPointer?
typealias RequestCurrentStats_t = @convention(c) (UnsafeMutableRawPointer?) -> Bool
typealias SetAchievement_t = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Bool
typealias StoreStats_t = @convention(c) (UnsafeMutableRawPointer?) -> Bool
typealias BIsSubscribedApp_t = @convention(c) (UnsafeMutableRawPointer?, UInt32) -> Bool

func emit(_ object: [String: Any], code: Int32) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(code)
}

func fail(_ message: String, owned: Bool = true) -> Never {
    emit(["ok": false, "owned": owned, "message": message], code: 1)
}

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

guard let appIDText = argument("--appid"),
      let appID = UInt32(appIDText),
      let shimPath = argument("--shim"),
      let idsText = argument("--ids") else {
    fail("usage: AchievementUploader --appid <id> --shim <path> --ids <id,id>")
}
let achievementIDs = idsText.split(separator: ",").map(String.init).filter { !$0.isEmpty }
guard !achievementIDs.isEmpty else { fail("No achievements were selected.") }

setenv("SteamAppId", appIDText, 1)
setenv("SteamGameId", appIDText, 1)
setenv("SteamAppId", appIDText, 1)

guard let handle = dlopen(shimPath, RTLD_NOW | RTLD_LOCAL) else {
    fail("Could not load the game's Steamworks library.")
}

func symbol<T>(_ name: String, _ type: T.Type) -> T? {
    guard let pointer = dlsym(handle, name) else { return nil }
    return unsafeBitCast(pointer, to: T.self)
}

guard let initFn = symbol("SteamAPI_Init", SteamAPI_Init_t.self),
      let shutdownFn = symbol("SteamAPI_Shutdown", SteamAPI_Shutdown_t.self),
      let runCallbacksFn = symbol("SteamAPI_RunCallbacks", SteamAPI_RunCallbacks_t.self),
      let userStatsFn = symbol("SteamAPI_SteamUserStats_v012", SteamUserStats_t.self),
      let appsFn = symbol("SteamAPI_SteamApps_v008", SteamApps_t.self),
      let requestFn = symbol("SteamAPI_ISteamUserStats_RequestCurrentStats", RequestCurrentStats_t.self),
      let setFn = symbol("SteamAPI_ISteamUserStats_SetAchievement", SetAchievement_t.self),
      let storeFn = symbol("SteamAPI_ISteamUserStats_StoreStats", StoreStats_t.self),
      let subscribedFn = symbol("SteamAPI_ISteamApps_BIsSubscribedApp", BIsSubscribedApp_t.self) else {
    fail("The game's Steamworks library is missing achievement functions.")
}

guard initFn() else {
    fail("SteamAPI_Init failed. Start Steam, sign in, and try again.")
}

guard let userStats = userStatsFn(), let apps = appsFn() else {
    shutdownFn()
    fail("Steamworks did not return the user stats interface.")
}

guard subscribedFn(apps, appID) else {
    shutdownFn()
    fail("This game is not on your Steam account, so its achievements cannot be public.", owned: false)
}

_ = requestFn(userStats)
for _ in 0..<20 {
    runCallbacksFn()
    usleep(100_000)
}

var storedCount = 0
for id in achievementIDs {
    if setFn(userStats, id) { storedCount += 1 }
}
let queued = storeFn(userStats)
for _ in 0..<30 {
    runCallbacksFn()
    usleep(100_000)
}
shutdownFn()

if !queued {
    fail("Steam rejected the achievement store request.")
}

emit([
    "ok": true,
    "owned": true,
    "set": storedCount,
    "total": achievementIDs.count,
    "message": "Uploaded \(storedCount) of \(achievementIDs.count) achievements to Steam. "
        + "It can take a few minutes for your profile to refresh.",
], code: 0)
