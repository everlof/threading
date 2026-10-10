/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef THREADING_PROXY_HTTP_H
#define THREADING_PROXY_HTTP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <llhttp.h>
#include "proxy_limits.h"

typedef struct {
    const char *data;
    size_t length;
} px_span;

typedef struct {
    px_span name;
    px_span value;
} px_header;

typedef struct {
    llhttp_t parser;
    llhttp_settings_t settings;
    char bytes[PX_HEADER_LIMIT];
    size_t length;
    size_t header_bytes;
    px_header headers[PX_HEADER_COUNT];
    size_t count;
    px_span target;
    bool headers_complete;
    bool complete;
    bool head_response;
    void (*body_observer)(void *context, const char *data, size_t length);
    void *body_context;
} px_http;

typedef struct {
    char host[PX_HOST_LIMIT + 1];
    unsigned port;
    px_span path;
    bool ipv6;
    bool tunnel;
} px_target;

void px_http_init(px_http *http, bool response, bool head_response);
/* Copies each header byte once. No parser callback keeps a pointer into a socket buffer. */
int px_http_headers(px_http *http, const char *data, size_t length, size_t *used);
int px_http_target(const px_http *http, px_target *target);
/* Inner HTTPS request must stay within the already authorized CONNECT authority. */
int px_http_tls_target(const px_http *http, px_target *target);
int px_http_render(const px_http *http, const px_target *target, char *out, size_t capacity, size_t *length);
int px_http_body(px_http *http, const char *data, size_t length, size_t *used);
bool px_http_eof(px_http *http);
const char *px_http_method(const px_http *http);

#endif
