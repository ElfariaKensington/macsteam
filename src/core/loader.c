// DYLD_INSERT_LIBRARIES entry point.
#include "../version.h"
#include "../util/log.h"
#include "../util/file.h"
#include "../config/config.h"
#include "../resolver/resolver.h"
#include "../resolver/sigdb.h"
#include "../core/macho.h"
#include "../core/reconcile.h"
#include "../hooks/hooks.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <stdint.h>
#include <sys/stat.h>
#include <dirent.h>
#include <mach-o/dyld.h>
#include <libgen.h>

#define STEAMCLIENT_DYLIB   "steamclient.dylib"
#define WAIT_TIMEOUT_MS     60000   // 60s, bootstrapper may take a while

__attribute__((visibility("default"))) const char *macsteam_version(void) {
    return MACSTEAM_VERSION;
}


static void unlink_sentinel(const char *dir, const char *name) {
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s", dir, name);
    if (unlink(path) == 0)
        SX_LOG("removed sentinel: %s", path);
}

// these two files force a redownload if left in place, so they must go
static void remove_crash_sentinel(void) {
    char exe_path[1024];
    uint32_t exe_size = sizeof(exe_path);
    if (_NSGetExecutablePath(exe_path, &exe_size) != 0) {
        SX_WARN("_NSGetExecutablePath failed");
        return;
    }

    char dir_buf[1024];
    strncpy(dir_buf, exe_path, sizeof(dir_buf) - 1);
    dir_buf[sizeof(dir_buf) - 1] = '\0';
    char *dir = dirname(dir_buf);

    SX_LOG("sentinel check dir: %s", dir);
    unlink_sentinel(dir, ".crash");
    unlink_sentinel(dir, ".forceupdate");
}

// hook_PkgParse is the ownership hook, but Steam only calls it when it parses a
// new package. So this tampers with pkg 20200 to break the cache, which makes
// the hook fire. 20200 is repaired by reconcile.c.
static const uint8_t PKG_VDF_CLEAN[] = {
    0xE8, 0x4E, 0x00, 0x00, 0x02,
    'b', 'i', 'l', 'l', 'i', 'n', 'g', 't', 'y', 'p', 'e'
};
static const uint8_t PKG_VDF_CORRUPT[] = { 0x20, 0x20, 0x01, 0x00 };

static void corrupt_packageinfo_vdf(void) {
    const char *home = sx_resolve_home();
    if (!home) return;

    char path[1024];
    sx_steam_appcache_path(path, sizeof(path), home, "packageinfo.vdf");

    int rc = sx_file_patch_bytes(path, PKG_VDF_CLEAN, sizeof(PKG_VDF_CLEAN),
                                 PKG_VDF_CORRUPT, sizeof(PKG_VDF_CORRUPT));
    if (rc == 1)
        SX_LOG("packageinfo.vdf: corrupted pkg 20200 (will refetch + re-parse)");
    else if (rc == 0)
        SX_LOG("packageinfo.vdf: already corrupted or not found (ok)");
    else
        SX_WARN("packageinfo.vdf: patch failed");
}



static int newest_sigdb_in_dir(const char *dir, char *buf, size_t buf_size) {
    DIR *d = opendir(dir);
    if (!d) return -1;

    uint64_t best = 0;
    char best_path[512] = {0};
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        const char *n = ent->d_name;
        size_t nl = strlen(n);
        if (nl < 6 || strcmp(n + nl - 5, ".json") != 0) continue;

        char *end = NULL;
        uint64_t v = strtoull(n, &end, 10);
        if (v == 0 || end != n + nl - 5) continue;

        char path[512];
        snprintf(path, sizeof(path), "%s/%s", dir, n);
        if (v >= best) {
            best = v;
            strncpy(best_path, path, sizeof(best_path) - 1);
            best_path[sizeof(best_path) - 1] = '\0';
        }
    }
    closedir(d);

    if (!best_path[0]) return -1;
    strncpy(buf, best_path, buf_size - 1);
    buf[buf_size - 1] = '\0';
    return 0;
}

static void
get_sigdb_path(char *buf, size_t buf_size) {
    const char *env = getenv("MACSTEAM_SIG");
    if (env && env[0]) {
        strncpy(buf, env, buf_size - 1);
        buf[buf_size - 1] = '\0';
        return;
    }

    const char *home = sx_resolve_home();
    if (!home) home = "/tmp";

    char dir[512];
    sx_macsteam_support_path(dir, sizeof(dir), home, "signatures/macos.arm64");

    if (newest_sigdb_in_dir(dir, buf, buf_size) == 0)
        return;

    snprintf(buf, buf_size, "%s/<none>.json", dir);
}

static int steamclient_already_loaded(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *img = _dyld_get_image_name(i);
        if (img && strstr(img, STEAMCLIENT_DYLIB))
            return 1;
    }
    return 0;
}

static void arm_late_injection_reconcile(const sx_resolve_result_t *resolved,
                                         const sx_config_t *cfg) {
    sx_reconcile_set_addrs(
        sx_resolve_find(resolved, "CSteamEngine::SwitchAppPackageCache__anchor_for_engine_global_ref__inferred"),
        sx_resolve_find(resolved, "CPackageInfoCache::ClearMap"),
        sx_resolve_find(resolved, "CPackageInfoCache::ReadFromDisk"));

    sx_reconcile_set_library_refresh_fns(
        sx_resolve_find(resolved, "CUserAppManager::MarkAppDirty"),
        sx_resolve_find(resolved, "CUserAppManager::RecomputeSubscribedApps"),
        sx_resolve_find(resolved, "CUserAppManager::EmitAppLicensesChanged"));

    sx_reconcile_set_library_refresh_apps(cfg->app_ids, cfg->app_count);

    sx_reconcile_arm_library_refresh();

    sx_reconcile_arm_after_inject();
}

static void *loader_worker(void *unused) {
    (void)unused;

    int late_injection = steamclient_already_loaded();
    if (late_injection)
        SX_LOG("LATE injection detected (%s already resident). "
               "Package-cache reconcile will run after hooks install",
               STEAMCLIENT_DYLIB);

    SX_LOG("waiting for %s to load...", STEAMCLIENT_DYLIB);

    const struct mach_header_64 *mh = NULL;
    intptr_t slide = 0;
    char dylib_path[1024] = {0};

    if (sx_wait_for_image_ex(STEAMCLIENT_DYLIB, WAIT_TIMEOUT_MS, &mh, &slide,
                             dylib_path, sizeof(dylib_path)) != 0) {
        SX_LOG("%s not found after %d ms (bootstrapper phase, "
               "hooks will install in relaunched client)", STEAMCLIENT_DYLIB, WAIT_TIMEOUT_MS);
        return NULL;
    }

    uintptr_t text_base = 0;
    size_t text_size = 0;

    if (sx_get_segment(mh, slide, "__TEXT", &text_base, &text_size) != 0) {
        SX_ERR("__TEXT segment not found in %s", STEAMCLIENT_DYLIB);
        return NULL;
    }

    SX_LOG("%s loaded: __TEXT @ 0x%lx (%zu bytes), slide=0x%lx",
           STEAMCLIENT_DYLIB, (unsigned long)text_base,
           text_size, (unsigned long)slide);

    static sx_config_t cfg = {0};

    char config_path[512];
    sx_file_config_path(config_path, sizeof(config_path));

    if (sx_config_load(config_path, &cfg) != 0) {
        SX_WARN("config not loaded from %s, running with no managed apps", config_path);
    } else {
        SX_LOG("config loaded: %d apps, %d packages, %d depot key groups",
               cfg.app_count, cfg.pkg_count, cfg.dk_count);
    }

    sx_sigdb_t sigdb = {0};

    char sig_path[512];
    get_sigdb_path(sig_path, sizeof(sig_path));

    if (sx_sigdb_load(sig_path, &sigdb) != 0) {
        SX_ERR("failed to load signature database from %s", sig_path);
        sx_config_free(&cfg);
        return NULL;
    }

    sx_resolve_result_t resolved = {0};

    int resolved_count = sx_resolve_all_ex(mh, slide, dylib_path, &sigdb, &resolved);
    SX_LOG("signatures: %d/%d resolved", resolved_count, sigdb.sig_count);

    sx_config_current = &cfg;

    int total = 0;
    int installed = sx_hooks_install_all(&resolved, &total);

    SX_LOG("=== macsteam ready: %d/%d hooks installed ===", installed, total);

    if (installed == 0)
        SX_WARN("no hooks installed, check signature database and config");

    // On late injection GetSubscribedApps already occured
    sx_hooks_apps_force_ready();

    if (late_injection)
        arm_late_injection_reconcile(&resolved, &cfg);

    sx_resolve_result_free(&resolved);
    sx_sigdb_free(&sigdb);

    return NULL;
}

__attribute__((constructor))
static void sx_init(void) {
    sx_log_init();

    // Loading into helper processes breaks CCrossProcessPipe.
    {
        const char *pn = getprogname();
        if (!pn || strcmp(pn, "steam_osx") != 0) {
            SX_LOG("macsteam inert in helper process '%s' (pid %d), not steam_osx",
                   pn ? pn : "(null)", getpid());
            return;
        }
    }

    remove_crash_sentinel();
    sx_whatsnew_patch_installed_css();

    SX_LOG("macsteam loaded into %s (pid %d)", getprogname(), getpid());

    corrupt_packageinfo_vdf();

    pthread_t t;
    if (pthread_create(&t, NULL, loader_worker, NULL) == 0) {
        pthread_detach(t);
    } else {
        SX_ERR("failed to create loader thread");
    }
}

__attribute__((destructor))
static void sx_fini(void) {
    SX_LOG("macsteam unloading, leaving hooks in place (OS reclaims on exit)");
}
