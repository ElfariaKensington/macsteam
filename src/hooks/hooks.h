// Hook registration and installation
#ifndef MACSTEAM_HOOKS_HOOKS_H
#define MACSTEAM_HOOKS_HOOKS_H

#include <stdint.h>
#include <stddef.h>
#include "../resolver/resolver.h"

enum {
    SX_HOOK_INLINE = 0,
    SX_HOOK_INSTRUMENT = 1,
};

typedef struct {
    const char  *name;
    const char  *sig_name;
    void        *hook_fn;
    void       **orig_fn;
    int          optional;
    int          kind;
} sx_hook_def_t;

int  sx_hooks_apps_count(void);
sx_hook_def_t *sx_hooks_apps_defs(void);
void sx_hooks_apps_force_ready(void);

int  sx_hooks_depot_count(void);
sx_hook_def_t *sx_hooks_depot_defs(void);
void sx_hooks_depot_set_helpers(uintptr_t ensure_capacity, uintptr_t seek_put);

int  sx_hooks_dlc_count(void);
sx_hook_def_t *sx_hooks_dlc_defs(void);

int  sx_hooks_package_count(void);
sx_hook_def_t *sx_hooks_package_defs(void);
void sx_hooks_package_set_helpers(uintptr_t pkg_parse);

int  sx_hooks_license_count(void);
sx_hook_def_t *sx_hooks_license_defs(void);

int  sx_hooks_manifest_count(void);
sx_hook_def_t *sx_hooks_manifest_defs(void);

int  sx_hooks_stats_count(void);
sx_hook_def_t *sx_hooks_stats_defs(void);

int  sx_hooks_ticket_count(void);
sx_hook_def_t *sx_hooks_ticket_defs(void);
void sx_hooks_ticket_set_helpers(uintptr_t put_bytes, uintptr_t put_tag,
                                 uintptr_t get_bytes);

void sx_hooks_ctx_set_helpers(uintptr_t getappid);

void sx_hooks_relaunch_install(void);

int sx_hooks_install_all(sx_resolve_result_t *resolved, int *total_out);

int sx_hook_passthrough(const char *name);

#endif // MACSTEAM_HOOKS_HOOKS_H
