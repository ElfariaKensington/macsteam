// Manifest request code via ManifestDeX (OpenSteamTool provider PR #200).
#include "hooks.h"
#include "../config/config.h"
#include "../util/log.h"
#include <stdint.h>
#include <ctype.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CFNetwork/CFNetwork.h>

#define MANIFEST_API_FMT "https://manifest.manifestdex.com/%llu"
#define MANIFEST_UA      "ManifestDeX/1.0"

static void *orig_GetManifestRequestCode = NULL;

typedef uint32_t (*fn_GetManifestRequestCode)(void *self, uint32_t app_id,
                                                uint32_t depot_id, uint64_t manifest_id,
                                                const char *branch, uint64_t *pRequestCode);

// Parse as an integer: request codes can exceed both INT64_MAX and 2^53.
static int parse_manifest_code(const char *body, uint64_t *out_code) {
    if (!body || !out_code) return -1;
    while (isspace((unsigned char)*body)) ++body;
    const char *digits = body;
    while (*body >= '0' && *body <= '9') ++body;
    size_t count = (size_t)(body - digits);
    if (!count || count > 20) return -1;
    while (isspace((unsigned char)*body)) ++body;
    if (*body) return -1;
    errno = 0;
    unsigned long long code = strtoull(digits, NULL, 10);
    if (errno == ERANGE || !code) return -1;
    *out_code = (uint64_t)code;
    return 0;
}

// Fetch manifest request code from the remote API. Returns 0 on success.
static int fetch_manifest_code(uint64_t manifest_id, uint64_t *out_code) {
    char url_buf[128];
    snprintf(url_buf, sizeof(url_buf), MANIFEST_API_FMT, (unsigned long long)manifest_id);

    CFURLRef url = CFURLCreateWithBytes(NULL, (const UInt8 *)url_buf,
                                        (CFIndex)strlen(url_buf),
                                        kCFStringEncodingUTF8, NULL);
    if (!url) return -1;

    CFHTTPMessageRef req = CFHTTPMessageCreateRequest(NULL, CFSTR("GET"), url, kCFHTTPVersion1_1);
    CFRelease(url);
    if (!req) return -1;

    CFHTTPMessageSetHeaderFieldValue(req, CFSTR("User-Agent"), CFSTR(MANIFEST_UA));

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CFReadStreamRef stream = CFReadStreamCreateForHTTPRequest(NULL, req);
#pragma clang diagnostic pop
    CFRelease(req);
    if (!stream) return -1;

    if (!CFReadStreamOpen(stream)) {
        CFRelease(stream);
        return -1;
    }

    UInt8 buf[64];
    CFIndex total = 0;
    int read_failed = 0;
    while (total < (CFIndex)(sizeof(buf) - 1)) {
        CFIndex n = CFReadStreamRead(stream, buf + total, (CFIndex)(sizeof(buf) - 1) - total);
        if (n <= 0) { read_failed = n < 0; break; }
        total += n;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CFHTTPMessageRef response = (CFHTTPMessageRef)CFReadStreamCopyProperty(
        stream, kCFStreamPropertyHTTPResponseHeader);
#pragma clang diagnostic pop
    CFIndex status = response ? CFHTTPMessageGetResponseStatusCode(response) : 0;
    if (response) CFRelease(response);
    CFReadStreamClose(stream);
    CFRelease(stream);

    if (read_failed || status != 200 || total <= 0 || total == (CFIndex)(sizeof(buf) - 1)) {
        SX_WARN("manifest provider failed: manifest=%llu HTTP=%ld read_error=%d",
                (unsigned long long)manifest_id, (long)status, read_failed);
        return -1;
    }
    buf[total] = '\0';
    if (memchr(buf, '\0', (size_t)total)) return -1;
    return parse_manifest_code((const char *)buf, out_code);
}

static uint32_t hook_GetManifestRequestCode(void *self, uint32_t app_id,
                                              uint32_t depot_id, uint64_t manifest_id,
                                              const char *branch, uint64_t *pRequestCode) {
    sx_config_t *g_cfg = sx_config_current;
    fn_GetManifestRequestCode orig =
        (fn_GetManifestRequestCode)orig_GetManifestRequestCode;

    if (g_cfg && sx_config_has_app(g_cfg, (int)app_id)) {
        uint64_t code = 0;
        if (fetch_manifest_code(manifest_id, &code) == 0 && pRequestCode) {
            *pRequestCode = code;
            SX_LOG_ONCE_KEY(depot_id,
                    "GetManifestRequestCode: app=%u depot=%u manifest=0x%llx -> manifestdex code=0x%llx",
                    app_id, depot_id, (unsigned long long)manifest_id,
                    (unsigned long long)code);
            return 1;
        }
        // API failed, fall through to original
        SX_LOG_ONCE_KEY(depot_id,
                "GetManifestRequestCode: app=%u depot=%u manifest=0x%llx -> manifestdex FAILED, passthrough",
                app_id, depot_id, (unsigned long long)manifest_id);
    }

    return orig(self, app_id, depot_id, manifest_id, branch, pRequestCode);
}


static sx_hook_def_t g_hooks[] = {
    {
        .name     = "GetManifestRequestCode",
        .sig_name = "CAppInfo::GetManifestRequestCode",
        .hook_fn  = (void *)hook_GetManifestRequestCode,
        .orig_fn  = &orig_GetManifestRequestCode,
        .optional = 1,
    },
};

int sx_hooks_manifest_count(void) {
    return (int)(sizeof(g_hooks) / sizeof(g_hooks[0]));
}

sx_hook_def_t *sx_hooks_manifest_defs(void) {
    return g_hooks;
}
