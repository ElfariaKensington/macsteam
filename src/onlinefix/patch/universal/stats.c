// Adapted from ElfariaKensington/SomeAppOnlineFix (AGPL-3.0).
#include "../../onlinefix.h"
#include <string.h>

bool of_patch_stats(OFSession session, int kind, const void *payload, int size, unsigned char output[20]) {
    if (!session.patches.stats_id || !session.game || kind != 1101 || !payload || size != 20) return false;
    uint64_t id;
    memcpy(&id, payload, sizeof(id));
    if (id != 480) return false;
    memcpy(output, payload, 20);
    id = session.game;
    memcpy(output, &id, sizeof(id));
    return true;
}

static int (*callback_original)(void *, int, int, int, const void *, int);

static int callback_hook(void *engine, int pipe, int user, int kind, const void *payload, int size) {
    OFSession s = of_session();
    unsigned char local[20];
    if (of_ready && of_patch_stats(s, kind, payload, size, local)) {
        payload = local;
        of_log("stats callback: 480 -> %u pipe=%d", s.game, pipe);
    }
    // Steam copies this payload before the stack buffer goes out of scope.
    return callback_original(engine, pipe, user, kind, payload, size);
}

OFHook of_stats_hook = {"CSteamEngine::PostCallbackToPipe", (void *)callback_hook, (void **)&callback_original};
