# macsteam 

"Steam unlock client" for macOS. ARM macOS, specifically. **This does not support Intel Macs!**

## Huh?

If you don't know what a Steam Unlock Client is, think 'SteamTools/OpenSteamTool/HubcapTools'. SLSSteam if you have good taste. If you don't know what those are, this isn't for you.

This is a minimal unlock client, at the moment. It supports game ownership spoofing ('unlocking') and license injection/downloading. It also has an achievement schema fetcher that is, umm, heavily 'inspired' by the one used in [SLSSteam](https://github.com/AceSLS/SLSsteam) but is no where as good or as well tested as that component was re-engineered hastily over the course of a few hours so that I could release.... 

Other than that one thing, this is an original work. It is _not_ a port of OpenSteamTool or SLSSteam to macOS. 

Manifest request codes are fetched from ManifestDeX over HTTPS, using the provider protocol documented in [OpenSteamTool PR #200](https://github.com/OpenSteam001/OpenSteamTool/pull/200). Downloads depend on this external service being available.

## How?

1. The config app deploys a dylib 'into' the Steam app bundle. 
2. A dylib (`macsteam.dylib`) is injected into Steam on launch, which does the unlock work.

Pretty boring. 

On Steam startup, macsteam also hides the “From the library of…” row (including
the lender avatar/status) and the legacy library-sharing retirement notice.
The patch preserves the JavaScript file's byte length to avoid triggering Steam's
startup size repair, and reapplies when macsteam loads after an update. It only
changes the UI; sharing permissions are unaffected. Unknown bundle signatures
are left unchanged, and Steam updates may require updating the signatures.

## macSteam Config

The companion app can handle all the basics. It can deploy the macSteam dylib, it can import games, you can use it to remove games from your unlock list, you can toggle the features that support being toggled (with more to come). You can also edit the config by hand by going to ```~/Library/Application Support/macSteam``` and editing the config file.

In macSteam Settings, **Hide Steam Cloud errors** optionally hides library Cloud
error indicators and Cloud failure/conflict notifications without disabling syncing.
Error-only Cloud columns collapse completely, and sidebar titles retain their
normal installed/uninstalled colors. It continues past game-launch Cloud warnings
using Steam’s “play anyway” action, without choosing local or remote saves. It defaults to off. Restart Steam
after changing it; turning it off restores the original UI. The config key is
`HideCloudErrors: yes` (or `no`).

The Cloud patch discovers render functions and callbacks from semantic UI names;
it does not depend on minified variable names or CSS hashes. It reapplies to new
bundles at startup and preserves file size. Recovery copies are keyed to the
patched bundle’s SHA-256, so restoring the toggle cannot overwrite a Steam update
with an old bundle. If a future structure is unrecognized, the bundle stays
untouched and the reason is logged.

Regression check against an unmodified Steam bundle:
```bash
python3 scripts/tests/cloud_errors.py /path/to/steamui/sp.js
```

## Usage

Download the latest release from the [Releases page](https://github.com/crghofficial/macsteam/releases).

Unzip it. Move macSteam Config to Applications. 

Go to Install, hit Install, let macSteam deploy. You will get a TCC prompt to allow macSteam to modify other applications, allow it.

## Building from source

The dylib:

```bash
make rebuild
```

The config app:

```bash
cd macsteam-app
bash make_app.sh
```

There is also a science experiment in the repo, a macSteam launcher that does not modify the Steam app bundle in any way. It is included for the enjoyment of others, but is not intended to be used. 

## OnlineFix

OnlineFix routing from [SomeAppOnlineFix](https://github.com/ElfariaKensington/SomeAppOnlineFix)
(AGPL-3.0) runs inside `macsteam.dylib`. In the config app, right-click a game in
Apps and choose **OnlineFix…** to enable routing and select compatibility patches.
Settings are read again on each launch, so changing them does not require restarting Steam.
A valid original game license is still required. This routing does not itself grant ownership.

Alternatively, add `-onlinefix` to a game's launch options; `-realappid` keeps its
original AppID visible after networking starts. Without either per-game configuration
or `-onlinefix`, macsteam leaves the game's OnlineFix identity alone.

The existing `config.yaml` stores per-game options separately from the unlock list:

```yaml
OnlineFix:
  105600:
    KeepRealAppID: no
    StartupAppID: yes
    OverlayAppID: yes
    InputAppID: yes
    StatsAppID: yes
```

The session uses AppID 480 for networking, while the optional patches restore the
original startup, overlay, controller and stats identities. All four patches default
to enabled. Only one routed game per Steam process is supported. The seven required
hooks must all resolve and install before routing activates. Profiles are included
for Steam builds 1791918634 and 1792618285; older profiles leave routing inactive.
`MACSTEAM_DISABLE=onlinefix` disables installation. No separate OnlineFix manager or
dylib is required. Game-file and Wine/Photon patches from the source manager are not
part of the Steam routing runtime.

Run `make test-onlinefix` for the runtime and C/Swift config integration checks.

## Contributing

PRs are welcome. I could currently badly use a **real name** and an **icon**.

## License

AGPLV2 with grifters being the reason why.
