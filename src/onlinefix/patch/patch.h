// Adapted from ElfariaKensington/SomeAppOnlineFix (AGPL-3.0).
#pragma once
#include <stdbool.h>

typedef struct {
    bool startup_id, overlay_id, input_id, stats_id;
} OFPatches;

#define OF_DEFAULT_PATCHES ((OFPatches){true, true, true, true})


typedef struct {
    const char *name;
    void *replacement;
    void **original;
} OFHook;

extern OFHook of_identity_hook, of_overlay_hook, of_input_hook, of_stats_hook;
