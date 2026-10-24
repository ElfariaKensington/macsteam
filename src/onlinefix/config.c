// OnlineFix routing reads macsteam's config at launch so edits apply immediately.
#include "onlinefix.h"
#include "../config/config.h"
#include "../util/file.h"
#include <stdlib.h>

bool of_config_game(uint32_t game, bool *keep_id, OFPatches *patches) {
    char path[512];
    sx_file_config_path(path, sizeof(path));
    sx_config_t *cfg = calloc(1, sizeof(*cfg));
    if (!cfg) return false;
    bool found = false;
    if (sx_config_load(path, cfg) == 0) {
        for (int i = 0; i < cfg->onlinefix_count; ++i) {
            const sx_onlinefix_game_t *entry = &cfg->onlinefix_games[i];
            if (entry->app_id != (int)game) continue;
            *keep_id = entry->keep_real_app_id;
            *patches = (OFPatches){entry->startup_app_id, entry->overlay_app_id,
                                  entry->input_app_id, entry->stats_app_id};
            found = true;
            break;
        }
    }
    sx_config_free(cfg);
    free(cfg);
    return found;
}
