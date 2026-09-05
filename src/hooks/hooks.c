// Hook registration and installation
#include "hooks.h"
#include "../util/log.h"
#include <string.h>
#include <stdlib.h>

extern int DobbyHook(void *address, void *replace_call, void **origin_call);
typedef void (*sx_instrument_cb_t)(void *address, void *ctx);
extern int DobbyInstrument(void *address, sx_instrument_cb_t pre_handler);

static int name_in_env_list(const char *env, const char *name) {
    const char *dis = getenv(env);
    if (!dis || !dis[0] || !name) return 0;
    size_t nlen = strlen(name);
    const char *p = dis;
    while (*p) {
        const char *comma = strchr(p, ',');
        size_t seg = comma ? (size_t)(comma - p) : strlen(p);
        if (seg == nlen && strncmp(p, name, nlen) == 0) return 1;
        if (!comma) break;
        p = comma + 1;
    }
    return 0;
}

static int hook_is_disabled(const char *name) {
    return name_in_env_list("MACSTEAM_DISABLE", name);
}

int sx_hook_passthrough(const char *name) {
    return name_in_env_list("MACSTEAM_PASSTHROUGH", name);
}

typedef struct {
    const char     *module_name;
    int           (*count_fn)(void);
    sx_hook_def_t *(*defs_fn)(void);
} sx_hook_module_t;

static const sx_hook_module_t g_modules[] = {
    { "apps",     sx_hooks_apps_count,     sx_hooks_apps_defs     },
    { "depot",    sx_hooks_depot_count,    sx_hooks_depot_defs    },
    { "dlc",      sx_hooks_dlc_count,      sx_hooks_dlc_defs      },
    { "package",  sx_hooks_package_count,  sx_hooks_package_defs  },
    { "license",  sx_hooks_license_count,  sx_hooks_license_defs  },
    { "manifest", sx_hooks_manifest_count, sx_hooks_manifest_defs },
    { "stats",    sx_hooks_stats_count,    sx_hooks_stats_defs    },
    { "ticket",   sx_hooks_ticket_count,   sx_hooks_ticket_defs   },
};

#define NUM_MODULES (sizeof(g_modules) / sizeof(g_modules[0]))

int sx_hooks_install_all(sx_resolve_result_t *resolved, int *total_out) {
    int total = 0, installed = 0;

    sx_hooks_depot_set_helpers(
        sx_resolve_find(resolved, "CUtlBuffer::EnsureCapacity"),
        sx_resolve_find(resolved, "CUtlBuffer::SeekPut"));
    sx_hooks_package_set_helpers(
        sx_resolve_find(resolved, "CPackageInfo::BParseFromBuffer"));
    sx_hooks_ticket_set_helpers(
        sx_resolve_find(resolved, "CUtlBuffer::PutBytes"),
        sx_resolve_find(resolved, "CUtlBuffer::PutTag"),
        sx_resolve_find(resolved, "CUtlBuffer::GetBytes"));
    sx_hooks_ctx_set_helpers(
        sx_resolve_find(resolved, "IClientUtils::GetAppID"));

    for (size_t m = 0; m < NUM_MODULES; m++) {
        const sx_hook_module_t *mod = &g_modules[m];
        int count = mod->count_fn();
        sx_hook_def_t *defs = mod->defs_fn();

        for (int i = 0; i < count; i++) {
            sx_hook_def_t *hk = &defs[i];
            total++;

            if (hook_is_disabled(hk->name)) {
                SX_WARN("[%s] %s: DISABLED via MACSTEAM_DISABLE", mod->module_name, hk->name);
                continue;
            }

            uintptr_t addr = sx_resolve_find(resolved, hk->sig_name);
            if (addr == 0) {
                if (hk->optional)
                    SX_DBG("[%s] %s: unresolved (optional)", mod->module_name, hk->name);
                else
                    SX_WARN("[%s] %s: unresolved, cannot install", mod->module_name, hk->name);
                continue;
            }

            int ret;
            if (hk->kind == SX_HOOK_INSTRUMENT)
                ret = DobbyInstrument((void *)addr, (sx_instrument_cb_t)hk->hook_fn);
            else
                ret = DobbyHook((void *)addr, hk->hook_fn, hk->orig_fn);

            if (ret == 0) {
                installed++;
                SX_LOG("[%s] %s: %s @ %p", mod->module_name, hk->name,
                       hk->kind == SX_HOOK_INSTRUMENT ? "instrumented" : "hooked",
                       (void *)addr);
            } else {
                SX_ERR("[%s] %s: %s failed (ret=%d) @ %p",
                       mod->module_name, hk->name,
                       hk->kind == SX_HOOK_INSTRUMENT ? "DobbyInstrument" : "DobbyHook",
                       ret, (void *)addr);
            }
        }
    }

    sx_hooks_relaunch_install();

    if (total_out) *total_out = total;
    SX_LOG("hooks: %d/%d installed", installed, total);
    return installed;
}
