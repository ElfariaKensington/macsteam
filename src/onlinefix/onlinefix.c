// Adapted from ElfariaKensington/SomeAppOnlineFix (AGPL-3.0).
#include "onlinefix.h"
#include "install.h"
#include <dobby.h>
#include "ipc.h"
#include "../hooks/hooks.h"
#include "../util/log.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>


_Atomic bool of_ready;
static uint32_t (*session_original)(void *, uint32_t, uint8_t);
static OFDispatch network_original;
void of_networking(void);

static void launch_hook(void *pc, DobbyRegisterContext *registers) {
    (void)pc;
    if (of_ready) of_start((const char *)registers->general.regs.x2,
                          (const uint64_t *)registers->general.regs.x4);
}

static uint32_t session_hook(void *engine, uint32_t game, uint8_t update) {
    OFSession s = of_session();
    if (of_ready && s.game && game == s.game) {
        of_log("pipe AppID: %u -> 480", game);
        game = 480;
    }
    return session_original(engine, game, update);
}

static uint64_t network_hook(void *object, void *request, void *reply, void *context) {
    if (of_ready && readable(request, 4)) of_networking();
    return network_original(object, request, reply, context);
}

static OFHook launch = {"CUser::SpawnProcess", (void *)launch_hook, NULL};
static OFHook session = {"CSteamEngine::SetAppIDForCurrentPipe", (void *)session_hook, (void **)&session_original};
static OFHook network = {"IClientNetworkingSocketsSerialized::__ipc_server_dispatch", (void *)network_hook, (void **)&network_original};

static OFHook *targets[] = {
    &launch, &of_overlay_hook, &of_input_hook, &session,
    &of_identity_hook, &network, &of_stats_hook,
};

// Use macsteam's resolved Steam profile; never install a second loader or child filter.
void of_log(const char *format, ...) {
    char message[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);
    SX_LOG("[onlinefix] %s", message);
}

bool of_install_resolved(const sx_resolve_result_t *resolved) {
    const size_t count = sizeof(targets) / sizeof(targets[0]);
    void *addresses[count];
    if (of_ready) return true;
    if (getenv("ONLINEFIX_DISABLE") || sx_hook_disabled("onlinefix")) return false;
    // Resolve and check all targets before touching Steam. Partial installation
    // stays in passthrough mode because of_ready is published only on success.
    for (size_t i = 0; i < count; ++i) {
        addresses[i] = (void *)sx_resolve_find(resolved, targets[i]->name);
        if (!addresses[i] || sx_hook_disabled(targets[i]->name) || sx_hook_passthrough("onlinefix")) {
            of_log("inactive: required target unavailable: %s", targets[i]->name);
            return false;
        }
    }
    for (size_t i = 0; i < count; ++i) {
        OFHook h = *targets[i];
        int result = h.original ? DobbyHook(addresses[i], h.replacement, h.original)
            : DobbyInstrument(addresses[i], (dobby_instrument_callback_t)h.replacement);
        of_log("hook %s @ %p: %d", h.name, addresses[i], result);
        if (result) {
            of_log("installation incomplete; installed hooks stay in passthrough mode");
            return false;
        }
    }
    of_ready = true;
    return true;
}
