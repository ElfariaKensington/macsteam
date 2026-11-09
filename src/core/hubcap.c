// Store-page bridge and live config refresh.
#include "hubcap.h"
#include "../config/config.h"
#include "../core/reconcile.h"
#include "../util/file.h"
#include "../util/log.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

#define HUB_REQUEST_NAME   "hubcap-refresh.request"
#define HUB_ACK_NAME       "hubcap-refresh.ack"
#define HUB_PATH_NAME      "hubcap-bridge.path"
#define HUB_LOCK_NAME      "hubcap-bridge.lock"
#define HUB_TOKEN_LEN      36
#define HUB_POLL_MS        500

static atomic_int g_ready;
static pthread_t g_thread;
static char g_last_token[HUB_TOKEN_LEN + 1];

static void hub_path(char *buf, size_t size, const char *name) {
    const char *home = sx_resolve_home();
    if (!home) home = "/tmp";
    sx_macsteam_support_path(buf, size, home, name);
}

static void ensure_cef_marker(void) {
    const char *home = sx_resolve_home();
    if (!home) return;
    char dir[1024];
    snprintf(dir, sizeof(dir),
             "%s/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS",
             home);
    mkdir(dir, 0755);
    char path[1200];
    snprintf(path, sizeof(path), "%s/.cef-enable-remote-debugging", dir);
    int fd = open(path, O_CREAT | O_WRONLY, 0600);
    if (fd >= 0) close(fd);
}

static int read_bridge_path(char *out, size_t size) {
    char path[1024];
    hub_path(path, sizeof(path), HUB_PATH_NAME);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    size_t n = fread(out, 1, size - 1, f);
    fclose(f);
    if (n == 0 || n >= size) return 0;
    out[n] = '\0';
    while (n > 0 && (out[n - 1] == '\n' || out[n - 1] == '\r' || out[n - 1] == ' '))
        out[--n] = '\0';
    return out[0] == '/' && access(out, X_OK) == 0;
}

static char **clean_environment(void) {
    size_t count = 0;
    while (environ[count]) count++;
    char **env = calloc(count + 1, sizeof(char *));
    if (!env) return NULL;
    size_t out = 0;
    for (size_t i = 0; i < count; i++) {
        const char *e = environ[i];
        if (strncmp(e, "DYLD_INSERT_LIBRARIES=", 22) == 0) continue;
        if (strncmp(e, "STEAM_APP_BUNDLE_PATH=", 22) == 0) continue;
        env[out++] = environ[i];
    }
    env[out] = NULL;
    return env;
}

static int bridge_already_running(void) {
    char path[1024];
    hub_path(path, sizeof(path), HUB_LOCK_NAME);
    int fd = open(path, O_CREAT | O_RDWR, 0600);
    if (fd < 0) return 0;
    int held = flock(fd, LOCK_EX | LOCK_NB) != 0;
    if (!held) flock(fd, LOCK_UN);
    close(fd);
    return held;
}

static void spawn_bridge(void) {
    if (bridge_already_running()) {
        SX_LOG("[hubcap] store bridge already running; not spawning another");
        return;
    }

    char exe[1024];
    if (!read_bridge_path(exe, sizeof(exe))) {
        // The app normally writes the path on first launch. Keep a sensible fallback
        // so a freshly installed app still works before it has ever been opened.
        snprintf(exe, sizeof(exe),
                 "/Applications/macSteam Config.app/Contents/MacOS/MacsteamApp");
        if (access(exe, X_OK) != 0) {
            SX_WARN("[hubcap] config app not found, store bridge not started");
            return;
        }
    }

    ensure_cef_marker();

    char **env = clean_environment();
    if (!env) return;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    char *argv[] = { exe, "--hubcap-store-bridge", NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, exe, &actions, NULL, argv, env);
    posix_spawn_file_actions_destroy(&actions);
    free(env);

    if (rc == 0) {
        SX_LOG("[hubcap] store bridge started (pid %d)", (int)pid);
    } else {
        SX_WARN("[hubcap] could not start Store bridge: %s", strerror(rc));
    }
}

static int valid_token(const char *s) {
    if (strlen(s) != HUB_TOKEN_LEN) return 0;
    for (int i = 0; i < HUB_TOKEN_LEN; i++) {
        unsigned char c = (unsigned char)s[i];
        if (!(isxdigit(c) || c == '-')) return 0;
    }
    return 1;
}

static void write_ack(const char *token, const char *status, int app_count) {
    char path[1024], tmp[1120];
    hub_path(path, sizeof(path), HUB_ACK_NAME);
    snprintf(tmp, sizeof(tmp), "%s.%d.tmp", path, (int)getpid());

    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fprintf(f, "%s\n%s\n%d\n", token, status, app_count);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    if (rename(tmp, path) != 0) unlink(tmp);
}

static void process_request(const char *token) {
    if (!atomic_load(&g_ready)) return;

    char path[1024];
    sx_file_config_path(path, sizeof(path));
    sx_config_t *cfg = calloc(1, sizeof(*cfg));
    if (!cfg) return;

    if (sx_config_load(path, cfg) != 0) {
        SX_WARN("[hubcap] config reload failed; keeping the active config");
        write_ack(token, "error", 0);
        free(cfg);
        return;
    }

    sx_config_t *old = atomic_exchange_explicit(&sx_config_current, cfg,
                                                memory_order_acq_rel);
    (void)old; // Hooks may still be reading the old pointer; leaking one struct per
               // add is preferable to a use-after-free inside Steam.

    sx_reconcile_set_library_refresh_apps(cfg->app_ids, cfg->app_count);
    sx_reconcile_arm_after_inject();
    sx_reconcile_arm_library_refresh();

    SX_LOG("[hubcap] loaded %d apps for live library activation", cfg->app_count);
    write_ack(token, "ok", cfg->app_count);
}

static void *watcher(void *arg) {
    (void)arg;
    for (;;) {
        char request[1024];
        hub_path(request, sizeof(request), HUB_REQUEST_NAME);
        struct stat st;
        if (stat(request, &st) == 0 && st.st_size > 0 && st.st_size <= 128) {
            FILE *f = fopen(request, "r");
            if (f) {
                char token[HUB_TOKEN_LEN + 2] = {0};
                size_t n = fread(token, 1, HUB_TOKEN_LEN + 1, f);
                fclose(f);
                if (n > 0) token[n] = '\0';
                char *nl = strpbrk(token, "\r\n ");
                if (nl) *nl = '\0';
                if (valid_token(token) && strcmp(token, g_last_token) != 0 &&
                    atomic_load(&g_ready)) {
                    strncpy(g_last_token, token, sizeof(g_last_token) - 1);
                    process_request(token);
                }
            }
        }
        usleep(HUB_POLL_MS * 1000);
    }
    return NULL;
}

void sx_hubcap_set_ready(int ready) {
    atomic_store(&g_ready, ready ? 1 : 0);
}

void sx_hubcap_start(void) {
    spawn_bridge();
    if (pthread_create(&g_thread, NULL, watcher, NULL) == 0) {
        pthread_detach(g_thread);
    } else {
        SX_WARN("[hubcap] failed to create refresh watcher");
    }
}
