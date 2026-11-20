// In-memory Steam UI patching in the main Steam Helper process.
// Interposes open/openat/fopen and chains through plain libc calls so outer/inner
// DYLD_INSERT_LIBRARIES interposers compose cleanly without touching files on disk.

#include "steamui.h"
#include "../config/config.h"
#include "../util/file.h"
#include "../util/log.h"

#include <crt_externs.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(uintptr_t)&_replacement, \
        (const void *)(uintptr_t)&_replacee \
    }

#define STEAMUI_MAX_FILE (64 * 1024 * 1024)

static _Thread_local int g_in_interposer = 0;

static pthread_once_t g_proc_once = PTHREAD_ONCE_INIT;
static int g_is_main_helper = 0;

static void detect_process_once(void) {
    const char *pn = getprogname();
    if (!pn || strcmp(pn, "Steam Helper") != 0)
        return;

    int *argcp = _NSGetArgc();
    char ***argvp = _NSGetArgv();
    if (!argcp || !argvp || !*argvp)
        return;

    int argc = *argcp;
    char **argv = *argvp;
    for (int i = 1; i < argc; i++) {
        if (argv[i] && strncmp(argv[i], "--type=", 7) == 0)
            return;
    }
    g_is_main_helper = 1;
}

static int is_main_helper(void) {
    pthread_once(&g_proc_once, detect_process_once);
    return g_is_main_helper;
}

static pthread_once_t g_cfg_once = PTHREAD_ONCE_INIT;
static int g_hide_whats_new = 0;
static int g_hide_cloud_errors = 0;

static void load_config_once(void) {
    char config_path[1024];
    sx_file_config_path(config_path, sizeof(config_path));
    sx_config_t cfg;
    memset(&cfg, 0, sizeof(cfg));
    if (sx_config_load(config_path, &cfg) == 0) {
        g_hide_whats_new = cfg.hide_whats_new ? 1 : 0;
        g_hide_cloud_errors = cfg.hide_cloud_errors ? 1 : 0;
        sx_config_free(&cfg);
    }
}

static void ensure_config_loaded(void) {
    pthread_once(&g_cfg_once, load_config_once);
}

static int should_inspect_path(const char *path, int *is_css, int *is_sp_js) {
    const char *ui = strstr(path, "/steamui/");
    if (!ui)
        return 0;

    const char *rel = ui + 9;
    if (strncmp(rel, "localization/", 13) == 0 ||
        strncmp(rel, "libraries/", 10) == 0) {
        return 0;
    }

    size_t len = strlen(path);
    if (len >= 4 && strcmp(path + len - 4, ".css") == 0) {
        *is_css = 1;
        *is_sp_js = 0;
        return 1;
    }
    if (len >= 3 && strcmp(path + len - 3, ".js") == 0) {
        const char *base = strrchr(path, '/');
        base = base ? base + 1 : path;
        *is_css = 0;
        *is_sp_js = (strcmp(base, "sp.js") == 0);
        return 1;
    }
    return 0;
}

// Read via plain open() so any lower interposer in DYLD_INSERT_LIBRARIES is preserved.
// Returns a NUL-terminated heap buffer of *out_len bytes, or NULL on failure.
static char *read_chained_file(const char *path, size_t *out_len) {
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return NULL;

    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) ||
        st.st_size <= 0 || st.st_size > STEAMUI_MAX_FILE) {
        close(fd);
        return NULL;
    }

    size_t total = (size_t)st.st_size;
    char *buf = malloc(total + 1);
    if (!buf) {
        close(fd);
        return NULL;
    }

    size_t done = 0;
    while (done < total) {
        ssize_t n = read(fd, buf + done, total - done);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            free(buf);
            close(fd);
            return NULL;
        }
        if (n == 0) {
            free(buf);
            close(fd);
            return NULL;
        }
        done += (size_t)n;
    }

    close(fd);
    buf[total] = '\0';
    *out_len = total;
    return buf;
}

static int spill_to_temp(const char *bytes, size_t len) {
    const char *home = sx_resolve_home();
    if (!home)
        return -1;

    char tmpl[1024];
    sx_macsteam_support_path(tmpl, sizeof(tmpl), home, "steamui.XXXXXX");

    char *slash = strrchr(tmpl, '/');
    if (slash && slash != tmpl) {
        char dir[1024];
        size_t dlen = (size_t)(slash - tmpl);
        if (dlen < sizeof(dir)) {
            memcpy(dir, tmpl, dlen);
            dir[dlen] = '\0';
            mkdir(dir, 0755);
        }
    }

    int fd = mkstemp(tmpl);
    if (fd < 0)
        return -1;
    unlink(tmpl);

    size_t done = 0;
    while (done < len) {
        ssize_t n = write(fd, bytes + done, len - done);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            close(fd);
            return -1;
        }
        if (n == 0) {
            close(fd);
            return -1;
        }
        done += (size_t)n;
    }

    if (lseek(fd, 0, SEEK_SET) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

typedef struct {
    int valid;
    char sp_path[2048];
    off_t sp_size;
    time_t sp_mtime_sec;
    long sp_mtime_nsec;
    int hide_whats_new;
    size_t count;
    char hashes[4][64];
} sx_key_cache_t;

static pthread_mutex_t g_keys_mu = PTHREAD_MUTEX_INITIALIZER;
static sx_key_cache_t g_key_cache;

static size_t get_css_hashes(const char *css_path, char out_hashes[4][64]) {
    const char *ui = strstr(css_path, "/steamui/");
    if (!ui)
        return 0;

    size_t dir_len = (size_t)(ui - css_path) + 9; // includes "/steamui/"
    char sp_path[2048];
    if (dir_len + 6 > sizeof(sp_path))
        return 0;
    memcpy(sp_path, css_path, dir_len);
    memcpy(sp_path + dir_len, "sp.js", 6);

    struct stat disk_st;
    if (stat(sp_path, &disk_st) != 0)
        return 0;

    pthread_mutex_lock(&g_keys_mu);

    // Key the cache by the on-disk sp.js stat so re-resolution triggers on Steam updates.
    if (!g_key_cache.valid ||
        strcmp(g_key_cache.sp_path, sp_path) != 0 ||
        g_key_cache.sp_size != disk_st.st_size ||
        g_key_cache.sp_mtime_sec != disk_st.st_mtimespec.tv_sec ||
        g_key_cache.sp_mtime_nsec != disk_st.st_mtimespec.tv_nsec ||
        g_key_cache.hide_whats_new != g_hide_whats_new) {

        size_t sp_len = 0;
        char *sp_js = read_chained_file(sp_path, &sp_len);
        if (!sp_js) {
            pthread_mutex_unlock(&g_keys_mu);
            return 0;
        }

        const char *keys[4];
        size_t nkeys = 0;
        keys[nkeys++] = "SharedLibrary";
        keys[nkeys++] = "OldSharingWarning";
        if (g_hide_whats_new) {
            keys[nkeys++] = "LibraryHomeWhatsNew";
            keys[nkeys++] = "UpdatesContainer";
        }

        char resolved[4][64];
        int nres = sx_steamui_resolve_keys(sp_js, sp_len, keys, nkeys, resolved);
        free(sp_js);

        g_key_cache.count = 0;
        for (size_t i = 0; i < nkeys; i++) {
            if (resolved[i][0] != '\0') {
                memcpy(g_key_cache.hashes[g_key_cache.count], resolved[i], 64);
                g_key_cache.count++;
            }
        }
        snprintf(g_key_cache.sp_path, sizeof(g_key_cache.sp_path), "%s", sp_path);
        g_key_cache.sp_size = disk_st.st_size;
        g_key_cache.sp_mtime_sec = disk_st.st_mtimespec.tv_sec;
        g_key_cache.sp_mtime_nsec = disk_st.st_mtimespec.tv_nsec;
        g_key_cache.hide_whats_new = g_hide_whats_new;
        g_key_cache.valid = 1;

        SX_LOG("steamui: resolved %d/%zu CSS keys from %s", nres, nkeys, sp_path);
    }

    size_t count = g_key_cache.count;
    for (size_t i = 0; i < count; i++)
        memcpy(out_hashes[i], g_key_cache.hashes[i], 64);

    pthread_mutex_unlock(&g_keys_mu);
    return count;
}

static int try_serve_inner(const char *path, int oflag, int is_css, int is_sp_js) {
    ensure_config_loaded();

    if (!is_css && !(is_sp_js && g_hide_cloud_errors))
        return -1;

    size_t raw_len = 0;
    char *raw = read_chained_file(path, &raw_len);
    if (!raw)
        return -1;

    char *patched = NULL;
    size_t patched_len = 0;

    if (is_css) {
        char hashes[4][64];
        size_t count = get_css_hashes(path, hashes);
        if (count > 0) {
            const char *ptrs[4];
            for (size_t i = 0; i < count; i++)
                ptrs[i] = hashes[i];
            patched = sx_steamui_css_hide(raw, raw_len, ptrs, count, &patched_len);
        }
    } else if (is_sp_js && g_hide_cloud_errors) {
        patched = sx_steamui_cloud_transform(raw, raw_len, &patched_len);
    }

    free(raw);
    if (!patched)
        return -1;

    int fd = spill_to_temp(patched, patched_len);
    free(patched);
    if (fd < 0)
        return -1;

    if (oflag & O_CLOEXEC)
        fcntl(fd, F_SETFD, FD_CLOEXEC);

    if (is_css) {
        SX_LOG_ONCE("steamui: served patched CSS (%s) to %s pid %d",
                    path, getprogname(), getpid());
    } else {
        SX_LOG_ONCE("steamui: served patched sp.js (Cloud errors hidden) to %s pid %d",
                    getprogname(), getpid());
    }
    return fd;
}

static int try_serve(const char *path, int oflag) {
    if (!path)
        return -1;
    if ((oflag & O_ACCMODE) != O_RDONLY ||
        (oflag & (O_CREAT | O_TRUNC | O_APPEND | O_DIRECTORY)) != 0) {
        return -1;
    }

    int is_css = 0;
    int is_sp_js = 0;
    if (!should_inspect_path(path, &is_css, &is_sp_js))
        return -1;

    g_in_interposer = 1;
    int fd = try_serve_inner(path, oflag, is_css, is_sp_js);
    g_in_interposer = 0;
    return fd;
}

static int sx_open(const char *path, int oflag, ...) {
    va_list ap;
    va_start(ap, oflag);
    mode_t mode = (oflag & O_CREAT) ? (mode_t)va_arg(ap, int) : 0;
    va_end(ap);

    if (is_main_helper() && !g_in_interposer) {
        int served = try_serve(path, oflag);
        if (served >= 0)
            return served;
    }
    if (oflag & O_CREAT)
        return open(path, oflag, mode);
    return open(path, oflag);
}

static int sx_openat(int dirfd, const char *path, int oflag, ...) {
    va_list ap;
    va_start(ap, oflag);
    mode_t mode = (oflag & O_CREAT) ? (mode_t)va_arg(ap, int) : 0;
    va_end(ap);

    if (path && path[0] == '/' && is_main_helper() && !g_in_interposer) {
        int served = try_serve(path, oflag);
        if (served >= 0)
            return served;
    }
    if (oflag & O_CREAT)
        return openat(dirfd, path, oflag, mode);
    return openat(dirfd, path, oflag);
}

static int fopen_readonly_flags(const char *mode) {
    if (!mode || mode[0] != 'r')
        return -1;
    int oflag = O_RDONLY;
    for (const char *p = mode + 1; *p; p++) {
        if (*p == '+')
            return -1;
        if (*p == 'e')
            oflag |= O_CLOEXEC;
    }
    return oflag;
}

static FILE *sx_fopen(const char *path, const char *mode) {
    if (path && mode && is_main_helper() && !g_in_interposer) {
        int oflag = fopen_readonly_flags(mode);
        if (oflag >= 0) {
            int served = try_serve(path, oflag);
            if (served >= 0) {
                FILE *fp = fdopen(served, mode);
                if (fp)
                    return fp;
                close(served);
            }
        }
    }
    return fopen(path, mode);
}

DYLD_INTERPOSE(sx_open, open);
DYLD_INTERPOSE(sx_openat, openat);
DYLD_INTERPOSE(sx_fopen, fopen);
