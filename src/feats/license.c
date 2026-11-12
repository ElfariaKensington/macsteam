// License injection
#include "license.h"
#include "../config/config.h"
#include "../core/session.h"
#include "../constants.h"
#include "../util/log.h"
#include <string.h>
#include <stdlib.h>
#include <stdint.h>

static uint8_t g_empty_country_str[24] = {0};

#define BODY_RPF_CURSIZE   0x20
#define BODY_RPF_TOTSIZE   0x24
#define BODY_RPF_REP       0x28
#define REP_ELEMENTS_OFF   0x08

static uint32_t sx_injected_license_owner_id(void) {
    uint32_t acct = sx_session_account_id();
    return acct ? acct : LICENSE_OWNER_ID_FALLBACK;
}

static void fill_injected_license(void *new_lic, uint32_t pkg) {
    License_t *lic = (License_t *)new_lic;
    // NULL or Steam will free it.
    lic->arena = NULL;
    // Without this the license path derefs garbage.
    lic->countryStr      = g_empty_country_str;
    lic->packageId       = pkg;
    lic->timeCreated     = FAKE_PURCHASE_TIME;
    lic->timeNextProcess = 0;
    lic->minuteLimit     = 0;
    lic->minutesUsed     = 0;
    lic->paymentMethod   = FAKE_PAYMENT_METHOD;
    lic->flags           = 0;
    lic->licenseType     = FAKE_LICENSE_TYPE;
    lic->territoryCode   = 0;
    lic->changeNumber    = FAKE_CHANGE_NUMBER;
    lic->ownerId         = sx_injected_license_owner_id();
}

static void *clone_injected_license(const void *template_lic, uint32_t pkg) {
    void *new_lic = malloc(LIC_OBJ_SIZE_FALLBACK);
    if (!new_lic) return NULL;
    memcpy(new_lic, template_lic, LIC_OBJ_SIZE_FALLBACK);
    fill_injected_license(new_lic, pkg);
    return new_lic;
}

static int has_license(void **elements, int count, uint32_t pkg) {
    for (int i = 0; i < count; i++) {
        const License_t *lic = elements[i];
        if (lic && lic->packageId == pkg) return 1;
    }
    return 0;
}

static void inject_licenses_into_body(void *body) {
    sx_config_t *g_cfg = sx_config_current;
    if (!g_cfg || g_cfg->pkg_count == 0) return;

    uint8_t *b = (uint8_t *)body;
    int32_t cur_size   = *(int32_t *)(b + BODY_RPF_CURSIZE);
    int32_t tot_size   = *(int32_t *)(b + BODY_RPF_TOTSIZE);
    void   *rep        = *(void **)(b + BODY_RPF_REP);

    if (!rep || cur_size <= 0) {
        SX_WARN("InitFromPacket: license list empty or no rep (cur=%d rep=%p)", cur_size, rep);
        return;
    }

    uint8_t *rep_bytes = (uint8_t *)rep;
    void **elements = (void **)(rep_bytes + REP_ELEMENTS_OFF);

    SX_LOG("InitFromPacket: EMsg 780. %d licenses, capacity=%d, rep=%p, objsize=%d",
           cur_size, tot_size, rep, LIC_OBJ_SIZE_FALLBACK);

    void *template_lic = elements[0];
    if (!template_lic) {
        SX_WARN("InitFromPacket: License[0] is NULL, cannot clone");
        return;
    }

    int to_inject = 0;
    for (int i = 0; i < g_cfg->pkg_count; i++) {
        if (!has_license(elements, cur_size, (uint32_t)g_cfg->package_ids[i]))
            to_inject++;
    }
    if (!to_inject) return;

    int new_total = cur_size + to_inject;

    if (new_total > tot_size) {
        size_t new_rep_size = REP_ELEMENTS_OFF + (size_t)new_total * sizeof(void *);
        void *new_rep = malloc(new_rep_size);
        if (!new_rep) {
            SX_ERR("InitFromPacket: malloc(%zu) for new Rep failed", new_rep_size);
            return;
        }
        memset(new_rep, 0, new_rep_size);
        memcpy((uint8_t *)new_rep + REP_ELEMENTS_OFF,
               (uint8_t *)rep + REP_ELEMENTS_OFF,
               (size_t)cur_size * sizeof(void *));
        *(int32_t *)new_rep = (int32_t)cur_size;
        *(void **)(b + BODY_RPF_REP) = new_rep;

        rep = new_rep;
        rep_bytes = (uint8_t *)new_rep;
        elements = (void **)(rep_bytes + REP_ELEMENTS_OFF);
        tot_size = new_total;

        SX_LOG("InitFromPacket: grew Rep array to capacity %d (allocated_size=%d)",
               new_total, cur_size);
    }

    int injected = 0;
    for (int i = 0; i < g_cfg->pkg_count; i++) {
        uint32_t pkg = (uint32_t)g_cfg->package_ids[i];
        if (has_license(elements, cur_size + injected, pkg)) continue;

        void *new_lic = clone_injected_license(template_lic, pkg);
        if (!new_lic) {
            SX_ERR("InitFromPacket: malloc(%d) for License clone failed", LIC_OBJ_SIZE_FALLBACK);
            continue;
        }

        elements[cur_size + injected] = new_lic;
        injected++;

        SX_LOG("InitFromPacket: injected License for package %u (clone @ %p)", pkg, new_lic);
    }

    *(int32_t *)(b + BODY_RPF_CURSIZE) = cur_size + injected;
    // total_size_ must match the actual Rep capacity or Steam's next grow goes OOB.
    if (tot_size > *(int32_t *)(b + BODY_RPF_TOTSIZE))
        *(int32_t *)(b + BODY_RPF_TOTSIZE) = tot_size;

    SX_LOG("InitFromPacket: license injection complete. %d added, total now %d",
           injected, cur_size + injected);
}

void sx_license_inject_from_packet(CProtoBufMsg_t *msg) {
    sx_config_t *g_cfg = sx_config_current;
    if (!g_cfg || g_cfg->pkg_count == 0)
        return;

    uint32_t emsg = msg->eMsg & EMSG_MASK;

    if (emsg != EMSG_CLIENT_LICENSE_LIST)
        return;

    void *body = msg->body;
    if (!body) {
        SX_WARN("InitFromPacket: EMsg 780 but body is NULL");
        return;
    }

    SX_LOG("InitFromPacket: intercepted EMsg 780 (ClientLicenseList), body=%p", body);

    inject_licenses_into_body(body);
}

void sx_license_handle_list(void *body) {
    sx_config_t *g_cfg = sx_config_current;

    if (body && g_cfg && g_cfg->pkg_count > 0) {
        SX_LOG("HandleLicenseList: injecting %d configured package(s) into genuine body",
               g_cfg->pkg_count);
        inject_licenses_into_body(body);
    }
}
