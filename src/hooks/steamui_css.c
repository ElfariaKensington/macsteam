#include "steamui.h"
#include "../util/log.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static int is_css_ident_char(unsigned char c) {
    return (c >= 'A' && c <= 'Z') ||
           (c >= 'a' && c <= 'z') ||
           (c >= '0' && c <= '9') ||
           c == '_' || c == '-';
}

static const char *find_key_needle(const char *hay, size_t hay_len,
                                   const char *key, size_t key_len,
                                   const char *needle, size_t needle_len) {
    if (needle)
        return memmem(hay, hay_len, needle, needle_len);

    // Fallback for keys too long for the stack needle buffer.
    const char *cur = hay;
    const char *end = hay + hay_len;
    while (cur < end) {
        const char *hit = memmem(cur, (size_t)(end - cur), key, key_len);
        if (!hit)
            return NULL;
        if ((size_t)(end - hit) >= key_len + 2 &&
            hit[key_len] == ':' && hit[key_len + 1] == '"') {
            return hit;
        }
        cur = hit + 1;
    }
    return NULL;
}

int sx_steamui_resolve_keys(const char *js, size_t len,
                            const char *const *keys, size_t n,
                            char hashes[][64]) {
    if (hashes) {
        for (size_t i = 0; i < n; i++)
            hashes[i][0] = '\0';
    }
    if (!js || len < 4 || !keys || !hashes || n == 0)
        return 0;

    int resolved = 0;
    const char *end = js + len;

    for (size_t k = 0; k < n; k++) {
        const char *key = keys[k];
        if (!key || key[0] == '\0')
            continue;

        size_t klen = strlen(key);
        char stack_needle[256];
        const char *needle = NULL;
        size_t needle_len = klen + 2;
        if (needle_len <= sizeof(stack_needle)) {
            memcpy(stack_needle, key, klen);
            stack_needle[klen] = ':';
            stack_needle[klen + 1] = '"';
            needle = stack_needle;
        }

        char found[64] = {0};
        size_t found_len = 0;
        size_t matches = 0;
        int conflict = 0;

        // Start at js + 1 because a valid match requires ',' or '{' at hit[-1].
        const char *cur = js + 1;
        while (cur < end) {
            const char *hit = find_key_needle(cur, (size_t)(end - cur),
                                              key, klen, needle, needle_len);
            if (!hit)
                break;

            if (hit[-1] == ',' || hit[-1] == '{') {
                const char *hstart = hit + klen + 2;
                const char *h = hstart;
                while (h < end && (size_t)(h - hstart) <= 63 &&
                       is_css_ident_char((unsigned char)*h)) {
                    h++;
                }
                size_t hlen = (size_t)(h - hstart);
                if (hlen >= 1 && hlen <= 63 && h < end && *h == '"') {
                    matches++;
                    if (matches == 1) {
                        memcpy(found, hstart, hlen);
                        found[hlen] = '\0';
                        found_len = hlen;
                    } else if (!conflict &&
                               (hlen != found_len || memcmp(hstart, found, hlen) != 0)) {
                        conflict = 1;
                    }
                }
            }
            cur = hit + 1;
        }

        if (matches > 0 && !conflict) {
            memcpy(hashes[k], found, found_len + 1);
            resolved++;
        } else if (matches == 0) {
            SX_WARN("steamui: CSS key '%s' unresolved (0 occurrences)", key);
        } else {
            SX_WARN("steamui: CSS key '%s' unresolved (%zu conflicting occurrences)",
                    key, matches);
        }
    }

    return resolved;
}

static int css_has_selector(const char *css, size_t len,
                            const char *hash, size_t hlen) {
    if (hlen == 0 || len < hlen + 1)
        return 0;

    const char *cur = css + 1;
    const char *end = css + len;
    while (cur < end) {
        const char *hit = memmem(cur, (size_t)(end - cur), hash, hlen);
        if (!hit)
            return 0;
        if (hit[-1] == '.') {
            const char *after = hit + hlen;
            if (after == end || !is_css_ident_char((unsigned char)*after))
                return 1;
        }
        cur = hit + 1;
    }
    return 0;
}

char *sx_steamui_css_hide(const char *css, size_t len,
                          const char *const *hashes, size_t n,
                          size_t *out_len) {
    if (out_len)
        *out_len = 0;
    if (!css || len == 0 || !hashes || n == 0)
        return NULL;

    static const char marker[] = "/* macsteam */";
    if (memmem(css, len, marker, sizeof(marker) - 1) != NULL)
        return NULL;

    uint8_t *matched = calloc(n, sizeof(uint8_t));
    if (!matched)
        return NULL;

    size_t matched_count = 0;
    size_t selectors_len = 0;

    for (size_t i = 0; i < n; i++) {
        const char *h = hashes[i];
        if (!h || h[0] == '\0')
            continue;

        int dup = 0;
        for (size_t j = 0; j < i; j++) {
            if (matched[j] && strcmp(hashes[j], h) == 0) {
                dup = 1;
                break;
            }
        }
        if (dup)
            continue;

        size_t hlen = strlen(h);
        if (css_has_selector(css, len, h, hlen)) {
            matched[i] = 1;
            if (matched_count > 0)
                selectors_len += 1; // ','
            selectors_len += 1 + hlen; // '.' + hash
            matched_count++;
        }
    }

    if (matched_count == 0) {
        free(matched);
        return NULL;
    }

    static const char prefix[] = "\n/* macsteam */\n";
    static const char suffix[] = "{display:none!important}\n";
    size_t prefix_len = sizeof(prefix) - 1;
    size_t suffix_len = sizeof(suffix) - 1;
    size_t total_len = len + prefix_len + selectors_len + suffix_len;

    char *out = malloc(total_len + 1);
    if (!out) {
        free(matched);
        return NULL;
    }

    char *p = out;
    memcpy(p, css, len);
    p += len;
    memcpy(p, prefix, prefix_len);
    p += prefix_len;

    int first = 1;
    for (size_t i = 0; i < n; i++) {
        if (!matched[i])
            continue;
        if (!first)
            *p++ = ',';
        first = 0;
        *p++ = '.';
        size_t hlen = strlen(hashes[i]);
        memcpy(p, hashes[i], hlen);
        p += hlen;
    }

    memcpy(p, suffix, suffix_len);
    p += suffix_len;
    *p = '\0';

    free(matched);
    if (out_len)
        *out_len = total_len;
    return out;
}
