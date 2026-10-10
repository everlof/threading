/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef THREADING_PROXY_OUTPUT_H
#define THREADING_PROXY_OUTPUT_H

#include <stdbool.h>
#include <stdint.h>
#include <uv.h>
#include "proxy_limits.h"

typedef struct px_event px_event;
typedef struct {
    uv_loop_t *loop;
    uv_pipe_t pipe;
    uv_tty_t tty;
    uv_stream_t *stream;
    px_event *first;
    px_event *last;
    unsigned pending;
    size_t pending_bytes;
    uint64_t dropped;
    bool file;
    bool stopped;
    void (*on_error)(void *context);
    void *error_context;
} px_output;

int px_output_init(px_output *output, uv_loop_t *loop);
/* False means the bounded queue cannot accept the message. MCP must close its lease,
 * while best-effort observation output may drop the record. */
bool px_output_send(px_output *output, const char *text);
void px_output_stop(px_output *output);

#endif
