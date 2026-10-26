// Ticket trickery
#ifndef MACSTEAM_FEATS_TICKET_H
#define MACSTEAM_FEATS_TICKET_H

#include <stdint.h>

void sx_ticket_set_helpers(uintptr_t put_bytes, uintptr_t put_tag,
                           uintptr_t get_bytes);

uint32_t sx_ticket_source_app(void);
void sx_ticket_set_source_app(uint32_t app_id);

int sx_ticket_serve_extended(void *server_this, void *reqReader, void *respWriter);

#endif // MACSTEAM_FEATS_TICKET_H
