// Adapted from ElfariaKensington/SomeAppOnlineFix (AGPL-3.0).
#include "../../onlinefix.h"
#include <dobby.h>

void of_patch_overlay(OFSession session, const uint64_t *game, uint64_t *overlay) {
    if (session.patches.overlay_id && session.game && game && overlay && game != overlay &&
        *game == 480 && *overlay == 480)
        *overlay = session.game;
}


static void environment_hook(void *pc, DobbyRegisterContext *registers) {
    (void)pc;
    if (!of_ready) return;
    OFSession s = of_session();
    uint64_t *game = (uint64_t *)registers->general.regs.x1;
    uint64_t *overlay = (uint64_t *)registers->general.regs.x2;
    of_patch_overlay(s, game, overlay);
}

OFHook of_overlay_hook = {"CUser::BuildSpawnEnvBlock", (void *)environment_hook, NULL};
