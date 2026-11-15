// Config file parser
#ifndef MACSTEAM_CONFIG_CONFIG_H
#define MACSTEAM_CONFIG_CONFIG_H

#include <stddef.h>
#include <stdatomic.h>

#define SX_CONFIG_MAX_DK       256
#define SX_CONFIG_MAX_DEPOTS   64
#define SX_CONFIG_ACH_ID       96

typedef struct {
    int app_id;
    int keep_real_app_id;
    int startup_app_id, overlay_app_id, input_app_id, stats_app_id;
} sx_onlinefix_game_t;

typedef struct {
    int    app_id;
    int    all;        // unlock every achievement in the schema
    char **ids;        // otherwise, the selected achievement ids
    int    id_count;
    int    id_cap;
} sx_ach_app_t;

typedef struct sx_config {
    int  *app_ids;
    int   app_count;

    int  *package_ids;
    int   pkg_count;

    // Per-app achievement spoofing selections.
    sx_ach_app_t *ach_apps;
    int           ach_app_count;

    struct {
        int app_id;
        struct {
            int  depot_id;
            char key[65];
        } depots[SX_CONFIG_MAX_DEPOTS];
        int depot_count;
    } depot_keys[SX_CONFIG_MAX_DK];
    int dk_count;

    int hide_whats_new;
    sx_onlinefix_game_t *onlinefix_games;
    int onlinefix_count;
    int hide_cloud_errors;
} sx_config_t;

extern _Atomic(sx_config_t *) sx_config_current;

int sx_config_load(const char *path, sx_config_t *cfg);
void sx_config_free(sx_config_t *cfg);
int sx_config_has_app(sx_config_t *cfg, int app_id);
int sx_config_has_package(sx_config_t *cfg, int package_id);
int sx_config_wants_achievements(sx_config_t *cfg, int app_id);
const sx_ach_app_t *sx_config_achievement_app(sx_config_t *cfg, int app_id);
int sx_config_achievement_all(sx_config_t *cfg, int app_id);
int sx_config_achievement_selected(sx_config_t *cfg, int app_id, const char *ach_id);
int sx_config_app_depots(sx_config_t *cfg, int app_id, int *out, int max);
int sx_config_get_depot_key_any(sx_config_t *cfg, int depot_id, char *key_out, size_t key_out_sz);

#endif // MACSTEAM_CONFIG_CONFIG_H
