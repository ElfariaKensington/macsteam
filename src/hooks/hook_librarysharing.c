// Hide the shared-library owner row and legacy-sharing retirement notice.
#include "hooks.h"
#include "../util/file.h"
#include "../util/log.h"

#include <stdio.h>
#include <string.h>

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

    // These signatures come from Steam's shipped sp.js. If its bundle changes,
    // leave unmatched code alone. Padding preserves every byte offset and the
    // file size checked by Steam's startup verifier; never rewrite as text.
    static const char *find[] = {
        "className:(0,M.A)(V().Row,V().SharedLibrary),",
        "className:(0,M.A)(V().Row,V().OldSharingWarning),",
    };
    static const char hidden[] = "style:{display:\"none\"},";
    int patched = 0;
    for (size_t i = 0; i < sizeof(find) / sizeof(find[0]); i++) {
        size_t len = strlen(find[i]);
        char replacement[128];
        if (len > sizeof(replacement) || len < sizeof(hidden) - 1)
            continue;
        memset(replacement, ' ', len);
        memcpy(replacement, hidden, sizeof(hidden) - 1);
        int rc = sx_file_patch_bytes(path, (const uint8_t *)find[i], len,
                                     (const uint8_t *)replacement, len);
        if (rc < 0)
            SX_WARN("Library sharing: could not patch row %zu in %s", i, path);
        else
            patched += rc;
    }
    if (patched)
        SX_LOG("Library sharing: hid %d UI row(s), preserving sp.js size", patched);
}
