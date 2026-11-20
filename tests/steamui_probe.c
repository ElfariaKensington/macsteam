#include "hooks/steamui.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static char *slurp(const char *path, size_t *out_len) {
    FILE *fp = fopen(path, "rb");
    if (!fp) {
        perror(path);
        return NULL;
    }
    struct stat st;
    if (fstat(fileno(fp), &st) != 0 || st.st_size <= 0) {
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

int main(int argc, char **argv) {
    if (argc < 2 || argv[1][0] == '\0') {
        printf("steamui_probe: skipped (pass <steamui-dir> to run against a Steam install)\n");
        return 0;
    }

    const char *dir = argv[1];
    size_t dlen = strlen(dir);
    while (dlen > 1 && dir[dlen - 1] == '/')
        dlen--;

    char sp_js_path[2048];
    char sp_css_path[2048];
    int n1 = snprintf(sp_js_path, sizeof(sp_js_path), "%.*s/sp.js", (int)dlen, dir);
    int n2 = snprintf(sp_css_path, sizeof(sp_css_path), "%.*s/css/sp.css", (int)dlen, dir);
    if (n1 < 0 || (size_t)n1 >= sizeof(sp_js_path) ||
        n2 < 0 || (size_t)n2 >= sizeof(sp_css_path)) {
        fprintf(stderr, "steamui_probe: path too long\n");
        return 1;
    }

    size_t js_len = 0;
    char *js = slurp(sp_js_path, &js_len);
    if (!js)
        return 1;

    size_t css_len = 0;
    char *css = slurp(sp_css_path, &css_len);
    if (!css) {
        free(js);
        return 1;
    }

    static const char *const keys[4] = {
        "SharedLibrary",
        "OldSharingWarning",
        "LibraryHomeWhatsNew",
        "UpdatesContainer",
    };

    char hashes[4][64];
    int resolved = sx_steamui_resolve_keys(js, js_len, keys, 4, hashes);
    for (size_t i = 0; i < 4; i++) {
        printf("%s -> %s\n", keys[i], hashes[i][0] ? hashes[i] : "<UNRESOLVED>");
    }

    if (resolved != 4) {
        fprintf(stderr, "steamui_probe: only %d/4 keys resolved\n", resolved);
        free(css);
        free(js);
        return 1;
    }

    const char *ptrs[4] = { hashes[0], hashes[1], hashes[2], hashes[3] };
    size_t patched_len = 0;
    char *patched = sx_steamui_css_hide(css, css_len, ptrs, 4, &patched_len);
    if (!patched || patched_len <= css_len) {
        fprintf(stderr, "steamui_probe: sx_steamui_css_hide returned NULL or unchanged\n");
        free(patched);
        free(css);
        free(js);
        return 1;
    }

    const char *appended = patched + css_len;
    size_t appended_len = patched_len - css_len;
    if (!memmem(appended, appended_len, "/* macsteam */", 14)) {
        fprintf(stderr, "steamui_probe: missing macsteam marker in appended block\n");
        free(patched);
        free(css);
        free(js);
        return 1;
    }

    for (size_t i = 0; i < 4; i++) {
        char selector[66];
        snprintf(selector, sizeof(selector), ".%s", hashes[i]);
        size_t slen = strlen(selector);
        const char *hit = memmem(appended, appended_len, selector, slen);
        if (!hit || (hit[slen] != ',' && hit[slen] != '{')) {
            fprintf(stderr, "steamui_probe: selector %s missing from appended block\n", selector);
            free(patched);
            free(css);
            free(js);
            return 1;
        }
    }

    size_t second_len = 0;
    char *second = sx_steamui_css_hide(patched, patched_len, ptrs, 4, &second_len);
    if (second != NULL) {
        fprintf(stderr, "steamui_probe: second sx_steamui_css_hide call was not idempotent\n");
        free(second);
        free(patched);
        free(css);
        free(js);
        return 1;
    }

    printf("steamui_probe: PASS (4/4 keys hidden, idempotent)\n");
    free(patched);
    free(css);
    free(js);
    return 0;
}
