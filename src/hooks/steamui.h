#ifndef SX_HOOKS_STEAMUI_H
#define SX_HOOKS_STEAMUI_H

#include <stddef.h>

// Resolve CSS-module export keys (`[,{]Key:"hash"`) in a Steam JS bundle.
// Writes each resolved hash (or "" if unresolved) into hashes[i] and returns
// the number of keys resolved.
int sx_steamui_resolve_keys(const char *js, size_t len,
                            const char *const *keys, size_t n,
                            char hashes[][64]);

// Return a malloc'd copy of css with an appended macsteam display:none rule
// covering only hashes that occur as `.hash` selectors in css, or NULL if none
// apply or the block is already present.
char *sx_steamui_css_hide(const char *css, size_t len,
                          const char *const *hashes, size_t n,
                          size_t *out_len);

// Run cloud_errors.js over sp.js. Returns a malloc'd NUL-terminated result and its
// length, or NULL when the bundle is not recognized or nothing changed.
char *sx_steamui_cloud_transform(const char *source, size_t len, size_t *out_len);

// One-time cleanup of legacy on-disk Steam UI edits (steam_osx only).
void sx_steamui_restore_disk(void);

#endif
