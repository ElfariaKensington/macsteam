// Ticket trickery
#include "ticket.h"
#include "../config/config.h"
#include "../util/log.h"
#include <string.h>
#include <stdint.h>
#include <stdlib.h>

typedef void (*fn_put_bytes)(void *buf, const void *src, int len);
typedef void (*fn_put_tag)(void *buf, unsigned tag);
typedef int  (*fn_get_bytes)(void *buf, void *dst, int64_t len);

static fn_put_bytes g_put_bytes = NULL;
static fn_put_tag   g_put_tag   = NULL;
static fn_get_bytes g_get_bytes = NULL;

void sx_ticket_set_helpers(uintptr_t put_bytes, uintptr_t put_tag,
                           uintptr_t get_bytes) {
    g_put_bytes = (fn_put_bytes)put_bytes;
    g_put_tag   = (fn_put_tag)put_tag;
    g_get_bytes = (fn_get_bytes)get_bytes;
}

static int utlbuf_read(void *buf, void *dst, int len) {
    if (!g_get_bytes) return 0;
    return g_get_bytes(buf, dst, len);
}

#define IMPL_VTABLE_SLOT 0x348

typedef int64_t (*fn_get_ticket_impl)(void *self, uint32_t appId, void *buf,
                                       uint32_t bufMax, uint32_t *pOffAppId,
                                       uint32_t *pOffSteamId, uint32_t *pOffSig,
                                       uint32_t *pSigSize);

#define SOURCE_APPID       7
#define MAX_TICKET_BUF     4096

static int should_forge(uint32_t app_id) {
    sx_config_t *cfg = sx_config_current;
    if (!cfg || !sx_config_has_app(cfg, (int)app_id))
        return 0;
    return 1;
}

static void serialize_response(void *resp, int64_t totalSize, const void *ticket,
                               uint32_t cbMaxTicket, uint32_t offAppId,
                               uint32_t offSteamId, uint32_t offSig,
                               uint32_t sigSize) {
    uint32_t v;

    g_put_tag(resp, 0x0B);

    v = (uint32_t)totalSize;
    g_put_bytes(resp, &v, 4);

    g_put_bytes(resp, ticket, (int)cbMaxTicket);

    v = offAppId;
    g_put_bytes(resp, &v, 4);

    v = offSteamId;
    g_put_bytes(resp, &v, 4);

    v = offSig;
    g_put_bytes(resp, &v, 4);

    v = sigSize;
    g_put_bytes(resp, &v, 4);
}

int sx_ticket_serve_extended(void *server_this, void *reqReader, void *respWriter) {
    if (!g_put_bytes || !g_put_tag || !g_get_bytes) {
        SX_LOG_ONCE("GetAppOwnershipTicketExtendedData: helpers unresolved");
        return 0;
    }

    uint32_t req_appId = 0, req_cbMax = 0, req_fence = 0;
    utlbuf_read(reqReader, &req_appId, 4);
    utlbuf_read(reqReader, &req_cbMax, 4);
    utlbuf_read(reqReader, &req_fence, 4);

    if (!should_forge(req_appId)) {
        if (req_cbMax == 0 || req_cbMax > MAX_TICKET_BUF)
            return 0;

        uint8_t *ticket_buf = (uint8_t *)calloc(1, req_cbMax);
        if (!ticket_buf) return 0;

        uint32_t offAppId = 0, offSteamId = 0, offSig = 0, sigSize = 0;
        fn_get_ticket_impl impl = *(fn_get_ticket_impl *)(*(uintptr_t *)server_this + IMPL_VTABLE_SLOT);
        int64_t ret = impl(server_this, req_appId, ticket_buf, req_cbMax,
                           &offAppId, &offSteamId, &offSig, &sigSize);

        serialize_response(respWriter, ret, ticket_buf, req_cbMax,
                           offAppId, offSteamId, offSig, sigSize);
        free(ticket_buf);
        return 1;
    }

    uint8_t *source_buf = (uint8_t *)calloc(1, MAX_TICKET_BUF);
    if (!source_buf) return 0;

    uint32_t src_off_app = 0, src_off_steam = 0, src_off_sig = 0, src_sig_size = 0;
    fn_get_ticket_impl impl = *(fn_get_ticket_impl *)(*(uintptr_t *)server_this + IMPL_VTABLE_SLOT);
    int64_t src_len = impl(server_this, SOURCE_APPID, source_buf, MAX_TICKET_BUF,
                           &src_off_app, &src_off_steam, &src_off_sig, &src_sig_size);

    uint32_t body_len = src_off_sig;
    uint32_t sig_size = src_sig_size;

    if (src_len <= 0 || body_len == 0 || sig_size == 0 ||
        body_len + sig_size != (uint32_t)src_len) {
        SX_WARN("GetAppOwnershipTicketExtendedData: appid-7 ticket invalid (len=%lld, sigOff=%u, sigSize=%u)",
                (long long)src_len, body_len, sig_size);
        free(source_buf);
        return 0;
    }

    uint32_t forged_physical = (uint32_t)src_len + 4;

    if (forged_physical > req_cbMax) {
        SX_WARN("GetAppOwnershipTicketExtendedData: forged ticket (%u bytes) exceeds cbMaxTicket (%u)",
                forged_physical, req_cbMax);
        free(source_buf);
        return 0;
    }

    // layout: [body | 4B target appId | sig]
    uint8_t *forged = (uint8_t *)calloc(1, req_cbMax);
    if (!forged) { free(source_buf); return 0; }

    memcpy(forged, source_buf, body_len);
    memcpy(forged + body_len, &req_appId, 4);
    memcpy(forged + body_len + 4, source_buf + body_len, sig_size);

    uint32_t reported_size = (uint32_t)src_len;

    serialize_response(respWriter, (int64_t)reported_size, forged, req_cbMax,
                       body_len,
                       src_off_steam,
                       body_len + 4,
                       sig_size);

    SX_LOG("GetAppOwnershipTicketExtendedData: FORGED app %u (source=7, bodyLen=%u, sigOff=%u->%u, physical=%u, reported=%u)",
           req_appId, body_len, src_off_sig, body_len + 4, forged_physical, reported_size);

    free(forged);
    free(source_buf);
    return 1;
}
