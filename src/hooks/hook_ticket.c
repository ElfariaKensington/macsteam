// Ticket trickery
#include "hooks.h"
#include "../feats/ticket.h"
#include "../util/log.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define METHOD_HASH_EXTENDED_DATA 0xC7E71245u

static void *orig_ServerDispatch = NULL;

typedef int64_t (*fn_ServerDispatch)(void *server_this, void *reqReader,
                                     void *respWriter, void *a4);

typedef int (*fn_get_bytes)(void *buf, void *dst, int64_t len);
static fn_get_bytes g_get_bytes = NULL;

void sx_hooks_ticket_set_helpers(uintptr_t put_bytes, uintptr_t put_tag,
                                 uintptr_t get_bytes) {
    sx_ticket_set_helpers(put_bytes, put_tag, get_bytes);
    g_get_bytes = (fn_get_bytes)get_bytes;
}

static uint32_t peek_method_hash(void *reqReader) {
    uint8_t *b = (uint8_t *)reqReader;
    void    *data = *(void **)b;
    int32_t  cur  = *(int32_t *)(b + 16);
    int32_t  end  = *(int32_t *)(b + 24);
    if (!data || end - cur < 4)
        return 0;
    return *(uint32_t *)((uint8_t *)data + cur);
}

static int64_t hook_ServerDispatch(void *server_this, void *reqReader,
                                   void *respWriter, void *a4) {
    fn_ServerDispatch orig = (fn_ServerDispatch)orig_ServerDispatch;

    if (!g_get_bytes)
        return orig(server_this, reqReader, respWriter, a4);

    uint32_t hash = peek_method_hash(reqReader);
    if (hash != METHOD_HASH_EXTENDED_DATA)
        return orig(server_this, reqReader, respWriter, a4);

    uint32_t consumed_hash;
    g_get_bytes(reqReader, &consumed_hash, 4);

    if (sx_ticket_serve_extended(server_this, reqReader, respWriter))
        return 0;

    return 0;
}

static void *orig_FindAppOwnershipTicket = NULL;

typedef int64_t (*fn_find_ticket)(void *cuser, uint32_t appid, int fetch);
typedef int   (*fn_store_read)(void *cuser, int mode, const char *name,
                               void *out_data, uint32_t *len);
typedef void (*fn_buf_ctor)(void *buf);
typedef void (*fn_buf_ensure)(void *buf, uint32_t cap);
typedef void (*fn_buf_put)(void *buf, const void *src, int len);

static fn_buf_ctor   g_buf_ctor   = NULL;
static fn_buf_ensure g_buf_ensure = NULL;
static fn_store_read g_store_read = NULL;
static fn_buf_put    g_buf_put    = NULL;

#define TICKET_STORE_MODE      6
#define TICKET_STORE_CAP       0x800
#define TICKET_SOURCE_APPID    7

void sx_hooks_ticket_set_source_helpers(uintptr_t buf_ctor,
                                        uintptr_t ensure_capacity,
                                        uintptr_t put_bytes,
                                        uintptr_t store_read) {
    g_buf_ctor   = (fn_buf_ctor)buf_ctor;
    g_buf_ensure = (fn_buf_ensure)ensure_capacity;
    g_buf_put    = (fn_buf_put)put_bytes;
    g_store_read = (fn_store_read)store_read;
}

static int64_t hook_FindAppOwnershipTicket(void *cuser, uint32_t appid,
                                           int fetch) {
    fn_find_ticket orig = (fn_find_ticket)orig_FindAppOwnershipTicket;

    if (appid != TICKET_SOURCE_APPID ||
        !g_store_read || !g_buf_ctor || !g_buf_ensure || !g_buf_put)
        return orig(cuser, appid, fetch);

    char name[8];
    if (snprintf(name, sizeof(name), "%u", appid) <= 0)
        return orig(cuser, appid, fetch);

    uint8_t store_data[TICKET_STORE_CAP];
    uint32_t len = TICKET_STORE_CAP;

    if (!g_store_read(cuser, TICKET_STORE_MODE, name, store_data, &len)) {
        SX_LOG_ONCE("[ticket] app-7 store entry missing (client never cached it)");
        return orig(cuser, appid, fetch);
    }
    if (len < 48 || len > TICKET_STORE_CAP) {
        SX_WARN("[ticket] app-7 store entry abnormal (len=%u)", len);
        return orig(cuser, appid, fetch);
    }

    void *buf = malloc(0x40);
    if (!buf) return orig(cuser, appid, fetch);
    memset(buf, 0, 0x40);

    g_buf_ctor(buf);
    g_buf_ensure(buf, len);
    g_buf_put(buf, store_data, (int)len);

    SX_LOG("[ticket] app-7 restored from store for lookup (len=%u)", len);
    return (int64_t)buf;
}

static sx_hook_def_t g_hooks[] = {
    {
        .name     = "TicketForge",
        .sig_name = "IClientUser::__ipc_server_dispatch",
        .hook_fn  = (void *)hook_ServerDispatch,
        .orig_fn  = &orig_ServerDispatch,
        .optional = 1,
    },
    {
        .name     = "TicketReader",
        .sig_name = "CUser::FindAppOwnershipTicket",
        .hook_fn  = (void *)hook_FindAppOwnershipTicket,
        .orig_fn  = &orig_FindAppOwnershipTicket,
        .optional = 1,
    },
};

int sx_hooks_ticket_count(void) {
    return (int)(sizeof(g_hooks) / sizeof(g_hooks[0]));
}

sx_hook_def_t *sx_hooks_ticket_defs(void) {
    return g_hooks;
}
