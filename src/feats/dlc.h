// DLC injection
#ifndef MACSTEAM_FEATS_DLC_H
#define MACSTEAM_FEATS_DLC_H

#include <stdint.h>

int sx_dlc_is_installed(void *iface, uint32_t app_id, uint32_t dlc_id, int origResult);

int sx_dlc_force_available(void *iface, uint32_t app_id, int index, uint32_t *pDlcId,
                           int *pAvailable, int origResult);

int sx_dlc_user_subscribed_in_ticket(void *iface, uint32_t app_id, int origResult);

#endif // MACSTEAM_FEATS_DLC_H
