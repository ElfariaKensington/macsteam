// Caller pipe context
#ifndef MACSTEAM_CORE_CTX_H
#define MACSTEAM_CORE_CTX_H

#include <stdint.h>

void     sx_ctx_set_getappid(uintptr_t getappid);

uint32_t sx_ctx_caller_appid(void *iface_this);

#endif // MACSTEAM_CORE_CTX_H
