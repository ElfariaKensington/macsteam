// GetUserStats owner redirect
#include "hooks.h"
#include "../config/config.h"
#include "../feats/schema_owners.h"
#include "../constants.h"
#include "../steam_types.h"
#include "../util/log.h"
#include <stdint.h>

#define MSG_BODY_OFF          offsetof(CProtoBufMsg_t, body)
#define SEND_HASBITS_OFF      0x10
#define SEND_GAME_ID_OFF      0x18
#define SEND_STEAMID_OFF      0x28
#define SEND_STEAMID_HASBIT   8

#define RECV_ERESULT_OFF      0x5C
#define RECV_STATS_COUNT_OFF  0x20
#define RECV_ACH_COUNT_OFF    0x38

typedef int (*fn_sendAndRecv)(void *self, void *send, uint32_t a2,
                              uint32_t timeOut, void *recv, uint32_t targetType);
static void *orig_sendAndRecv = NULL;

static inline uintptr_t msg_body(void *msg) {
    if (!msg) return 0;
    return *(uintptr_t *)((char *)msg + MSG_BODY_OFF);
}

static void send_set_owner(uintptr_t body, uint64_t owner) {
    *(uint64_t *)(body + SEND_STEAMID_OFF) = owner;
    *(uint32_t *)(body + SEND_HASBITS_OFF) |= SEND_STEAMID_HASBIT;
}

static void recv_keep_schema_only(uintptr_t body) {
    *(uint32_t *)(body + RECV_STATS_COUNT_OFF) = 0;
    *(uint32_t *)(body + RECV_ACH_COUNT_OFF)   = 0;
}

static int recv_is_ok(uintptr_t body) {
    return *(int32_t *)(body + RECV_ERESULT_OFF) == USERSTATS_RESP_ERESULT_OK;
}

static int try_owner(void *self, void *send, uint32_t a2, uint32_t timeOut,
                     void *recv, uintptr_t send_body, uintptr_t recv_body,
                     uint64_t owner) {
    fn_sendAndRecv orig = (fn_sendAndRecv)orig_sendAndRecv;
    send_set_owner(send_body, owner);
    int ret = orig(self, send, a2, timeOut, recv,
                   EMSG_CLIENT_GET_USER_STATS_RESPONSE);
    return ret && recv_is_ok(recv_body);
}

static int hook_sendAndRecv(void *self, void *send, uint32_t a2,
                            uint32_t timeOut, void *recv, uint32_t targetType) {
    fn_sendAndRecv orig = (fn_sendAndRecv)orig_sendAndRecv;

    if (targetType != EMSG_CLIENT_GET_USER_STATS_RESPONSE ||
        sx_hook_passthrough("sendAndRecv"))
        return orig(self, send, a2, timeOut, recv, targetType);

    uintptr_t send_body = msg_body(send);
    uintptr_t recv_body = msg_body(recv);
    if (!send_body || !recv_body)
        return orig(self, send, a2, timeOut, recv, targetType);

    sx_config_t *cfg = sx_config_current;
    int appId = (int)(*(uint64_t *)(send_body + SEND_GAME_ID_OFF) & 0xFFFFFF);
    if (!cfg || !sx_config_has_app(cfg, appId))
        return orig(self, send, a2, timeOut, recv, targetType);

    uint64_t original = *(uint64_t *)(send_body + SEND_STEAMID_OFF);

    uint64_t pref = sx_schema_owners_preferred(appId);
    if (pref && try_owner(self, send, a2, timeOut, recv,
                          send_body, recv_body, pref)) {
        recv_keep_schema_only(recv_body);
        SX_DBG("[stats] app %d: schema via preferred owner %llu", appId,
               (unsigned long long)pref);
        return 1;
    }

    sx_owner_list_t reviewers;
    sx_schema_owners_get(appId, &reviewers);
    for (int i = 0; i < reviewers.count; i++) {
        uint64_t owner = reviewers.ids[i];
        if (owner == pref) continue;
        if (try_owner(self, send, a2, timeOut, recv,
                      send_body, recv_body, owner)) {
            recv_keep_schema_only(recv_body);
            sx_schema_owners_set_preferred(appId, owner);
            SX_LOG("[stats] app %d: schema via reviewer %llu", appId,
                   (unsigned long long)owner);
            return 1;
        }
        sx_schema_owners_blacklist(appId, owner);
    }

    *(uint64_t *)(send_body + SEND_STEAMID_OFF) = original;
    SX_DBG("[stats] app %d: no owner schema, passthrough", appId);
    return orig(self, send, a2, timeOut, recv, targetType);
}

#define JOB_STEAMID_OFF   0x1D8
#define JOB_GAMEID_OFF    0x1E0
#define WORKER_RESP_COUNT_SP_OFF  0x80

typedef int (*fn_worker)(void *job);
static void *orig_worker = NULL;

static int worker_appid(uintptr_t job) {
    uint64_t gid = *(uint64_t *)(job + JOB_GAMEID_OFF);
    if ((gid & 0xFF000000) == 0x2000000)
        return (int)(gid >> 32);
    return (int)(gid & 0xFFFFFF);
}

static int worker_wants_redirect(uintptr_t job, uint64_t *owner_out) {
    sx_config_t *cfg = sx_config_current;
    if (!cfg || sx_hook_passthrough("RequestUserStats.worker")) return 0;
    int appId = worker_appid(job);
    if (!sx_config_has_app(cfg, appId)) return 0;

    uint64_t owner = sx_schema_owners_preferred(appId);
    if (!owner) {
        sx_owner_list_t reviewers;
        sx_schema_owners_get(appId, &reviewers);
        if (reviewers.count > 0) owner = reviewers.ids[0];
    }
    if (!owner) return 0;
    *owner_out = owner;
    return 1;
}

static int hook_worker(void *job) {
    fn_worker orig = (fn_worker)orig_worker;
    uintptr_t j = (uintptr_t)job;
    uint64_t owner = 0;
    if (!worker_wants_redirect(j, &owner))
        return orig(job);

    uint64_t original = *(uint64_t *)(j + JOB_STEAMID_OFF);
    *(uint64_t *)(j + JOB_STEAMID_OFF) = owner;
    int ret = orig(job);
    *(uint64_t *)(j + JOB_STEAMID_OFF) = original;

    SX_LOG("[stats] app %d: unified schema via owner %llu (worker ret=%d)",
           worker_appid(j), (unsigned long long)owner, ret);
    return ret;
}

typedef struct { uint64_t _d0, sp, _d1; struct { uint64_t x[29]; } general; } sx_arm64_ctx_t;

static void instrument_worker_resp(void *address, void *ctx_) {
    (void)address;
    sx_arm64_ctx_t *ctx = (sx_arm64_ctx_t *)ctx_;
    uintptr_t job = (uintptr_t)ctx->general.x[19];
    if (!job) return;

    sx_config_t *cfg = sx_config_current;
    if (!cfg || sx_hook_passthrough("RequestUserStats.worker")) return;
    int appId = worker_appid(job);
    if (!sx_config_has_app(cfg, appId)) return;

    uint32_t *count = (uint32_t *)(ctx->sp + WORKER_RESP_COUNT_SP_OFF);
    SX_LOG("[stats] app %d: cleared %u owner stat(s) from reply", appId, *count);
    *count = 0;
}

static sx_hook_def_t g_hooks[] = {
    {
        .name     = "sendAndRecv",
        .sig_name = "CAPIJob::sendAndRecv",
        .hook_fn  = (void *)hook_sendAndRecv,
        .orig_fn  = &orig_sendAndRecv,
        .optional = 1,
    },
    {
        .name     = "RequestUserStats.worker",
        .sig_name = "CAPIJobRequestUserStats::Run.worker",
        .hook_fn  = (void *)hook_worker,
        .orig_fn  = &orig_worker,
        .optional = 1,
    },
    {
        .name     = "RequestUserStats.worker.resp",
        .sig_name = "CAPIJobRequestUserStats::Run.worker.transport_ret",
        .hook_fn  = (void *)instrument_worker_resp,
        .orig_fn  = NULL,
        .optional = 1,
        .kind     = SX_HOOK_INSTRUMENT,
    },
};

int sx_hooks_stats_count(void) {
    return (int)(sizeof(g_hooks) / sizeof(g_hooks[0]));
}

sx_hook_def_t *sx_hooks_stats_defs(void) {
    return g_hooks;
}
