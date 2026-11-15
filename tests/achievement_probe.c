#include "core/bkv.h"
#include "feats/achievements.h"
#include "config/config.h"
#include "constants.h"
#include "util/log.h"

#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char g_home[512];
static char g_stats[1024];

static sx_bkv_node_t *section(const char *name) {
    sx_bkv_node_t *n = (sx_bkv_node_t *)calloc(1, sizeof(*n));
    assert(n);
    n->type = SX_BKV_SECTION;
    n->name = strdup(name);
    assert(n->name);
    return n;
}

static sx_bkv_node_t *append_section(sx_bkv_node_t *parent, const char *name) {
    sx_bkv_node_t *node = section(name);
    sx_bkv_node_t **tail = &parent->child;
    while (*tail) tail = &(*tail)->next;
    *tail = node;
    return node;
}

static void add_bits(sx_bkv_node_t *stat, const char *const *ids, int count) {
    sx_bkv_node_t *bits = sx_bkv_ensure_section(stat, "bits");
    assert(bits);
    for (int i = 0; i < count; i++) {
        char name[16];
        snprintf(name, sizeof(name), "%d", i + 1);
        sx_bkv_node_t *bit = append_section(bits, name);
        assert(bit);
        assert(sx_bkv_set_string(bit, "name", ids[i]));
    }
}

static sx_bkv_node_t *build_schema(void) {
    sx_bkv_node_t *root = section("123");
    assert(sx_bkv_set_int(root, "version", 21));
    sx_bkv_node_t *stats = sx_bkv_ensure_section(root, "stats");
    assert(stats);

    static const char *const a_ids[] = {"ACH_A", "ACH_B", "ACH_C"};
    sx_bkv_node_t *a = sx_bkv_ensure_section(stats, "0");
    assert(sx_bkv_set_string(a, "type", "ACHIEVEMENTS"));
    add_bits(a, a_ids, 3);

    sx_bkv_node_t *num = sx_bkv_ensure_section(stats, "1");
    assert(sx_bkv_set_int(num, "type", 1));

    static const char *const old_ids[] = {"ACH_D", "ACH_E"};
    sx_bkv_node_t *old = sx_bkv_ensure_section(stats, "2");
    assert(sx_bkv_set_int(old, "type_int", 5));
    add_bits(old, old_ids, 2);

    sx_bkv_node_t *wide = sx_bkv_ensure_section(stats, "3");
    assert(sx_bkv_set_string(wide, "type", "groupachievements"));
    sx_bkv_node_t *bits = sx_bkv_ensure_section(wide, "bits");
    assert(bits);
    for (int i = 0; i < 32; i++) {
        char section[16], id[32];
        snprintf(section, sizeof(section), "%d", i + 1);
        snprintf(id, sizeof(id), "ACH_WIDE_%d", i);
        sx_bkv_node_t *bit = append_section(bits, section);
        assert(bit);
        assert(sx_bkv_set_string(bit, "name", id));
    }
    return root;
}

static sx_bkv_node_t *build_cache(void) {
    sx_bkv_node_t *root = section("cache");
    assert(sx_bkv_set_int(root, "crc", (int32_t)0x11223344u));
    assert(sx_bkv_set_int(root, "PendingChanges", 0));

    sx_bkv_node_t *s0 = sx_bkv_ensure_section(root, "0");
    assert(sx_bkv_set_int(s0, "data", 0));
    sx_bkv_node_t *times = sx_bkv_ensure_section(s0, "AchievementTimes");
    assert(sx_bkv_set_int(times, "1", 111));

    sx_bkv_node_t *s9 = sx_bkv_ensure_section(root, "9");
    assert(sx_bkv_set_int(s9, "data", 42));
    return root;
}

static void write_blob(const char *path, const sx_bkv_node_t *root) {
    size_t size = sx_bkv_encoded_size(root);
    uint8_t *buf = (uint8_t *)malloc(size);
    assert(buf);
    int n = sx_bkv_encode(root, buf, size);
    assert(n == (int)size);
    FILE *f = fopen(path, "wb");
    assert(f);
    assert(fwrite(buf, 1, size, f) == size);
    assert(fclose(f) == 0);
    free(buf);
}

static sx_bkv_node_t *read_blob(const char *path) {
    FILE *f = fopen(path, "rb");
    assert(f);
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    assert(size > 0);
    rewind(f);
    uint8_t *buf = (uint8_t *)malloc((size_t)size);
    assert(buf);
    assert(fread(buf, 1, (size_t)size, f) == (size_t)size);
    fclose(f);
    sx_bkv_node_t *root = sx_bkv_parse(buf, (size_t)size);
    free(buf);
    assert(root);
    return root;
}

static int32_t node_int(const sx_bkv_node_t *root, const char *sec, const char *key) {
    const sx_bkv_node_t *s = sx_bkv_child(root, sec);
    assert(s && s->type == SX_BKV_SECTION);
    const sx_bkv_node_t *n = sx_bkv_child(s, key);
    assert(n && n->type == SX_BKV_INT);
    return n->v.i32;
}

static int32_t root_int(const sx_bkv_node_t *root, const char *key) {
    const sx_bkv_node_t *n = sx_bkv_child(root, key);
    assert(n && n->type == SX_BKV_INT);
    return n->v.i32;
}

static void test_roundtrip(void) {
    sx_bkv_node_t *schema = build_schema();
    size_t size = sx_bkv_encoded_size(schema);
    uint8_t *first = (uint8_t *)malloc(size);
    uint8_t *second = (uint8_t *)malloc(size);
    assert(first && second);
    assert(sx_bkv_encode(schema, first, size) == (int)size);

    sx_bkv_node_t *parsed = sx_bkv_parse(first, size);
    assert(parsed);
    assert(sx_bkv_encode(parsed, second, size) == (int)size);
    assert(memcmp(first, second, size) == 0);

    sx_bkv_free(parsed);
    free(first); free(second);
    sx_bkv_free(schema);
}

static void test_schema_collect(void) {
    sx_bkv_node_t *schema = build_schema();
    sx_ach_stat_t stats[8];

    static char *picked[] = {(char *)"ACH_A", (char *)"ACH_C"};
    sx_ach_app_t app = { .app_id = 123, .all = 0, .ids = picked, .id_count = 2 };
    sx_config_t cfg = { .ach_apps = &app, .ach_app_count = 1 };

    int count = sx_ach_collect_schema(schema, 123, &cfg, stats, 8);
    assert(count == 3);
    assert(stats[0].stat_id == 0 && stats[0].bits == 3 && stats[0].selected == 0x5);
    assert(stats[1].stat_id == 2 && stats[1].bits == 2 && stats[1].selected == 0x0);
    assert(stats[2].stat_id == 3 && stats[2].bits == 32 && stats[2].selected == 0x0);

    app.all = 1;
    count = sx_ach_collect_schema(schema, 123, &cfg, stats, 8);
    assert(count == 3);
    assert(stats[0].selected == 0x7);
    assert(stats[1].selected == 0x3);
    assert(stats[2].selected == 0xFFFFFFFFu);

    // A different app is not selected.
    count = sx_ach_collect_schema(schema, 999, &cfg, stats, 8);
    assert(count == 3 && stats[0].selected == 0);

    sx_bkv_free(schema);
}

static void test_apply_restore(void) {
    sx_ach_stat_t stat = { .stat_id = 0, .bits = 3, .selected = 0x7 };
    sx_bkv_node_t *cache = build_cache();

    sx_ach_orig_t orig;
    sx_ach_capture(cache, &stat, &orig);
    assert(orig.section_present && orig.present && orig.data == 0);
    assert(orig.time_count == 1 && orig.times[0].bit == 1 && orig.times[0].time == 111);

    assert(sx_ach_apply(cache, &stat, &orig, SX_ACH_FALLBACK_UNLOCK_TIME) == 1);
    assert(node_int(cache, "0", "data") == 0x7);

    const sx_bkv_node_t *s0 = sx_bkv_child(cache, "0");
    const sx_bkv_node_t *times = sx_bkv_child(s0, "AchievementTimes");
    assert(times && times->type == SX_BKV_SECTION);
    for (int bit = 0; bit < 3; bit++) {
        char name[8];
        snprintf(name, sizeof(name), "%d", bit);
        const sx_bkv_node_t *n = sx_bkv_child(times, name);
        assert(n && n->type == SX_BKV_INT);
        assert(n->v.i32 == (int32_t)SX_ACH_FALLBACK_UNLOCK_TIME);
    }
    assert(node_int(cache, "9", "data") == 42);
    assert(root_int(cache, "crc") == (int32_t)0x11223344u);

    // Idempotent.
    assert(sx_ach_apply(cache, &stat, &orig, SX_ACH_FALLBACK_UNLOCK_TIME) == 0);

    // Narrow the selection: only bits 0 and 2. The old original time for bit 1
    // must come back, and the bits we added without an original time vanish.
    stat.selected = 0x5;
    assert(sx_ach_apply(cache, &stat, &orig, SX_ACH_FALLBACK_UNLOCK_TIME) == 1);
    assert(node_int(cache, "0", "data") == 0x5);
    s0 = sx_bkv_child(cache, "0");
    times = sx_bkv_child(s0, "AchievementTimes");
    for (int bit = 0; bit < 3; bit++) {
        char name[8];
        snprintf(name, sizeof(name), "%d", bit);
        const sx_bkv_node_t *n = sx_bkv_child(times, name);
        if (bit == 1) {
            assert(n && n->v.i32 == 111);
        } else {
            assert(n && n->v.i32 == (int32_t)SX_ACH_FALLBACK_UNLOCK_TIME);
        }
    }

    // Select only bit 1, which was originally unlocked with time 111.
    stat.selected = 0x2;
    assert(sx_ach_apply(cache, &stat, &orig, SX_ACH_FALLBACK_UNLOCK_TIME) == 1);
    assert(node_int(cache, "0", "data") == 0x2);
    s0 = sx_bkv_child(cache, "0");
    times = sx_bkv_child(s0, "AchievementTimes");
    assert(times);
    assert(sx_bkv_child(times, "0") == NULL);
    const sx_bkv_node_t *b1 = sx_bkv_child(times, "1");
    assert(b1 && b1->v.i32 == (int32_t)SX_ACH_FALLBACK_UNLOCK_TIME);
    assert(sx_bkv_child(times, "2") == NULL);

    // Empty selection restores the original state.
    stat.selected = 0;
    assert(sx_ach_apply(cache, &stat, &orig, SX_ACH_FALLBACK_UNLOCK_TIME) == 1);
    assert(node_int(cache, "0", "data") == 0);
    s0 = sx_bkv_child(cache, "0");
    times = sx_bkv_child(s0, "AchievementTimes");
    assert(times && sx_bkv_child(times, "1") && !sx_bkv_child(times, "0"));

    // Full selection, then the explicit restore path used on disable.
    stat.selected = 0x7;
    assert(sx_ach_apply(cache, &stat, &orig, SX_ACH_FALLBACK_UNLOCK_TIME) == 1);
    assert(sx_ach_restore(cache, 0, &orig) == 1);
    assert(node_int(cache, "0", "data") == 0);
    s0 = sx_bkv_child(cache, "0");
    times = sx_bkv_child(s0, "AchievementTimes");
    const sx_bkv_node_t *only = sx_bkv_child(times, "1");
    assert(only && only->v.i32 == 111);
    assert(node_int(cache, "9", "data") == 42);

    sx_bkv_free(cache);
}

static sx_ach_app_t *find_app(sx_config_t *cfg, int app_id) {
    for (int i = 0; i < cfg->ach_app_count; i++)
        if (cfg->ach_apps[i].app_id == app_id) return &cfg->ach_apps[i];
    return NULL;
}

static void test_config_parse(void) {
    char path[1200];
    snprintf(path, sizeof(path), "%s/config.yaml", g_home);
    FILE *f = fopen(path, "w");
    assert(f);
    fputs("HideWhatsNew: yes\n"
          "Apps:\n"
          "  - 123\n"
          "AchievementSpoof:\n"
          "  123: all\n"
          "  456:\n"
          "    - ACH_ONE\n"
          "    - \"ACH_TWO\"\n"
          "  - 789\n"
          "PackageIds:\n"
          "  - 20200\n", f);
    assert(fclose(f) == 0);

    sx_config_t cfg;
    assert(sx_config_load(path, &cfg) == 0);
    assert(cfg.ach_app_count == 3);
    assert(cfg.app_count == 1 && cfg.pkg_count == 1);

    sx_ach_app_t *all = find_app(&cfg, 123);
    assert(all && all->all && all->id_count == 0);

    sx_ach_app_t *some = find_app(&cfg, 456);
    assert(some && !some->all && some->id_count == 2);
    assert(sx_config_achievement_selected(&cfg, 456, "ACH_ONE"));
    assert(sx_config_achievement_selected(&cfg, 456, "ACH_TWO"));
    assert(!sx_config_achievement_selected(&cfg, 456, "ACH_THREE"));

    sx_ach_app_t *legacy = find_app(&cfg, 789);
    assert(legacy && legacy->all);

    assert(sx_config_wants_achievements(&cfg, 123));
    assert(sx_config_wants_achievements(&cfg, 456));
    assert(sx_config_wants_achievements(&cfg, 789));
    assert(!sx_config_wants_achievements(&cfg, 999));

    sx_config_free(&cfg);
}

static void test_full_cycle(void) {
    char schema_path[1200], cache_path[1200];
    snprintf(schema_path, sizeof(schema_path), "%s/UserGameStatsSchema_123.bin", g_stats);
    snprintf(cache_path, sizeof(cache_path), "%s/UserGameStats_42_123.bin", g_stats);

    sx_bkv_node_t *schema = build_schema();
    write_blob(schema_path, schema);
    sx_bkv_free(schema);

    sx_bkv_node_t *cache = build_cache();
    write_blob(cache_path, cache);
    sx_bkv_free(cache);

    static sx_config_t cfg;
    static sx_ach_app_t app;
    static char *picked[] = {(char *)"ACH_A", (char *)"ACH_WIDE_9"};
    memset(&cfg, 0, sizeof(cfg));
    memset(&app, 0, sizeof(app));
    static int apps[] = {123};
    cfg.app_ids = apps; cfg.app_count = 1;
    app.app_id = 123; app.ids = picked; app.id_count = 2;
    cfg.ach_apps = &app; cfg.ach_app_count = 1;
    sx_config_current = &cfg;

    sx_ach_spoof_sync();

    sx_bkv_node_t *after = read_blob(cache_path);
    assert(node_int(after, "0", "data") == 0x1);
    const sx_bkv_node_t *s0 = sx_bkv_child(after, "0");
    const sx_bkv_node_t *t0 = sx_bkv_child(s0, "AchievementTimes");
    assert(t0 && sx_bkv_child(t0, "0") && sx_bkv_child(t0, "1"));
    assert(!sx_bkv_child(t0, "2"));
    assert(node_int(after, "3", "data") == 0x200);
    const sx_bkv_node_t *s3 = sx_bkv_child(after, "3");
    const sx_bkv_node_t *t3 = sx_bkv_child(s3, "AchievementTimes");
    assert(t3 && sx_bkv_child(t3, "9"));
    assert(sx_bkv_child(after, "2") == NULL);
    assert(node_int(after, "9", "data") == 42);
    assert(root_int(after, "crc") == (int32_t)0x11223344u);
    sx_bkv_free(after);

    // Change the selection to a different achievement in the same stat.
    static char *picked2[] = {(char *)"ACH_B"};
    app.ids = picked2;
    app.id_count = 1;
    sx_ach_spoof_sync();

    after = read_blob(cache_path);
    assert(node_int(after, "0", "data") == 0x2);
    s0 = sx_bkv_child(after, "0");
    t0 = sx_bkv_child(s0, "AchievementTimes");
    assert(t0 && sx_bkv_child(t0, "1"));
    assert(!sx_bkv_child(t0, "0"));
    assert(sx_bkv_child(after, "3") == NULL);
    sx_bkv_free(after);

    // Disable -> restore the original cache.
    cfg.ach_app_count = 0;
    sx_ach_spoof_sync();

    after = read_blob(cache_path);
    assert(node_int(after, "0", "data") == 0);
    s0 = sx_bkv_child(after, "0");
    t0 = sx_bkv_child(s0, "AchievementTimes");
    assert(t0 && sx_bkv_child(t0, "1") && !sx_bkv_child(t0, "0"));
    assert(sx_bkv_child(after, "3") == NULL);
    assert(node_int(after, "9", "data") == 42);
    sx_bkv_free(after);

    char state_path[1200];
    snprintf(state_path, sizeof(state_path),
             "%s/Library/Application Support/macsteam/achievement-spoof.state", g_home);
    assert(access(state_path, F_OK) != 0);
}

static void test_create_missing_cache(void) {
    char schema_path[1200], cache_path[1200];
    snprintf(schema_path, sizeof(schema_path), "%s/UserGameStatsSchema_456.bin", g_stats);
    snprintf(cache_path, sizeof(cache_path), "%s/UserGameStats_42_456.bin", g_stats);

    sx_bkv_node_t *schema = build_schema();
    write_blob(schema_path, schema);
    sx_bkv_free(schema);

    static sx_config_t cfg;
    static sx_ach_app_t app;
    static char *picked[] = {(char *)"ACH_A", (char *)"ACH_WIDE_9"};
    static int apps[] = {456};
    memset(&cfg, 0, sizeof(cfg));
    memset(&app, 0, sizeof(app));
    cfg.app_ids = apps; cfg.app_count = 1;
    app.app_id = 456; app.ids = picked; app.id_count = 2;
    cfg.ach_apps = &app; cfg.ach_app_count = 1;
    sx_config_current = &cfg;

    sx_ach_spoof_sync();
    assert(access(cache_path, F_OK) == 0);

    sx_bkv_node_t *cache = read_blob(cache_path);
    assert(cache);
    assert(node_int(cache, "0", "data") == 0x1);
    assert(node_int(cache, "3", "data") == 0x200);
    assert(sx_bkv_child(cache, "2") == NULL);
    assert(root_int(cache, "crc") == 0);
    const sx_bkv_node_t *s3 = sx_bkv_child(cache, "3");
    const sx_bkv_node_t *t3 = s3 ? sx_bkv_child(s3, "AchievementTimes") : NULL;
    assert(t3 && sx_bkv_child(t3, "9"));
    sx_bkv_free(cache);

    cfg.ach_app_count = 0;
    sx_ach_spoof_sync();

    cache = read_blob(cache_path);
    assert(cache);
    assert(sx_bkv_child(cache, "0") == NULL);
    assert(sx_bkv_child(cache, "3") == NULL);
    sx_bkv_free(cache);
}

int main(void) {
    sx_log_level = SX_LVL_WARN;

    char tmpl[] = "/tmp/macsteam-ach-XXXXXX";
    char *dir = mkdtemp(tmpl);
    assert(dir);
    snprintf(g_home, sizeof(g_home), "%s", dir);
    assert(setenv("HOME", g_home, 1) == 0);

    snprintf(g_stats, sizeof(g_stats),
             "%s/Library/Application Support/Steam/appcache/stats", g_home);
    char cmd[1200];
    snprintf(cmd, sizeof(cmd), "mkdir -p '%s'", g_stats);
    assert(system(cmd) == 0);

    test_roundtrip();
    test_schema_collect();
    test_apply_restore();
    test_config_parse();
    test_full_cycle();
    test_create_missing_cache();

    puts("Achievement spoof checks passed");
    return 0;
}
