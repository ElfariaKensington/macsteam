// License injection hooks
#include "hooks.h"
#include "../config/config.h"
#include "../core/reconcile.h"
#include "../feats/achievements.h"
#include "../feats/license.h"
#include "../constants.h"
#include "../steam_types.h"
#include "../util/log.h"
#include <stdatomic.h>
#include <stdint.h>


static void *orig_BLoggedOn = NULL;
typedef int (*fn_BLoggedOn)(void *self);
static atomic_int g_ach_logged_on = 0;

static int hook_BLoggedOn(void *self) {
    fn_BLoggedOn orig = (fn_BLoggedOn)orig_BLoggedOn;
    int result = orig(self);
    SX_DBG("BLoggedOn: %d", result);
    if (result) {
        sx_reconcile_set_login_observed();
        if (!atomic_exchange(&g_ach_logged_on, 1) && sx_ach_spoof_enabled())
            sx_ach_spoof_sync();
    } else {
        atomic_store(&g_ach_logged_on, 0);
    }
    return result;
}

static void *orig_InitFromPacket = NULL;
typedef uint64_t (*fn_InitFromPacket)(void *self, void *packet);

static uint64_t hook_InitFromPacket(void *self, void *packet) {
    fn_InitFromPacket orig = (fn_InitFromPacket)orig_InitFromPacket;
    uint64_t result = orig(self, packet);

    if (sx_hook_passthrough("InitFromPacket"))
        return result;

    if (!packet)
        return result;

    sx_license_inject_from_packet((CProtoBufMsg_t *)self);
    return result;
}


static void *orig_HandleLicenseList = NULL;
typedef uint8_t (*fn_HandleLicenseList)(void *cuser, void *body);

static uint8_t hook_HandleLicenseList(void *cuser, void *body) {
    fn_HandleLicenseList orig = (fn_HandleLicenseList)orig_HandleLicenseList;

    if (sx_hook_passthrough("HandleLicenseList"))
        return orig(cuser, body);

    sx_license_handle_list(body);

    return orig(cuser, body);
}


static sx_hook_def_t g_hooks[] = {
    {
        .name     = "BLoggedOn",
        .sig_name = "IClientUser::BLoggedOn",
        .hook_fn  = (void *)hook_BLoggedOn,
        .orig_fn  = &orig_BLoggedOn,
        .optional = 1,
    },
    {
        .name     = "InitFromPacket",
        .sig_name = "CProtoBufMsg::InitFromPacket",
        .hook_fn  = (void *)hook_InitFromPacket,
        .orig_fn  = &orig_InitFromPacket,
        .optional = 0,
    },
    {
        .name     = "HandleLicenseList",
        .sig_name = "CUser::HandleLicenseList",
        .hook_fn  = (void *)hook_HandleLicenseList,
        .orig_fn  = &orig_HandleLicenseList,
        .optional = 1,
    },
};

int sx_hooks_license_count(void) {
    return (int)(sizeof(g_hooks) / sizeof(g_hooks[0]));
}

sx_hook_def_t *sx_hooks_license_defs(void) {
    return g_hooks;
}
