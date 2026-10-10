/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef THREADING_PROXY_CAPTURE_H
#define THREADING_PROXY_CAPTURE_H
#include "http.h"

enum { PX_BODY_DEFAULT = 65536, PX_BODY_MAX = 1048576, PX_CAPTURE_BUDGET = 16777216 };
typedef struct { size_t used; } px_capture_budget;
typedef struct { size_t name, name_length, value, value_length; } px_captured_header;
typedef struct {
    char *head;
    size_t head_length, target, target_length, count;
    px_captured_header headers[PX_HEADER_COUNT];
    unsigned char *body;
    size_t length, capacity, limit;
    uint64_t seen;
    bool present, complete, limited;
    px_capture_budget *budget;
} px_message_capture;
typedef struct { px_message_capture request, response; } px_capture;

void px_capture_init(px_capture *capture, px_capture_budget *budget, size_t limit);
void px_capture_headers(px_message_capture *capture, px_http *http);
void px_capture_dispose(px_capture *capture);
size_t px_capture_size(const px_capture *capture);
bool px_capture_copy(px_capture *destination, const px_capture *source, px_capture_budget *budget);
#endif
