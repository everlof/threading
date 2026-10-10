/* SPDX-License-Identifier: GPL-3.0-only */
#include "platform.h"

#include <signal.h>
#include <string.h>

int px_platform_start(px_platform *platform, uv_loop_t *loop, uv_signal_cb callback, void *context) {
    memset(platform, 0, sizeof(*platform));
    const int signals[] = {
        SIGINT,
#ifndef _WIN32
        SIGTERM,
#endif
    };
#ifndef _WIN32
    /* A disconnected capture consumer or client must not terminate the worker. */
    signal(SIGPIPE, SIG_IGN);
#endif
    for (unsigned i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) {
        int status = uv_signal_init(loop, &platform->signals[i]);
        if (status < 0) return status;
        ++platform->count;
        platform->signals[i].data = context;
        status = uv_signal_start(&platform->signals[i], callback, signals[i]);
        if (status < 0) return status;
    }
    return 0;
}

void px_platform_stop(px_platform *platform) {
    for (unsigned i = 0; i < platform->count; ++i) uv_close((uv_handle_t *)&platform->signals[i], NULL);
    platform->count = 0;
}
