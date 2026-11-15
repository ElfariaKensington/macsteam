// Binary KeyValues (BKV) reader/writer
#include "bkv.h"
#include "../util/log.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define BKV_MAX_DEPTH 64
#define BKV_SCALAR_HEAD 1

typedef struct {
    const uint8_t *data;
    size_t         len;
    size_t         pos;
} bkv_cur_t;

static char *dup_name(const char *src, size_t len) {
    char *out = (char *)malloc(len + 1);
    if (!out) return NULL;
    memcpy(out, src, len);
    out[len] = '\0';
    return out;
}

static int read_name(bkv_cur_t *c, char **out) {
    size_t start = c->pos;
    while (c->pos < c->len && c->data[c->pos] != 0) c->pos++;
    if (c->pos >= c->len) return -1;
    *out = dup_name((const char *)c->data + start, c->pos - start);
    c->pos++;
    return *out ? 0 : -1;
}

static int read_bytes(bkv_cur_t *c, void *out, size_t n) {
    if (n > c->len - c->pos) return -1;
    memcpy(out, c->data + c->pos, n);
    c->pos += n;
    return 0;
}

static void free_children(sx_bkv_node_t *child);

static sx_bkv_node_t *parse_node(bkv_cur_t *c, int depth) {
    if (depth > BKV_MAX_DEPTH || c->pos >= c->len) return NULL;

    uint8_t type = c->data[c->pos++];
    if (type == SX_BKV_END) return NULL;

    sx_bkv_node_t *node = (sx_bkv_node_t *)calloc(1, sizeof(*node));
    if (!node) return NULL;
    node->type = type;

    if (read_name(c, &node->name) != 0) {
        free(node);
        return NULL;
    }

    switch (type) {
    case SX_BKV_SECTION: {
        sx_bkv_node_t **tail = &node->child;
        for (;;) {
            if (c->pos >= c->len) goto fail;
            if (c->data[c->pos] == SX_BKV_END) { c->pos++; break; }
            sx_bkv_node_t *kid = parse_node(c, depth + 1);
            if (!kid) goto fail;
            *tail = kid;
            tail = &kid->next;
        }
        break;
    }
    case SX_BKV_STRING: {
        size_t start = c->pos;
        while (c->pos < c->len && c->data[c->pos] != 0) c->pos++;
        if (c->pos >= c->len) goto fail;
        node->v.str = dup_name((const char *)c->data + start, c->pos - start);
        if (!node->v.str) goto fail;
        c->pos++;
        break;
    }
    case SX_BKV_INT:
        if (read_bytes(c, &node->v.i32, 4) != 0) goto fail;
        break;
    case SX_BKV_FLOAT:
        if (read_bytes(c, &node->v.f32, 4) != 0) goto fail;
        break;
    case SX_BKV_UINT64:
        if (read_bytes(c, &node->v.u64, 8) != 0) goto fail;
        break;
    case SX_BKV_INT64:
        if (read_bytes(c, &node->v.i64, 8) != 0) goto fail;
        break;
    default:
        goto fail;
    }
    return node;

fail:
    if (type == SX_BKV_SECTION) free_children(node->child);
    else if (type == SX_BKV_STRING) free(node->v.str);
    free(node->name);
    free(node);
    return NULL;
}

static void free_children(sx_bkv_node_t *child) {
    while (child) {
        sx_bkv_node_t *next = child->next;
        if (child->type == SX_BKV_SECTION) free_children(child->child);
        else if (child->type == SX_BKV_STRING) free(child->v.str);
        free(child->name);
        free(child);
        child = next;
    }
}

sx_bkv_node_t *sx_bkv_parse(const uint8_t *data, size_t len) {
    if (!data || !len) return NULL;
    bkv_cur_t c = { data, len, 0 };

    if (data[0] != SX_BKV_SECTION) return NULL;
    c.pos = 1;
    char *name = NULL;
    if (read_name(&c, &name) != 0) return NULL;

    sx_bkv_node_t *root = (sx_bkv_node_t *)calloc(1, sizeof(*root));
    if (!root) { free(name); return NULL; }
    root->type = SX_BKV_SECTION;
    root->name = name;

    sx_bkv_node_t **tail = &root->child;
    while (c.pos < len) {
        if (c.data[c.pos] == SX_BKV_END) {
            // A trailing END terminates the root section. Anything after it is
            // not part of the BKV document.
            c.pos++;
            break;
        }
        sx_bkv_node_t *kid = parse_node(&c, 1);
        if (!kid) { sx_bkv_free(root); return NULL; }
        *tail = kid;
        tail = &kid->next;
    }

    if (c.pos != len && c.pos < len) {
        // Schema files carry a trailing END sentinel; some files pad with
        // zeroes. Accept either, reject anything else as corrupt.
        for (size_t i = c.pos; i < len; i++) {
            if (c.data[i] != 0 && c.data[i] != SX_BKV_END) {
                sx_bkv_free(root);
                return NULL;
            }
        }
    }
    return root;
}

sx_bkv_node_t *sx_bkv_new_section(const char *name) {
    if (!name) return NULL;
    sx_bkv_node_t *node = (sx_bkv_node_t *)calloc(1, sizeof(*node));
    if (!node) return NULL;
    node->type = SX_BKV_SECTION;
    node->name = strdup(name);
    if (!node->name) { free(node); return NULL; }
    return node;
}

void sx_bkv_free(sx_bkv_node_t *node) {
    if (!node) return;
    free_children(node->child);
    free(node->name);
    free(node);
}

sx_bkv_node_t *sx_bkv_child(const sx_bkv_node_t *section, const char *name) {
    if (!section || section->type != SX_BKV_SECTION || !name) return NULL;
    for (sx_bkv_node_t *c = section->child; c; c = c->next)
        if (c->name && strcmp(c->name, name) == 0) return c;
    return NULL;
}

static void unlink_child(sx_bkv_node_t *section, sx_bkv_node_t *node) {
    sx_bkv_node_t **link = &section->child;
    while (*link) {
        if (*link == node) { *link = node->next; return; }
        link = &(*link)->next;
    }
}

static void destroy_node(sx_bkv_node_t *node) {
    if (!node) return;
    if (node->type == SX_BKV_SECTION) free_children(node->child);
    else if (node->type == SX_BKV_STRING) free(node->v.str);
    free(node->name);
    free(node);
}

sx_bkv_node_t *sx_bkv_ensure_section(sx_bkv_node_t *section, const char *name) {
    if (!section || section->type != SX_BKV_SECTION || !name) return NULL;
    sx_bkv_node_t *node = sx_bkv_child(section, name);
    if (node && node->type == SX_BKV_SECTION) return node;
    if (node) {
        unlink_child(section, node);
        destroy_node(node);
    }
    node = (sx_bkv_node_t *)calloc(1, sizeof(*node));
    if (!node) return NULL;
    node->type = SX_BKV_SECTION;
    node->name = dup_name(name, strlen(name));
    if (!node->name) { free(node); return NULL; }
    node->next = section->child;
    section->child = node;
    return node;
}

sx_bkv_node_t *sx_bkv_set_int(sx_bkv_node_t *section, const char *name, int32_t value) {
    if (!section || section->type != SX_BKV_SECTION || !name) return NULL;
    sx_bkv_node_t *node = sx_bkv_child(section, name);
    if (node && node->type != SX_BKV_INT) {
        unlink_child(section, node);
        destroy_node(node);
        node = NULL;
    }
    if (!node) {
        node = (sx_bkv_node_t *)calloc(1, sizeof(*node));
        if (!node) return NULL;
        node->type = SX_BKV_INT;
        node->name = dup_name(name, strlen(name));
        if (!node->name) { free(node); return NULL; }
        node->next = section->child;
        section->child = node;
    }
    node->v.i32 = value;
    return node;
}

sx_bkv_node_t *sx_bkv_set_string(sx_bkv_node_t *section, const char *name, const char *value) {
    if (!section || section->type != SX_BKV_SECTION || !name || !value) return NULL;
    sx_bkv_node_t *node = sx_bkv_child(section, name);
    if (node && node->type != SX_BKV_STRING) {
        unlink_child(section, node);
        destroy_node(node);
        node = NULL;
    }
    if (!node) {
        node = (sx_bkv_node_t *)calloc(1, sizeof(*node));
        if (!node) return NULL;
        node->type = SX_BKV_STRING;
        node->name = dup_name(name, strlen(name));
        if (!node->name) { free(node); return NULL; }
        node->next = section->child;
        section->child = node;
    }
    char *copy = dup_name(value, strlen(value));
    if (!copy) return NULL;
    free(node->v.str);
    node->v.str = copy;
    return node;
}

void sx_bkv_remove(sx_bkv_node_t *section, const char *name) {
    if (!section || section->type != SX_BKV_SECTION || !name) return;
    sx_bkv_node_t *node = sx_bkv_child(section, name);
    if (!node) return;
    unlink_child(section, node);
    destroy_node(node);
}

static size_t node_size(const sx_bkv_node_t *node) {
    size_t n = BKV_SCALAR_HEAD + strlen(node->name) + 1;
    switch (node->type) {
    case SX_BKV_SECTION:
        for (const sx_bkv_node_t *c = node->child; c; c = c->next)
            n += node_size(c);
        n += 1; // END
        break;
    case SX_BKV_STRING:
        n += strlen(node->v.str) + 1;
        break;
    case SX_BKV_INT:
    case SX_BKV_FLOAT:
        n += 4;
        break;
    case SX_BKV_UINT64:
    case SX_BKV_INT64:
        n += 8;
        break;
    default:
        break;
    }
    return n;
}

size_t sx_bkv_encoded_size(const sx_bkv_node_t *node) {
    if (!node) return 0;
    // Steam's binary KeyValues files carry one END byte for the root section
    // and a second END sentinel after it. Both are required.
    return node_size(node) + (node->type == SX_BKV_SECTION ? 1u : 0u);
}

typedef struct {
    uint8_t *out;
    size_t   cap;
    size_t   pos;
    int      ok;
} bkv_writer_t;

static void put_bytes(bkv_writer_t *w, const void *src, size_t n) {
    if (!w->ok) return;
    if (n > w->cap - w->pos) { w->ok = 0; return; }
    memcpy(w->out + w->pos, src, n);
    w->pos += n;
}

static void put_byte(bkv_writer_t *w, uint8_t b) {
    put_bytes(w, &b, 1);
}

static void encode_node(bkv_writer_t *w, const sx_bkv_node_t *node) {
    if (!w->ok) return;
    put_byte(w, node->type);
    put_bytes(w, node->name, strlen(node->name) + 1);
    switch (node->type) {
    case SX_BKV_SECTION:
        for (const sx_bkv_node_t *c = node->child; c; c = c->next)
            encode_node(w, c);
        put_byte(w, SX_BKV_END);
        break;
    case SX_BKV_STRING:
        put_bytes(w, node->v.str, strlen(node->v.str) + 1);
        break;
    case SX_BKV_INT:
        put_bytes(w, &node->v.i32, 4);
        break;
    case SX_BKV_FLOAT:
        put_bytes(w, &node->v.f32, 4);
        break;
    case SX_BKV_UINT64:
        put_bytes(w, &node->v.u64, 8);
        break;
    case SX_BKV_INT64:
        put_bytes(w, &node->v.i64, 8);
        break;
    default:
        w->ok = 0;
        break;
    }
}

int sx_bkv_encode(const sx_bkv_node_t *node, uint8_t *out, size_t cap) {
    if (!node || !out) return -1;
    size_t need = sx_bkv_encoded_size(node);
    if (cap < need) return -1;
    bkv_writer_t w = { out, cap, 0, 1 };
    encode_node(&w, node);
    if (node->type == SX_BKV_SECTION) put_byte(&w, SX_BKV_END);
    return w.ok ? (int)w.pos : -1;
}

static int write_atomic(const char *path, const void *data, size_t len) {
    char tmp[4096];
    int n = snprintf(tmp, sizeof(tmp), "%s.macsteam.%d.tmp", path, (int)getpid());
    if (n < 0 || (size_t)n >= sizeof(tmp)) return -1;

    mode_t mode = 0644;
    struct stat st;
    if (stat(path, &st) == 0) mode = st.st_mode & 07777;

    FILE *f = fopen(tmp, "wb");
    if (!f) return -1;
    int ok = fwrite(data, 1, len, f) == len && fflush(f) == 0;
    if (ok) fsync(fileno(f));
    if (fclose(f) != 0) ok = 0;
    if (!ok) { unlink(tmp); return -1; }
    chmod(tmp, mode);
    if (rename(tmp, path) != 0) { unlink(tmp); return -1; }
    return 0;
}

int sx_bkv_write_file_atomic(const char *path, const sx_bkv_node_t *root) {
    if (!path || !root) return -1;
    size_t need = sx_bkv_encoded_size(root);
    if (!need) return -1;
    uint8_t *buf = (uint8_t *)malloc(need);
    if (!buf) return -1;
    int wrote = sx_bkv_encode(root, buf, need);
    if (wrote < 0) { free(buf); return -1; }
    int rc = write_atomic(path, buf, (size_t)wrote);
    free(buf);
    if (rc != 0)
        SX_WARN("[bkv] failed to write %s: %s", path, strerror(errno));
    return rc;
}
