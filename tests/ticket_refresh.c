// Exercise IPC routing with synthetic buffers; no Steam or user tickets.
#include <assert.h>
#include <sys/mman.h>
#include <unistd.h>
#include "../src/hooks/hook_ticket.c"

int sx_log_level = -1;
FILE *sx_log_file;
_Atomic(sx_config_t *) sx_config_current;
static int passthrough, calls;
static uint32_t received_app;
static uint8_t received_flag;
static uint32_t source_app = 7;
uint32_t sx_ticket_source_app(void) { return source_app; }
void sx_ticket_set_source_app(uint32_t app) { source_app = app; }
int sx_log_once_seen(const void *site, unsigned long key) { return 0; }
int sx_hook_passthrough(const char *name) { return passthrough; }
int sx_config_has_app(sx_config_t *cfg, int app) { return app == 848450; }
void sx_ticket_set_helpers(uintptr_t a, uintptr_t b, uintptr_t c) {}
int sx_ticket_serve_extended(void *self, void *request, void *response) { return 0; }
struct Reader {
    uint8_t *data;
    uint64_t capacity;
    int32_t current, put, end;
    uint8_t rest[36];
};
_Static_assert(offsetof(struct Reader, current) == 16, "read cursor ABI");
_Static_assert(offsetof(struct Reader, end) == 24, "buffer end ABI");
static int64_t native(void *self, void *request, void *response, void *unused) {
    struct Reader *reader = request;
    ++calls;
    received_app = 0;
    received_flag = 0;
    if (reader->end - reader->current >= 8)
        memcpy(&received_app, reader->data + reader->current + 4, 4);
    if (reader->end - reader->current >= 9)
        received_flag = reader->data[reader->current + 8];
    reader->current = reader->end;
    *(uint8_t *)response = 1;
    return 99;
}
static int cached(void *user, int mode, const char *name, void *data, uint32_t *length) {
    if (strcmp(name, "3712080") != 0) return 0;
    *length = 128;
    return 1;
}
static int get_bytes(void *buffer, void *output, int64_t size) { return 1; }
static void frame(uint8_t *data, uint32_t method, uint32_t app, uint8_t flag) {
    uint32_t fence = METHOD_HASH_UPDATE_TICKET + UPDATE_TICKET_FENCE_DELTA;
    memcpy(data, &method, 4); memcpy(data + 4, &app, 4);
    data[8] = flag; memcpy(data + 9, &fence, 4);
}
static void run(uint8_t *data, int size, uint32_t expected_app, uint8_t expected_flag) {
    struct Reader reader = {.data = data, .end = size};
    uint8_t before[13]; memcpy(before, data, 13);
    uint8_t response = 0;
    int previous_calls = calls;
    assert(hook_ServerDispatch(NULL, &reader, &response, NULL) == 99);
    assert(calls == previous_calls + 1 && received_app == expected_app);
    assert(received_flag == expected_flag && response == 1);
    assert(reader.current == size); // native cursor/result handling is preserved
    assert(memcmp(data, before, 13) == 0); // caller packet restored exactly
}
int main(void) {
    sx_config_t cfg = {0}; sx_config_current = &cfg;
    g_get_bytes = get_bytes; orig_ServerDispatch = native;
    uint8_t data[13];
    frame(data, METHOD_HASH_UPDATE_TICKET, 848450, 0); run(data, 13, 7, 0);
    frame(data, METHOD_HASH_UPDATE_TICKET, 848450, 1); run(data, 13, 7, 1);
    frame(data, METHOD_HASH_UPDATE_TICKET, 3712080, 0); run(data, 13, 3712080, 0);
    frame(data, METHOD_HASH_UPDATE_TICKET, 7, 0); run(data, 13, 7, 0);
    frame(data, 0x12345678, 848450, 0); run(data, 13, 848450, 0);
    frame(data, METHOD_HASH_UPDATE_TICKET, 848450, 0); data[9] ^= 1; run(data, 13, 848450, 0);
    frame(data, METHOD_HASH_UPDATE_TICKET, 848450, 2); run(data, 13, 848450, 2);
    frame(data, METHOD_HASH_UPDATE_TICKET, 848450, 0); run(data, 8, 848450, 0);
    passthrough = 1; run(data, 13, 848450, 0); passthrough = 0;
    sx_config_current = NULL; run(data, 13, 848450, 0); sx_config_current = &cfg;
    g_store_read = cached;
    sx_hooks_ticket_observe_owned_app((void *)1, 848450);
    assert(source_app == 7); // configured/spoofed app cannot become a real source
    sx_hooks_ticket_observe_owned_app((void *)1, 3712080);
    assert(source_app == 3712080);
    frame(data, METHOD_HASH_UPDATE_TICKET, 848450, 1); run(data, 13, 3712080, 1);
    size_t page_size = (size_t)sysconf(_SC_PAGESIZE);
    uint8_t *page = mmap(NULL, page_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(page != MAP_FAILED);
    frame(page, METHOD_HASH_UPDATE_TICKET, 848450, 0);
    assert(mprotect(page, page_size, PROT_READ) == 0);
    run(page, 13, 848450, 0); // read-only borrowed packets retain the original path
    assert(munmap(page, page_size) == 0);
    puts("Ticket refresh routing, native responses, packet restoration and fallback checks passed");
}
