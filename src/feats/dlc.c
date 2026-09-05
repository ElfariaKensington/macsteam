// DLC injection
#include "dlc.h"
#include "../config/config.h"
#include "../core/ctx.h"
#include "../util/log.h"

static int should_unlock(void *iface, uint32_t app_id) {
    sx_config_t *g_cfg = sx_config_current;
    if (!g_cfg || !sx_config_has_app(g_cfg, (int)app_id))
        return 0;

    if (sx_ctx_caller_appid(iface) == 0)
        return 0;

    return 1;
}

int sx_dlc_is_installed(void *iface, uint32_t app_id, uint32_t dlc_id, int origResult) {
    if (!origResult && should_unlock(iface, app_id)) {
        SX_LOG_ONCE_KEY(((unsigned long)app_id << 32) | dlc_id,
                        "IsAppDlcInstalled: SPOOFING dlc %u for app %u -> 1", dlc_id, app_id);
        return 1;
    }
    return origResult;
}

int sx_dlc_force_available(void *iface, uint32_t app_id, int index, uint32_t *pDlcId,
                           int *pAvailable, int origResult) {
    if (origResult && should_unlock(iface, app_id)) {
        if (pAvailable && !*pAvailable) {
            *pAvailable = 1;
            SX_LOG("BGetDLCDataByIndex: app=%u idx=%d dlc=%u -> forced available",
                   app_id, index, pDlcId ? *pDlcId : 0);
        }
    }
    return origResult;
}

int sx_dlc_user_subscribed_in_ticket(void *iface, uint32_t app_id, int origResult) {
    if (should_unlock(iface, app_id)) {
        SX_LOG_ONCE_KEY(app_id,
                        "IsUserSubscribedAppInTicket: SPOOFING app %u -> subscribed", app_id);
        return 0;
    }
    return origResult;
}
