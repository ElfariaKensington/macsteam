#include <pthread.h>
// Standalone native activation test. All paths and native Steam functions are mocked.
// clang -std=c17 -Isrc scripts/tests/hubcap_refresh.c src/config/config.c \
//   -framework CoreFoundation -o /tmp/macsteam-hubcap-refresh-test
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <notify.h>
#include <CoreFoundation/CoreFoundation.h>
#include "../../src/core/reconcile.c"

int sx_log_level = -1;
FILE *sx_log_file = NULL;
static char scratch[] = "/tmp/macsteam-refresh-test-XXXXXX";
static int dirty, recomputed, emitted, cleared, reread;
static unsigned char manager[16384];

const char *sx_resolve_home(void) { return scratch; }
void sx_macsteam_support_path(char *out, size_t size, const char *home, const char *rel) {
    (void)home; snprintf(out, size, "%s/%s", scratch, rel);
}
void sx_file_config_path(char *out, size_t size) {
    sx_macsteam_support_path(out, size, scratch, "config.yaml");
}
void sx_steam_appcache_path(char *out, size_t size, const char *home, const char *rel) {
    sx_macsteam_support_path(out, size, home, rel);
}
int sx_file_patch_bytes(const char *p, const uint8_t *a, size_t n, const uint8_t *b, size_t m) {
    (void)p; (void)a; (void)n; (void)b; (void)m; return 0;
}
void sx_hooks_apps_refresh_library(void) { sx_reconcile_fire_library_refresh(manager); }
static void clear_map(void *map) { assert(map); cleared++; }
static int64_t read_disk(void *cache) { assert(cache); reread++; return 1; }
static void mark_dirty(void *self, uint32_t app, char flag) {
    assert(self == manager); assert(app == 42); assert(flag == 0); dirty++;
}
static void *concurrent_refresh(void *self) {
    assert(sx_reconcile_fire_library_refresh(self) == 0);
    return NULL;
}
static void recompute(void *self) {
    assert(self == manager); recomputed++;
    // Steam may call an ownership hook recursively during recomputation.
    assert(sx_reconcile_fire_library_refresh(self) == 0);
    pthread_t other;
    assert(pthread_create(&other, NULL, concurrent_refresh, self) == 0);
    assert(pthread_join(other, NULL) == 0);
}
static void emit(void *self) { assert(self == manager); emitted++; }
static void write_file(const char *name, const char *value) {
    char path[1024]; sx_macsteam_support_path(path, sizeof(path), scratch, name);
    FILE *file = fopen(path, "w"); assert(file); fputs(value, file); assert(fclose(file) == 0);
}
static int acknowledged(const char *id) {
    char path[1024], data[64] = {0};
    sx_macsteam_support_path(path, sizeof(path), scratch, "hubcap-refresh.ack");
    FILE *file = fopen(path, "r"); if (!file) return 0;
    fread(data, 1, sizeof(data) - 1, file); fclose(file); return strcmp(data, id) == 0;
}
static void wait_for_ack(const char *id) {
    for (int i = 0; i < 200 && !acknowledged(id); i++)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
    assert(acknowledged(id));
}
int main(void) {
    assert(mkdtemp(scratch));
    uint8_t *anchor = aligned_alloc(4096, 4096);
    uint8_t *engine = calloc(1, 16384);
    assert(anchor && engine);
    memset(anchor, 0, 4096);
    // Same instruction shape as Steam 1792618285, deliberately shifted to prove
    // the decoder does not rely on the old +0x40 site or +4400 cache offset.
    *(uint32_t *)(anchor + 0x78) = 0x90000015; // ADRP x21, same page
    *(uint32_t *)(anchor + 0x7c) = 0x91000000 | (0x800 << 10) | (21 << 5) | 21;
    *(uint32_t *)(anchor + 0x80) = 0xF94002B6; // LDR x22, [x21]
    *(uint32_t *)(anchor + 0x84) = 0x5282A317; // MOV w23, #5400
    *(uint32_t *)(anchor + 0x88) = 0x8B1702C0; // ADD x0, x22, x23
    *(uint32_t *)(anchor + 0x8c) = 0x94000001; // BL
    *(void **)(anchor + 0x800) = engine;
    *(uint32_t *)(anchor + 0x200) = 0x94000000 | ((0x230 - 0x200) / 4);
    *(uint32_t *)(anchor + 0x238) = 0x90000008; // ADRP x8, same page
    *(uint32_t *)(anchor + 0x23c) = 0x91000000 | (0x900 << 10) | (8 << 5) | 8;
    *(uintptr_t *)(engine + 5648) = (uintptr_t)(anchor + 0x900); // package cache
    *(uintptr_t *)(engine + 5400) = (uintptr_t)(anchor + 0xa00); // different app cache
    *(uint32_t *)(anchor + 0x240) = 0xF8008408; // STR x8, [x0], #8
    *(uint32_t *)(anchor + 0x244) = 0x94000000 | ((0x2c0 - 0x244) / 4);
    size_t map_offset = 0;
    uintptr_t vtable = 0;
    assert(resolve_engine_global((uintptr_t)anchor) == (uintptr_t)(anchor + 0x800));
    assert(resolve_map_clear((uintptr_t)(anchor + 0x200), &map_offset, &vtable) == (uintptr_t)(anchor + 0x2c0));
    assert(map_offset == 8);
    assert(vtable == (uintptr_t)(anchor + 0x900));
    sx_reconcile_set_addrs((uintptr_t)anchor, (uintptr_t)(anchor + 0x200), (uintptr_t)read_disk);
    assert(resolve_package_cache() == engine + 5648);
    *(uintptr_t *)(engine + 8000) = vtable;
    assert(resolve_package_cache() == NULL); // ambiguous objects fail closed
    *(uintptr_t *)(engine + 8000) = 0;
    assert((uintptr_t)g_clearmap_fn == (uintptr_t)(anchor + 0x2c0));
    g_clearmap_fn = clear_map; // use a safe native stub after validating the actual decoder
    sx_reconcile_set_library_refresh_fns((uintptr_t)mark_dirty, (uintptr_t)recompute, (uintptr_t)emit);
    sx_reconcile_enable_live_reload();
    sx_reconcile_set_login_observed();
    write_file("config.yaml", "Apps:\n  - 42\nPackageIds:\n  - 20200\n");
    const char *first = "11111111-1111-1111-1111-111111111111";
    write_file("hubcap-refresh.request", first);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.macsteam.hubcap.refresh"), NULL, NULL, true);
    wait_for_ack(first);
    assert(dirty == 1 && recomputed == 1 && emitted == 1 && cleared == 1 && reread == 1);
    sx_config_t *active = atomic_load(&sx_config_current);
    assert(sx_config_has_app(active, 42));
    const char *second = "22222222-2222-2222-2222-222222222222";
    write_file("hubcap-refresh.request", second);
    notify_post("com.macsteam.hubcap.refresh");
    wait_for_ack(second);
    assert(atomic_load(&sx_config_current) == active); // no snapshot leak on retries
    assert(dirty == 2 && recomputed == 2 && emitted == 2);
    write_file("hubcap-refresh.request", "invalid request");
    notify_post("com.macsteam.hubcap.refresh");
    for (int i = 0; i < 10; i++) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
    assert(dirty == 2 && emitted == 2);
    assert(acknowledged(second));
    const char *names[] = {"config.yaml", "hubcap-refresh.request", "hubcap-refresh.ack", "hubcap-runtime.apps"};
    for (size_t i = 0; i < sizeof(names)/sizeof(names[0]); i++) {
        char path[1024]; sx_macsteam_support_path(path, sizeof(path), scratch, names[i]); unlink(path);
    }
    rmdir(scratch);
    sx_config_free(active); free(active); free(anchor); free(engine);
    puts("Native activation: passed (Darwin notification, native refresh, acknowledgement, retry, re-entry, invalid request)");
    return 0;
}
