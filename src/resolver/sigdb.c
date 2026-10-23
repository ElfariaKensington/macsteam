// Signature database loader
#include "sigdb.h"
#include "../util/log.h"
#include "../util/file.h"
#include "../../vendor/cJSON.h"

#include <stdlib.h>
#include <string.h>

static cJSON *parse_sigdb_json(const char *path) {
    size_t len = 0;
    uint8_t *raw = sx_slurp_file(path, &len);
    if (!raw) return NULL;

    char *buf = (char *)realloc(raw, len + 1);
    if (!buf) { free(raw); return NULL; }
    buf[len] = '\0';

    cJSON *root = cJSON_Parse(buf);
    free(buf);
    return root;
}

static uintptr_t parse_hex_addr(const char *s) {
    if (!s) return 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
    return (uintptr_t)strtoull(s, NULL, 16);
}

// JSON numbers lose precision above 2^53, but build ids fit
static uint64_t read_build_id(cJSON *obj, const char *key) {
    cJSON *j = cJSON_GetObjectItem(obj, key);
    if (!j) return 0;
    if (cJSON_IsString(j) && j->valuestring)
        return strtoull(j->valuestring, NULL, 10);
    if (cJSON_IsNumber(j))
        return (uint64_t)j->valuedouble;
    return 0;
}

static void json_copy_str(cJSON *obj, const char *key, char *dst, size_t dstsz) {
    cJSON *j = cJSON_GetObjectItem(obj, key);
    if (j && cJSON_IsString(j) && j->valuestring && dstsz > 0) {
        strncpy(dst, j->valuestring, dstsz - 1);
        dst[dstsz - 1] = '\0';
    }
}

static void parse_anchor(cJSON *sig, sx_anchor_t *a) {
    cJSON *obj = cJSON_GetObjectItem(sig, "anchor");
    if (!obj || !cJSON_IsObject(obj)) return;

    cJSON *k = cJSON_GetObjectItem(obj, "kind");
    if (!k || !cJSON_IsString(k) || !k->valuestring) return;

    if (strcmp(k->valuestring, "string") == 0) {
        a->kind = SX_ANCHOR_STRING;
        json_copy_str(obj, "value", a->str, sizeof(a->str));
    } else if (strcmp(k->valuestring, "insn_after_string") == 0) {
        a->kind = SX_ANCHOR_INSN_AFTER_STRING;
        json_copy_str(obj, "value", a->str, sizeof(a->str));
        cJSON *n = cJSON_GetObjectItem(obj, "n");
        a->nth = (n && cJSON_IsNumber(n)) ? n->valueint : 1;
        // mnem defaults to BLR in the engine when insn/insn_mask are 0
    } else if (strcmp(k->valuestring, "vtable_slot") == 0) {
        a->kind = SX_ANCHOR_VTABLE_SLOT;
        cJSON *v = cJSON_GetObjectItem(obj, "va");
        a->va = parse_hex_addr((v && cJSON_IsString(v)) ? v->valuestring : "0");
    } else if (strcmp(k->valuestring, "nth_ref") == 0) {
        a->kind = SX_ANCHOR_NTH_REF;
        json_copy_str(obj, "value", a->str, sizeof(a->str));
        cJSON *n = cJSON_GetObjectItem(obj, "n");
        a->nth = (n && cJSON_IsNumber(n)) ? n->valueint : 1;
    }
}

int sx_sigdb_load(const char *path, sx_sigdb_t *out) {
    if (!path || !out) return -1;
    memset(out, 0, sizeof(*out));

    cJSON *root = parse_sigdb_json(path);
    if (!root) { SX_ERR("sigdb: cannot read or parse '%s'", path); return -1; }

    cJSON *j;

    if ((j = cJSON_GetObjectItem(root, "schema_version")))
        out->schema_version = j->valueint;
    if ((j = cJSON_GetObjectItem(root, "profile_version")))
        out->sigdb_version = j->valueint;
    out->steam_build = read_build_id(root, "steam_build");
    json_copy_str(root, "steam_build_date", out->steam_build_date, sizeof(out->steam_build_date));

    cJSON *sigs = cJSON_GetObjectItem(root, "signatures");
    if (sigs && cJSON_IsArray(sigs) && cJSON_GetArraySize(sigs) > 0) {
        int count = cJSON_GetArraySize(sigs);
        out->signatures = (sx_sig_entry_t *)calloc((size_t)count, sizeof(sx_sig_entry_t));
        if (!out->signatures) { cJSON_Delete(root); return -1; }
        out->sig_count = count;

        int idx = 0;
        cJSON *sig = NULL;
        cJSON_ArrayForEach(sig, sigs) {
            if (idx >= count) break;
            sx_sig_entry_t *e = &out->signatures[idx++];
            json_copy_str(sig, "name", e->name, sizeof(e->name));
            json_copy_str(sig, "aob_hex", e->aob_hex, sizeof(e->aob_hex));
            if ((j = cJSON_GetObjectItem(sig, "reference_va")))
                e->reference_va = parse_hex_addr(cJSON_IsString(j) ? j->valuestring : "0");
            if ((j = cJSON_GetObjectItem(sig, "deprecated")))
                e->deprecated = cJSON_IsTrue(j) ? 1 : 0;
            if ((j = cJSON_GetObjectItem(sig, "match_offset")))
                e->match_offset = (int32_t)j->valueint;
            parse_anchor(sig, &e->anchor);
        }
    }

    cJSON_Delete(root);
    SX_LOG("sigdb: loaded %d signatures from '%s' (schema=%d, profile=%d, steam_build=%llu %s)",
           out->sig_count, path, out->schema_version, out->sigdb_version,
           (unsigned long long)out->steam_build,
           out->steam_build_date[0] ? out->steam_build_date : "");
    return 0;
}

void sx_sigdb_free(sx_sigdb_t *p) {
    if (!p) return;
    free(p->signatures);
    p->signatures = NULL;
    p->sig_count = 0;
}

uint64_t sx_sigdb_peek_build(const char *path) {
    cJSON *root = parse_sigdb_json(path);
    if (!root) return 0;

    uint64_t build = read_build_id(root, "steam_build");
    cJSON_Delete(root);
    return build;
}
