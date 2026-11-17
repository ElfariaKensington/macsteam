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
typealias ClearAchievement_t = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Bool
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
      let shimPath = argument("--shim") else {
    fail("usage: AchievementUploader --appid <id> --shim <path> --ids <id,id> [--all <id,id>]")
}
let achievementIDs = (argument("--ids") ?? "")
    .split(separator: ",").map(String.init).filter { !$0.isEmpty }
let allIDs = (argument("--all") ?? "")
    .split(separator: ",").map(String.init).filter { !$0.isEmpty }
guard !achievementIDs.isEmpty || !allIDs.isEmpty else {
    fail("No achievements were selected.")
}

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

func firstSymbol<T>(_ names: [String], _ type: T.Type) -> T? {
    for name in names {
        if let value: T = symbol(name, type) { return value }
    }
    return nil
}

// Steamworks shims differ between SDK generations: newer builds export
// SteamAPI_InitSafe/SteamUserStats_v013 and drop RequestCurrentStats, older
// ones export SteamAPI_Init/SteamUserStats_v012. Resolve by capability, not
// by one hard-coded ABI.
let initFns = ["SteamAPI_Init", "SteamAPI_InitSafe"].compactMap {
    symbol($0, SteamAPI_Init_t.self)
}
let shutdownFn = symbol("SteamAPI_Shutdown", SteamAPI_Shutdown_t.self)
let runCallbacksFn = symbol("SteamAPI_RunCallbacks", SteamAPI_RunCallbacks_t.self)
let userStatsFn = firstSymbol(
    (1...13).reversed().map { String(format: "SteamAPI_SteamUserStats_v%03d", $0) },
    SteamUserStats_t.self)
let appsFn = firstSymbol(
    (1...8).reversed().map { String(format: "SteamAPI_SteamApps_v%03d", $0) },
    SteamApps_t.self)
let requestFn = symbol("SteamAPI_ISteamUserStats_RequestCurrentStats", RequestCurrentStats_t.self)
let setFn = symbol("SteamAPI_ISteamUserStats_SetAchievement", SetAchievement_t.self)
let clearFn = symbol("SteamAPI_ISteamUserStats_ClearAchievement", ClearAchievement_t.self)
let storeFn = symbol("SteamAPI_ISteamUserStats_StoreStats", StoreStats_t.self)
let subscribedFn = symbol("SteamAPI_ISteamApps_BIsSubscribedApp", BIsSubscribedApp_t.self)

guard !initFns.isEmpty else {
    fail("The game's Steamworks library exports neither SteamAPI_Init nor SteamAPI_InitSafe.")
}
guard let userStatsFn, let appsFn, let setFn, let storeFn, let subscribedFn else {
    fail("The game's Steamworks library is missing achievement functions.")
}

var initialized = false
for initFn in initFns {
    if initFn() { initialized = true; break }
}
guard initialized else {
    fail("SteamAPI_Init failed. Start Steam, sign in, and try again.")
}
defer { shutdownFn?() }

guard let userStats = userStatsFn(), let apps = appsFn() else {
    fail("Steamworks did not return the user stats interface.")
}

guard subscribedFn(apps, appID) else {
    fail("This game is not on your Steam account, so its achievements cannot be public.", owned: false)
}

// Note: BIsSubscribedApp is also true for a shared/borrowed license. Steam has
// accepted stores from those licenses, so do not gate on GetAppOwner here.

// Newer SDKs request stats during init and no longer export this call.
_ = requestFn?(userStats)
for _ in 0..<20 {
    runCallbacksFn?()
    usleep(100_000)
}

let selected = Set(achievementIDs)
var storedCount = 0
var clearedCount = 0
var clearAttempts = 0

if allIDs.isEmpty {
    for id in achievementIDs {
        if setFn(userStats, id) { storedCount += 1 }
    }
} else {
    guard let clearFn else {
        fail("This game's Steamworks library cannot lock achievements.")
    }
    let allSet = Set(allIDs)
    for id in allIDs {
        if selected.contains(id) {
            if setFn(userStats, id) { storedCount += 1 }
        } else {
            clearAttempts += 1
            // If the local cache already says "unachieved", ClearAchievement is
            // a no-op and never marks the stat dirty. Set it first so the clear
            // is a real state transition that StoreStats will send.
            _ = setFn(userStats, id)
            if clearFn(userStats, id) { clearedCount += 1 }
        }
    }
    // Selected IDs missing from --all still get set.
    for id in achievementIDs where !allSet.contains(id) {
        if setFn(userStats, id) { storedCount += 1 }
    }
}

let queued = storeFn(userStats)
for _ in 0..<30 {
    runCallbacksFn?()
    usleep(100_000)
}

if !queued {
    fail("Steam rejected the achievement store request. This usually means the signed-in "
        + "account does not own this game, or its license is not tied to the account.")
}
if storedCount == 0 && clearedCount == 0 {
    fail("Steam did not accept any of the selected achievement IDs.")
}

var message: String
if achievementIDs.isEmpty {
    message = "Cleared \(clearedCount) of \(clearAttempts) achievements from Steam."
} else {
    message = "Uploaded \(storedCount) of \(achievementIDs.count) selected "
        + "achievement\(achievementIDs.count == 1 ? "" : "s") to Steam."
    if clearAttempts > 0 {
        message += " Locked \(clearedCount) of \(clearAttempts) unselected "
            + "achievement\(clearAttempts == 1 ? "" : "s")."
    }
}
message += " It can take a few minutes for your profile to refresh."

emit([
    "ok": true,
    "owned": true,
    "set": storedCount,
    "total": achievementIDs.count,
    "cleared": clearedCount,
    "clear_total": clearAttempts,
    "message": message,
], code: 0)
