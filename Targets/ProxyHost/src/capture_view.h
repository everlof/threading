/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef THREADING_PROXY_CAPTURE_VIEW_H
#define THREADING_PROXY_CAPTURE_VIEW_H
#include "capture.h"
#include <cJSON.h>
void px_capture_detail(cJSON *result, const px_capture *capture, bool redact);
cJSON *px_capture_body_page(const px_message_capture *message, size_t offset, size_t limit,
                           bool decode, bool redact, const char **error);
cJSON *px_capture_header_page(const px_message_capture *message, size_t index, size_t offset,
                             size_t limit, bool redact, const char **error);
#endif
