// Dynamic schema owner discovery via Steam Store reviews
// Based on the approach from SLSsteam by AceSLS (https://github.com/AceSLS/SLSsteam)
#include "schema_owners.h"
#include "../util/log.h"
#include <CoreFoundation/CoreFoundation.h>
#include <CFNetwork/CFNetwork.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// The Store reviews JSON endpoint now redirects to the storefront for many
// networks. The community reviews page is HTML but exposes the same reviewer
// Steam IDs through profile links and data-miniprofile attributes.
#define REVIEWS_URL_FMT \
    "https://steamcommunity.com/app/%d/reviews/?browsefilter=mostrecent&p=1"

#define REVIEWS_BUF_SIZE (256 * 1024)

#define STEAMID64_BASE 76561197960265728ULL

#define MAX_TRACKED_APPS  256
#define MAX_BLACKLIST     64

typedef struct {
    int      appId;
    uint64_t preferred;
    uint64_t blacklist[MAX_BLACKLIST];
    int      bl_count;
    time_t   cooldown_until;
} app_owner_state_t;

static app_owner_state_t g_states[MAX_TRACKED_APPS];
static int g_state_count = 0;

static app_owner_state_t *find_or_create(int appId) {
    for (int i = 0; i < g_state_count; i++)
        if (g_states[i].appId == appId) return &g_states[i];
    if (g_state_count >= MAX_TRACKED_APPS) return NULL;
    app_owner_state_t *s = &g_states[g_state_count++];
    memset(s, 0, sizeof(*s));
    s->appId = appId;
    return s;
}

static int is_blacklisted(app_owner_state_t *s, uint64_t owner) {
    for (int i = 0; i < s->bl_count; i++)
        if (s->blacklist[i] == owner) return 1;
    return 0;
}

static char *fetch_reviews_html(int appId) {
    char url_buf[256];
    snprintf(url_buf, sizeof(url_buf), REVIEWS_URL_FMT, appId);

    CFURLRef url = CFURLCreateWithBytes(NULL, (const UInt8 *)url_buf,
                                        (CFIndex)strlen(url_buf),
                                        kCFStringEncodingUTF8, NULL);
    if (!url) return NULL;

    CFHTTPMessageRef req = CFHTTPMessageCreateRequest(NULL, CFSTR("GET"), url, kCFHTTPVersion1_1);
    CFRelease(url);
    if (!req) return NULL;

    CFHTTPMessageSetHeaderFieldValue(req, CFSTR("User-Agent"),
                                     CFSTR("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                                           "AppleWebKit/605.1.15 (KHTML, like Gecko) "
                                           "Version/17.0 Safari/605.1.15"));

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CFReadStreamRef stream = CFReadStreamCreateForHTTPRequest(NULL, req);
#pragma clang diagnostic pop
    CFRelease(req);
    if (!stream) return NULL;

    CFReadStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(),
                                    kCFRunLoopDefaultMode);

    if (!CFReadStreamOpen(stream)) {
        CFReadStreamUnscheduleFromRunLoop(stream, CFRunLoopGetCurrent(),
                                          kCFRunLoopDefaultMode);
        CFRelease(stream);
        return NULL;
    }

    char *buf = (char *)malloc(REVIEWS_BUF_SIZE);
    if (!buf) {
        CFReadStreamUnscheduleFromRunLoop(stream, CFRunLoopGetCurrent(),
                                          kCFRunLoopDefaultMode);
        CFReadStreamClose(stream);
        CFRelease(stream);
        return NULL;
    }

    CFAbsoluteTime deadline =
        CFAbsoluteTimeGetCurrent() + SCHEMA_OWNERS_FETCH_TIMEOUT_SEC;

    CFIndex total = 0;
    int timed_out = 0;
    while (total < (CFIndex)(REVIEWS_BUF_SIZE - 1)) {
        CFStreamStatus st = CFReadStreamGetStatus(stream);
        if (st == kCFStreamStatusAtEnd || st == kCFStreamStatusError)
            break;

        if (CFReadStreamHasBytesAvailable(stream)) {
            CFIndex n = CFReadStreamRead(stream, (UInt8 *)buf + total,
                                         (CFIndex)(REVIEWS_BUF_SIZE - 1) - total);
            if (n <= 0) break;
            total += n;
            continue;
        }

        CFTimeInterval remaining = deadline - CFAbsoluteTimeGetCurrent();
        if (remaining <= 0) { timed_out = 1; break; }

        CFTimeInterval slice = remaining < 0.25 ? remaining : 0.25;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, slice, true);
    }

    CFReadStreamUnscheduleFromRunLoop(stream, CFRunLoopGetCurrent(),
                                      kCFRunLoopDefaultMode);
    CFReadStreamClose(stream);
    CFRelease(stream);

    if (timed_out) {
        SX_WARN("[schema_owners] app %d: reviews fetch timed out after %.0fs",
                appId, (double)SCHEMA_OWNERS_FETCH_TIMEOUT_SEC);
        free(buf);
        return NULL;
    }

    if (total <= 0) { free(buf); return NULL; }
    buf[total] = '\0';
    return buf;
}

static int add_owner(uint64_t id, uint64_t *out, int count, int max,
                     app_owner_state_t *state) {
    if (count >= max || id < STEAMID64_BASE) return 0;
    if (state && is_blacklisted(state, id)) return 0;
    for (int i = 0; i < count; i++)
        if (out[i] == id) return 0;
    out[count] = id;
    return 1;
}

// Pull numeric reviewer profile IDs out of the community reviews HTML.
static int extract_steamids(const char *html, uint64_t *out, int max,
                            app_owner_state_t *state) {
    if (!html || !out || max <= 0) return 0;
    int count = 0;

    const char *needle = "steamcommunity.com/profiles/";
    const char *p = html;
    while (count < max && (p = strstr(p, needle)) != NULL) {
        p += strlen(needle);
        char *end = NULL;
        unsigned long long id = strtoull(p, &end, 10);
        if (end == p || id == 0) { p = end ? end : p + 1; continue; }
        p = end;
        if (add_owner((uint64_t)id, out, count, max, state)) count++;
    }

    // Reviews whose author uses a vanity URL still carry the numeric account id.
    const char *miniprofile = "data-miniprofile=\"";
    p = html;
    while (count < max && (p = strstr(p, miniprofile)) != NULL) {
        p += strlen(miniprofile);
        char *end = NULL;
        unsigned long long account = strtoull(p, &end, 10);
        if (end == p || account == 0 || account > 0xFFFFFFFFull) {
            p = end ? end : p + 1;
            continue;
        }
        p = end;
        if (add_owner(STEAMID64_BASE + account, out, count, max, state)) count++;
    }
    return count;
}

void sx_schema_owners_get(int appId, sx_owner_list_t *out) {
    out->count = 0;
    if (appId <= 0) return;
    app_owner_state_t *s = find_or_create(appId);
    if (!s) return;

    time_t now = time(NULL);
    if (s->cooldown_until > now) {
        SX_DBG("[schema_owners] app %d: on cooldown for %d more seconds",
               appId, (int)(s->cooldown_until - now));
        return;
    }

    char *html = fetch_reviews_html(appId);
    if (!html) {
        SX_WARN("[schema_owners] app %d: reviews page request failed", appId);
        s->cooldown_until = now + SCHEMA_OWNERS_COOLDOWN_MINUTES * 60;
        return;
    }

    out->count = extract_steamids(html, out->ids, SCHEMA_OWNERS_MAX, s);
    free(html);

    if (out->count == 0)
        s->cooldown_until = now + SCHEMA_OWNERS_COOLDOWN_MINUTES * 60;

    SX_DBG("[schema_owners] app %d: found %d reviewer(s)", appId, out->count);
}

void sx_schema_owners_blacklist(int appId, uint64_t owner) {
    app_owner_state_t *s = find_or_create(appId);
    if (!s) return;
    if (is_blacklisted(s, owner)) return;
    if (s->bl_count >= MAX_BLACKLIST) return;
    s->blacklist[s->bl_count++] = owner;
    if (s->preferred == owner) s->preferred = 0;
    SX_DBG("[schema_owners] app %d: blacklisted owner %llu", appId,
           (unsigned long long)owner);
}

void sx_schema_owners_set_preferred(int appId, uint64_t owner) {
    app_owner_state_t *s = find_or_create(appId);
    if (!s) return;
    s->preferred = owner;
}

uint64_t sx_schema_owners_preferred(int appId) {
    app_owner_state_t *s = find_or_create(appId);
    return s ? s->preferred : 0;
}
