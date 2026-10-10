/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef THREADING_PROXY_PLATFORM_H
#define THREADING_PROXY_PLATFORM_H

#include <uv.h>

typedef struct {
    uv_signal_t signals[2];
    unsigned count;
} px_platform;

int px_platform_start(px_platform *platform, uv_loop_t *loop, uv_signal_cb callback, void *context);
void px_platform_stop(px_platform *platform);

#endif
