/* SPDX-License-Identifier: GPL-3.0-only */
#include "capture.h"
#include <stdlib.h>
#include <string.h>

static void *reserve(px_capture_budget *budget, size_t length) {
    if (!length || length > PX_CAPTURE_BUDGET - budget->used) return NULL;
    void *memory = malloc(length);
    if (memory) budget->used += length;
    return memory;
}

static void erase(void *memory, size_t length) {
    volatile unsigned char *bytes = memory;
    while (length--) *bytes++ = 0;
    free(memory);
}

static void capture_body(void *context, const char *bytes, size_t length) {
    px_message_capture *capture = context;
    capture->seen += length;
    if (capture->limited) return;
    size_t available = capture->limit - capture->length;
    size_t keep = length < available ? length : available;
    size_t needed = capture->length + keep;
    if (needed > capture->capacity) {
        size_t capacity = capture->capacity ? capture->capacity : 4096;
        while (capacity < needed) capacity *= 2;
        if (capacity > capture->limit) capacity = capture->limit;
        size_t extra = capacity - capture->capacity;
        if (extra > PX_CAPTURE_BUDGET - capture->budget->used) {
            capture->limited = true;
            return;
        }
        void *memory = realloc(capture->body, capacity);
        if (!memory) { capture->limited = true; return; }
        capture->body = memory;
        capture->capacity = capacity;
        capture->budget->used += extra;
    }
    if (keep) memcpy(capture->body + capture->length, bytes, keep);
    capture->length += keep;
    if (keep != length) capture->limited = true;
}

void px_capture_init(px_capture *capture, px_capture_budget *budget, size_t limit) {
    memset(capture, 0, sizeof(*capture));
    capture->request.budget = capture->response.budget = budget;
    capture->request.limit = capture->response.limit = limit;
}

void px_capture_headers(px_message_capture *capture, px_http *http) {
    capture->present = true;
    http->body_observer = capture_body;
    http->body_context = capture;
    capture->head = reserve(capture->budget, http->header_bytes);
    if (!capture->head) return; /* Capture pressure never changes forwarding. */
    capture->head_length = http->header_bytes;
    memcpy(capture->head, http->bytes, http->header_bytes);
    capture->count = http->count;
    if (http->target.data) {
        capture->target = (size_t)(http->target.data - http->bytes);
        capture->target_length = http->target.length;
    }
    for (size_t i = 0; i < http->count; ++i) {
        px_header header = http->headers[i];
        capture->headers[i] = (px_captured_header){
            (size_t)(header.name.data - http->bytes), header.name.length,
            header.value.data ? (size_t)(header.value.data - http->bytes) : 0, header.value.length
        };
    }
}

static void dispose_message(px_message_capture *message) {
    if (message->budget) message->budget->used -= message->head_length + message->capacity;
    erase(message->head, message->head_length);
    erase(message->body, message->capacity);
    memset(message, 0, sizeof(*message));
}

void px_capture_dispose(px_capture *capture) {
    dispose_message(&capture->request);
    dispose_message(&capture->response);
}

size_t px_capture_size(const px_capture *capture) {
    return capture->request.head_length + capture->request.length +
           capture->response.head_length + capture->response.length;
}

static bool copy_message(px_message_capture *destination, const px_message_capture *source, px_capture_budget *budget) {
    *destination = *source;
    destination->budget = budget;
    destination->head = NULL;
    destination->body = NULL;
    destination->head_length = destination->capacity = 0;
    if (source->head_length) {
        destination->head = reserve(budget, source->head_length);
        if (!destination->head) return false;
        destination->head_length = source->head_length;
        memcpy(destination->head, source->head, source->head_length);
    }
    if (source->length) {
        destination->body = reserve(budget, source->length);
        if (!destination->body) return false;
        destination->capacity = source->length;
        memcpy(destination->body, source->body, source->length);
    }
    return true;
}

bool px_capture_copy(px_capture *destination, const px_capture *source, px_capture_budget *budget) {
    memset(destination, 0, sizeof(*destination));
    if (copy_message(&destination->request, &source->request, budget) &&
        copy_message(&destination->response, &source->response, budget)) return true;
    px_capture_dispose(destination);
    return false;
}
