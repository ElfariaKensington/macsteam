// Store-page bridge and live config refresh.
// The config app writes hubcap-refresh.request after saving config.yaml. This thread
// reloads the config, swaps it in, arms Steam's package/library refresh, and answers
// with hubcap-refresh.ack so the app can tell the user the add worked.
#ifndef MACSTEAM_CORE_HUBCAP_H
#define MACSTEAM_CORE_HUBCAP_H

void sx_hubcap_start(void);
void sx_hubcap_set_ready(int ready);

#endif // MACSTEAM_CORE_HUBCAP_H
