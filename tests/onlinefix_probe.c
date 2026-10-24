// OnlineFix integration regression checks; adapted from SomeAppOnlineFix's runtime tests.
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "../src/onlinefix/onlinefix.c"
#include "../src/config/config.h"

static int hook_calls, fail_at;
int DobbyHook(void *address, void *replacement, void **original) {
    (void)address; (void)replacement; (void)original;
    return ++hook_calls == fail_at ? -1 : 0;
}
int DobbyInstrument(void *address, dobby_instrument_callback_t callback) {
    (void)address; (void)callback;
    return ++hook_calls == fail_at ? -1 : 0;
}
int sx_hook_disabled(const char *name) { return getenv("TEST_DISABLE") && !strcmp(name, "onlinefix"); }
int sx_hook_passthrough(const char *name) { (void)name; return 0; }
uintptr_t sx_resolve_find(const sx_resolve_result_t *resolved, const char *name) {
    for (int i = 0; i < resolved->count; ++i)
        if (!strcmp(resolved->entries[i].name, name)) return resolved->entries[i].address;
    return 0;
}

static uint32_t observed;
static uint32_t record_session(void *engine, uint32_t id, uint8_t update) {
    (void)engine; (void)update; observed = id; return 17;
}
static uint64_t reply_id(void *object, void *request, void *reply, void *context) {
    (void)object; (void)request; (void)context;
    IPCBuffer *out = reply;
    uint32_t id = 480;
    out->bytes[out->written] = 0x0b;
    memcpy(out->bytes + out->written + 1, &id, 4);
    out->written += 5; out->extent = out->written;
    return 31;
}
static uint64_t no_reply(void *o, void *i, void *r, void *c) {
    (void)o; (void)i; (void)r; (void)c; return 37;
}
static void write_config(const char *path, const char *text) {
    FILE *file = fopen(path, "w");
    assert(file && fputs(text, file) >= 0 && fclose(file) == 0);
}

int main(int argc, char **argv) {
    char config[] = "/tmp/macsteam-onlinefix-XXXXXX";
    int fd = mkstemp(config); assert(fd >= 0); close(fd);
    assert(setenv("MACSTEAM_CONFIG", config, 1) == 0);
    const char *defaults = "Apps:\n  - 413150\nOnlineFix:\n  105600:\n    KeepRealAppID: no\nHideWhatsNew: yes\n";
    write_config(config, defaults);
    uint64_t game = 105600;
    of_start("game", &game);
    assert(game == 105600 && of_session().game == 105600 && !of_session().keep_id);
    assert(of_identity(of_session(), 480) == 105600);
    of_networking(); assert(of_identity(of_session(), 480) == 480);
    game = 105600; of_start("game -realappid", &game); of_networking();
    assert(of_identity(of_session(), 480) == 105600);
    game = 413150; of_start("game", &game);
    assert(game == 413150 && !of_session().game); // Apps alone never enable routing.
    game = 413150; of_start("game -onlinefix", &game);
    assert(game == 413150 && of_session().game == 413150);
    assert(of_patch_input(of_session(), 480) == 413150);
    uint64_t launch_id = 413150, overlay_id = 413150;
    of_patch_environment(of_session(), &launch_id, &overlay_id);
    assert(launch_id == 480 && overlay_id == 413150);
    unsigned char payload[20] = {0}, output[20];
    memcpy(payload, &launch_id, 8);
    assert(of_patch_stats(of_session(), 1101, payload, 20, output));
    uint64_t id; memcpy(&id, output, 8); assert(id == 413150);
    memcpy(&id, payload, 8); assert(id == 480);
    assert(!of_patch_stats(of_session(), 1101, payload, 19, output));
    assert(!of_patch_stats(of_session(), 999, payload, 20, output));
    write_config(config, "OnlineFix:\n  105600:\n    StartupAppID: no\n    OverlayAppID: no\n    InputAppID: no\n    StatsAppID: no\n");
    game = 105600; of_start("game", &game);
    assert(game == 105600 && of_identity(of_session(), 480) == 480);
    launch_id = overlay_id = 105600; of_patch_environment(of_session(), &launch_id, &overlay_id);
    assert(overlay_id == 480 && of_patch_input(of_session(), 480) == 480);
    assert(!of_patch_stats(of_session(), 1101, payload, 20, output));
    const char *invalid[] = {
        "OnlineFix:\n  480:\n", "OnlineFix:\n  0:\n", "OnlineFix:\n  105600.5:\n",
        "OnlineFix:\n  105600:\n    StatsAppID: maybe\n",
        "OnlineFix:\n  105600:\n    Unknown: yes\n",
        "OnlineFix:\n  105600:\n    StatsAppID: no\n    StatsAppID: yes\n",
        "OnlineFix:\n  105600:\n  105600:\n",
        "OnlineFix:\n  105600: yes\n", "OnlineFix:\n    StatsAppID: yes\n"
    };
    for (size_t i = 0; i < sizeof(invalid)/sizeof(invalid[0]); ++i) {
        write_config(config, invalid[i]);
        game = 105600; of_start("game", &game);
        assert(game == 105600 && !of_session().game);
    }
    write_config(config, "Apps:\n  - 413150\nOnlineFix:\n  105600:\n    StatsAppID: typo\nPackageIds:\n  - 20200\n");
    sx_config_t *cfg = calloc(1, sizeof(*cfg)); assert(cfg);
    assert(sx_config_load(config, cfg) == 0);
    assert(cfg->onlinefix_count == 0 && sx_config_has_app(cfg, 413150) && sx_config_has_package(cfg, 20200));
    sx_config_free(cfg); free(cfg);
    assert(of_argument("game '-onlinefix'", "-onlinefix"));
    assert(of_argument("game -online\\fix", "-onlinefix"));
    assert(!of_argument("game --onlinefix -onlinefix-more", "-onlinefix"));
    assert(!of_argument("game \"-onlinefix", "-onlinefix"));
    for (uint64_t invalid_id = 0xffffff + 1; invalid_id < 0xffffff + 3; ++invalid_id) {
        game = invalid_id; of_start("game -onlinefix", &game);
        assert(game == invalid_id && !of_session().game);
    }
    write_config(config, defaults);
    game = 105600; of_start("game", &game);
    session_original = record_session;
    of_ready = false;
    assert(session_hook(NULL, 105600, 0) == 17 && observed == 105600);
    of_ready = true;
    assert(session_hook(NULL, 105600, 0) == 17 && observed == 480);
    assert(session_hook(NULL, 999, 0) == 17 && observed == 999);
    // Actual hook boundary: process tracking keeps 620; only child env uses 480.
    game = 620;
    DobbyRegisterContext launch_regs = {0};
    launch_regs.general.regs.x2 = (uintptr_t)"portal2.exe -onlinefix";
    launch_regs.general.regs.x4 = (uintptr_t)&game;
    launch_hook(NULL, &launch_regs);
    assert(game == 620 && of_session().game == 620);
    assert(session_hook(NULL, 620, 0) == 17 && observed == 480);
    uint64_t env_game = game, env_original = game, env_overlay = game;
    DobbyRegisterContext env_regs = {0};
    env_regs.general.regs.x1 = (uintptr_t)&env_game;
    env_regs.general.regs.x2 = (uintptr_t)&env_original;
    env_regs.general.regs.x4 = (uintptr_t)&env_overlay;
    dobby_instrument_callback_t environment = (void *)of_overlay_hook.replacement;
    environment(NULL, &env_regs);
    assert(game == 620 && env_game == 480 && env_original == 620 && env_overlay == 620);
    OFSession disabled_overlay = of_session();
    disabled_overlay.patches.overlay_id = false;
    env_game = env_overlay = 620;
    of_patch_environment(disabled_overlay, &env_game, &env_overlay);
    assert(env_game == 480 && env_overlay == 480 && game == 620);
    env_game = env_overlay = 999;
    of_patch_environment(of_session(), &env_game, &env_overlay);
    assert(env_game == 999 && env_overlay == 999);
    env_game = 620;
    of_patch_environment(of_session(), &env_game, &env_game);
    assert(env_game == 620); // Never overwrite aliased tracking storage.
    env_game = env_overlay = 620;
    of_ready = false;
    environment(NULL, &env_regs);
    assert(env_game == 620 && env_overlay == 620);
    of_ready = true;
    game = 105600; of_start("game", &game);
    unsigned char request[4], response[32] = {0};
    uint32_t method = 0x09607ec4; memcpy(request, &method, 4);
    IPCBuffer in = {.bytes=request, .capacity=4, .written=4, .extent=4};
    IPCBuffer out = {.bytes=response, .capacity=32};
    *of_identity_hook.original = (void *)reply_id; network_original = no_reply;
    OFDispatch utils = (OFDispatch)of_identity_hook.replacement;
    assert(utils(NULL, &in, &out, NULL) == 31);
    memcpy(&observed, response+1, 4); assert(observed == 105600);
    assert(network_hook(NULL, &in, NULL, NULL) == 37);
    out.written = out.extent = 0;
    utils(NULL, &in, &out, NULL);
    memcpy(&observed, response+1, 4); assert(observed == 480);
    in.cursor = -1; assert(!readable(&in, 4)); in.cursor = 0;
    in.extent = 5; assert(!readable(&in, 4));
    of_ready = false;
    sx_resolved_t entries[7];
    for (size_t i = 0; i < 7; ++i) entries[i] = (sx_resolved_t){targets[i]->name, 0x1000 + i * 4};
    sx_resolve_result_t resolved = {.entries=entries, .count=6};
    assert(!of_install_resolved(&resolved) && hook_calls == 0 && !of_ready);
    resolved.count = 7;
    setenv("TEST_DISABLE", "1", 1);
    assert(!of_install_resolved(&resolved) && hook_calls == 0 && !of_ready);
    unsetenv("TEST_DISABLE");
    fail_at = 3;
    assert(!of_install_resolved(&resolved) && hook_calls == 3 && !of_ready);
    hook_calls = fail_at = 0;
    assert(of_install_resolved(&resolved) && hook_calls == 7 && of_ready);
    assert(of_install_resolved(&resolved) && hook_calls == 7); // Idempotent after success.
    // Optional fixture produced by the Swift config round-trip check.
    if (argc > 1) {
        setenv("MACSTEAM_CONFIG", argv[1], 1);
        game = 105600; of_start("game", &game);
        assert(game == 105600 && of_session().keep_id && !of_session().patches.stats_id);
        assert(of_session().patches.overlay_id);
    }
    unlink(config);
    puts("OnlineFix integration checks passed");
}
