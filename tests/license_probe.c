#include "config/config.h"
#include "constants.h"
#include "feats/license.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

_Atomic(sx_config_t *) sx_config_current;
int sx_log_level = -1;
FILE *sx_log_file;

uint32_t sx_session_account_id(void) { return 12345; }

typedef struct {
    uint8_t padding[0x20];
    int32_t count;
    int32_t capacity;
    void *rep;
} test_body_t;

static void **licenses(test_body_t *body) {
    return (void **)((uint8_t *)body->rep + 8);
}

static void init_body(test_body_t *body, int capacity) {
    memset(body, 0, sizeof(*body));
    body->capacity = capacity;
    body->rep = calloc(1, 8 + (size_t)capacity * sizeof(void *));
    assert(body->rep);
    License_t *lic = calloc(1, LIC_OBJ_SIZE_FALLBACK);
    assert(lic);
    lic->packageId = 1;
    licenses(body)[0] = lic;
    body->count = 1;
}

static void free_body(test_body_t *body) {
    for (int i = 0; i < body->count; i++) free(licenses(body)[i]);
    free(body->rep);
}

static void assert_injected(test_body_t *body, int count) {
    assert(body->count == count);
    assert(body->capacity >= count);
    License_t *lic = licenses(body)[1];
    assert(lic->packageId == 20200);
    assert(lic->ownerId == 12345);
}

int main(void) {
    int packages[] = {20200, 20200, 1, 20201};
    sx_config_t *cfg = calloc(1, sizeof(*cfg));
    assert(cfg);
    cfg->package_ids = packages;
    cfg->pkg_count = 3;
    sx_config_current = cfg;

    test_body_t body;
    init_body(&body, 4);
    CProtoBufMsg_t msg = {0};
    msg.eMsg = EMSG_CLIENT_LICENSE_LIST;
    msg.body = &body;
    sx_license_inject_from_packet(&msg);
    assert_injected(&body, 2);
    sx_license_handle_list(&body);
    sx_license_inject_from_packet(&msg);
    assert_injected(&body, 2);
    free_body(&body);

    // Reconnects may reuse the same message and body addresses.
    for (int i = 0; i < 3; i++) {
        init_body(&body, 4);
        sx_license_handle_list(&body);
        assert_injected(&body, 2);
        sx_license_inject_from_packet(&msg);
        assert_injected(&body, 2);
        free_body(&body);
    }

    // A failed attempt must not prevent a later valid list from being handled.
    memset(&body, 0, sizeof(body));
    sx_license_handle_list(&body);
    sx_license_inject_from_packet(&msg);
    init_body(&body, 1);
    void *old_rep = body.rep;
    sx_license_inject_from_packet(&msg);
    assert_injected(&body, 2);
    assert(body.rep != old_rep);
    free(old_rep);

    // A live configuration update adds only the newly configured package.
    cfg->pkg_count = 4;
    old_rep = body.rep;
    sx_license_handle_list(&body);
    assert_injected(&body, 3);
    assert(((License_t *)licenses(&body)[2])->packageId == 20201);
    if (old_rep != body.rep) free(old_rep);
    sx_license_handle_list(&body);
    assert_injected(&body, 3);
    free_body(&body);

    init_body(&body, 4);
    msg.eMsg = 1;
    sx_license_inject_from_packet(&msg);
    assert(body.count == 1);
    sx_license_handle_list(NULL);
    free_body(&body);
    sx_config_current = NULL;
    free(cfg);
    puts("License reconnect regression tests passed.");
    return 0;
}
