// Disable Steam's native per-app cloud switch for macSteam-unlocked games.
//
// Steam Cloud denies uploads for apps the account does not own, so every launch
// shows "Unable to sync" and a cloud sync failed dialog. Steam keeps the per-app
// switch in userdata/<account>/7/remote/sharedconfig.vdf; toggling it through
// SteamUI is the only way to persist it while the client is running.
(() => {
    if (window.__macsteamCloud) {
        return;
    }

    const registered = new Set();
    let enabled = false;
    let current = new Set();

    function report(details) {
        if (!enabled || !details || !details.bCloudEnabledForApp) return;
        if (!current.has(details.unAppID)) return;
        try {
            window.macsteamCloud(JSON.stringify({
                appid: details.unAppID,
                cloudEnabled: true,
                freeRemovable: !!details.bFreeRemovableLicense,
                status: details.eCloudStatus,
            }));
        } catch (e) {
            // The CEF binding disappears while the page is unloading.
        }
    }

    function register(appid) {
        if (registered.has(appid)) return;
        try {
            if (typeof SteamClient === "undefined" ||
                !SteamClient.Apps ||
                !SteamClient.Apps.RegisterForAppDetails) {
                return;
            }
            registered.add(appid);
            SteamClient.Apps.RegisterForAppDetails(appid, (a, b) => report(b || a));
        } catch (e) {
            registered.delete(appid);
        }
    }

    window.__macsteamCloud = {
        sync(appids, isEnabled) {
            enabled = !!isEnabled;
            current = new Set(appids || []);
            if (!enabled) return;
            for (const appid of current) {
                register(appid);
            }
        },
    };
})();
