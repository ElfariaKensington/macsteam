// Binary KeyValues (BKV) reader/writer
//
// Steam stores both the achievement schema and the per-user stats cache as
// binary KeyValues blobs. This is a small DOM implementation: parse a whole
// file, edit it, serialize it back byte-for-byte in the same layout.
#ifndef MACSTEAM_CORE_BKV_H
#define MACSTEAM_CORE_BKV_H

#include <stddef.h>
#include <stdint.h>

enum {
    SX_BKV_SECTION = 0,
    SX_BKV_STRING  = 1,
    SX_BKV_INT     = 2,
    SX_BKV_FLOAT   = 3,
    SX_BKV_UINT64  = 7,
    SX_BKV_END     = 8,
    SX_BKV_INT64   = 10,
};

typedef struct sx_bkv_node {
    char *name;
    uint8_t type;
    union {
        char    *str;
        int32_t  i32;
        float    f32;
        uint64_t u64;
        int64_t  i64;
    } v;
    struct sx_bkv_node *child;   // sections only
    struct sx_bkv_node *next;
} sx_bkv_node_t;

// Parse one root section. Returns NULL on malformed input.
sx_bkv_node_t *sx_bkv_parse(const uint8_t *data, size_t len);
void           sx_bkv_free(sx_bkv_node_t *node);

sx_bkv_node_t *sx_bkv_new_section(const char *name);
sx_bkv_node_t *sx_bkv_child(const sx_bkv_node_t *section, const char *name);
sx_bkv_node_t *sx_bkv_ensure_section(sx_bkv_node_t *section, const char *name);
sx_bkv_node_t *sx_bkv_set_int(sx_bkv_node_t *section, const char *name, int32_t value);
sx_bkv_node_t *sx_bkv_set_string(sx_bkv_node_t *section, const char *name, const char *value);
void           sx_bkv_remove(sx_bkv_node_t *section, const char *name);

size_t sx_bkv_encoded_size(const sx_bkv_node_t *node);
int    sx_bkv_encode(const sx_bkv_node_t *node, uint8_t *out, size_t cap);

// Serialize and atomically replace path. Returns 0 on success.
int sx_bkv_write_file_atomic(const char *path, const sx_bkv_node_t *root);

#endif // MACSTEAM_CORE_BKV_H
