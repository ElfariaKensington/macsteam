// Achievement spoofing via Steam's local stats cache.
#include "achievements.h"
#include "../config/config.h"
#include "../constants.h"
#include "../core/stats_cache.h"
#include "../util/file.h"
#include "../util/log.h"

#include <dirent.h>
#include <dispatch/dispatch.h>
#include <notify.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define STATE_HEADER "v1"
#define STATE_FILE   "achievement-spoof.state"
#define STATE_MAX    4096
#define AUTO_DELAY_US (2 * 1000 * 1000)

typedef struct {
    int           app_id;
    uint32_t      account_id;
    uint32_t      stat_id;
    sx_ach_orig_t orig;
} state_entry_t;

static pthread_mutex_t g_sync_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_sched_mu = PTHREAD_MUTEX_INITIALIZER;

static state_entry_t *g_entries = NULL;
static int            g_entry_count = 0;
static int            g_entry_cap = 0;

// ---------------------------------------------------------------------------
// Helpers

static int name_u32(const char *name, uint32_t *out) {
    if (!name || !*name) return 0;
    uint64_t v = 0;
    for (const char *p = name; *p; p++) {
        if (*p < '0' || *p > '9') return 0;
        v = v * 10 + (uint64_t)(*p - '0');
        if (v > 0xFFFFFFFFull) return 0;
    }
    *out = (uint32_t)v;
    return 1;
}

static int is_achievement_stat(const sx_bkv_node_t *stat) {
    const sx_bkv_node_t *type = sx_bkv_child(stat, "type");
    if (type) {
        if (type->type == SX_BKV_STRING)
            return strcasecmp(type->v.str, "ACHIEVEMENTS") == 0 ||
                   strcasecmp(type->v.str, "GROUPACHIEVEMENTS") == 0;
        if (type->type == SX_BKV_INT)
            return type->v.i32 == 4 || type->v.i32 == 5;
    }
    const sx_bkv_node_t *type_int = sx_bkv_child(stat, "type_int");
    if (type_int && type_int->type == SX_BKV_INT)
        return type_int->v.i32 == 4 || type_int->v.i32 == 5;
    return 0;
}

static uint32_t selection_mask(const sx_bkv_node_t *stat, int app_id,
                               const sx_config_t *cfg, uint32_t *bits_out,
                               uint32_t *valid_out) {
    int all = cfg && sx_config_achievement_all((sx_config_t *)cfg, app_id);
    uint32_t mask = 0;
    uint32_t valid = 0;
    uint32_t total = 0;

    for (const sx_bkv_node_t *c = stat->child; c; c = c->next) {
        if (c->type != SX_BKV_SECTION || strcmp(c->name, "bits") != 0) continue;
        for (const sx_bkv_node_t *b = c->child; b; b = b->next) {
            uint32_t bit = total;
            if (!name_u32(b->name, &bit))
                bit = total;
            if (bit < SX_ACH_MAX_BITS) {
                valid |= 1u << bit;
                if (all) {
                    mask |= 1u << bit;
                } else if (cfg) {
                    const sx_bkv_node_t *id = sx_bkv_child(b, "name");
                    if (id && id->type == SX_BKV_STRING &&
                        sx_config_achievement_selected((sx_config_t *)cfg, app_id, id->v.str))
                        mask |= 1u << bit;
                }
            }
            total++;
        }
    }
    *bits_out = total > SX_ACH_MAX_BITS ? SX_ACH_MAX_BITS : total;
    *valid_out = valid;
    return mask;
}

static uint32_t bit_mask(uint32_t bits) {
    if (bits >= 32) return 0xFFFFFFFFu;
    return bits ? ((1u << bits) - 1u) : 0u;
}

static void stat_key(uint32_t stat_id, char *buf, size_t size) {
    snprintf(buf, size, "%u", stat_id);
}

// ---------------------------------------------------------------------------
// Schema

int sx_ach_collect_schema(const sx_bkv_node_t *schema_root, int app_id,
                          const sx_config_t *cfg,
                          sx_ach_stat_t *out, int max) {
    if (!schema_root || !out || max <= 0) return 0;
    const sx_bkv_node_t *stats = sx_bkv_child(schema_root, "stats");
    if (!stats || stats->type != SX_BKV_SECTION) return 0;

    int count = 0;
    for (const sx_bkv_node_t *node = stats->child; node; node = node->next) {
        if (count >= max) break;
        if (node->type != SX_BKV_SECTION) continue;
        uint32_t stat_id;
        if (!name_u32(node->name, &stat_id)) continue;
        if (!is_achievement_stat(node)) continue;
        uint32_t bits = 0;
        uint32_t valid = 0;
        uint32_t selected = selection_mask(node, app_id, cfg, &bits, &valid);
        if (!bits) continue;
        out[count].stat_id = stat_id;
        out[count].bits = bits;
        out[count].valid_mask = valid;
        out[count].selected = selected;
        count++;
    }

    // Deterministic order regardless of how the schema was serialized.
    for (int i = 1; i < count; i++) {
        sx_ach_stat_t key = out[i];
        int j = i - 1;
        while (j >= 0 && out[j].stat_id > key.stat_id) {
            out[j + 1] = out[j];
            j--;
        }
        out[j + 1] = key;
    }
    return count;
}

// ---------------------------------------------------------------------------
// Cache mutation

void sx_ach_capture(const sx_bkv_node_t *cache_root,
                    const sx_ach_stat_t *stat, sx_ach_orig_t *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    if (!cache_root || !stat) return;

    char key[16];
    stat_key(stat->stat_id, key, sizeof(key));
    const sx_bkv_node_t *sec = sx_bkv_child(cache_root, key);
    if (!sec || sec->type != SX_BKV_SECTION) return;
    out->section_present = 1;

    const sx_bkv_node_t *data = sx_bkv_child(sec, "data");
    if (data && data->type == SX_BKV_INT) {
        out->present = 1;
        out->data = data->v.i32;
    }

    const sx_bkv_node_t *times = sx_bkv_child(sec, "AchievementTimes");
    if (times && times->type == SX_BKV_SECTION) {
        for (const sx_bkv_node_t *t = times->child; t; t = t->next) {
            if (t->type != SX_BKV_INT) continue;
            uint32_t bit;
            if (!name_u32(t->name, &bit) || bit >= SX_ACH_MAX_BITS) continue;
            if (out->time_count >= SX_ACH_MAX_BITS) break;
            int slot = out->time_count++;
            out->times[slot].bit = (int)bit;
            out->times[slot].time = t->v.i32;
        }
    }
}

static int orig_time(const sx_ach_orig_t *orig, uint32_t bit, int32_t *out) {
    for (int i = 0; i < orig->time_count; i++) {
        if ((uint32_t)orig->times[i].bit == bit) {
            *out = orig->times[i].time;
            return 1;
        }
    }
    return 0;
}

int sx_ach_apply(sx_bkv_node_t *cache_root, const sx_ach_stat_t *stat,
                 const sx_ach_orig_t *orig, uint32_t unlock_time) {
    if (!cache_root || !stat || !orig || !stat->bits) return 0;

    char key[16];
    stat_key(stat->stat_id, key, sizeof(key));
    uint32_t valid = stat->valid_mask ? stat->valid_mask : bit_mask(stat->bits);
    uint32_t mask = stat->selected & valid;

    if (!orig->section_present && mask == 0) {
        if (!sx_bkv_child(cache_root, key)) return 0;
        sx_bkv_remove(cache_root, key);
        return 1;
    }

    sx_bkv_node_t *sec = sx_bkv_ensure_section(cache_root, key);
    if (!sec) return 0;

    int changed = 0;
    uint32_t base = orig->present ? (uint32_t)orig->data : 0;
    uint32_t wanted = base | mask;
    sx_bkv_node_t *data = sx_bkv_child(sec, "data");
    if (!data || data->type != SX_BKV_INT || (uint32_t)data->v.i32 != wanted) {
        if (!sx_bkv_set_int(sec, "data", (int32_t)wanted)) return 0;
        changed = 1;
    }

    int any_time = 0;
    for (uint32_t bit = 0; bit < SX_ACH_MAX_BITS; bit++) {
        if (!(valid & (1u << bit))) continue;
        int32_t dummy;
        if ((mask & (1u << bit)) || orig_time(orig, bit, &dummy)) {
            any_time = 1;
            break;
        }
    }

    if (!any_time) {
        if (sx_bkv_child(sec, "AchievementTimes")) {
            sx_bkv_remove(sec, "AchievementTimes");
            changed = 1;
        }
        return changed;
    }

    sx_bkv_node_t *times = sx_bkv_ensure_section(sec, "AchievementTimes");
    if (!times) return changed;
    int32_t fallback = (int32_t)unlock_time;

    for (uint32_t bit = 0; bit < SX_ACH_MAX_BITS; bit++) {
        if (!(valid & (1u << bit))) continue;
        char name[16];
        snprintf(name, sizeof(name), "%u", bit);
        int has_time = 0;
        int32_t when = 0;
        if (mask & (1u << bit)) {
            has_time = 1;
            when = fallback;
        } else {
            has_time = orig_time(orig, bit, &when);
        }

        if (has_time) {
            sx_bkv_node_t *node = sx_bkv_child(times, name);
            if (!node || node->type != SX_BKV_INT || node->v.i32 != when) {
                if (!sx_bkv_set_int(times, name, when)) return changed;
                changed = 1;
            }
        } else if (sx_bkv_child(times, name)) {
            sx_bkv_remove(times, name);
            changed = 1;
        }
    }
    return changed;
}

int sx_ach_restore(sx_bkv_node_t *cache_root, uint32_t stat_id,
                   const sx_ach_orig_t *orig) {
    if (!cache_root || !orig) return 0;

    char key[16];
    stat_key(stat_id, key, sizeof(key));
    sx_bkv_node_t *sec = sx_bkv_child(cache_root, key);
    if (!sec || sec->type != SX_BKV_SECTION) return 0;

    if (!orig->section_present) {
        sx_bkv_remove(cache_root, key);
        return 1;
    }

    if (orig->present) {
        sx_bkv_node_t *data = sx_bkv_child(sec, "data");
        if (!data || data->type != SX_BKV_INT || data->v.i32 != orig->data) {
            if (!sx_bkv_set_int(sec, "data", orig->data)) return 0;
        }
    } else {
        sx_bkv_remove(sec, "data");
    }

    sx_bkv_remove(sec, "AchievementTimes");
    if (orig->time_count > 0) {
        sx_bkv_node_t *times = sx_bkv_ensure_section(sec, "AchievementTimes");
        if (!times) return 0;
        for (int i = 0; i < orig->time_count; i++) {
            char name[16];
            snprintf(name, sizeof(name), "%d", orig->times[i].bit);
            if (!sx_bkv_set_int(times, name, orig->times[i].time)) return 0;
        }
    }
    return 1;
}

// ---------------------------------------------------------------------------
// State file

static void entries_free(void) {
    free(g_entries);
    g_entries = NULL;
    g_entry_count = 0;
    g_entry_cap = 0;
}

static state_entry_t *entry_find(int app_id, uint32_t account_id, uint32_t stat_id) {
    for (int i = 0; i < g_entry_count; i++) {
        if (g_entries[i].app_id == app_id &&
            g_entries[i].account_id == account_id &&
            g_entries[i].stat_id == stat_id)
            return &g_entries[i];
    }
    return NULL;
}

static state_entry_t *entry_add(int app_id, uint32_t account_id, uint32_t stat_id) {
    if (g_entry_count >= STATE_MAX) return NULL;
    if (g_entry_count >= g_entry_cap) {
        int cap = g_entry_cap ? g_entry_cap * 2 : 32;
        state_entry_t *grown = (state_entry_t *)realloc(g_entries, (size_t)cap * sizeof(*grown));
        if (!grown) return NULL;
        g_entries = grown;
        g_entry_cap = cap;
    }
    state_entry_t *e = &g_entries[g_entry_count++];
    memset(e, 0, sizeof(*e));
    e->app_id = app_id;
    e->account_id = account_id;
    e->stat_id = stat_id;
    return e;
}

static void entry_remove_at(int index) {
    if (index < 0 || index >= g_entry_count) return;
    memmove(&g_entries[index], &g_entries[index + 1],
            (size_t)(g_entry_count - index - 1) * sizeof(g_entries[0]));
    g_entry_count--;
}

static void state_path(char *buf, size_t size) {
    const char *home = sx_resolve_home();
    if (!home) home = "/tmp";
    sx_macsteam_support_path(buf, size, home, STATE_FILE);
}

static void ensure_parent_dir(const char *path) {
    char dir[2048];
    snprintf(dir, sizeof(dir), "%s", path);
    char *slash = strrchr(dir, '/');
    if (!slash) return;
    *slash = '\0';
    mkdir(dir, 0755);
}

static void state_load(void) {
    entries_free();
    char path[2048];
    state_path(path, sizeof(path));
    FILE *f = fopen(path, "r");
    if (!f) return;

    char line[2048];
    while (fgets(line, sizeof(line), f)) {
        char *save = NULL;
        char *tok = strtok_r(line, " \t\r\n", &save);
        if (!tok || strcmp(tok, STATE_HEADER) != 0) continue;
        tok = strtok_r(NULL, " \t\r\n", &save);
        if (!tok) continue;
        int app_id = atoi(tok);
        tok = strtok_r(NULL, " \t\r\n", &save);
        if (!tok) continue;
        uint32_t account_id = (uint32_t)strtoul(tok, NULL, 10);
        tok = strtok_r(NULL, " \t\r\n", &save);
        if (!tok) continue;
        uint32_t stat_id = (uint32_t)strtoul(tok, NULL, 10);
        tok = strtok_r(NULL, " \t\r\n", &save);
        if (!tok) continue;
        int section_present = atoi(tok) ? 1 : 0;
        tok = strtok_r(NULL, " \t\r\n", &save);
        if (!tok) continue;
        int has_data = strcmp(tok, "-") != 0;
        int32_t data = has_data ? (int32_t)strtoul(tok, NULL, 16) : 0;
        tok = strtok_r(NULL, " \t\r\n", &save);
        int count = tok ? atoi(tok) : 0;

        state_entry_t *e = entry_add(app_id, account_id, stat_id);
        if (!e) break;
        e->orig.section_present = section_present;
        e->orig.present = has_data;
        e->orig.data = data;

        for (int i = 0; i < count && e->orig.time_count < SX_ACH_MAX_BITS; i++) {
            tok = strtok_r(NULL, " \t\r\n", &save);
            if (!tok) break;
            int bit = 0, when = 0;
            if (sscanf(tok, "%d:%d", &bit, &when) == 2 &&
                bit >= 0 && bit < SX_ACH_MAX_BITS) {
                int slot = e->orig.time_count++;
                e->orig.times[slot].bit = bit;
                e->orig.times[slot].time = when;
            }
        }
    }
    fclose(f);
    SX_DBG("[achievements] state: %d entr%s", g_entry_count,
           g_entry_count == 1 ? "y" : "ies");
}

static int state_save(void) {
    char path[2048], tmp[2100];
    state_path(path, sizeof(path));
    ensure_parent_dir(path);
    snprintf(tmp, sizeof(tmp), "%s.%d.tmp", path, (int)getpid());

    FILE *f = fopen(tmp, "w");
    if (!f) {
        SX_WARN("[achievements] cannot write %s: %s", tmp, strerror(errno));
        return -1;
    }
    for (int i = 0; i < g_entry_count; i++) {
        const state_entry_t *e = &g_entries[i];
        fprintf(f, "%s %d %u %u %d ", STATE_HEADER, e->app_id, e->account_id,
                e->stat_id, e->orig.section_present ? 1 : 0);
        if (e->orig.present) fprintf(f, "%08X ", (uint32_t)e->orig.data);
        else fputs("- ", f);
        fprintf(f, "%d", e->orig.time_count);
        for (int t = 0; t < e->orig.time_count; t++)
            fprintf(f, " %d:%d", e->orig.times[t].bit, e->orig.times[t].time);
        fputc('\n', f);
    }
    int ok = fflush(f) == 0;
    if (ok) fsync(fileno(f));
    if (fclose(f) != 0) ok = 0;
    if (!ok) { unlink(tmp); return -1; }

    if (g_entry_count == 0) {
        unlink(path);
        unlink(tmp);
        return 0;
    }
    if (rename(tmp, path) != 0) { unlink(tmp); return -1; }
    return 0;
}

// ---------------------------------------------------------------------------
// Mapping

static int config_has_achievements(const sx_config_t *cfg, int app_id) {
    return cfg ? sx_config_wants_achievements((sx_config_t *)cfg, app_id) : 0;
}

static int config_has_any(const sx_config_t *cfg) {
    return cfg && cfg->ach_app_count > 0;
}

static void cache_path(int app_id, uint32_t account_id, char *buf, size_t size) {
    const char *home = sx_resolve_home();
    char dir[1024];
    if (!home) home = "/tmp";
    sx_steam_appcache_path(dir, sizeof(dir), home, "stats");
    snprintf(buf, size, "%s/UserGameStats_%u_%d.bin", dir, account_id, app_id);
}

static void stats_dir_path(char *buf, size_t size) {
    const char *home = sx_resolve_home();
    if (!home) home = "/tmp";
    sx_steam_appcache_path(buf, size, home, "stats");
}

// ---------------------------------------------------------------------------
// Sync

static int bkv_matches(const sx_bkv_node_t *root, const uint8_t *data, size_t len) {
    size_t need = sx_bkv_encoded_size(root);
    if (need != len) return 0;
    uint8_t *buf = (uint8_t *)malloc(need);
    if (!buf) return 0;
    int n = sx_bkv_encode(root, buf, need);
    int same = (n == (int)len && memcmp(buf, data, len) == 0);
    free(buf);
    return same;
}

static int sync_cache_file(int app_id, uint32_t account_id,
                           const char *path, const sx_ach_stat_t *stats, int count,
                           int *state_dirty) {
    size_t len = 0;
    uint8_t *blob = sx_slurp_file(path, &len);
    if (!blob) return 0;

    sx_bkv_node_t *root = sx_bkv_parse(blob, len);
    if (!root) {
        SX_WARN("[achievements] app %d: cannot parse %s", app_id, path);
        free(blob);
        return 0;
    }
    if (strcmp(root->name, "cache") != 0) {
        sx_bkv_free(root);
        free(blob);
        return 0;
    }

    int file_dirty = 0;
    int applied = 0;
    for (int i = 0; i < count; i++) {
        state_entry_t *known = entry_find(app_id, account_id, stats[i].stat_id);
        if (!known) {
            if (stats[i].selected == 0) continue;
            sx_ach_orig_t orig;
            sx_ach_capture(root, &stats[i], &orig);
            known = entry_add(app_id, account_id, stats[i].stat_id);
            if (!known) continue;
            known->orig = orig;
            *state_dirty = 1;
        }

        int changed = sx_ach_apply(root, &stats[i], &known->orig,
                                   SX_ACH_FALLBACK_UNLOCK_TIME);
        if (!changed) continue;
        applied++;
        file_dirty = 1;
    }

    int needs_write = file_dirty || !bkv_matches(root, blob, len);
    if (!needs_write) {
        sx_bkv_free(root);
        free(blob);
        return 0;
    }

    // Persist originals before touching the cache so a crash cannot leave an
    // unrecoverable edit behind.
    if (file_dirty && *state_dirty && state_save() != 0) {
        SX_WARN("[achievements] app %d: state save failed; leaving %s alone",
                app_id, path);
        sx_bkv_free(root);
        free(blob);
        return 0;
    }

    int rc = sx_bkv_write_file_atomic(path, root);
    sx_bkv_free(root);
    free(blob);
    if (rc != 0) {
        SX_WARN("[achievements] app %d: failed to write %s", app_id, path);
        return 0;
    }
    if (applied)
        SX_LOG("[achievements] app %d: updated %d achievement group(s) in %s",
               app_id, applied, path);
    else
        SX_DBG("[achievements] app %d: normalized stats cache %s", app_id, path);
    return 1;
}

static uint32_t newest_account_id(const char *dir_path) {
    DIR *dir = opendir(dir_path);
    if (!dir) return 0;

    uint32_t best = 0;
    time_t best_time = 0;
    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        unsigned account = 0;
        int app = 0;
        if (sscanf(ent->d_name, "UserGameStats_%u_%d.bin", &account, &app) != 2)
            continue;

        char path[1200];
        snprintf(path, sizeof(path), "%s/%s", dir_path, ent->d_name);
        struct stat st;
        if (stat(path, &st) != 0) continue;
        if (best == 0 || st.st_mtime >= best_time) {
            best = (uint32_t)account;
            best_time = st.st_mtime;
        }
    }
    closedir(dir);
    return best;
}

static int create_cache_file(int app_id, uint32_t account_id,
                             const sx_ach_stat_t *stats, int count,
                             int *state_dirty) {
    int has_selection = 0;
    for (int i = 0; i < count; i++) {
        if (stats[i].selected) { has_selection = 1; break; }
    }
    if (!has_selection) return 0;

    sx_bkv_node_t *root = sx_bkv_new_section("cache");
    if (!root) return 0;
    if (!sx_bkv_set_int(root, "PendingChanges", 0) ||
        !sx_bkv_set_int(root, "crc", 0)) {
        sx_bkv_free(root);
        return 0;
    }

    int applied = 0;
    for (int i = 0; i < count; i++) {
        if (!stats[i].selected) continue;

        sx_ach_orig_t orig;
        memset(&orig, 0, sizeof(orig));
        state_entry_t *known = entry_find(app_id, account_id, stats[i].stat_id);
        if (!known) {
            known = entry_add(app_id, account_id, stats[i].stat_id);
            if (!known) continue;
        }
        // A missing cache has no original values to preserve.
        known->orig = orig;
        *state_dirty = 1;
        if (sx_ach_apply(root, &stats[i], &orig, SX_ACH_FALLBACK_UNLOCK_TIME))
            applied++;
    }

    if (!applied) {
        sx_bkv_free(root);
        return 0;
    }
    if (*state_dirty && state_save() != 0) {
        SX_WARN("[achievements] app %d: state save failed; not creating a cache", app_id);
        sx_bkv_free(root);
        return 0;
    }

    char path[1200];
    cache_path(app_id, account_id, path, sizeof(path));
    int rc = sx_bkv_write_file_atomic(path, root);
    sx_bkv_free(root);
    if (rc != 0) {
        SX_WARN("[achievements] app %d: failed to create %s", app_id, path);
        return 0;
    }
    SX_LOG("[achievements] app %d: created stats cache %s", app_id, path);
    return 1;
}

static int sync_app(const sx_config_t *cfg, int app_id, int *state_dirty) {
    char schema_path[1200];
    if (sx_stats_schema_path(app_id, schema_path, sizeof(schema_path)) != 0)
        return 0;

    size_t schema_len = 0;
    uint8_t *schema_blob = sx_slurp_file(schema_path, &schema_len);
    if (!schema_blob) {
        SX_DBG("[achievements] app %d: no schema yet (%s)", app_id, schema_path);
        return 0;
    }
    sx_bkv_node_t *schema = sx_bkv_parse(schema_blob, schema_len);
    free(schema_blob);
    if (!schema) {
        SX_WARN("[achievements] app %d: cannot parse schema %s", app_id, schema_path);
        return 0;
    }

    sx_ach_stat_t stats[SX_ACH_MAX_STATS];
    int count = sx_ach_collect_schema(schema, app_id, cfg, stats, SX_ACH_MAX_STATS);
    sx_bkv_free(schema);
    if (!count) {
        SX_DBG("[achievements] app %d: schema has no achievement stats", app_id);
        return 0;
    }

    char dir_path[1024];
    stats_dir_path(dir_path, sizeof(dir_path));
    DIR *dir = opendir(dir_path);
    if (!dir) return 0;

    int touched = 0;
    int saw_app = 0;
    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        unsigned account = 0;
        int app = 0;
        if (sscanf(ent->d_name, "UserGameStats_%u_%d.bin", &account, &app) != 2)
            continue;
        if (app != app_id) continue;

        saw_app = 1;
        char path[1200];
        cache_path(app_id, (uint32_t)account, path, sizeof(path));
        touched |= sync_cache_file(app_id, (uint32_t)account, path,
                                    stats, count, state_dirty);
    }
    closedir(dir);

    if (!saw_app) {
        uint32_t account_id = newest_account_id(dir_path);
        if (account_id) {
            touched |= create_cache_file(app_id, account_id, stats, count, state_dirty);
        } else {
            SX_WARN("[achievements] app %d: no stats cache and no account to create one",
                    app_id);
        }
    }

    if (!touched)
        SX_DBG("[achievements] app %d: %d achievement group(s), cache already current",
               app_id, count);
    return touched;
}

static int restore_disabled(const sx_config_t *cfg, int *state_dirty) {
    int touched = 0;
    for (int i = 0; i < g_entry_count; ) {
        state_entry_t *e = &g_entries[i];
        if (config_has_achievements(cfg, e->app_id)) { i++; continue; }

        int app_id = e->app_id;
        uint32_t account_id = e->account_id;

        char path[1200];
        cache_path(app_id, account_id, path, sizeof(path));
        size_t len = 0;
        uint8_t *blob = sx_slurp_file(path, &len);
        sx_bkv_node_t *root = blob ? sx_bkv_parse(blob, len) : NULL;

        int changed = 0;
        if (root) {
            for (int j = 0; j < g_entry_count; j++) {
                state_entry_t *candidate = &g_entries[j];
                if (candidate->app_id != app_id ||
                    candidate->account_id != account_id) continue;
                changed |= sx_ach_restore(root, candidate->stat_id, &candidate->orig);
            }
        }

        int needs_write = root && (changed || !bkv_matches(root, blob, len));
        int wrote = 1;
        if (needs_write)
            wrote = sx_bkv_write_file_atomic(path, root) == 0;
        sx_bkv_free(root);
        free(blob);

        // Could not persist the restore: keep the snapshots for a later run.
        if (!wrote) return touched;

        if (changed) {
            SX_LOG("[achievements] app %d: restored achievements in %s", app_id, path);
            touched = 1;
        }

        for (int j = g_entry_count - 1; j >= 0; j--) {
            if (g_entries[j].app_id == app_id &&
                g_entries[j].account_id == account_id) {
                entry_remove_at(j);
                *state_dirty = 1;
            }
        }
        // The entry at i was removed; the next entry shifted into its place.
    }
    return touched;
}

static void sync_internal(int only_app) {
    pthread_mutex_lock(&g_sync_mu);

    sx_config_t *cfg = sx_config_current;
    if (!cfg) {
        pthread_mutex_unlock(&g_sync_mu);
        return;
    }

    state_load();
    int state_dirty = 0;

    for (int i = 0; i < cfg->ach_app_count; i++) {
        int app_id = cfg->ach_apps[i].app_id;
        if (only_app >= 0 && app_id != only_app) continue;
        sync_app(cfg, app_id, &state_dirty);
    }

    if (only_app < 0)
        restore_disabled(cfg, &state_dirty);

    if (state_dirty)
        state_save();

    pthread_mutex_unlock(&g_sync_mu);
}

void sx_ach_spoof_sync(void) {
    sync_internal(-1);
}

void sx_ach_spoof_sync_app(int app_id) {
    if (app_id > 0) sync_internal(app_id);
}

int sx_ach_spoof_enabled(void) {
    return config_has_any(sx_config_current);
}

// ---------------------------------------------------------------------------
// Config reload watcher

static int g_watch_token = -1;

static void reload_config(void) {
    sx_config_t *next = (sx_config_t *)calloc(1, sizeof(*next));
    if (!next) return;
    char path[1024];
    sx_file_config_path(path, sizeof(path));
    if (sx_config_load(path, next) != 0) {
        free(next);
        SX_WARN("[achievements] config reload failed; keeping the active config");
        return;
    }
    sx_config_current = next; // old snapshots stay alive for concurrent readers
    SX_LOG("[achievements] config reloaded; syncing selections");
    sx_ach_spoof_sync();
}

void sx_ach_spoof_start_watcher(void) {
    if (g_watch_token >= 0) return;
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    if (notify_register_dispatch("com.macsteam.achievements.refresh",
                                 &g_watch_token, queue, ^(int token) {
        (void)token;
        reload_config();
    }) != NOTIFY_STATUS_OK) {
        g_watch_token = -1;
        SX_WARN("[achievements] could not register config watcher");
    } else {
        SX_DBG("[achievements] config watcher registered");
    }
}

// ---------------------------------------------------------------------------
// Delayed sync (stats hook)

typedef struct {
    int app_id;
} schedule_arg_t;

static void *schedule_worker(void *opaque) {
    schedule_arg_t *arg = (schedule_arg_t *)opaque;
    int app_id = arg->app_id;
    free(arg);
    usleep(AUTO_DELAY_US);
    sx_ach_spoof_sync_app(app_id);
    return NULL;
}

void sx_ach_spoof_schedule(int app_id) {
    if (app_id <= 0 || !sx_ach_spoof_enabled()) return;

    static int recent[32];
    static time_t recent_at[32];
    time_t now = time(NULL);

    pthread_mutex_lock(&g_sched_mu);
    int slot = -1;
    for (int i = 0; i < 32; i++) {
        if (recent[i] == app_id && now - recent_at[i] < 30) {
            pthread_mutex_unlock(&g_sched_mu);
            return;
        }
        if (recent[i] == 0) { slot = i; break; }
    }
    if (slot < 0) {
        // Replace the oldest slot.
        slot = 0;
        for (int i = 1; i < 32; i++)
            if (recent_at[i] < recent_at[slot]) slot = i;
    }
    recent[slot] = app_id;
    recent_at[slot] = now;
    pthread_mutex_unlock(&g_sched_mu);

    schedule_arg_t *arg = (schedule_arg_t *)malloc(sizeof(*arg));
    if (!arg) return;
    arg->app_id = app_id;

    pthread_t thread;
    if (pthread_create(&thread, NULL, schedule_worker, arg) != 0) {
        free(arg);
        return;
    }
    pthread_detach(thread);
}
