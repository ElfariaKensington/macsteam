// Ticket trickery
#include "hooks.h"
#include "../feats/ticket.h"
#include "../config/config.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include "../util/log.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define METHOD_HASH_EXTENDED_DATA 0xC7E71245u
#define METHOD_HASH_UPDATE_TICKET 0xCEDD4F18u
#define UPDATE_TICKET_FENCE_DELTA 0x003DC67Au
#define TICKET_REFRESH_SOURCE_APPID 7u

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

// Audited in ARM64 Steam 1792618285 at 0x812cc4: appid:u32,
// request_new:bool, fence:u32; the reply remains the native bool response.
static uint8_t *managed_ticket_update_argument(void *reader) {
    if (!reader || sx_hook_passthrough("TicketForge")) return NULL;
    uint8_t *object = reader;
    uint8_t *data = *(uint8_t **)object;
    int32_t current = *(int32_t *)(object + 16);
    int32_t end = *(int32_t *)(object + 24);
    if (!data || current < 0 || end < current || end - current < 13) return NULL;
    uint8_t *payload = data + current;
    uint32_t method, appid, fence;
    memcpy(&method, payload, 4);
    memcpy(&appid, payload + 4, 4);
    memcpy(&fence, payload + 9, 4);
    if (method != METHOD_HASH_UPDATE_TICKET || payload[8] > 1 ||
        fence != METHOD_HASH_UPDATE_TICKET + UPDATE_TICKET_FENCE_DELTA ||
        appid == TICKET_REFRESH_SOURCE_APPID) return NULL;
    sx_config_t *cfg = sx_config_current;
    if (!cfg || !sx_config_has_app(cfg, (int)appid)) return NULL;

    // IPC input can be borrowed read-only memory. Preserve native handling in
    // that case; never change VM protections or copy a private CUtlBuffer layout.
    mach_vm_address_t region = (mach_vm_address_t)(uintptr_t)(payload + 4);
    mach_vm_size_t length = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object_name = MACH_PORT_NULL;
    kern_return_t status = mach_vm_region(mach_task_self(), &region, &length,
        VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object_name);
    if (object_name != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object_name);
    uintptr_t address = (uintptr_t)(payload + 4);
    if (status != KERN_SUCCESS || !(info.protection & VM_PROT_WRITE) ||
        address < region || address - region > length ||
        length - (address - region) < sizeof(uint32_t)) return NULL;
    return payload + 4;
}

static int64_t hook_ServerDispatch(void *server_this, void *reqReader,
                                   void *respWriter, void *a4) {
    fn_ServerDispatch orig = (fn_ServerDispatch)orig_ServerDispatch;

    if (!g_get_bytes)
        return orig(server_this, reqReader, respWriter, a4);

    uint32_t hash = peek_method_hash(reqReader);
    if (hash == METHOD_HASH_UPDATE_TICKET) {
        uint8_t *argument = managed_ticket_update_argument(reqReader);
        if (argument) {
            uint32_t appid;
            memcpy(&appid, argument, 4);
            uint32_t source = sx_ticket_source_app();
            // The extended getter uses this same cached source ticket.
            // Refresh that same real ticket using Steam's own cache/expiry and
            // network logic, instead of waiting for a ticket we never consume.
            memcpy(argument, &source, 4);
            int64_t result = orig(server_this, reqReader, respWriter, a4);
            memcpy(argument, &appid, 4);
            SX_LOG("[ticket] checked native source %u for app %u", source, appid);
            return result;
        }
    }
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

static int source_is_cached(void *cuser, uint32_t appid) {
    char name[16];
    snprintf(name, sizeof(name), "%u", appid);
    uint8_t data[TICKET_STORE_CAP];
    uint32_t size = sizeof(data);
    return g_store_read(cuser, TICKET_STORE_MODE, name, data, &size) &&
           size >= 48 && size <= sizeof(data);
}

void sx_hooks_ticket_observe_owned_app(void *cuser, uint32_t appid) {
    sx_config_t *cfg = sx_config_current;
    if (!cuser || !appid || !g_store_read || !cfg ||
        sx_config_has_app(cfg, (int)appid) ||
        sx_ticket_source_app() != TICKET_SOURCE_APPID) return;
    // Only original ownership/subscription results reach here, before injection.
    // Prefer the historical source when present, otherwise use an existing real
    // owned ticket. No ticket is requested or manufactured by this selection.
    if (source_is_cached(cuser, TICKET_SOURCE_APPID)) return;
    if (source_is_cached(cuser, appid)) {
        sx_ticket_set_source_app(appid);
        SX_LOG("[ticket] selected existing owned ticket cache for app %u", appid);
    }
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
