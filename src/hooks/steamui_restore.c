// One-time cleanup of old on-disk Steam UI patches (runs in steam_osx only).
#include "steamui.h"
#include "cloud_errors_legacy.h"
#include "../util/file.h"
#include "../util/log.h"

#include <CommonCrypto/CommonDigest.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define RESTORE_MAX_FILE (64 * 1024 * 1024)

static char *read_file_all(const char *path, size_t *out_len) {
    FILE *fp = fopen(path, "rb");
    if (!fp)
        return NULL;

    struct stat st;
    if (fstat(fileno(fp), &st) != 0 || !S_ISREG(st.st_mode) ||
        st.st_size <= 0 || st.st_size > RESTORE_MAX_FILE) {
        fclose(fp);
        return NULL;
    }

    size_t len = (size_t)st.st_size;
    char *buf = malloc(len + 1);
    if (!buf) {
        fclose(fp);
        return NULL;
    }

    size_t got = fread(buf, 1, len, fp);
    fclose(fp);
    if (got != len) {
        free(buf);
        return NULL;
    }
    buf[len] = '\0';
    *out_len = len;
    return buf;
}

static int save_atomic(const char *path, const char *data, size_t len, mode_t mode) {
    char tmp[4096];
    int n = snprintf(tmp, sizeof(tmp), "%s.XXXXXX", path);
    if (n < 0 || (size_t)n >= sizeof(tmp))
        return -1;

    int fd = mkstemp(tmp);
    if (fd < 0)
        return -1;

    size_t written = 0;
    while (written < len) {
        ssize_t r = write(fd, data + written, len - written);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (r == 0)
            break;
        written += (size_t)r;
    }

    int ok = (written == len) && (fchmod(fd, mode) == 0) && (fsync(fd) == 0);
    if (close(fd) != 0)
        ok = 0;
    if (ok && rename(tmp, path) == 0)
        return 0;

    unlink(tmp);
    return -1;
}

static int migrate_legacy(char *data, size_t len) {
    static const char marker[] = "null/*macsteam-cloud-error*/";
    if (!memmem(data, len, marker, sizeof(marker) - 1))
        return 0;

    int hits = 0;
    for (size_t i = 0; i < sizeof(legacy_patches) / sizeof(legacy_patches[0]); i++) {
        size_t size = strlen(legacy_patches[i].original);
        size_t hidden_len = strlen(legacy_patches[i].hidden);
        char hidden[1024];
        if (size > sizeof(hidden) || hidden_len > size)
            continue;
        memset(hidden, ' ', size);
        memcpy(hidden, legacy_patches[i].hidden, hidden_len);
        char *hit = memmem(data, len, hidden, size);
        if (hit) {
            memcpy(hit, legacy_patches[i].original, size);
            hits++;
        }
    }
    return hits;
}

static void delete_cloud_recovery_copies(const char *ui_dir) {
    DIR *dir = opendir(ui_dir);
    if (!dir)
        return;

    static const char prefix[] = "sp.js.macsteam-cloud.";
    static const char suffix[] = ".original";
    size_t plen = sizeof(prefix) - 1;
    size_t slen = sizeof(suffix) - 1;

    int removed = 0;
    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        const char *name = ent->d_name;
        size_t nlen = strlen(name);
        if (nlen <= plen + slen)
            continue;
        if (strncmp(name, prefix, plen) != 0)
            continue;
        if (strcmp(name + nlen - slen, suffix) != 0)
            continue;

        char full[2560];
        int n = snprintf(full, sizeof(full), "%s/%s", ui_dir, name);
        if (n > 0 && (size_t)n < sizeof(full) && unlink(full) == 0)
            removed++;
    }

    closedir(dir);
    if (removed > 0) {
        SX_LOG("steamui restore: deleted %d old sp.js recovery %s",
               removed, removed == 1 ? "copy" : "copies");
    }
}

static void restore_sp_js(const char *ui_dir) {
    char sp_path[2304];
    int n = snprintf(sp_path, sizeof(sp_path), "%s/sp.js", ui_dir);
    if (n < 0 || (size_t)n >= sizeof(sp_path))
        return;

    int restore_failed = 0;
    struct stat st;
    if (stat(sp_path, &st) == 0 && S_ISREG(st.st_mode)) {
        size_t len = 0;
        char *current = read_file_all(sp_path, &len);
        if (current) {
            unsigned char digest[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256(current, (CC_LONG)len, digest);
            char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
            for (size_t i = 0; i < sizeof(digest); i++)
                snprintf(hex + i * 2, 3, "%02x", digest[i]);

            char backup_path[2560];
            char *work = NULL;
            int from_backup = 0;
            int bn = snprintf(backup_path, sizeof(backup_path),
                              "%s.macsteam-cloud.%s.original", sp_path, hex);
            if (bn > 0 && (size_t)bn < sizeof(backup_path)) {
                size_t backup_len = 0;
                char *backup = read_file_all(backup_path, &backup_len);
                if (backup) {
                    if (backup_len == len) {
                        work = backup;
                        from_backup = 1;
                    } else {
                        SX_WARN("steamui restore: ignoring size-mismatched recovery copy %s",
                                backup_path);
                        free(backup);
                    }
                }
            }

            if (!work) {
                work = malloc(len + 1);
                if (work)
                    memcpy(work, current, len + 1);
            }

            if (work) {
                int legacy_hits = migrate_legacy(work, len);
                if (memcmp(work, current, len) != 0) {
                    if (save_atomic(sp_path, work, len, st.st_mode & 0777) == 0) {
                        SX_LOG("steamui restore: restored sp.js (%s%s%s)",
                               from_backup ? "recovery copy" : "",
                               (from_backup && legacy_hits > 0) ? " + " : "",
                               legacy_hits > 0 ? "legacy migration" : "");
                    } else {
                        SX_WARN("steamui restore: failed to write restored sp.js");
                        restore_failed = 1;
                    }
                }
                free(work);
            }
            free(current);
        }
    }

    // Keep recovery copies if restoring from one failed so the next launch can retry.
    if (!restore_failed)
        delete_cloud_recovery_copies(ui_dir);
}

static char *strip_old_whatsnew_css(const char *css, size_t len,
                                    size_t *out_len, int *removed_count) {
    static const char needle[] = ";display:none!important";
    static const char fp1[] = "linear-gradient(to top, #171d25";
    static const char fp2[] = "padding:8px 0px 16px;display:flex;flex-direction:column;gap:24px";
    const size_t needle_len = sizeof(needle) - 1;
    const size_t fp1_len = sizeof(fp1) - 1;
    const size_t fp2_len = sizeof(fp2) - 1;

    char *out = malloc(len + 1);
    if (!out)
        return NULL;

    size_t o = 0;
    int removed = 0;

    size_t brace_out_start[64];
    int has_nested[64];
    int depth = 0;

    int in_comment = 0;
    char quote = '\0';

    for (size_t i = 0; i < len; i++) {
        char c = css[i];
        char next = (i + 1 < len) ? css[i + 1] : '\0';

        if (in_comment) {
            out[o++] = c;
            if (c == '*' && next == '/') {
                out[o++] = next;
                i++;
                in_comment = 0;
            }
            continue;
        }
        if (quote) {
            out[o++] = c;
            if (c == '\\' && i + 1 < len) {
                out[o++] = next;
                i++;
            } else if (c == quote) {
                quote = '\0';
            }
            continue;
        }
        if (c == '/' && next == '*') {
            out[o++] = c;
            out[o++] = next;
            i++;
            in_comment = 1;
            continue;
        }
        if (c == '"' || c == '\'') {
            quote = c;
            out[o++] = c;
            continue;
        }

        if (c == '{') {
            if (depth > 0 && depth - 1 < 64)
                has_nested[depth - 1] = 1;
            out[o++] = c;
            if (depth < 64) {
                brace_out_start[depth] = o;
                has_nested[depth] = 0;
            }
            depth++;
            continue;
        }

        if (c == '}' && depth > 0) {
            depth--;
            if (depth < 64 && !has_nested[depth]) {
                size_t body_start = brace_out_start[depth];
                size_t body_len = o - body_start;
                if (body_len >= needle_len &&
                    memcmp(out + o - needle_len, needle, needle_len) == 0 &&
                    (memmem(out + body_start, body_len, fp1, fp1_len) != NULL ||
                     memmem(out + body_start, body_len, fp2, fp2_len) != NULL)) {
                    while (o - body_start >= needle_len &&
                           memcmp(out + o - needle_len, needle, needle_len) == 0) {
                        o -= needle_len;
                        removed++;
                    }
                }
            }
            out[o++] = c;
            continue;
        }

        out[o++] = c;
    }

    if (removed == 0) {
        free(out);
        return NULL;
    }

    out[o] = '\0';
    *out_len = o;
    *removed_count = removed;
    return out;
}

static void restore_css_dir(const char *ui_dir) {
    char css_dir[2304];
    int n = snprintf(css_dir, sizeof(css_dir), "%s/css", ui_dir);
    if (n < 0 || (size_t)n >= sizeof(css_dir))
        return;

    DIR *dir = opendir(css_dir);
    if (!dir)
        return;

    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        const char *name = ent->d_name;
        size_t nlen = strlen(name);
        if (nlen < 4 || strcmp(name + nlen - 4, ".css") != 0)
            continue;

        char path[2560];
        int pn = snprintf(path, sizeof(path), "%s/%s", css_dir, name);
        if (pn < 0 || (size_t)pn >= sizeof(path))
            continue;

        struct stat st;
        if (stat(path, &st) != 0 || !S_ISREG(st.st_mode))
            continue;

        size_t len = 0;
        char *raw = read_file_all(path, &len);
        if (!raw)
            continue;

        size_t out_len = 0;
        int removed = 0;
        char *cleaned = strip_old_whatsnew_css(raw, len, &out_len, &removed);
        free(raw);
        if (!cleaned)
            continue;

        if (save_atomic(path, cleaned, out_len, st.st_mode & 0777) == 0) {
            SX_LOG("steamui restore: removed %d legacy What's New edit(s) from %s",
                   removed, path);
        } else {
            SX_WARN("steamui restore: failed to save restored CSS %s", path);
        }
        free(cleaned);
    }

    closedir(dir);
}

void sx_steamui_restore_disk(void) {
    const char *home = sx_resolve_home();
    if (!home)
        return;

    char ui_dir[2048];
    int n = snprintf(ui_dir, sizeof(ui_dir),
                     "%s/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamui",
                     home);
    if (n < 0 || (size_t)n >= sizeof(ui_dir))
        return;

    restore_sp_js(ui_dir);
    restore_css_dir(ui_dir);
}
