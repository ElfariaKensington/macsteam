// Adapted from ElfariaKensington/SomeAppOnlineFix (AGPL-3.0).
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// ABI observations from MacSteam's ARM64 Steam profile; no SDK structs are available.
typedef struct {
    unsigned char *bytes;
    int32_t capacity, grow, cursor, written, extent;
    unsigned char reserved[2], error, mode;
} IPCBuffer;
_Static_assert(offsetof(IPCBuffer, cursor) == 16, "IPC read cursor ABI");
_Static_assert(offsetof(IPCBuffer, error) == 30, "IPC error ABI");


typedef uint64_t (*OFDispatch)(void *, void *, void *, void *);

static inline bool readable(const IPCBuffer *b, int size) {
    return b && b->bytes && !b->error && !(b->mode & 1) && b->cursor >= 0 &&
        b->written >= 0 && b->written <= b->capacity && b->extent <= b->capacity &&
        b->extent >= b->cursor && b->extent - b->cursor >= size;
}
