// Adapted from ElfariaKensington/SomeAppOnlineFix (AGPL-3.0).
#include "onlinefix.h"
#include <ctype.h>
#include <pthread.h>
#include <stddef.h>
#include <string.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
// shortcut: one active game per Steam process; use per-pipe sessions before supporting concurrent games.
static OFSession current;

bool of_argument(const char *command, const char *argument) {
    if (!command || !argument || !*argument) return false;
    const size_t length = strlen(argument);
    while (*command) {
        size_t position = 0;
        bool same = true;
        char delimiter = 0;
        while (isspace((unsigned char)*command)) ++command;
        if (!*command) break;
        do {
            char c = *command++;
            if (c == delimiter) { delimiter = 0; continue; }
            if (!delimiter && (c == '"' || c == '\'')) { delimiter = c; continue; }
            if (c == '\\' && delimiter != '\'' && *command) c = *command++;
            if (position >= length || c != argument[position]) same = false;
            ++position;
        } while (*command && (delimiter || !isspace((unsigned char)*command)));
        if (!delimiter && same && position == length) return true;
    }
    return false;
}

OFSession of_session(void) {
    pthread_mutex_lock(&lock);
    OFSession result = current;
    pthread_mutex_unlock(&lock);
    return result;
}

void of_start(const char *command, const uint64_t *game) {
    OFSession next = {.patches = OF_DEFAULT_PATCHES};
    if (game && *game > 0 && *game <= 0xffffff && *game != 480) {
        bool keep = false;
        bool configured = of_config_game((uint32_t)*game, &keep, &next.patches);
        if (configured || of_argument(command, "-onlinefix")) {
            next.game = (uint32_t)*game;
            next.keep_id = keep || of_argument(command, "-realappid");
            // Keep the launch ID intact: Steam uses it to track the running game.
        }
    }
    pthread_mutex_lock(&lock);
    next.generation = current.generation + 1;
    current = next;
    pthread_mutex_unlock(&lock);
    if (next.game) {
        of_log("launch game=%u session=480 keep-id=%d", next.game, next.keep_id);
        of_log("patches game=%u: startup-id=%d overlay-id=%d input-id=%d stats-id=%d", next.game,
               next.patches.startup_id, next.patches.overlay_id, next.patches.input_id, next.patches.stats_id);
    }
}

void of_networking(void) {
    pthread_mutex_lock(&lock);
    bool changed = current.game && !current.networking;
    if (current.game) current.networking = true;
    pthread_mutex_unlock(&lock);
    if (changed) of_log("networking active: matchmaking uses 480");
}
