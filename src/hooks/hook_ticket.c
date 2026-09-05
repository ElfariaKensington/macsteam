// Ticket trickery
#include "hooks.h"
#include "../feats/ticket.h"
#include <stdint.h>

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

static sx_hook_def_t g_hooks[] = {
    {
        .name     = "TicketForge",
        .sig_name = "IClientUser::__ipc_server_dispatch",
        .hook_fn  = (void *)hook_ServerDispatch,
        .orig_fn  = &orig_ServerDispatch,
        .optional = 1,
    },
};

int sx_hooks_ticket_count(void) {
    return (int)(sizeof(g_hooks) / sizeof(g_hooks[0]));
}

sx_hook_def_t *sx_hooks_ticket_defs(void) {
    return g_hooks;
}
