// Adapted from ElfariaKensington/SomeAppOnlineFix (AGPL-3.0).
#include "../../onlinefix.h"

uint32_t of_patch_input(OFSession session, uint32_t reported) {
    return session.patches.input_id && session.game && reported == 480 ? session.game : reported;
}

static uint64_t (*input_original)(void *, uint32_t);

static uint64_t input_hook(void *controller, uint32_t game) {
    OFSession s = of_session();
    if (of_ready) game = of_patch_input(s, game);
    return input_original(controller, game);
}

OFHook of_input_hook = {"CSteamController::OptedInMask", (void *)input_hook, (void **)&input_original};
