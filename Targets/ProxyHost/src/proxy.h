/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef THREADING_PROXY_H
#define THREADING_PROXY_H

#include <stdbool.h>
#include <stdint.h>
#include <uv.h>
#include "proxy_limits.h"
#include "tls.h"
#include "capture.h"

typedef struct px_proxy px_proxy;

typedef struct {
    unsigned port; /* Zero selects an ephemeral port. Listener is always IPv4 loopback. */
    unsigned max_connections;
    uint64_t idle_timeout_ms;
    px_tls_policy *tls; /* Borrowed immutable policy; outlives the drained proxy. */
    size_t body_limit; /* Zero disables payload capture. */
} px_config;

/* Borrowed values, valid only during the callback. */
typedef struct {
    uint64_t id;
    const char *method;
    const char *host;
    unsigned port;
    unsigned status;
    bool tunnel;
    bool tls_inspected;
    const char *tls_version;
    uint64_t client_bytes;
    uint64_t upstream_bytes;
    uint64_t duration_ms;
    size_t peak_pending_bytes;
    const char *result;
    const px_capture *capture;
} px_flow;

typedef void (*px_flow_callback)(const px_flow *flow, void *context);

/* All calls and callbacks belong to the supplied worker loop. Never an app/UI thread. */
px_proxy *px_proxy_create(uv_loop_t *loop, px_config config, px_flow_callback callback, void *context);
int px_proxy_start(px_proxy *proxy);
unsigned px_proxy_port(const px_proxy *proxy);
void px_proxy_stop(px_proxy *proxy);
bool px_proxy_drained(const px_proxy *proxy);
/* Only after the loop has drained all close/request callbacks. */
void px_proxy_destroy(px_proxy *proxy);

#endif
