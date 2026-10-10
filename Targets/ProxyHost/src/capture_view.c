/* SPDX-License-Identifier: GPL-3.0-only */
#include "capture_view.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <zlib.h>

static unsigned char lower(unsigned char c) { return c >= 'A' && c <= 'Z' ? (unsigned char)(c + 32) : c; }
static bool equal(const char *a, size_t length, const char *b) {
    if (strlen(b) != length) return false;
    for (size_t i = 0; i < length; ++i) if (lower((unsigned char)a[i]) != (unsigned char)b[i]) return false;
    return true;
}

static bool sensitive(const char *name, size_t length) {
    static const char *keys[] = {"authorization", "proxyauthorization", "cookie", "setcookie", "password", "passwd",
        "secret", "clientsecret", "token", "accesstoken", "refreshtoken", "idtoken", "apikey", "xapikey", "sessionid"};
    char normalized[64];
    size_t count = 0;
    for (size_t i = 0; i < length; ++i) {
        unsigned char c = lower((unsigned char)name[i]);
        if (c == '-' || c == '_') continue;
        if (count == sizeof(normalized)) return false;
        normalized[count++] = (char)c;
    }
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); ++i) if (equal(normalized, count, keys[i])) return true;
    return false;
}

static char *copy(const char *bytes, size_t length) {
    char *result = malloc(length + 1);
    if (result) { if (length) memcpy(result, bytes, length); result[length] = 0; }
    return result;
}

/* HTTP field values are octets. Latin-1 preserves every byte as valid JSON Unicode. */
static char *header_text(const char *bytes, size_t length) {
    char *result = malloc(length * 2 + 1);
    if (!result) return NULL;
    size_t used = 0;
    for (size_t i = 0; i < length; ++i) {
        unsigned char c = (unsigned char)bytes[i];
        if (c >= 128) { result[used++] = (char)(0xc0 | (c >> 6)); result[used++] = (char)(0x80 | (c & 63)); }
        else result[used++] = (char)c;
    }
    result[used] = 0;
    return result;
}

static int hex(unsigned char c) {
    c = lower(c);
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

static bool sensitive_parameter(const char *name, size_t length) {
    char decoded[128];
    size_t count = 0;
    for (size_t i = 0; i < length; ++i) {
        if (count == sizeof(decoded)) return false;
        if (name[i] == '%' && i + 2 < length && hex((unsigned char)name[i+1]) >= 0 && hex((unsigned char)name[i+2]) >= 0) {
            decoded[count++] = (char)(hex((unsigned char)name[i+1]) * 16 + hex((unsigned char)name[i+2]));
            i += 2;
        } else decoded[count++] = name[i];
    }
    return sensitive(decoded, count);
}

/* Replace in place, preserving byte offsets even when a parameter value is very long. */
static void redact_parameters(char *text, size_t length) {
    size_t start = 0;
    while (start < length) {
        size_t end = start;
        while (end < length && text[end] != '&' && text[end] != ';') ++end;
        size_t equals = start;
        while (equals < end && text[equals] != '=') ++equals;
        if (equals < end && sensitive_parameter(text + start, equals - start)) memset(text + equals + 1, '*', end - equals - 1);
        start = end + 1;
    }
}

/* cJSON validates structure and decodes field names, but serializing its double-valued
 * numbers would round large IDs. Walk the validated source once and replace only secret
 * value spans, preserving every other byte (including numeric lexemes and whitespace). */
static size_t skip_space(const char *text, size_t cursor) {
    while (text[cursor] == ' ' || text[cursor] == '\n' || text[cursor] == '\r' || text[cursor] == '\t') ++cursor;
    return cursor;
}

static size_t skip_string(const char *text, size_t cursor) {
    ++cursor;
    while (text[cursor] != '"') {
        if (text[cursor] == '\\') ++cursor;
        ++cursor;
    }
    return cursor + 1;
}

static size_t value_end(const cJSON *node, const char *text, size_t cursor) {
    if (cJSON_IsString(node)) return skip_string(text, cursor);
    if (cJSON_IsArray(node) || cJSON_IsObject(node)) {
        cursor = skip_space(text, cursor + 1);
        for (const cJSON *child = node->child; child; child = child->next) {
            if (cJSON_IsObject(node)) cursor = skip_space(text, skip_space(text, skip_string(text, cursor)) + 1);
            cursor = skip_space(text, value_end(child, text, cursor));
            if (child->next) cursor = skip_space(text, cursor + 1);
        }
        return cursor + 1;
    }
    while (text[cursor] && !strchr(",]} \t\r\n", text[cursor])) ++cursor;
    return cursor;
}

typedef struct { const char *source; char *output; size_t copied, written; } json_redaction;
static size_t redact_value(const cJSON *node, size_t cursor, json_redaction *view) {
    const char *text = view->source;
    if (!cJSON_IsArray(node) && !cJSON_IsObject(node)) return value_end(node, text, cursor);
    cursor = skip_space(text, cursor + 1);
    for (const cJSON *child = node->child; child; child = child->next) {
        bool hide = cJSON_IsObject(node) && sensitive(child->string, strlen(child->string));
        if (cJSON_IsObject(node)) cursor = skip_space(text, skip_space(text, skip_string(text, cursor)) + 1);
        if (hide) {
            size_t length = cursor - view->copied;
            memcpy(view->output + view->written, text + view->copied, length);
            view->written += length;
            static const char marker[] = "\"[redacted]\"";
            memcpy(view->output + view->written, marker, sizeof(marker) - 1);
            view->written += sizeof(marker) - 1;
            cursor = value_end(child, text, cursor);
            view->copied = cursor;
        } else cursor = redact_value(child, cursor, view);
        cursor = skip_space(text, cursor);
        if (child->next) cursor = skip_space(text, cursor + 1);
    }
    return cursor + 1;
}

static char *redact_json(const cJSON *tree, const char *text, size_t length) {
    /* The shortest matched property name is five bytes; 3x bounds even one-byte values. */
    char *result = malloc(length * 3 + 1);
    if (!result) return NULL;
    json_redaction view = {text, result, 0, 0};
    redact_value(tree, skip_space(text, 0), &view);
    memcpy(result + view.written, text + view.copied, length - view.copied);
    result[view.written + length - view.copied] = 0;
    return result;
}

static px_span header(const px_message_capture *message, const char *name) {
    for (size_t i = 0; i < message->count; ++i) {
        px_captured_header h = message->headers[i];
        if (equal(message->head + h.name, h.name_length, name)) return (px_span){message->head + h.value, h.value_length};
    }
    return (px_span){"", 0};
}

static cJSON *description(const px_message_capture *message, bool redact) {
    cJSON *result = cJSON_CreateObject();
    cJSON_AddBoolToObject(result, "present", message->present);
    cJSON_AddBoolToObject(result, "complete", message->present && message->complete);
    cJSON_AddBoolToObject(result, "headers_available", message->head != NULL);
    cJSON_AddNumberToObject(result, "header_count", (double)message->count);
    cJSON_AddNumberToObject(result, "captured_body_bytes", (double)message->length);
    char count[32];
    snprintf(count, sizeof(count), "%llu", (unsigned long long)message->seen);
    cJSON_AddStringToObject(result, "observed_body_bytes", count);
    cJSON_AddBoolToObject(result, "body_truncated", message->limited || !message->complete);
    cJSON *headers = cJSON_AddArrayToObject(result, "headers");
    size_t count_headers = message->count < 12 ? message->count : 12;
    for (size_t i = 0; i < count_headers; ++i) {
        px_captured_header h = message->headers[i];
        cJSON *item = cJSON_CreateObject();
        cJSON_AddItemToArray(headers, item);
        char *name = header_text(message->head + h.name, h.name_length < 128 ? h.name_length : 128);
        bool hidden = redact && sensitive(message->head + h.name, h.name_length);
        size_t value_length = h.value_length < 256 ? h.value_length : 256;
        char *value = hidden ? copy("[redacted]", 10) : header_text(message->head + h.value, value_length);
        cJSON_AddNumberToObject(item, "index", (double)i);
        cJSON_AddStringToObject(item, "name", name ? name : "");
        cJSON_AddStringToObject(item, "value", value ? value : "");
        cJSON_AddBoolToObject(item, "truncated", h.name_length > 128 || (!hidden && h.value_length > value_length));
        free(name); free(value);
    }
    cJSON_AddBoolToObject(result, "more_headers", count_headers < message->count);
    return result;
}

void px_capture_detail(cJSON *result, const px_capture *capture, bool redact) {
    cJSON_AddStringToObject(result, "data_classification", "untrusted_network_data");
    cJSON_AddStringToObject(result, "header_semantics", "original_client_request_and_origin_response");
    cJSON_AddStringToObject(result, "redaction", redact ? "common_credential_fields" : "none");
    const px_message_capture *request = &capture->request;
    if (request->head && request->target_length) {
        char *target = copy(request->head + request->target, request->target_length);
        if (target) {
            char *query = strchr(target, '?');
            if (redact && query) redact_parameters(query + 1, strlen(query + 1));
            size_t maximum = 4096;
            if (request->target_length > maximum) target[maximum] = 0;
            cJSON_AddStringToObject(result, "request_target", target);
            cJSON_AddBoolToObject(result, "target_truncated", request->target_length > maximum);
            free(target);
        }
    }
    cJSON_AddItemToObject(result, "request", description(&capture->request, redact));
    cJSON_AddItemToObject(result, "response", description(&capture->response, redact));
}

/* Reject invalid UTF-8 and non-text controls; binary pages remain lossless base64. */
static bool text_bytes(const unsigned char *bytes, size_t length) {
    for (size_t i = 0; i < length;) {
        unsigned char c = bytes[i++];
        if (c < 128) { if ((c < 32 && c != '\n' && c != '\r' && c != '\t') || c == 127) return false; continue; }
        unsigned remaining; uint32_t value, minimum;
        if (c >= 0xc2 && c <= 0xdf) { remaining = 1; value = c & 31u; minimum = 128; }
        else if (c >= 0xe0 && c <= 0xef) { remaining = 2; value = c & 15u; minimum = 2048; }
        else if (c >= 0xf0 && c <= 0xf4) { remaining = 3; value = c & 7u; minimum = 65536; }
        else return false;
        if (remaining > length - i) return false;
        while (remaining--) { c = bytes[i++]; if ((c & 0xc0) != 0x80) return false; value = (value << 6) | (c & 63u); }
        if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return false;
    }
    return true;
}

static char *base64(const unsigned char *bytes, size_t length) {
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    char *result = malloc((length + 2) / 3 * 4 + 1);
    if (!result) return NULL;
    size_t written = 0;
    for (size_t i = 0; i < length; i += 3) {
        unsigned value = (unsigned)bytes[i] << 16;
        if (i + 1 < length) value |= (unsigned)bytes[i + 1] << 8;
        if (i + 2 < length) value |= bytes[i + 2];
        result[written++] = alphabet[value >> 18]; result[written++] = alphabet[(value >> 12) & 63];
        result[written++] = i + 1 < length ? alphabet[(value >> 6) & 63] : '=';
        result[written++] = i + 2 < length ? alphabet[value & 63] : '=';
    }
    result[written] = 0;
    return result;
}

static cJSON *page(const unsigned char *bytes, size_t length, size_t offset, size_t limit, bool raw) {
    if (offset > length) return NULL;
    size_t count = length - offset < limit ? length - offset : limit;
    /* Offsets are always bytes. A UTF-8 character split by the page uses base64. */
    const unsigned char *start = bytes ? bytes + offset : (const unsigned char *)"";
    bool text = !raw && text_bytes(start, count);
    char *data = text ? copy((const char *)start, count) : base64(start, count);
    if (!data) return NULL;
    cJSON *result = cJSON_CreateObject();
    cJSON_AddStringToObject(result, "data_classification", "untrusted_network_data");
    cJSON_AddStringToObject(result, "encoding", text ? "utf8" : "base64");
    cJSON_AddStringToObject(result, "data", data ? data : "");
    cJSON_AddNumberToObject(result, "offset", (double)offset);
    cJSON_AddNumberToObject(result, "bytes", (double)count);
    cJSON_AddNumberToObject(result, "total_bytes", (double)length);
    cJSON_AddNumberToObject(result, "next_offset", (double)(offset + count));
    cJSON_AddBoolToObject(result, "has_more", offset + count < length);
    free(data);
    return result;
}

cJSON *px_capture_header_page(const px_message_capture *message, size_t index, size_t offset,
                             size_t limit, bool redact, const char **error) {
    if (!message->head || index > message->count) { *error = "Header is not retained"; return NULL; }
    /* index == count exposes the request target, allowing lossless paging of long URLs. */
    const char *name = "request-target";
    size_t name_length = strlen(name), length = message->target_length;
    const char *value = message->head + message->target;
    if (index < message->count) {
        px_captured_header h = message->headers[index];
        name = message->head + h.name; name_length = h.name_length;
        value = message->head + h.value; length = h.value_length;
    }
    char *safe = copy(value, length);
    if (!safe) { *error = "Allocation failed"; return NULL; }
    if (redact && index < message->count && sensitive(name, name_length)) { free(safe); safe = copy("[redacted]", 10); length = 10; }
    if (!safe) { *error = "Allocation failed"; return NULL; }
    if (redact && index == message->count) {
        char *query = strchr(safe, '?');
        if (query) redact_parameters(query + 1, strlen(query + 1));
    }
    cJSON *result = page((unsigned char *)safe, length, offset, limit, false);
    free(safe);
    if (!result) { *error = "Offset exceeds retained field length"; return NULL; }
    char *name_text = header_text(name, name_length < 256 ? name_length : 256);
    cJSON_AddStringToObject(result, "name", name_text ? name_text : "");
    cJSON_AddBoolToObject(result, "name_truncated", name_length > 256);
    free(name_text);
    return result;
}

cJSON *px_capture_body_page(const px_message_capture *message, size_t offset, size_t limit,
                           bool decode, bool redact, const char **error) {
    if (!message->present) { *error = "No HTTP message was captured (opaque tunnels contain no HTTP capture)"; return NULL; }
    if (!message->head && (decode || redact)) { *error = "Headers were not retained; use decode=false,redact=false for captured body bytes"; return NULL; }
    const unsigned char *bytes = message->body;
    size_t length = message->length;
    unsigned char *decoded = NULL;
    bool decode_limited = false;
    px_span encoding = header(message, "content-encoding");
    if (decode && encoding.length && !equal(encoding.data, encoding.length, "identity")) {
        int window = equal(encoding.data, encoding.length, "gzip") ? 31 :
                     equal(encoding.data, encoding.length, "deflate") ? 15 : 0;
        if (!window) { *error = "Unsupported Content-Encoding; use decode=false, redact=false for captured bytes"; return NULL; }
        decoded = malloc(PX_BODY_MAX + 1u);
        if (!decoded) { *error = "Allocation failed"; return NULL; }
        z_stream stream = {0};
        stream.next_in = (Bytef *)bytes; stream.avail_in = (uInt)length;
        stream.next_out = decoded; stream.avail_out = PX_BODY_MAX + 1u;
        int status = inflateInit2(&stream, window);
        if (status == Z_OK) {
            status = inflate(&stream, Z_FINISH);
            length = (size_t)stream.total_out;
            decode_limited = length > PX_BODY_MAX;
            if (decode_limited) length = PX_BODY_MAX;
            bool partial = (status == Z_BUF_ERROR || status == Z_OK) && (decode_limited || message->limited || !message->complete);
            if ((status != Z_STREAM_END && !partial) || (status == Z_STREAM_END && stream.avail_in)) status = Z_DATA_ERROR;
            inflateEnd(&stream);
        }
        if (status != Z_STREAM_END && status != Z_BUF_ERROR && status != Z_OK) {
            free(decoded); *error = "Invalid or unsupported compressed body; use decode=false, redact=false for captured bytes"; return NULL;
        }
        bytes = decoded;
    }
    char *redacted = NULL;
    const char *redaction = "none";
    if (redact) {
        px_span content_type = header(message, "content-type");
        const char *semicolon = memchr(content_type.data, ';', content_type.length);
        size_t type_length = semicolon ? (size_t)(semicolon - content_type.data) : content_type.length;
        bool json = equal(content_type.data, type_length, "application/json") ||
            (type_length >= 5 && equal(content_type.data + type_length - 5, 5, "+json"));
        if (!decode && encoding.length && !equal(encoding.data, encoding.length, "identity")) {
            free(decoded); *error = "Compressed bytes require redact=false or decode=true"; return NULL;
        }
        if (json) {
            if (message->limited || !message->complete || decode_limited || !text_bytes(bytes, length)) {
                free(decoded); *error = "Cannot redact incomplete JSON; use redact=false to inspect the captured prefix"; return NULL;
            }
            char *terminated = copy((const char *)bytes, length);
            cJSON *tree = terminated ? cJSON_ParseWithLengthOpts(terminated, length + 1, NULL, true) : NULL;
            /* cJSON cannot preserve embedded NULs: don't return a misleading redacted view. */
            if (!tree || strstr(terminated, "\\u0000")) {
                cJSON_Delete(tree); free(terminated); free(decoded);
                *error = "Cannot redact this JSON; use redact=false to inspect exact bytes"; return NULL;
            }
            redacted = redact_json(tree, terminated, length);
            cJSON_Delete(tree); free(terminated);
            if (!redacted) { free(decoded); *error = "Could not allocate redacted view"; return NULL; }
            redaction = "common_json_credential_fields";
        } else if (equal(content_type.data, type_length, "application/x-www-form-urlencoded")) {
            if (!text_bytes(bytes, length)) { free(decoded); *error = "Form contains non-text bytes; use redact=false for exact bytes"; return NULL; }
            redacted = copy((const char *)bytes, length);
            if (!redacted) { free(decoded); *error = "Could not allocate redacted view"; return NULL; }
            redact_parameters(redacted, length);
            redaction = "common_form_credential_fields";
        } else redaction = "not_applied_to_unstructured_content";
        if (redacted) { bytes = (unsigned char *)redacted; length = strlen(redacted); }
    }
    cJSON *result = page(bytes, length, offset, limit, !decode);
    if (!result) *error = "Offset exceeds available body length";
    else {
        cJSON_AddStringToObject(result, "representation", decode ? "content_decoded" : "transfer_decoded_original_bytes");
        cJSON_AddStringToObject(result, "redaction", redaction);
        cJSON_AddBoolToObject(result, "capture_truncated", message->limited || !message->complete);
        cJSON_AddBoolToObject(result, "decode_truncated", decode_limited);
    }
    free(redacted); free(decoded);
    return result;
}
