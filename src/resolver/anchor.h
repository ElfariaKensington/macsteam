// Anchor resolution
#ifndef MACSTEAM_RESOLVER_ANCHOR_H
#define MACSTEAM_RESOLVER_ANCHOR_H

#include <stdint.h>
#include <stddef.h>
#include <mach-o/loader.h>

typedef enum {
    SX_ANCHOR_NONE = 0,
    SX_ANCHOR_STRING,             // fn that PC-relative references a C string
    SX_ANCHOR_VTABLE_SLOT,        // code ptr stored at a data VA
    SX_ANCHOR_INSN_AFTER_STRING,  // insn after the Nth `mnem` past a string ref
    SX_ANCHOR_NTH_REF,            // Nth ADRP+ADD ref to any instance of a string
} sx_anchor_kind_t;

typedef struct {
    sx_anchor_kind_t kind;
    char             str[256];   // STRING / INSN_AFTER_STRING
    uintptr_t        va;         // VTABLE_SLOT (unslid)
    uint32_t         insn;       // INSN_AFTER_STRING: opcode-match value
    uint32_t         insn_mask;  // INSN_AFTER_STRING: opcode mask
    int              nth;        // INSN_AFTER_STRING / NTH_REF: which match (1-based)
} sx_anchor_t;

// Runtime address with slide applied, or 0.
uintptr_t sx_anchor_resolve(const struct mach_header_64 *mh, intptr_t slide,
                            uintptr_t text_base, size_t text_size,
                            const sx_anchor_t *anchor);

#endif // MACSTEAM_RESOLVER_ANCHOR_H
