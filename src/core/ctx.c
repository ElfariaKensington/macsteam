// Caller pipe context
#include "ctx.h"
#include "../util/log.h"


typedef uint32_t (*fn_GetAppID)(void *iface_this);

static fn_GetAppID g_getappid = NULL;

void sx_ctx_set_getappid(uintptr_t getappid) {
    g_getappid = (fn_GetAppID)getappid;
}

uint32_t sx_ctx_caller_appid(void *iface_this) {
    if (!g_getappid || !iface_this) {
        SX_LOG_ONCE("sx_ctx: GetAppID unresolved, pipe context unknown");
        return UINT32_MAX;
    }
    return g_getappid(iface_this);
}
