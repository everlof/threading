/* SPDX-License-Identifier: GPL-3.0-only */
#include "http.h"

#include <stdio.h>
#include <string.h>

static unsigned char ascii_lower(unsigned char value) {
    return value >= 'A' && value <= 'Z' ? (unsigned char)(value + ('a' - 'A')) : value;
}

static bool equal_span(px_span a, px_span b) {
    if (a.length != b.length) return false;
    for (size_t i = 0; i < a.length; ++i) {
        if (ascii_lower((unsigned char)a.data[i]) != ascii_lower((unsigned char)b.data[i])) return false;
    }
    return true;
}

static bool equal(px_span a, const char *b) {
    return equal_span(a, (px_span){b, strlen(b)});
}

static px_span trimmed(px_span span) {
    while (span.length && (span.data[0] == ' ' || span.data[0] == '\t')) {
        ++span.data;
        --span.length;
    }
    while (span.length && (span.data[span.length - 1] == ' ' || span.data[span.length - 1] == '\t')) --span.length;
    return span;
}

static bool contains_token(px_span list, px_span token) {
    while (list.length) {
        const char *comma = memchr(list.data, ',', list.length);
        size_t size = comma ? (size_t)(comma - list.data) : list.length;
        if (equal_span(trimmed((px_span){list.data, size}), token)) return true;
        if (!comma) break;
        list.data += size + 1;
        list.length -= size + 1;
    }
    return false;
}

static int on_url(llhttp_t *parser, const char *data, size_t length) {
    px_http *http = parser->data;
    if (!http->target.data) http->target.data = data;
    http->target.length += length;
    return 0;
}

static int on_field(llhttp_t *parser, const char *data, size_t length) {
    px_http *http = parser->data;
    /* Trailers are a separate protocol feature; never forward unvalidated trailer headers. */
    if (http->headers_complete || http->count == PX_HEADER_COUNT) return HPE_USER;
    px_span *field = &http->headers[http->count].name;
    if (!field->data) field->data = data;
    field->length += length;
    return 0;
}

static int on_value(llhttp_t *parser, const char *data, size_t length) {
    px_http *http = parser->data;
    if (http->headers_complete || http->count == PX_HEADER_COUNT) return HPE_USER;
    px_span *value = &http->headers[http->count].value;
    if (!value->data) value->data = data;
    value->length += length;
    return 0;
}

static int on_value_complete(llhttp_t *parser) {
    px_http *http = parser->data;
    if (http->count == PX_HEADER_COUNT) return HPE_USER;
    ++http->count;
    return 0;
}

static int on_headers(llhttp_t *parser) {
    px_http *http = parser->data;
    http->headers_complete = true;
    return http->head_response ? 1 : 0;
}

static int on_body(llhttp_t *parser, const char *data, size_t length) {
    px_http *http = parser->data;
    if (http->body_observer) http->body_observer(http->body_context, data, length);
    return 0;
}

static int on_complete(llhttp_t *parser) {
    px_http *http = parser->data;
    http->complete = true;
    return HPE_PAUSED;
}

void px_http_init(px_http *http, bool response, bool head_response) {
    memset(http, 0, sizeof(*http));
    llhttp_settings_init(&http->settings);
    http->settings.on_url = on_url;
    http->settings.on_header_field = on_field;
    http->settings.on_header_value = on_value;
    http->settings.on_header_value_complete = on_value_complete;
    http->settings.on_headers_complete = on_headers;
    http->settings.on_message_complete = on_complete;
    http->settings.on_body = on_body;
    llhttp_init(&http->parser, response ? HTTP_RESPONSE : HTTP_REQUEST, &http->settings);
    http->parser.data = http;
    http->head_response = head_response;
}

static bool connection_names(const px_http *http, px_span name) {
    for (size_t i = 0; i < http->count; ++i) {
        if (equal(http->headers[i].name, "connection") && contains_token(http->headers[i].value, name)) return true;
    }
    return false;
}

static int validate_headers(const px_http *http) {
    if (http->parser.http_major != 1 || http->parser.http_minor > 1) return -1;
    unsigned hosts = 0;
    for (size_t i = 0; i < http->count; ++i) {
        px_header header = http->headers[i];
        if (equal(header.name, "host") && ++hosts > 1) return -1;
        if (equal(header.name, "upgrade")) return -1;
        if (equal(header.name, "transfer-encoding") && !equal(trimmed(header.value), "chunked")) return -1;
        if (equal(header.name, "expect") && !equal(trimmed(header.value), "100-continue")) return -1;
        /* Removing framing headers named by Connection would create a different message. */
        if ((equal(header.name, "content-length") || equal(header.name, "transfer-encoding") ||
             equal(header.name, "host") || equal(header.name, "expect")) && connection_names(http, header.name)) return -1;
    }
    return 0;
}

int px_http_headers(px_http *http, const char *data, size_t length, size_t *used) {
    *used = 0;
    while (*used < length) {
        if (http->length == sizeof(http->bytes)) return -1;
        http->bytes[http->length++] = data[(*used)++];
        if (http->length >= 4 && memcmp(http->bytes + http->length - 4, "\r\n\r\n", 4) == 0) {
            llhttp_errno_t result = llhttp_execute(&http->parser, http->bytes, http->length);
            if (result != HPE_OK && !(http->complete && (result == HPE_PAUSED || result == HPE_PAUSED_UPGRADE))) return -1;
            if (!http->headers_complete || validate_headers(http) != 0) return -1;
            http->header_bytes = http->length;
            return 1;
        }
    }
    return 0;
}

static bool parse_port(px_span text, unsigned *port) {
    if (!text.length || text.length > 5) return false;
    unsigned value = 0;
    for (size_t i = 0; i < text.length; ++i) {
        unsigned char digit = (unsigned char)text.data[i];
        if (digit < '0' || digit > '9') return false;
        value = value * 10 + (unsigned)(digit - '0');
    }
    if (!value || value > 65535) return false;
    *port = value;
    return true;
}

static bool parse_authority(px_span authority, px_target *target) {
    px_span host = authority;
    px_span port = {NULL, 0};
    if (!authority.length) return false;
    if (authority.data[0] == '[') {
        const char *end = memchr(authority.data, ']', authority.length);
        if (!end) return false;
        host = (px_span){authority.data + 1, (size_t)(end - authority.data - 1)};
        size_t rest = authority.length - (size_t)(end - authority.data) - 1;
        if (rest) {
            if (end[1] != ':') return false;
            port = (px_span){end + 2, rest - 1};
        }
        target->ipv6 = true;
    } else {
        const char *colon = memchr(authority.data, ':', authority.length);
        if (colon) {
            host.length = (size_t)(colon - authority.data);
            port = (px_span){colon + 1, authority.length - host.length - 1};
        }
    }
    if (!host.length || host.length > PX_HOST_LIMIT) return false;
    for (size_t i = 0; i < host.length; ++i) {
        unsigned char c = ascii_lower((unsigned char)host.data[i]);
        bool allowed = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '.';
        if (target->ipv6) allowed = (c >= 'a' && c <= 'f') || (c >= '0' && c <= '9') || c == ':' || c == '.';
        if (!allowed) return false;
        target->host[i] = (char)c;
    }
    target->host[host.length] = '\0';
    if (port.data) return parse_port(port, &target->port);
    return !target->tunnel;
}

int px_http_target(const px_http *http, px_target *target) {
    memset(target, 0, sizeof(*target));
    target->tunnel = http->parser.method == HTTP_CONNECT;
    target->port = 80;
    px_span url = http->target;
    if (target->tunnel) {
        if (http->parser.flags & (F_CONTENT_LENGTH | F_CHUNKED)) return -1;
        return parse_authority(url, target) ? 0 : -1;
    }
    if (url.length < 7 || !equal((px_span){url.data, 7}, "http://")) return -1;
    url.data += 7;
    url.length -= 7;
    size_t authority_length = 0;
    while (authority_length < url.length && url.data[authority_length] != '/' && url.data[authority_length] != '?') ++authority_length;
    if (!parse_authority((px_span){url.data, authority_length}, target)) return -1;
    target->path = (px_span){url.data + authority_length, url.length - authority_length};
    for (size_t i = 0; i < target->path.length; ++i) {
        unsigned char c = (unsigned char)target->path.data[i];
        if (c <= 32 || c >= 127 || c == '#' || c == '\\') return -1;
    }
    return 0;
}

int px_http_tls_target(const px_http *http, px_target *target) {
    px_span path = http->target;
    if (http->parser.method == HTTP_CONNECT || !path.length || path.data[0] != '/') return -1;
    for (size_t i = 0; i < path.length; ++i) {
        unsigned char c = (unsigned char)path.data[i];
        if (c <= 32 || c >= 127 || c == '#' || c == '\\') return -1;
    }
    bool found = false;
    for (size_t i = 0; i < http->count; ++i) {
        if (!equal(http->headers[i].name, "host")) continue;
        px_target authority = {0};
        authority.port = 443;
        if (!parse_authority(http->headers[i].value, &authority) ||
            authority.port != target->port || strcmp(authority.host, target->host) != 0) return -1;
        found = true;
    }
    if (!found) return -1;
    target->path = path;
    return 0;
}

static bool append(char *out, size_t capacity, size_t *length, px_span value) {
    if (value.length > capacity - *length) return false;
    if (value.length) memcpy(out + *length, value.data, value.length);
    *length += value.length;
    return true;
}

static bool literal(char *out, size_t capacity, size_t *length, const char *value) {
    return append(out, capacity, length, (px_span){value, strlen(value)});
}

static bool hop_header(const px_http *http, px_span name) {
    static const char *const names[] = {
        "connection", "proxy-connection", "proxy-authorization", "proxy-authenticate",
        "keep-alive", "te", "trailer", "upgrade"
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
        if (equal(name, names[i])) return true;
    }
    return connection_names(http, name);
}

int px_http_render(const px_http *http, const px_target *target, char *out, size_t capacity, size_t *length) {
    *length = 0;
    if (http->parser.type == HTTP_REQUEST) {
        char authority[PX_HOST_LIMIT + 16];
        int n = snprintf(authority, sizeof(authority), target->ipv6 ? "[%s]:%u" : "%s:%u", target->host, target->port);
        if (n < 0 || (size_t)n >= sizeof(authority)) return -1;
        if (!literal(out, capacity, length, px_http_method(http)) || !literal(out, capacity, length, " ")) return -1;
        if ((!target->path.length || target->path.data[0] == '?') && !literal(out, capacity, length, "/")) return -1;
        if (!append(out, capacity, length, target->path) ||
            !literal(out, capacity, length, " HTTP/1.1\r\nHost: ") ||
            !literal(out, capacity, length, authority) || !literal(out, capacity, length, "\r\n")) return -1;
    } else {
        const char *end = memchr(http->bytes, '\r', http->length);
        if (!end || !append(out, capacity, length, (px_span){http->bytes, (size_t)(end - http->bytes) + 2})) return -1;
    }
    for (size_t i = 0; i < http->count; ++i) {
        px_header h = http->headers[i];
        if (hop_header(http, h.name) || (http->parser.type == HTTP_REQUEST && equal(h.name, "host"))) continue;
        if (!append(out, capacity, length, h.name) || !literal(out, capacity, length, ": ") ||
            !append(out, capacity, length, h.value) || !literal(out, capacity, length, "\r\n")) return -1;
    }
    bool informational = http->parser.type == HTTP_RESPONSE && http->parser.status_code < 200;
    return literal(out, capacity, length, informational ? "\r\n" : "Connection: close\r\n\r\n") ? 0 : -1;
}

int px_http_body(px_http *http, const char *data, size_t length, size_t *used) {
    *used = 0;
    if (http->complete) return 0;
    llhttp_errno_t result = llhttp_execute(&http->parser, data, length);
    if (result == HPE_OK) {
        *used = length;
        return 0;
    }
    if (result == HPE_PAUSED && http->complete) {
        *used = (size_t)(llhttp_get_error_pos(&http->parser) - data);
        return 0;
    }
    return -1;
}

bool px_http_eof(px_http *http) {
    if (http->complete) return true;
    llhttp_errno_t result = llhttp_finish(&http->parser);
    return (result == HPE_OK || result == HPE_PAUSED) && http->complete;
}

const char *px_http_method(const px_http *http) {
    return http->headers_complete ? llhttp_method_name((llhttp_method_t)http->parser.method) : "UNKNOWN";
}
