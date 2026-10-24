// Adapted from ElfariaKensington/SomeAppOnlineFix (AGPL-3.0).
#include "../../onlinefix.h"
#include "../../ipc.h"
#include <string.h>

uint32_t of_identity(OFSession session, uint32_t reported) {
    bool restore = session.keep_id || (session.patches.startup_id && !session.networking);
    return session.game && reported == 480 && restore ? session.game : reported;
}

static OFDispatch utils_original;

static uint64_t utils_hook(void *object, void *request, void *reply, void *context) {
    IPCBuffer *in = request, *out = reply;
    OFSession before = of_session();
    uint32_t method = 0;
    int start = -1;
    if (of_ready && before.game && readable(in, 4) && out &&
        !out->error && !(out->mode & 1) && out->written >= 0 && out->written <= out->capacity) {
        memcpy(&method, in->bytes + in->cursor, 4);
        start = out->written;
    }
    uint64_t result = utils_original(object, request, reply, context);
    if (method != 0x09607ec4 || start < 0 || !readable(out, 0) ||
        out->written < start || out->written - start < 5 || out->bytes[start] != 0x0b)
        return result;
    OFSession after = of_session();
    if (before.generation == after.generation) {
        uint32_t id;
        memcpy(&id, out->bytes + start + 1, 4);
        id = of_identity(after, id);
        memcpy(out->bytes + start + 1, &id, 4);
    }
    return result;
}

OFHook of_identity_hook = {"IClientUtils::__ipc_server_dispatch", (void *)utils_hook, (void **)&utils_original};
