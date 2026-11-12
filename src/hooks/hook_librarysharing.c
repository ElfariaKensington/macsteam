// Hide the shared-library owner row and legacy-sharing retirement notice.
#include "hooks.h"
#include "../util/file.h"
#include "../util/log.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Steam's minified sp.js renames its identifiers every build, so the rows are located by
// their stable CSS-module keys instead of a fixed string. Each row looks like
//     className:(0,<a>.<b>)(<c>().Row,<c>().<Key>),
// and is overwritten in place with `style:{display:"none"},` plus space padding. Every byte
// offset and the file size stay the same, which is what Steam's startup verifier checks;
// never rewrite the file as text.
#define SX_CLASS_PREFIX     "className:(0,"
#define SX_MAX_ROW_SPAN     96

static const char *const kRowKeys[] = { "SharedLibrary", "OldSharingWarning" };
static const char kHidden[] = "style:{display:\"none\"},";

// If `p` (pointing at ".<Key>),") ends a row expression, return its start, else NULL.
static uint8_t *row_start(uint8_t *buf, uint8_t *p) {
    size_t lo = (size_t)(p - buf) > SX_MAX_ROW_SPAN ? SX_MAX_ROW_SPAN : (size_t)(p - buf);
    size_t plen = sizeof(SX_CLASS_PREFIX) - 1;
    for (size_t back = plen; back <= lo; back++) {
        uint8_t *s = p - back;
        if (memcmp(s, SX_CLASS_PREFIX, plen) != 0)
            continue;
        // The span between must be one plain call chain: no braces or statement breaks.
        for (uint8_t *q = s + plen; q < p; q++)
            if (*q == '{' || *q == '}' || *q == ';' || *q == '"' || *q == '\n')
                return NULL;
        return s;
    }
    return NULL;
}

void sx_librarysharing_patch_installed_js(void) {
    const char *home = sx_resolve_home();
    if (!home)
        return;

    char path[2048];
    int n = snprintf(path, sizeof(path),
                     "%s/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamui/sp.js",
                     home);
    if (n < 0 || (size_t)n >= sizeof(path))
        return;

    size_t fsize = 0;
    uint8_t *buf = sx_slurp_file(path, &fsize);
    if (!buf)
        return;

    size_t offs[16], lens[16];
    int found = 0;
    for (size_t k = 0; k < sizeof(kRowKeys) / sizeof(kRowKeys[0]); k++) {
        char needle[64];
        int nl = snprintf(needle, sizeof(needle), ".%s),", kRowKeys[k]);
        for (size_t i = 0; i + (size_t)nl <= fsize && found < 16; i++) {
            if (buf[i] != '.' || memcmp(buf + i, needle, (size_t)nl) != 0)
                continue;
            uint8_t *start = row_start(buf, buf + i);
            if (!start)
                continue;
            size_t len = (size_t)(buf + i + (size_t)nl - start);
            if (len < sizeof(kHidden) - 1)
                continue;
            offs[found] = (size_t)(start - buf);
            lens[found] = len;
            found++;
        }
    }
    free(buf);

    if (!found) {
        SX_DBG("Library sharing: no unpatched rows in sp.js (already hidden or bundle changed)");
        return;
    }

    FILE *f = fopen(path, "r+b");
    if (!f) {
        SX_WARN("Library sharing: could not open %s", path);
        return;
    }
    int patched = 0;
    for (int i = 0; i < found; i++) {
        char rep[160];
        if (lens[i] > sizeof(rep))
            continue;
        memset(rep, ' ', lens[i]);
        memcpy(rep, kHidden, sizeof(kHidden) - 1);
        if (fseek(f, (long)offs[i], SEEK_SET) == 0 && fwrite(rep, 1, lens[i], f) == lens[i])
            patched++;
        else
            SX_WARN("Library sharing: write failed at offset %zu in %s", offs[i], path);
    }
    if (fclose(f) != 0)
        SX_WARN("Library sharing: close failed for %s", path);
    if (patched)
        SX_LOG("Library sharing: hid %d UI row(s), preserving sp.js size", patched);
}
