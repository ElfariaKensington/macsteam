// Achievement spoofing
//
// Steam keeps the authoritative copy of a user's achievements in a local
// binary-KeyValues cache:
//
//   ~/Library/Application Support/Steam/appcache/stats/
//       UserGameStats_<account>_<app>.bin
//
// The file also carries the CRC the client sends to Steam when it asks for
// stats. Steam only refreshes the cache when that CRC differs from the
// server's, so writing achievements into the file while leaving the CRC alone
// makes the client serve the patched values to games and to the Steam UI.
//
// Achievement definitions (stat id + bit count) come from the matching
// UserGameStatsSchema_<app>.bin. The original values are recorded in a state
// file before the first edit so disabling the feature restores them.
#ifndef MACSTEAM_FEATS_ACHIEVEMENTS_H
#define MACSTEAM_FEATS_ACHIEVEMENTS_H

#include <stdint.h>
#include "../core/bkv.h"
#include "../config/config.h"

#define SX_ACH_MAX_STATS  128
#define SX_ACH_MAX_BITS   32

typedef struct {
    uint32_t stat_id;
    uint32_t bits;
    uint32_t valid_mask; // bit mask of defined bits in the schema
    uint32_t selected;   // bit mask of the achievements the user picked
} sx_ach_stat_t;

typedef struct {
    int      section_present;
    int      present;
    int32_t  data;
    int      time_count;
    struct {
        int     bit;
        int32_t time;
    } times[SX_ACH_MAX_BITS];
} sx_ach_orig_t;

// Parse the "stats" tree of a schema and return the achievement stat ids,
// their bit counts, and the selected mask for this app. Exposed for tests.
int sx_ach_collect_schema(const sx_bkv_node_t *schema_root, int app_id,
                          const sx_config_t *cfg,
                          sx_ach_stat_t *out, int max);

// Snapshot the original achievement state before editing. Exposed for tests.
void sx_ach_capture(const sx_bkv_node_t *cache_root,
                    const sx_ach_stat_t *stat, sx_ach_orig_t *out);

// Write the selected bits and unlock times for one stat, restoring the
// original values for unselected bits. Returns 1 if the cache changed.
int sx_ach_apply(sx_bkv_node_t *cache_root, const sx_ach_stat_t *stat,
                 const sx_ach_orig_t *orig, uint32_t unlock_time);

// Restore one stat to a previously captured snapshot. Returns 1 if changed.
int sx_ach_restore(sx_bkv_node_t *cache_root, uint32_t stat_id,
                   const sx_ach_orig_t *orig);

// Apply/undo the configured spoofs. Safe to call repeatedly and from any
// thread; work is serialized internally.
void sx_ach_spoof_sync(void);

// First sync of a Steam process, before Steam reads its stats caches. Pending
// restores are re-applied and their snapshots released.
void sx_ach_spoof_startup_sync(void);

// Start listening for config changes made by the companion app or the Steam
// UI bridge. Registered once at load time.
void sx_ach_spoof_start_watcher(void);

// Apply/undo just one app (used after a stats exchange creates a schema).
void sx_ach_spoof_sync_app(int app_id);

// Queue one app for a delayed sync. Used by the stats hook so a schema that
// was just downloaded is picked up without blocking Steam's worker thread.
void sx_ach_spoof_schedule(int app_id);

// True when at least one app is configured for spoofing.
int sx_ach_spoof_enabled(void);

#endif // MACSTEAM_FEATS_ACHIEVEMENTS_H
