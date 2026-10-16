// Nukes "What's New" ad shelf. Valve: fuck you for not letting me turn your ad-junk off

#include "../util/log.h"
#include "../util/file.h"
#include "../config/config.h"

#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/syscall.h>
#include <stdio.h>
#include <errno.h>
#include <dirent.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(uintptr_t)&_replacement, \
        (const void *)(uintptr_t)&_replacee \
    }

// Raw syscalls so we don't recurse back into our own interpose
_Pragma("clang diagnostic push")
_Pragma("clang diagnostic ignored \"-Wdeprecated-declarations\"")
static int real_open(const char *path, int oflag, mode_t mode) {
    return (int)syscall(SYS_open, path, oflag, mode);
}
static int real_openat(int dirfd, const char *path, int oflag, mode_t mode) {
    return (int)syscall(SYS_openat, dirfd, path, oflag, mode);
}
_Pragma("clang diagnostic pop")

static int g_enabled = -1;
static pthread_once_t g_cfg_once = PTHREAD_ONCE_INIT;

static void load_flag(void) {
    char path[1024];
    sx_file_config_path(path, sizeof(path));

    sx_config_t cfg;
    memset(&cfg, 0, sizeof(cfg));
    if (sx_config_load(path, &cfg) == 0) {
        g_enabled = cfg.hide_whats_new ? 1 : 0;
        sx_config_free(&cfg);
    } else {
        g_enabled = 0;
    }
    SX_LOG("What's New hider: %s (config %s)",
           g_enabled ? "ENABLED" : "disabled", path);
}

// Prevents infinite recursion when config load triggers open()
static _Thread_local int g_in_flag_load;

static int whatsnew_enabled(void) {
    if (g_in_flag_load)
        return 0;
    g_in_flag_load = 1;
    pthread_once(&g_cfg_once, load_flag);
    g_in_flag_load = 0;
    return g_enabled == 1;
}

static int ends_with(const char *s, const char *suf) {
    size_t ls = strlen(s), lf = strlen(suf);
    return ls >= lf && memcmp(s + ls - lf, suf, lf) == 0;
}

static int should_patch(const char *path) {
    return path
        && strstr(path, "steamui") != NULL
        && ends_with(path, ".css");
}

static const char *FINGERPRINTS[] = {
    "linear-gradient(to top, #171d25",
    "padding:8px 0px 16px;display:flex;flex-direction:column;gap:24px",
};
static const char INJECT[] = ";display:none!important";

static char *transform_css(const char *src, size_t len, size_t *out_len) {
    size_t offsets[sizeof(FINGERPRINTS) / sizeof(FINGERPRINTS[0])];
    size_t count = 0;
    for (size_t i = 0; i < sizeof(FINGERPRINTS) / sizeof(FINGERPRINTS[0]); i++) {
        const char *fingerprint = FINGERPRINTS[i];
        const char *hit = memmem(src, len, fingerprint, strlen(fingerprint));
        if (!hit)
            continue;
        const char *end = memchr(hit, '}', (size_t)(src + len - hit));
        if (!end)
            continue;
        if (memmem(hit, (size_t)(end - hit), INJECT, sizeof(INJECT) - 1))
            continue;
        size_t offset = (size_t)(end - src);
        if (count == 0 || offsets[count - 1] != offset)
            offsets[count++] = offset;
    }
    if (count == 0)
        return NULL;
    if (count == 2 && offsets[0] > offsets[1]) {
        size_t tmp = offsets[0];
        offsets[0] = offsets[1];
        offsets[1] = tmp;
    }

    size_t inj = sizeof(INJECT) - 1;
    char *out = (char *)malloc(len + count * inj);
    if (!out)
        return NULL;

    size_t src_pos = 0;
    size_t out_pos = 0;
    for (size_t i = 0; i < count; i++) {
        size_t chunk = offsets[i] - src_pos;
        memcpy(out + out_pos, src + src_pos, chunk);
        out_pos += chunk;
        memcpy(out + out_pos, INJECT, inj);
        out_pos += inj;
        src_pos = offsets[i];
    }
    memcpy(out + out_pos, src + src_pos, len - src_pos);
    *out_len = len + count * inj;
    return out;
}

static char *read_all(int fd, size_t *out_len) {
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0 || st.st_size > 32 * 1024 * 1024)
        return NULL;
    size_t sz = (size_t)st.st_size;
    char *buf = (char *)malloc(sz);
    if (!buf)
        return NULL;
    size_t got = 0;
    while (got < sz) {
        ssize_t n = read(fd, buf + got, sz - got);
        if (n <= 0) { free(buf); return NULL; }
        got += (size_t)n;
    }
    *out_len = sz;
    return buf;
}

static int make_patched_fd(const char *path) {
    int src_fd = real_open(path, O_RDONLY, 0);
    if (src_fd < 0)
        return -1;

    size_t len = 0;
    char *src = read_all(src_fd, &len);
    close(src_fd);
    if (!src)
        return -1;

    size_t out_len = 0;
    char *out = transform_css(src, len, &out_len);
    free(src);
    if (!out)
        return -1;

    const char *home = sx_resolve_home();
    if (!home) home = "/tmp";
    char dir[1024];
    sx_macsteam_support_path(dir, sizeof(dir), home, NULL);
    mkdir(dir, 0755);

    char tmpl[1100];
    snprintf(tmpl, sizeof(tmpl), "%s/whatsnew.XXXXXX", dir);
    int tfd = mkstemp(tmpl);
    if (tfd < 0) { free(out); return -1; }
    unlink(tmpl);

    size_t wrote = 0;
    while (wrote < out_len) {
        ssize_t n = write(tfd, out + wrote, out_len - wrote);
        if (n <= 0) { free(out); close(tfd); return -1; }
        wrote += (size_t)n;
    }
    free(out);

    if (lseek(tfd, 0, SEEK_SET) != 0) { close(tfd); return -1; }

    SX_LOG_ONCE("What's New: served patched CSS (%s)", path);
    return tfd;
}

static int patch_css_file(const char *path) {
    int src_fd = real_open(path, O_RDONLY, 0);
    if (src_fd < 0)
        return -1;

    struct stat st;
    if (fstat(src_fd, &st) != 0) {
        close(src_fd);
        return -1;
    }

    size_t len = 0;
    char *src = read_all(src_fd, &len);
    close(src_fd);
    if (!src)
        return -1;

    size_t out_len = 0;
    char *out = transform_css(src, len, &out_len);
    free(src);
    if (!out)
        return 0;

    char tmpl[1200];
    snprintf(tmpl, sizeof(tmpl), "%s.macsteam.XXXXXX", path);
    int fd = mkstemp(tmpl);
    if (fd < 0) {
        free(out);
        return -1;
    }
    fchmod(fd, st.st_mode & 0777);

    size_t wrote = 0;
    while (wrote < out_len) {
        ssize_t n = write(fd, out + wrote, out_len - wrote);
        if (n <= 0)
            break;
        wrote += (size_t)n;
    }
    free(out);

    int sync_rc = wrote == out_len ? fsync(fd) : -1;
    int close_rc = close(fd);
    int rc = (wrote == out_len && sync_rc == 0 && close_rc == 0
              && rename(tmpl, path) == 0) ? 1 : -1;
    if (rc < 0)
        unlink(tmpl);
    return rc;
}

void sx_whatsnew_patch_installed_css(void) {
    char config_path[1024];
    sx_file_config_path(config_path, sizeof(config_path));

    sx_config_t cfg;
    memset(&cfg, 0, sizeof(cfg));
    if (sx_config_load(config_path, &cfg) != 0)
        return;
    int enabled = cfg.hide_whats_new;
    sx_config_free(&cfg);
    if (!enabled)
        return;

    const char *home = sx_resolve_home();
    if (!home)
        return;
    char dir_path[1024];
    snprintf(dir_path, sizeof(dir_path),
             "%s/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamui/css",
             home);

    DIR *dir = opendir(dir_path);
    if (!dir)
        return;

    int patched = 0;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (!ends_with(entry->d_name, ".css"))
            continue;
        char path[1200];
        snprintf(path, sizeof(path), "%s/%s", dir_path, entry->d_name);
        int rc = patch_css_file(path);
        if (rc > 0)
            patched++;
        else if (rc < 0)
            SX_WARN("What's New: failed to patch %s", path);
    }
    closedir(dir);
    SX_LOG("What's New: patched %d installed CSS file(s)", patched);
}

static int is_ro(int oflag) {
    return (oflag & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC | O_APPEND)) == 0;
}

static int sx_open(const char *path, int oflag, ...) {
    mode_t mode = 0;
    if (oflag & O_CREAT) {
        va_list ap; va_start(ap, oflag);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    if (is_ro(oflag) && should_patch(path) && whatsnew_enabled()) {
        int fd = make_patched_fd(path);
        if (fd >= 0)
            return fd;
    }

    return real_open(path, oflag, mode);
}

static int sx_openat(int dirfd, const char *path, int oflag, ...) {
    mode_t mode = 0;
    if (oflag & O_CREAT) {
        va_list ap; va_start(ap, oflag);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    if (path && path[0] == '/' && is_ro(oflag)
        && should_patch(path) && whatsnew_enabled()) {
        int fd = make_patched_fd(path);
        if (fd >= 0)
            return fd;
    }

    return real_openat(dirfd, path, oflag, mode);
}

static int fopen_mode_to_oflag(const char *mode) {
    if (!mode || !mode[0])
        return -1;
    int oflag;
    switch (mode[0]) {
        case 'r': oflag = O_RDONLY; break;
        case 'w': oflag = O_WRONLY | O_CREAT | O_TRUNC; break;
        case 'a': oflag = O_WRONLY | O_CREAT | O_APPEND; break;
        default:  return -1;
    }
    for (const char *p = mode + 1; *p; ++p) {
        if (*p == '+') {
            oflag = (oflag & ~(O_RDONLY | O_WRONLY)) | O_RDWR;
        } else if (*p == 'x') {
            oflag |= O_EXCL;
        } else if (*p == 'e') {
            oflag |= O_CLOEXEC;
        }
    }
    return oflag;
}

static FILE *sx_fopen(const char *path, const char *mode) {
    int oflag = fopen_mode_to_oflag(mode);
    if (!path || oflag < 0) {
        errno = EINVAL;
        return NULL;
    }

    int is_read = (oflag & (O_WRONLY | O_RDWR)) == 0;
    if (is_read && should_patch(path) && whatsnew_enabled()) {
        int pfd = make_patched_fd(path);
        if (pfd >= 0) {
            FILE *fp = fdopen(pfd, mode);
            if (fp)
                return fp;
            close(pfd);
        }
    }

    int fd = real_open(path, oflag, 0666);
    if (fd < 0)
        return NULL;
    FILE *fp = fdopen(fd, mode);
    if (!fp) {
        int e = errno;
        close(fd);
        errno = e;
    }
    return fp;
}

DYLD_INTERPOSE(sx_open, open);
DYLD_INTERPOSE(sx_openat, openat);
DYLD_INTERPOSE(sx_fopen, fopen);
