// Signature resolver
#include "resolver.h"
#include "aob.h"
#include "anchor.h"
#include "../core/macho.h"
#include "../util/log.h"

#include <stdlib.h>
#include <string.h>

int sx_is_arm64_prologue(uintptr_t addr) {
    if (!addr) return 0;
    uint32_t insn = *(const uint32_t *)addr;

    if ((insn & 0xFF0003FF) == 0xD10003FF) return 1; // SUB SP, SP, #imm
    if ((insn & 0xFFC07FFF) == 0xA9007BFD) return 1; // STP x29, x30, [SP, #off]
    if ((insn & 0xFFC07FFF) == 0xA9807BFD) return 1; // STP x29, x30, [SP, #off]!
    if (insn == 0xD503237F) return 1;                 // PACIBSP
    if ((insn & 0xFFC003FF) == 0x910003FD) return 1; // ADD x29, SP, #imm (MOV if imm=0)
    if ((insn & 0xFFC003E0) == 0xA98003E0) return 1; // STP Xt, Xt2, [SP, #off]!
    if ((insn & 0xFFC003E0) == 0xA90003E0) return 1; // STP Xt, Xt2, [SP, #off]

    return 0;
}

static void result_add(sx_resolve_result_t *r, const char *name, uintptr_t addr) {
    if (r->count >= r->capacity) {
        int new_cap = r->capacity ? r->capacity * 2 : 64;
        sx_resolved_t *new_entries = (sx_resolved_t *)realloc(
            r->entries, (size_t)new_cap * sizeof(sx_resolved_t));
        if (!new_entries) return;
        r->entries = new_entries;
        r->capacity = new_cap;
    }
    sx_resolved_t *e = &r->entries[r->count++];
    e->name = name;
    e->address = addr;
}

int sx_resolve_all_ex(const struct mach_header_64 *mh, intptr_t slide,
                      const char *dylib_path,
                      sx_sigdb_t *sigdb, sx_resolve_result_t *out) {
    if (!mh || !sigdb || !out) return 0;
    memset(out, 0, sizeof(*out));

    uintptr_t text_base = 0;
    size_t text_size = 0;
    int have_text = (sx_get_segment(mh, slide, "__TEXT", &text_base, &text_size) == 0);

    if (!have_text) {
        SX_ERR("resolver: __TEXT segment not found, cannot scan");
        return 0;
    }

    SX_LOG("resolver: scanning __TEXT @ 0x%lx (%zu bytes) for %d signatures",
           text_base, text_size, sigdb->sig_count);
    if (dylib_path)
        SX_LOG("resolver: file-based fallback enabled: %s", dylib_path);

    int resolved = 0;

    for (int i = 0; i < sigdb->sig_count; i++) {
        sx_sig_entry_t *sig = &sigdb->signatures[i];
        uintptr_t addr = 0;
        const char *method = "unresolved";

        if (sig->deprecated) {
            result_add(out, sig->name, 0);
            continue;
        }

        if (sig->aob_hex[0]) {
            sx_pattern_t pat;
            if (sx_pattern_from_hex(sig->aob_hex, &pat) == 0) {
                addr = sx_aob_scan_unique(text_base, text_size, &pat);
                if (addr) {
                    method = "aob_mem";
                }

                if (!addr && dylib_path) {
                    addr = sx_aob_scan_file(dylib_path, slide, &pat);
                    if (addr) {
                        method = "aob_file";
                        SX_LOG("resolver: '%s' -> 0x%lx [aob_file] (runtime-patched, resolved from disk)",
                               sig->name, (unsigned long)addr);
                    }
                }

                sx_pattern_free(&pat);

                int scan_hit = (addr != 0);

                if (addr && sig->match_offset != 0) {
                    uintptr_t adjusted = addr - (uintptr_t)sig->match_offset;
                    SX_DBG("resolver: '%s' match_offset=%d: 0x%lx -> 0x%lx",
                           sig->name, sig->match_offset,
                           (unsigned long)addr, (unsigned long)adjusted);
                    if (adjusted < text_base || adjusted >= text_base + text_size) {
                        SX_WARN("resolver: '%s' match_offset=%d puts start 0x%lx outside __TEXT, rejecting",
                                sig->name, sig->match_offset, (unsigned long)adjusted);
                        addr = 0;
                    } else {
                        addr = adjusted;
                    }
                }

                if (!addr && !scan_hit) {
                    SX_WARN("resolver: '%s' AOB scan failed (no unique match in mem or file)",
                            sig->name);
                }
            } else {
                SX_ERR("resolver: '%s' invalid AOB pattern", sig->name);
            }
        }

        // Anchor fallback, survives Steam updates
        if (!addr && sig->anchor.kind != SX_ANCHOR_NONE) {
            addr = sx_anchor_resolve(mh, slide, text_base, text_size, &sig->anchor);
            if (addr) {
                method = "anchor";
                SX_LOG("resolver: '%s' -> 0x%lx [anchor] (AOB stale, re-derived)",
                       sig->name, (unsigned long)addr);
            }
        }

        // Dev fallback, not update-safe
        if (!addr && sig->reference_va) {
            uintptr_t candidate = sig->reference_va + (uintptr_t)slide;
            int in_text = candidate >= text_base &&
                          candidate <= text_base + text_size - sizeof(uint32_t);
            if (in_text && sx_is_arm64_prologue(candidate)) {
                addr = candidate;
                method = "reference_va";
                SX_DBG("resolver: '%s' -> 0x%lx (reference_va fallback)", sig->name, addr);
            }
        }

        if (addr) {
            resolved++;
            SX_DBG("resolver: '%s' -> 0x%lx [%s]", sig->name, addr, method);
        }

        result_add(out, sig->name, addr);
    }

    SX_LOG("resolver: %d/%d signatures resolved", resolved, sigdb->sig_count);
    return resolved;
}

uintptr_t sx_resolve_find(const sx_resolve_result_t *result, const char *name) {
    if (!result || !name) return 0;
    for (int i = 0; i < result->count; i++) {
        const sx_resolved_t *entry = &result->entries[i];
        if (entry->name && strcmp(entry->name, name) == 0)
            return entry->address;
    }
    return 0;
}

void sx_resolve_result_free(sx_resolve_result_t *result) {
    if (!result) return;
    free(result->entries);
    memset(result, 0, sizeof(*result));
}
