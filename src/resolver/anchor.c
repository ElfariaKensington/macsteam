// Anchor resolution
#include "anchor.h"
#include "resolver.h"
#include "../core/macho.h"
#include "../util/log.h"

#include <string.h>

#define BLR_MATCH 0xD63F0000u
#define BLR_MASK  0xFFFFFC1Fu

static uintptr_t decode_adrp(uintptr_t pc, uint32_t insn, int *rd) {
    if ((insn & 0x9F000000u) != 0x90000000u) return 0; // ADRP: op=1, 10000
    uint32_t immlo = (insn >> 29) & 0x3u;
    uint32_t immhi = (insn >> 5) & 0x7FFFFu;
    int64_t imm = (int64_t)((immhi << 2) | immlo);
    imm = (imm << 43) >> 43;           // sign-extend 21-bit
    *rd = (int)(insn & 0x1Fu);
    return (pc & ~(uintptr_t)0xFFF) + (uintptr_t)(imm << 12);
}

static uintptr_t decode_add_imm(uint32_t insn, int adrp_rd, uintptr_t page) {
    if ((insn & 0x7F800000u) != 0x11000000u) return 0; // ADD (imm), shift=0
    int rn = (int)((insn >> 5) & 0x1Fu);
    if (rn != adrp_rd) return 0;
    uint32_t imm12 = (insn >> 10) & 0xFFFu;
    if ((insn >> 22) & 0x1u) imm12 <<= 12; // LSL #12
    return page + imm12;
}

static int find_all_cstring_vas(const struct mach_header_64 *mh, intptr_t slide,
                                const char *s, uintptr_t *out, int max) {
    static const char *segs[] = {"__TEXT", "__DATA_CONST", "__DATA"};
    size_t n = strlen(s);
    int count = 0;
    for (size_t si = 0; si < sizeof(segs) / sizeof(segs[0]); si++) {
        uintptr_t base = 0;
        size_t size = 0;
        if (sx_get_segment(mh, slide, segs[si], &base, &size) != 0) continue;
        if (size < n + 1) continue;
        const char *p = (const char *)base;
        for (size_t i = 0; i + n + 1 <= size; i++) {
            if (p[i] != s[0]) continue;
            if (memcmp(p + i, s, n) == 0 && p[i + n] == '\0') {
                if (count < max) out[count] = base + i;
                count++;
                i += n;
            }
        }
    }
    return count;
}

static uintptr_t find_cstring_va(const struct mach_header_64 *mh, intptr_t slide,
                                 const char *s) {
    uintptr_t va = 0;
    int n = find_all_cstring_vas(mh, slide, s, &va, 1);
    if (n == 1) return va;
    return 0; // not unique
}

static uintptr_t find_string_ref(uintptr_t text_base, size_t text_size,
                                 uintptr_t str_va) {
    uintptr_t hit = 0;
    for (size_t off = 0; off + 8 <= text_size; off += 4) {
        uintptr_t pc = text_base + off;
        uint32_t a = *(const uint32_t *)pc;
        int rd = -1;
        uintptr_t page = decode_adrp(pc, a, &rd);
        if (!page) continue;
        uint32_t b = *(const uint32_t *)(pc + 4);
        uintptr_t target = decode_add_imm(b, rd, page);
        if (target != str_va) continue;
        if (hit) return 0; // ambiguous
        hit = pc;
    }
    return hit;
}

static uintptr_t find_nth_string_ref(uintptr_t text_base, size_t text_size,
                                     const uintptr_t *str_vas, int nvas, int nth) {
    int seen = 0;
    for (size_t off = 0; off + 8 <= text_size; off += 4) {
        uintptr_t pc = text_base + off;
        uint32_t a = *(const uint32_t *)pc;
        int rd = -1;
        uintptr_t page = decode_adrp(pc, a, &rd);
        if (!page) continue;
        uint32_t b = *(const uint32_t *)(pc + 4);
        uintptr_t target = decode_add_imm(b, rd, page);
        if (!target) continue;
        for (int i = 0; i < nvas; i++) {
            if (target == str_vas[i]) {
                if (++seen == nth) return pc;
                break;
            }
        }
    }
    return 0;
}

static uintptr_t walk_back_to_prologue(uintptr_t text_base, uintptr_t ref) {
    uintptr_t hit = 0;
    for (uintptr_t pc = ref; pc >= text_base; pc -= 4) {
        if (sx_is_arm64_prologue(pc)) {
            hit = pc;
        } else if (hit) {
            return hit;
        }
        if (pc == text_base) break;
    }
    return hit;
}

static uintptr_t nth_insn_after(uintptr_t text_base, size_t text_size,
                                uintptr_t ref, uint32_t match, uint32_t mask,
                                int nth) {
    uintptr_t end = text_base + text_size;
    int seen = 0;
    for (uintptr_t pc = ref; pc + 4 <= end; pc += 4) {
        uint32_t insn = *(const uint32_t *)pc;
        if ((insn & mask) == match) {
            if (++seen == nth) return pc + 4;
        }
    }
    return 0;
}

uintptr_t sx_anchor_resolve(const struct mach_header_64 *mh, intptr_t slide,
                            uintptr_t text_base, size_t text_size,
                            const sx_anchor_t *anchor) {
    if (!mh || !anchor || !text_base || !text_size) return 0;

    switch (anchor->kind) {
    case SX_ANCHOR_STRING: {
        uintptr_t str_va = find_cstring_va(mh, slide, anchor->str);
        if (!str_va) return 0;
        uintptr_t ref = find_string_ref(text_base, text_size, str_va);
        if (!ref) return 0;
        return walk_back_to_prologue(text_base, ref);
    }
    case SX_ANCHOR_INSN_AFTER_STRING: {
        uintptr_t str_va = find_cstring_va(mh, slide, anchor->str);
        if (!str_va) return 0;
        uintptr_t ref = find_string_ref(text_base, text_size, str_va);
        if (!ref) return 0;
        uint32_t match = anchor->insn ? anchor->insn : BLR_MATCH;
        uint32_t mask = anchor->insn_mask ? anchor->insn_mask : BLR_MASK;
        int nth = anchor->nth > 0 ? anchor->nth : 1;
        return nth_insn_after(text_base, text_size, ref, match, mask, nth);
    }
    case SX_ANCHOR_VTABLE_SLOT: {
        uintptr_t at = anchor->va + (uintptr_t)slide;
        uintptr_t ptr = *(const uintptr_t *)at;
        if (ptr < text_base || ptr >= text_base + text_size) return 0;
        return sx_is_arm64_prologue(ptr) ? ptr : 0;
    }
    case SX_ANCHOR_NTH_REF: {
        uintptr_t vas[16];
        int nvas = find_all_cstring_vas(mh, slide, anchor->str, vas, 16);
        if (nvas == 0) return 0;
        if (nvas > 16) nvas = 16;
        int nth = anchor->nth > 0 ? anchor->nth : 1;
        uintptr_t ref = find_nth_string_ref(text_base, text_size, vas, nvas, nth);
        if (!ref) return 0;
        return walk_back_to_prologue(text_base, ref);
    }
    default:
        return 0;
    }
}
