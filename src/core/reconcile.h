// Late-injection recovery
#ifndef MACSTEAM_CORE_RECONCILE_H
#define MACSTEAM_CORE_RECONCILE_H

#include <stdint.h>

void sx_reconcile_set_addrs(uintptr_t engine_ref_fn,
                            uintptr_t clearmap_fn,
                            uintptr_t readdisk_fn);

void sx_reconcile_set_library_refresh_fns(uintptr_t markdirty_fn,
                                          uintptr_t recompute_fn,
                                          uintptr_t emit_fn);

void sx_reconcile_set_library_refresh_apps(const int *app_ids, int app_count);

void sx_reconcile_arm_library_refresh(void);

void sx_reconcile_set_login_observed(void);
int  sx_reconcile_login_observed(void);

int  sx_reconcile_fire_library_refresh(void *app_mgr);

void sx_reconcile_arm_after_inject(void);
void sx_reconcile_enable_live_reload(void);

#endif // MACSTEAM_CORE_RECONCILE_H
