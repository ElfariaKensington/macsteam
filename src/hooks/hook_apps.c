// Ownership hooks
#include "hooks.h"
#include "../feats/apps.h"
#include "../config/config.h"
#include "../util/log.h"
#include "../core/reconcile.h"
#include "../core/session.h"
#include "../steam_types.h"
#include <stdint.h>

static void *g_app_mgr = NULL;

void sx_hooks_apps_force_ready(void) {
    sx_apps_force_ready();
}

#define CUSER_OWNER_ACCOUNTID 0x27A

static uint32_t read_cuser_account_id(void *cuser) {
    if (!cuser) return 0;
    return *(uint32_t *)((uint8_t *)cuser + CUSER_OWNER_ACCOUNTID);
}


static void *orig_CheckAppOwnership = NULL;
typedef int (*fn_CheckAppOwnership)(void *self, uint32_t appId, void *out);

static int hook_CheckAppOwnership(void *self, uint32_t appId, void *out) {
    fn_CheckAppOwnership orig = (fn_CheckAppOwnership)orig_CheckAppOwnership;
    int result = orig(self, appId, out);

    if (sx_hook_passthrough("CheckAppOwnership"))
        return result;

    if (sx_session_account_id() == 0) {
        uint32_t acct = read_cuser_account_id(self);
        sx_session_set_account_id(acct);
        if (acct)
            SX_LOG("CheckAppOwnership: captured accountId=%u", acct);
    }

    if (result) sx_hooks_ticket_observe_owned_app(self, appId);
    if (self) g_app_mgr = self;
    sx_reconcile_fire_library_refresh(g_app_mgr);

    return sx_apps_spoof_ownership(appId, result, (AppOwnershipInfo_t *)out,
                                   sx_session_account_id());
}

static void *orig_BIsAppOwnedForDepot = NULL;
typedef int (*fn_BIsAppOwnedForDepot)(void *self, uint32_t appId, uint32_t depotCtxAppId);

static int hook_BIsAppOwnedForDepot(void *self, uint32_t appId, uint32_t depotCtxAppId) {
    fn_BIsAppOwnedForDepot orig = (fn_BIsAppOwnedForDepot)orig_BIsAppOwnedForDepot;
    int result = orig(self, appId, depotCtxAppId);

    if (sx_hook_passthrough("BIsAppOwnedForDepot"))
        return result;

    return sx_apps_is_owned_for_depot(appId, depotCtxAppId, result);
}


static void *orig_GetSubscribedApps = NULL;
typedef uint32_t (*fn_GetSubscribedApps)(void *self, uint32_t *appids, uint32_t max_apps, uint32_t flags);

static uint32_t hook_GetSubscribedApps(void *self, uint32_t *appids, uint32_t max_apps, uint32_t flags) {
    fn_GetSubscribedApps orig = (fn_GetSubscribedApps)orig_GetSubscribedApps;
    uint32_t count = orig(self, appids, max_apps, flags);
    if (appids) {
        uint32_t available = count < max_apps ? count : max_apps;
        for (uint32_t i = 0; i < available; ++i)
            sx_hooks_ticket_observe_owned_app(self, appids[i]);
    }

    if (self) g_app_mgr = self;
    sx_reconcile_fire_library_refresh(g_app_mgr);

    return sx_apps_inject_subscribed(appids, max_apps, count);
}

static void *orig_BIsSubscribedApp = NULL;
typedef int (*fn_BIsSubscribedApp)(void *self, uint32_t appId);

static int hook_BIsSubscribedApp(void *self, uint32_t appId) {
    fn_BIsSubscribedApp orig = (fn_BIsSubscribedApp)orig_BIsSubscribedApp;
    int result = orig(self, appId);

    if (sx_hook_passthrough("BIsSubscribedApp"))
        return result;

    return sx_apps_is_subscribed(appId, result);
}


static sx_hook_def_t g_hooks[] = {
    {
        .name     = "CheckAppOwnership",
        .sig_name = "CUser::CheckAppOwnership",
        .hook_fn  = (void *)hook_CheckAppOwnership,
        .orig_fn  = &orig_CheckAppOwnership,
        .optional = 0,
    },
    {
        .name     = "BIsAppOwnedForDepot",
        .sig_name = "CUser::BIsAppOwnedForDepot",
        .hook_fn  = (void *)hook_BIsAppOwnedForDepot,
        .orig_fn  = &orig_BIsAppOwnedForDepot,
        .optional = 0,
    },
    {
        .name     = "GetSubscribedApps",
        .sig_name = "CUser::GetSubscribedApps",
        .hook_fn  = (void *)hook_GetSubscribedApps,
        .orig_fn  = &orig_GetSubscribedApps,
        .optional = 0,
    },
    {
        .name     = "BIsSubscribedApp",
        .sig_name = "IClientUser::BIsSubscribedApp",
        .hook_fn  = (void *)hook_BIsSubscribedApp,
        .orig_fn  = &orig_BIsSubscribedApp,
        .optional = 1,
    },
};

int sx_hooks_apps_count(void) {
    return (int)(sizeof(g_hooks) / sizeof(g_hooks[0]));
}

sx_hook_def_t *sx_hooks_apps_defs(void) {
    return g_hooks;
}
