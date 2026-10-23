// Presentation-only patching with per-bundle recovery; Cloud state is untouched.
#include "hooks.h"
#include "../config/config.h"
#include "../util/file.h"
#include "../util/log.h"
#include <JavaScriptCore/JavaScript.h>
#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "cloud_errors_legacy.h"

static const unsigned char patcher_js[] = {
#include "cloud_errors_js.inc"
, 0 };

static char *read_bundle(const char *path, size_t *length) {
    FILE *file = fopen(path, "rb");
    if (!file) return NULL;
    struct stat st;
    if (fstat(fileno(file), &st) || st.st_size <= 0 || st.st_size > 64 * 1024 * 1024) {
        fclose(file); return NULL;
    }
    size_t len = (size_t)st.st_size;
    char *data = malloc(len + 1);
    if (!data) { fclose(file); return NULL; }
    size_t got = fread(data, 1, len, file);
    fclose(file);
    if (got != len) { free(data); return NULL; }
    data[len] = 0;
    *length = len;
    return data;
}

static int save_bundle(const char *path, const char *data, size_t len, mode_t mode) {
    char tmp[4096];
    int n = snprintf(tmp, sizeof(tmp), "%s.XXXXXX", path);
    if (n < 0 || (size_t)n >= sizeof(tmp)) return -1;
    int fd = mkstemp(tmp);
    if (fd < 0) return -1;
    size_t written = 0;
    while (written < len) {
        ssize_t result = write(fd, data + written, len - written);
        if (result <= 0) break;
        written += (size_t)result;
    }
    int ok = written == len && fchmod(fd, mode) == 0 && fsync(fd) == 0;
    if (close(fd) != 0) ok = 0;
    if (ok && rename(tmp, path) == 0) return 0;
    unlink(tmp);
    return -1;
}

static void migrate_legacy(char *data, size_t len) {
    if (!strstr(data, "null/*macsteam-cloud-error*/")) return;
    for (size_t i = 0; i < sizeof(legacy_patches) / sizeof(legacy_patches[0]); i++) {
        size_t size = strlen(legacy_patches[i].original);
        size_t hidden_len = strlen(legacy_patches[i].hidden);
        char hidden[1024];
        if (size > sizeof(hidden) || hidden_len > size) continue;
        memset(hidden, ' ', size);
        memcpy(hidden, legacy_patches[i].hidden, hidden_len);
        char *hit = memmem(data, len, hidden, size);
        if (hit) memcpy(hit, legacy_patches[i].original, size);
    }
}

static char *transform(const char *source, size_t len) {
    JSGlobalContextRef context = JSGlobalContextCreate(NULL);
    JSStringRef script = JSStringCreateWithUTF8CString((const char *)patcher_js);
    JSValueRef exception = NULL;
    JSValueRef value = JSEvaluateScript(context, script, NULL, NULL, 1, &exception);
    JSStringRelease(script);
    char *out = NULL;
    if (!exception && value && JSValueIsObject(context, value)) {
        JSStringRef input = JSStringCreateWithUTF8CString(source);
        JSValueRef arg = JSValueMakeString(context, input);
        JSStringRelease(input);
        JSObjectRef function = JSValueToObject(context, value, &exception);
        if (!exception && JSObjectIsFunction(context, function)) {
            value = JSObjectCallAsFunction(context, function, NULL, 1, &arg, &exception);
            if (!exception && value && JSValueIsString(context, value)) {
                JSStringRef result = JSValueToStringCopy(context, value, &exception);
                size_t cap = JSStringGetMaximumUTF8CStringSize(result);
                if (!exception && JSCheckScriptSyntax(context, result, NULL, 1, &exception))
                    out = malloc(cap);
                if (out && JSStringGetUTF8CString(result, out, cap) != len + 1) {
                    free(out); out = NULL;
                }
                JSStringRelease(result);
            }
        }
    }
    if (exception) {
        JSStringRef message = JSValueToStringCopy(context, exception, NULL);
        char description[512];
        JSStringGetUTF8CString(message, description, sizeof(description));
        SX_WARN("Cloud error display: skipped bundle: %s", description);
        JSStringRelease(message);
    }
    JSGlobalContextRelease(context);
    return out;
}

void sx_clouderrors_patch_installed_js(void) {
    char config_path[1024];
    sx_file_config_path(config_path, sizeof(config_path));
    sx_config_t cfg;
    if (sx_config_load(config_path, &cfg) != 0) return;
    int enabled = cfg.hide_cloud_errors;
    sx_config_free(&cfg);
    const char *home = sx_resolve_home();
    if (!home) return;
    char path[2048], backup[2304];
    int n = snprintf(path, sizeof(path),
                     "%s/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamui/sp.js", home);
    if (n < 0 || (size_t)n >= sizeof(path)) return;
    struct stat st;
    if (stat(path, &st) != 0) return;
    size_t len;
    char *current = read_bundle(path, &len);
    if (!current) return;
    if (memchr(current, 0, len)) { free(current); return; }

    // A backup is keyed by the exact patched bytes. An update has a new digest,
    // so an old backup can never overwrite a newly installed Steam bundle.
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(current, (CC_LONG)len, digest);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (size_t i = 0; i < sizeof(digest); i++) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    snprintf(backup, sizeof(backup), "%s.macsteam-cloud.%s.original", path, hex);
    size_t baseline_len;
    char *baseline = read_bundle(backup, &baseline_len);
    if (baseline && baseline_len != len) {
        SX_WARN("Cloud error display: invalid recovery copy; leaving bundle unchanged");
        free(baseline); free(current); return;
    }
    if (!baseline) {
        baseline = malloc(len + 1);
        if (!baseline) { free(current); return; }
        memcpy(baseline, current, len + 1);
        migrate_legacy(baseline, len);
    }
    char *patched = enabled ? transform(baseline, len) : NULL;
    const char *desired = enabled ? patched : baseline;
    if (desired && memcmp(desired, current, len) != 0) {
        int safe = 1;
        if (enabled) {
            CC_SHA256(desired, (CC_LONG)len, digest);
            for (size_t i = 0; i < sizeof(digest); i++) snprintf(hex + i * 2, 3, "%02x", digest[i]);
            snprintf(backup, sizeof(backup), "%s.macsteam-cloud.%s.original", path, hex);
            safe = save_bundle(backup, baseline, len, 0600) == 0;
        }
        if (!safe || save_bundle(path, desired, len, st.st_mode & 0777) != 0)
            SX_WARN("Cloud error display: could not save bundle/recovery copy");
        else
            SX_LOG("Cloud error display: %s; syncing unaffected", enabled ? "hidden" : "restored");
    }
    free(patched);
    free(baseline);
    free(current);
}
