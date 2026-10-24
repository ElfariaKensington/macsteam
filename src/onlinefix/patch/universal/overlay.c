// Adapted from ElfariaKensington/SomeAppOnlineFix (AGPL-3.0).
#include "../../onlinefix.h"
#include <dobby.h>

// BuildSpawnEnvBlock receives copies of the launch ID. Rewrite only these
// environment values; SpawnProcess's own ID must remain the real game for
// Steam's running-game list and the compatibility-tool process tree.
void of_patch_environment(OFSession session, uint64_t *game, uint64_t *overlay) {
    if (!session.game || !game || !overlay || game == overlay || *game != session.game)
        return;
    *game = 480;
    if (*overlay == session.game || *overlay == 480)
        *overlay = session.patches.overlay_id ? session.game : 480;
}

static void environment_hook(void *pc, DobbyRegisterContext *registers) {
    (void)pc;
    if (!of_ready) return;
    OFSession s = of_session();
    uint64_t *game = (uint64_t *)registers->general.regs.x1;
    // ARM64 Steam: x1 supplies SteamGameId/SteamAppId, x4 supplies
    // SteamOverlayGameId. x2 supplies the original game's ancillary settings.
    uint64_t *overlay = (uint64_t *)registers->general.regs.x4;
    of_patch_environment(s, game, overlay);
}

OFHook of_overlay_hook = {"CUser::BuildSpawnEnvBlock", (void *)environment_hook, NULL};
