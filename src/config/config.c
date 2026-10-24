// Config file parser
#include "config.h"
#include "../util/log.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

_Atomic(sx_config_t *) sx_config_current = NULL;

enum parse_section {
    SEC_NONE = 0,
    SEC_APPS,
    SEC_PACKAGE_IDS,
    SEC_DEPOT_KEYS,
    SEC_ONLINEFIX,
};

static int indent_of(const char *line) {
    int n = 0;
    while (line[n] == ' ') n++;
    return n;
}

static void strip_trailing(char *s) {
    size_t len = strlen(s);
    while (len > 0 && (s[len-1] == '\n' || s[len-1] == '\r' ||
                       s[len-1] == ' '  || s[len-1] == '\t'))
        s[--len] = '\0';
}

static int parse_bool(const char *s) {
    if (!s) return 0;
    while (*s == ' ') s++;
    if (strcasecmp(s, "yes") == 0 || strcasecmp(s, "true") == 0 || strcmp(s, "1") == 0)
        return 1;
    return 0;
}

static const char *value_after_colon(const char *line) {
    const char *colon = strchr(line, ':');
    if (!colon) return NULL;
    colon++;
    while (*colon == ' ' || *colon == '\t') colon++;
    if (*colon == '\0' || *colon == '\n') return NULL;
    return colon;
}

static int section_is(const char *trimmed, const char *key) {
    size_t klen = strlen(key);
    return strncmp(trimmed, key, klen) == 0 && trimmed[klen] == ':';
}

static int key_before_colon(const char *line, char *buf, size_t buf_sz) {
    while (*line == ' ' || *line == '\t') line++;
    const char *colon = strchr(line, ':');
    if (!colon) return -1;
    size_t klen = (size_t)(colon - line);
    if (klen == 0 || klen >= buf_sz) return -1;
    memcpy(buf, line, klen);
    buf[klen] = '\0';
    while (klen > 0 && buf[klen-1] == ' ') buf[--klen] = '\0';
    return 0;
}

static void strip_quotes(char *s) {
    size_t len = strlen(s);
    if (len >= 2 && ((s[0] == '"' && s[len-1] == '"') ||
                     (s[0] == '\'' && s[len-1] == '\''))) {
        memmove(s, s + 1, len - 2);
        s[len - 2] = '\0';
    }
}

static int append_int(int **arr, int *count, int *cap, int value) {
    if (*count >= *cap) {
        int new_cap = (*cap == 0) ? 32 : (*cap * 2);
        int *new_arr = (int *)realloc(*arr, (size_t)new_cap * sizeof(int));
        if (!new_arr) return -1;
        *arr = new_arr;
        *cap = new_cap;
    }
    (*arr)[(*count)++] = value;
    return 0;
}

int sx_config_load(const char *path, sx_config_t *cfg) {
    if (!path || !cfg) return -1;
    memset(cfg, 0, sizeof(*cfg));

    FILE *f = fopen(path, "r");
    if (!f) {
        SX_ERR("config: cannot open '%s'", path);
        return -1;
    }

    char line[1024];
    enum parse_section section = SEC_NONE;
    int app_cap = 0, pkg_cap = 0;
    int dk_current_app = 0;
    int of_current = -1;
    unsigned of_seen = 0;
    int of_invalid = 0;

    while (fgets(line, sizeof(line), f)) {
        strip_trailing(line);
        int indent = indent_of(line);
        const char *trimmed = line + indent;

        if (trimmed[0] == '\0' || trimmed[0] == '#')
            continue;

        if (indent == 0) {
            section = SEC_NONE;
            dk_current_app = 0;
            of_current = -1;

            if (section_is(trimmed, "OnlineFix")) { section = SEC_ONLINEFIX; continue; }
            if (section_is(trimmed, "Apps"))           { section = SEC_APPS; continue; }
            if (section_is(trimmed, "PackageIds"))      { section = SEC_PACKAGE_IDS; continue; }
            if (section_is(trimmed, "DepotKeys"))       { section = SEC_DEPOT_KEYS; continue; }
            const char *val = value_after_colon(trimmed);
            if (val) {
                if (strncmp(trimmed, "HideWhatsNew", 12) == 0)
                    cfg->hide_whats_new = parse_bool(val);
            }
            continue;
        }

        if (section == SEC_ONLINEFIX) {
            if (of_invalid) continue;
            if (indent == 2) {
                of_current = -1;
                of_seen = 0;
                char key[64], *end = NULL;
                if (key_before_colon(line, key, sizeof(key)) != 0) goto invalid_onlinefix;
                long id = strtol(key, &end, 10);
                if (!*key || *end || id < 1 || id > 0xffffff || id == 480 || value_after_colon(line))
                    goto invalid_onlinefix;
                // Reject duplicate game entries rather than choosing one silently.
                for (int i = 0; i < cfg->onlinefix_count; ++i)
                    if (cfg->onlinefix_games[i].app_id == id) goto invalid_onlinefix;
                void *entries = realloc(cfg->onlinefix_games,
                    (size_t)(cfg->onlinefix_count + 1) * sizeof(*cfg->onlinefix_games));
                if (!entries) goto invalid_onlinefix;
                cfg->onlinefix_games = entries;
                of_current = cfg->onlinefix_count++;
                cfg->onlinefix_games[of_current] = (sx_onlinefix_game_t){(int)id, 0, 1, 1, 1, 1};
            } else if (indent == 4 && of_current >= 0) {
                char key[64];
                if (key_before_colon(line, key, sizeof(key)) != 0) goto invalid_onlinefix;
                const char *val = value_after_colon(line);
                if (!val) goto invalid_onlinefix;
                int on = parse_bool(val);
                if (!on && strcasecmp(val, "no") && strcasecmp(val, "false") && strcmp(val, "0"))
                    goto invalid_onlinefix;
                sx_onlinefix_game_t *g = &cfg->onlinefix_games[of_current];
                const char *keys[] = {"KeepRealAppID", "StartupAppID", "OverlayAppID", "InputAppID", "StatsAppID"};
                int *fields[] = {&g->keep_real_app_id, &g->startup_app_id, &g->overlay_app_id,
                                 &g->input_app_id, &g->stats_app_id};
                size_t k;
                for (k = 0; k < sizeof(keys) / sizeof(keys[0]); ++k)
                    if (!strcmp(key, keys[k])) break;
                if (k == sizeof(keys) / sizeof(keys[0]) || (of_seen & (1u << k)))
                    goto invalid_onlinefix;
                of_seen |= 1u << k;
                *fields[k] = on;
            } else goto invalid_onlinefix;
            continue;

invalid_onlinefix:
            // A typo in this optional feature must not discard the unlock list.
            free(cfg->onlinefix_games);
            cfg->onlinefix_games = NULL;
            cfg->onlinefix_count = 0;
            of_invalid = 1;
            SX_ERR("config: invalid OnlineFix settings in '%s'; routing disabled", path);
            continue;
        }

        if (indent == 2) {
            if (trimmed[0] == '-') {
                const char *item = trimmed + 1;
                while (*item == ' ') item++;
                int rc = 0;
                switch (section) {
                case SEC_APPS:
                    rc = append_int(&cfg->app_ids, &cfg->app_count, &app_cap, atoi(item)); break;
                case SEC_PACKAGE_IDS:
                    rc = append_int(&cfg->package_ids, &cfg->pkg_count, &pkg_cap, atoi(item)); break;
                default: break;
                }
                if (rc != 0)
                    SX_ERR("config: out of memory appending list item '%s' (dropped)", item);
                continue;
            }

            if (section == SEC_DEPOT_KEYS) {
                char key[64];
                if (key_before_colon(line, key, sizeof(key)) == 0)
                    dk_current_app = atoi(key);
                continue;
            }
            continue;
        }

        if (indent == 4 && section == SEC_DEPOT_KEYS && dk_current_app) {
            char key[64];
            if (key_before_colon(line, key, sizeof(key)) == 0) {
                const char *val = value_after_colon(line);
                if (val) {
                    int dk_idx = -1;
                    for (int i = 0; i < cfg->dk_count; i++) {
                        if (cfg->depot_keys[i].app_id == dk_current_app) {
                            dk_idx = i; break;
                        }
                    }
                    if (dk_idx < 0 && cfg->dk_count < SX_CONFIG_MAX_DK) {
                        dk_idx = cfg->dk_count++;
                        cfg->depot_keys[dk_idx].app_id = dk_current_app;
                        cfg->depot_keys[dk_idx].depot_count = 0;
                    }
                    if (dk_idx >= 0) {
                        int dc = cfg->depot_keys[dk_idx].depot_count;
                        if (dc < SX_CONFIG_MAX_DEPOTS) {
                            cfg->depot_keys[dk_idx].depots[dc].depot_id = atoi(key);
                            char tmp[67];
                            snprintf(tmp, sizeof(tmp), "%s", val);
                            strip_quotes(tmp);
                            snprintf(cfg->depot_keys[dk_idx].depots[dc].key,
                                     sizeof(cfg->depot_keys[dk_idx].depots[dc].key), "%s", tmp);
                            cfg->depot_keys[dk_idx].depot_count++;
                        }
                    }
                }
            }
            continue;
        }
    }

    fclose(f);
    SX_LOG("config: loaded '%s'. %d apps, %d pkgs, %d depot_key groups",
           path, cfg->app_count, cfg->pkg_count, cfg->dk_count);
    return 0;
}

void sx_config_free(sx_config_t *cfg) {
    if (!cfg) return;
    free(cfg->onlinefix_games); cfg->onlinefix_games = NULL; cfg->onlinefix_count = 0;
    free(cfg->app_ids); cfg->app_ids = NULL; cfg->app_count = 0;
    free(cfg->package_ids); cfg->package_ids = NULL; cfg->pkg_count = 0;
}

static int contains_int(const int *values, int count, int target) {
    for (int i = 0; i < count; i++)
        if (values[i] == target) return 1;
    return 0;
}

int sx_config_has_app(sx_config_t *cfg, int app_id) {
    return cfg ? contains_int(cfg->app_ids, cfg->app_count, app_id) : 0;
}

int sx_config_has_package(sx_config_t *cfg, int package_id) {
    return cfg ? contains_int(cfg->package_ids, cfg->pkg_count, package_id) : 0;
}

int sx_config_app_depots(sx_config_t *cfg, int app_id, int *out, int max) {
    if (!cfg || !out || max <= 0) return 0;
    int n = 0;
    for (int i = 0; i < cfg->dk_count && n < max; i++) {
        if (cfg->depot_keys[i].app_id != app_id) continue;
        for (int j = 0; j < cfg->depot_keys[i].depot_count && n < max; j++)
            out[n++] = cfg->depot_keys[i].depots[j].depot_id;
    }
    return n;
}

static int copy_key_checked(char *dst, size_t dst_sz, const char *src) {
    size_t n = strlen(src);
    if (dst_sz == 0 || n >= dst_sz) return -1;
    memcpy(dst, src, n + 1);
    return 0;
}

int sx_config_get_depot_key_any(sx_config_t *cfg, int depot_id, char *key_out, size_t key_out_sz) {
    if (!cfg || !key_out) return -1;
    for (int i = 0; i < cfg->dk_count; i++) {
        for (int j = 0; j < cfg->depot_keys[i].depot_count; j++) {
            if (cfg->depot_keys[i].depots[j].depot_id == depot_id)
                return copy_key_checked(key_out, key_out_sz, cfg->depot_keys[i].depots[j].key);
        }
    }
    return -1;
}
