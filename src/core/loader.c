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
#include <spawn.h>
#include <fcntl.h>

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




/* Steam's installed manifests are KeyValues text: "version" "1792618285". */
static uint64_t manifest_build_version(const uint8_t *buf, size_t len) {
    static const char key[] = "\"version\"";
    const size_t key_len = sizeof(key) - 1;
    if (!buf || len < key_len) return 0;

    for (size_t i = 0; i + key_len <= len; i++) {
        if (memcmp(buf + i, key, key_len) != 0) continue;
        size_t p = i + key_len;
        while (p < len && (buf[p] == ' ' || buf[p] == '\t' ||
                           buf[p] == '\r' || buf[p] == '\n'))
            p++;
        if (p >= len || buf[p++] != '"') continue;

        uint64_t build = 0;
        size_t digits = 0;
        while (p < len && buf[p] >= '0' && buf[p] <= '9') {
            uint64_t digit = (uint64_t)(buf[p++] - '0');
            if (build > (UINT64_MAX - digit) / 10) return 0;
            build = build * 10 + digit;
            digits++;
        }
        if (digits && p < len && buf[p] == '"') return build;
    }
    return 0;
}

static uint64_t running_steam_build(void) {
    const char *home = sx_resolve_home();
    if (!home) return 0;

    /* Keep this order in sync with MacCrab.detectedVersion(). */
    static const char *manifests[] = {
        "steam_client_signed-2_osx.manifest",
        "steam_client_signed_osx.manifest",
        "steam_client_osx.manifest",
    };
    for (size_t i = 0; i < sizeof(manifests) / sizeof(manifests[0]); i++) {
        char path[1024];
        int n = snprintf(path, sizeof(path),
                         "%s/Library/Application Support/Steam/Steam.AppBundle/"
                         "Steam/Contents/MacOS/package/%s", home, manifests[i]);
        if (n < 0 || (size_t)n >= sizeof(path)) continue;

        size_t len = 0;
        uint8_t *data = sx_slurp_file(path, &len);
        if (!data) continue;
        uint64_t build = manifest_build_version(data, len);
        free(data);
        if (build) return build;
    }
    return 0;
}

static int sigdb_for_build(const char *dir, uint64_t build,
                           char *buf, size_t buf_size) {
    if (!build) return -1;
    char path[512];
    int n = snprintf(path, sizeof(path), "%s/%llu.json", dir,
                     (unsigned long long)build);
    if (n < 0 || (size_t)n >= sizeof(path) || access(path, R_OK) != 0)
        return -1;
    n = snprintf(buf, buf_size, "%s", path);
    return (n >= 0 && (size_t)n < buf_size) ? 0 : -1;
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
get_sigdb_path(char *buf, size_t buf_size, uint64_t build) {
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

    if (build && sigdb_for_build(dir, build, buf, buf_size) == 0)
        return;

    if (build)
        SX_WARN("sigdb: no profile for Steam build %llu in %s; "
                "falling back to newest available",
                (unsigned long long)build, dir);

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

static void setup_library_refresh(const sx_resolve_result_t *resolved,
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

    sx_reconcile_enable_live_reload();
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

    uint64_t running_build = running_steam_build();
    char sig_path[512];
    get_sigdb_path(sig_path, sizeof(sig_path), running_build);

    if (sx_sigdb_load(sig_path, &sigdb) != 0) {
        SX_ERR("failed to load signature database from %s", sig_path);
        sx_config_free(&cfg);
        return NULL;
    }

    if (running_build && sigdb.steam_build &&
        sigdb.steam_build != running_build) {
        SX_WARN("sigdb: profile targets Steam build %llu but running client is "
                "%llu; hook addresses may be wrong",
                (unsigned long long)sigdb.steam_build,
                (unsigned long long)running_build);
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

    setup_library_refresh(&resolved, &cfg);
    if (late_injection)
        sx_reconcile_arm_after_inject();

    sx_resolve_result_free(&resolved);
    sx_sigdb_free(&sigdb);

    return NULL;
}

// The config app registers its actual executable location, so relocated installs
// work too. Run its bridge without an application window or injected environment.
static void start_hubcap_bridge(void) {
    const char *home = sx_resolve_home();
    if (!home) return;
    char path[1024], executable[4096] = {0};
    sx_macsteam_support_path(path, sizeof(path), home, "hubcap-bridge.path");
    FILE *file = fopen(path, "r");
    if (!file) return;
    size_t len = fread(executable, 1, sizeof(executable) - 1, file);
    fclose(file);
    if (!len || executable[0] != '/' || access(executable, X_OK) != 0) return;
    // steamui checks the marker in the unbundled client working directory.
    snprintf(path, sizeof(path), "%s/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/.cef-enable-remote-debugging", home);
    int fd = open(path, O_WRONLY | O_CREAT, 0600);
    if (fd >= 0) close(fd);
    extern char **environ;
    size_t count = 0;
    while (environ[count]) count++;
    char **env = calloc(count + 1, sizeof(char *));
    if (!env) return;
    size_t n = 0;
    for (size_t i = 0; i < count; i++) {
        if (strncmp(environ[i], "DYLD_INSERT_LIBRARIES=", sizeof("DYLD_INSERT_LIBRARIES=") - 1) == 0 ||
            strncmp(environ[i], "STEAM_APP_BUNDLE_PATH=", sizeof("STEAM_APP_BUNDLE_PATH=") - 1) == 0) continue;
        env[n++] = environ[i];
    }
    char *args[] = {executable, "--hubcap-store-bridge", NULL};
    pid_t pid;
    int rc = posix_spawn(&pid, executable, NULL, NULL, args, env);
    free(env);
    if (rc != 0) SX_WARN("[hubcap] could not start Store bridge: %s", strerror(rc));
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

    start_hubcap_bridge();
    // sp.js patch order matters. The Cloud error patcher keys its recovery copy by the hash of
    // the file it leaves behind, so anything that edits sp.js after it orphans that copy and the
    // next launch tries to patch an already-patched bundle. The shared-library patch is a
    // fixed-size edit that is a no-op once applied, so it runs first. scripts/tests/ui_patch_order.py
    // enforces this order.
    sx_librarysharing_patch_installed_js();
    remove_crash_sentinel();
    sx_clouderrors_patch_installed_js();
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
