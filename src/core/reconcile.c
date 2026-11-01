// Late-injection recovery
#include "reconcile.h"
#include "../util/log.h"
#include "../util/file.h"

#include <stdint.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <notify.h>
#include <fcntl.h>
#include <dispatch/dispatch.h>
#include "../hooks/hooks.h"
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "../config/config.h"

static int sx_reconcile_after_inject(void);
static int sx_reconcile_run_pending_if_ready(void);

static uintptr_t g_engine_ref_fn = 0;

typedef void (*fn_clearmap)(void *map_base);
static fn_clearmap g_clearmap_fn = NULL;
static size_t g_map_offset;
static uintptr_t g_package_cache_vtable;

typedef int64_t (*fn_readdisk)(void *cache_base);
static fn_readdisk g_readdisk_fn = NULL;

typedef void (*fn_appmgr_markdirty)(void *app_mgr, uint32_t appid, char flag);
typedef void (*fn_appmgr_op)(void *app_mgr);
static fn_appmgr_markdirty g_markdirty_fn = NULL;
static fn_appmgr_op g_recompute_fn = NULL;
static fn_appmgr_op g_emit_fn      = NULL;

static const int *g_refresh_app_ids = NULL;
static int        g_refresh_app_count = 0;

// Main thread only (recompute/emit aren't thread safe, much like C itself).
static atomic_int g_refresh_armed = 0;

static atomic_int g_login_observed = 0;

void sx_reconcile_set_login_observed(void) {
    if (!g_login_observed) {
        g_login_observed = 1;
        SX_LOG("[reconcile] login observed (BLoggedOn). Deferred reconcile + library refresh may now run");
    }
}

int sx_reconcile_login_observed(void) {
    return g_login_observed;
}

static int g_reconcile_pending = 0;
static int g_reload_token = -1;
static char g_refresh_request[64];
static atomic_flag g_refresh_lock = ATOMIC_FLAG_INIT;

// Readers in other hooks take immutable atomic snapshots. Retired snapshots must
// remain alive until Steam exits: freeing them here would race those readers.
static void live_reload_if_requested(void) {
    int changed = 0;
    if (g_reload_token < 0 || notify_check(g_reload_token, &changed) != NOTIFY_STATUS_OK || !changed)
        return;
    const char *home = sx_resolve_home();
    if (!home) return;
    char path[1024], request[64] = {0};
    sx_macsteam_support_path(path, sizeof(path), home, "hubcap-refresh.request");
    FILE *file = fopen(path, "r");
    if (!file) return;
    size_t len = fread(request, 1, sizeof(request) - 1, file);
    fclose(file);
    if (len != 36 || strspn(request, "0123456789abcdefABCDEF-") != len) return;
    if (!g_engine_ref_fn || !g_clearmap_fn || !g_readdisk_fn ||
        !g_markdirty_fn || !g_recompute_fn || !g_emit_fn) {
        SX_WARN("[hubcap] live activation unavailable: required Steam signatures unresolved");
        return;
    }
    sx_config_t *next = calloc(1, sizeof(*next));
    if (!next) return;
    sx_file_config_path(path, sizeof(path));
    if (sx_config_load(path, next) != 0) {
        sx_config_free(next); free(next);
        SX_WARN("[hubcap] config reload failed; keeping the active config");
        return;
    }
    sx_config_t *active = atomic_load(&sx_config_current);
    if (active && active->app_count == next->app_count && active->pkg_count == next->pkg_count &&
        active->dk_count == next->dk_count && active->hide_whats_new == next->hide_whats_new &&
        (next->app_count == 0 || memcmp(active->app_ids, next->app_ids, sizeof(int) * next->app_count) == 0) &&
        (next->pkg_count == 0 || memcmp(active->package_ids, next->package_ids, sizeof(int) * next->pkg_count) == 0) &&
        memcmp(active->depot_keys, next->depot_keys, sizeof(next->depot_keys[0]) * next->dk_count) == 0) {
        sx_config_free(next); free(next); next = active;
    } else {
        atomic_store(&sx_config_current, next);
    }
    sx_reconcile_set_library_refresh_apps(next->app_ids, next->app_count);
    memcpy(g_refresh_request, request, len + 1);
    sx_reconcile_arm_after_inject();
    sx_reconcile_arm_library_refresh();
    SX_LOG("[hubcap] loaded %d apps for live library activation", next->app_count);
}

static void write_live_state(void) {
    const char *home = sx_resolve_home();
    if (!home) return;
    char path[1024], temp[1100];
    sx_macsteam_support_path(path, sizeof(path), home, "hubcap-runtime.apps");
    snprintf(temp, sizeof(temp), "%s.%d.tmp", path, getpid());
    FILE *file = fopen(temp, "w");
    if (!file) return;
    fchmod(fileno(file), 0600);
    fprintf(file, "%d\n", getpid());
    for (int i = 0; i < g_refresh_app_count; i++) fprintf(file, "%d\n", g_refresh_app_ids[i]);
    int failed = ferror(file);
    if (fclose(file) != 0) failed = 1;
    if (failed || rename(temp, path) != 0) { unlink(temp); return; }
    if (!g_refresh_request[0]) return;
    sx_macsteam_support_path(path, sizeof(path), home, "hubcap-refresh.ack");
    snprintf(temp, sizeof(temp), "%s.%d.tmp", path, getpid());
    file = fopen(temp, "w");
    if (!file) return;
    fchmod(fileno(file), 0600);
    fputs(g_refresh_request, file);
    failed = ferror(file);
    if (fclose(file) != 0) failed = 1;
    if (failed || rename(temp, path) != 0) { unlink(temp); return; }
    SX_LOG("[hubcap] live activation acknowledged (%d apps)", g_refresh_app_count);
    g_refresh_request[0] = 0;
}

static int g_reload_fd = -1, g_reload_fd_token = -1;
static dispatch_source_t g_reload_source;

static void refresh_on_main(void *unused) {
    (void)unused;
    uint32_t token;
    while (read(g_reload_fd, &token, sizeof(token)) > 0) {}
    sx_hooks_apps_refresh_library();
}

void sx_reconcile_enable_live_reload(void) {
    if (notify_register_check("com.macsteam.hubcap.refresh", &g_reload_token) != NOTIFY_STATUS_OK)
        g_reload_token = -1;
    if (g_reload_token < 0) return;
    int changed;
    notify_check(g_reload_token, &changed);
    // A loader worker has no CFRunLoop. Deliver through a file descriptor to
    // Steam's main queue instead of installing an observer on that worker.
    if (notify_register_file_descriptor("com.macsteam.hubcap.refresh", &g_reload_fd,
                                        0, &g_reload_fd_token) != NOTIFY_STATUS_OK) return;
    fcntl(g_reload_fd, F_SETFL, fcntl(g_reload_fd, F_GETFL) | O_NONBLOCK);
    g_reload_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, g_reload_fd,
                                              0, dispatch_get_main_queue());
    if (g_reload_source) {
        dispatch_source_set_event_handler_f(g_reload_source, refresh_on_main);
        dispatch_resume(g_reload_source);
    }
}

static uintptr_t decode_adrp_add(uintptr_t site) {
    uint32_t adrp = *(uint32_t *)site;
    uint32_t add  = *(uint32_t *)(site + 4);

    if ((adrp & 0x9F000000u) != 0x90000000u)
        return 0;
    if ((add & 0xFFC00000u) != 0x91000000u)
        return 0;

    uint32_t immlo = (adrp >> 29) & 0x3;
    uint32_t immhi = (adrp >> 5)  & 0x7FFFF;
    int64_t  imm   = (int64_t)((immhi << 2) | immlo);
    if (imm & (1LL << 20))
        imm -= (1LL << 21);
    uintptr_t page = site & ~(uintptr_t)0xFFF;
    uintptr_t adrp_target = page + (uintptr_t)(imm << 12);

    uint32_t adrp_rd = adrp & 0x1F;
    uint32_t add_rn  = (add >> 5) & 0x1F;
    if (adrp_rd != add_rn)
        return 0;

    uint32_t imm12 = (add >> 10) & 0xFFF;
    uint32_t sh    = (add >> 22) & 0x1;
    if (sh) imm12 <<= 12;

    return adrp_target + imm12;
}

// This anchor references the app cache, not the package cache. Decode only its
// engine-global load; never reuse its member offset for another cache type.
static uintptr_t resolve_engine_global(uintptr_t anchor) {
    if (!anchor) return 0;
    for (size_t off = 0; off < 0x100; off += 4) {
        uintptr_t site = anchor + off;
        uintptr_t global = decode_adrp_add(site);
        if (!global) continue;
        uint32_t page_reg = *(uint32_t *)site & 31;
        uint32_t load = *(uint32_t *)(site + 8);
        uint32_t mov = *(uint32_t *)(site + 12);
        uint32_t add = *(uint32_t *)(site + 16);
        uint32_t call = *(uint32_t *)(site + 20);
        if ((load & 0xFFFFFC00) != 0xF9400000 || ((load >> 5) & 31) != page_reg ||
            (mov & 0xFFE00000) != 0x52800000 || // MOVZ Wn, #offset (no shift)
            (add & 0xFFE0FC1F) != 0x8B000000 || // ADD X0, Xengine, Xoffset
            ((add >> 5) & 31) != (load & 31) || ((add >> 16) & 31) != (mov & 31) ||
            (call & 0xFC000000) != 0x94000000) continue;
        size_t offset = (mov >> 5) & 0xFFFF;
        if (!offset || offset % sizeof(void *)) continue;
        return global;
    }
    return 0;
}

static uintptr_t branch_target(uintptr_t site) {
    uint32_t word = *(uint32_t *)site;
    if ((word & 0xFC000000) != 0x94000000) return 0;
    int64_t imm = word & 0x03FFFFFF;
    if (imm & (1 << 25)) imm -= (1 << 26);
    return site + imm * 4;
}

// The historical "ClearMap" signature names a deleting destructor in newer
// Steam. Never call it on an embedded object. Recover only its map-clear call.
static uintptr_t resolve_map_clear(uintptr_t wrapper, size_t *map_offset, uintptr_t *vtable) {
    if (!wrapper) return 0;
    uintptr_t destructor = 0;
    for (size_t off = 0; off < 0x20; off += 4) {
        destructor = branch_target(wrapper + off);
        if (destructor) break;
    }
    if (!destructor) return 0;
    for (size_t off = 0; off < 0x60; off += 4) {
        uint32_t store = *(uint32_t *)(destructor + off);
        // STR Xvtable, [X0], #mapOffset, followed immediately by BL clear(map).
        if ((store & 0xFFE00FE0) != 0xF8000400 || off < 8) continue;
        uintptr_t table = decode_adrp_add(destructor + off - 8);
        uint32_t table_reg = *(uint32_t *)(destructor + off - 4) & 31;
        if (!table || (store & 31) != table_reg) continue;
        unsigned offset = (store >> 12) & 0x1FF;
        uintptr_t clear = branch_target(destructor + off + 4);
        if (offset == 0 || offset >= 128 || offset % sizeof(void *) || !clear) continue;
        *map_offset = offset;
        *vtable = table;
        return clear;
    }
    return 0;
}

// Read through the VM API so an unexpected Steam layout fails closed instead
// of dereferencing a stale pointer. No cache field offsets are baked in.
static int read_memory(uintptr_t source, void *destination, size_t size) {
    mach_vm_size_t copied = 0;
    return mach_vm_read_overwrite(mach_task_self(), source, size,
        (mach_vm_address_t)destination, &copied) == KERN_SUCCESS && copied == size;
}

static void *resolve_package_cache(void) {
    uintptr_t global = resolve_engine_global(g_engine_ref_fn), engine = 0;
    if (!global || !g_package_cache_vtable ||
        !read_memory(global, &engine, sizeof(engine)) || !engine) return NULL;

    // Both caches are embedded in CSteamEngine. Match the package cache's
    // actual vtable, recovered from its destructor, rather than the neighboring
    // app cache used by the engine anchor. Reject missing or ambiguous matches.
    uintptr_t words[2048];
    size_t count = 0;
    for (; count < sizeof(words) / sizeof(words[0]); count++) {
        if (!read_memory(engine + count * sizeof(uintptr_t), &words[count], sizeof(uintptr_t))) break;
    }
    void *cache = NULL;
    for (size_t i = 0; i < count; i++) {
        if (words[i] != g_package_cache_vtable) continue;
        if (cache) return NULL;
        cache = (void *)(engine + i * sizeof(uintptr_t));
    }
    return cache;
}

// Repair pkg-20200 in packageinfo.vdf so the re-read doesn't drop it.
static const uint8_t PKG_VDF_CORRUPT_MARKER[] = {
    0x20, 0x20, 0x01, 0x00, 0x02,
    'b', 'i', 'l', 'l', 'i', 'n', 'g', 't', 'y', 'p', 'e'
};
static const uint8_t PKG_VDF_CLEAN_ID[] = { 0xE8, 0x4E, 0x00, 0x00 };

static int sx_reconcile_repair_packageinfo_vdf(void) {
    const char *home = sx_resolve_home();
    if (!home) return 0;

    char path[1024];
    sx_steam_appcache_path(path, sizeof(path), home, "packageinfo.vdf");

    int rc = sx_file_patch_bytes(path, PKG_VDF_CORRUPT_MARKER,
                                 sizeof(PKG_VDF_CORRUPT_MARKER),
                                 PKG_VDF_CLEAN_ID, sizeof(PKG_VDF_CLEAN_ID));
    if (rc == 1)
        SX_LOG("[reconcile] packageinfo.vdf repaired pkg 20200 (73760 -> 20200)");
    else if (rc < 0)
        SX_WARN("[reconcile] packageinfo.vdf repair failed");
    return rc == 1;
}


void sx_reconcile_set_addrs(uintptr_t engine_ref_fn,
                            uintptr_t clearmap_fn,
                            uintptr_t readdisk_fn) {
    g_engine_ref_fn = engine_ref_fn;
    g_clearmap_fn   = (fn_clearmap)resolve_map_clear(clearmap_fn, &g_map_offset, &g_package_cache_vtable);
    g_readdisk_fn   = (fn_readdisk)readdisk_fn;

    if (!engine_ref_fn || !g_clearmap_fn || !readdisk_fn) {
        SX_WARN("[reconcile] disabled, unresolved addrs "
                "(engine_ref=%p clearmap=%p readdisk=%p)",
                (void *)engine_ref_fn, (void *)clearmap_fn, (void *)readdisk_fn);
    } else {
        SX_DBG("[reconcile] addrs set: engine_ref=%p clearmap=%p readdisk=%p",
               (void *)engine_ref_fn, (void *)clearmap_fn, (void *)readdisk_fn);
    }
}

void sx_reconcile_set_library_refresh_fns(uintptr_t markdirty_fn,
                                  uintptr_t recompute_fn,
                                  uintptr_t emit_fn) {
    g_markdirty_fn = (fn_appmgr_markdirty)markdirty_fn;
    g_recompute_fn = (fn_appmgr_op)recompute_fn;
    g_emit_fn      = (fn_appmgr_op)emit_fn;
    if (!markdirty_fn || !recompute_fn || !emit_fn) {
        SX_WARN("[reconcile] auto-refresh disabled, native trio unresolved "
                "(markdirty=%p recompute=%p emit=%p). Reconcile still runs but "
                "UI needs a manual online/offline toggle",
                (void *)markdirty_fn, (void *)recompute_fn, (void *)emit_fn);
    } else {
        SX_DBG("[reconcile] library refresh trio set: MarkAppDirty=%p "
               "RecomputeSubscribedApps=%p EmitAppLicensesChanged=%p",
               (void *)markdirty_fn, (void *)recompute_fn, (void *)emit_fn);
    }
}

void sx_reconcile_set_library_refresh_apps(const int *app_ids, int app_count) {
    g_refresh_app_ids   = app_ids;
    g_refresh_app_count = (app_ids && app_count > 0) ? app_count : 0;
    SX_DBG("[reconcile] library refresh appid list set: %d app(s)", g_refresh_app_count);
}

void sx_reconcile_arm_library_refresh(void) {
    if (!g_markdirty_fn || !g_recompute_fn || !g_emit_fn) {
        SX_WARN("[reconcile] cannot arm library refresh, native trio unresolved");
        return;
    }
    g_refresh_armed = 1;
    SX_LOG("[reconcile] library refresh armed. Native sub_B19024(x%d)+sub_B1986C+"
           "sub_B19100 will fire once from the next main-thread "
           "CheckAppOwnership/GetSubscribedApps", g_refresh_app_count);
}

int sx_reconcile_fire_library_refresh(void *app_mgr) {
    // Hooks and the companion notification can arrive on different threads.
    // A nonblocking guard also rejects recursive ownership calls from Steam.
    if (atomic_flag_test_and_set_explicit(&g_refresh_lock, memory_order_acquire)) return 0;
    live_reload_if_requested();
    if (!g_refresh_armed || !g_login_observed || !app_mgr) {
        atomic_flag_clear_explicit(&g_refresh_lock, memory_order_release);
        return 0;
    }
    g_refresh_armed = 0;
    if (sx_reconcile_run_pending_if_ready() < 0) {
        atomic_flag_clear_explicit(&g_refresh_lock, memory_order_release);
        return 0;
    }

    SX_LOG("[reconcile] firing native library refresh on CUserAppManager=%p (x%d apps)",
           app_mgr, g_refresh_app_count);

    for (int i = 0; i < g_refresh_app_count; i++) {
        uint32_t appid = (uint32_t)g_refresh_app_ids[i];
        g_markdirty_fn(app_mgr, appid, 0);
    }
    SX_LOG("[reconcile] marked %d configured appid(s) dirty", g_refresh_app_count);

    g_recompute_fn(app_mgr);
    g_emit_fn(app_mgr);
    write_live_state();
    atomic_flag_clear_explicit(&g_refresh_lock, memory_order_release);
    return 1;
}

void sx_reconcile_arm_after_inject(void) {
    if (!g_engine_ref_fn || !g_clearmap_fn || !g_readdisk_fn) {
        SX_WARN("[reconcile] cannot arm reconcile, addresses unavailable");
        return;
    }
    g_reconcile_pending = 1;
    SX_LOG("[reconcile] reconcile armed (ClearMap+ReadFromDisk), runs from first post-login hook");
}

static int sx_reconcile_run_pending_if_ready(void) {
    if (!g_reconcile_pending)
        return 0;
    if (!g_login_observed)
        return 0;
    g_reconcile_pending = 0;
    SX_LOG("[reconcile] login complete. Running deferred package-cache "
           "reconcile now");
    return sx_reconcile_after_inject();
}

static int sx_reconcile_after_inject(void) {
    void *cache = resolve_package_cache();
    if (!cache) {
        SX_WARN("[reconcile] package cache type could not be verified; activation skipped");
        return -1;
    }

    sx_reconcile_repair_packageinfo_vdf();
    void *map_base = (void *)((uint8_t *)cache  + g_map_offset);

    SX_LOG("[reconcile] verified package cache=%p map=%p, clearing map + re-reading disk",
           cache, map_base);

    g_clearmap_fn(map_base);

    int64_t npkgs = g_readdisk_fn(cache);

    SX_LOG("[reconcile] ReadFromDisk re-read %lld package(s). PkgParse should have re-fired",
           (long long)npkgs);

    if (!g_refresh_armed) {
        SX_DBG("[reconcile] library refresh not armed, caller did not request the "
               "native AppLicensesChanged_t emit (UI may need manual toggle)");
    }

    return (int)npkgs;
}
