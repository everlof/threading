/* SPDX-License-Identifier: GPL-3.0-only */
#include "proxy.h"
#include "http.h"

#include <stdlib.h>
#include <stdio.h>
#include <string.h>

typedef struct px_connection px_connection;

enum { CLIENT_UNUSED, CLIENT_PENDING, CLIENT_ALLOWED, CLIENT_DENIED };
enum { CLIENT_APPROVAL_TIMEOUT_MS = 90000 };
typedef struct {
    int state;
    uint32_t address;
    uint64_t id, deadline;
} px_client_access;

typedef struct {
    uv_tcp_t tcp;
    uv_shutdown_t shutdown;
    px_connection *connection;
    size_t pending_bytes;
    px_tls *tls;
    bool pumping;
    bool initialized;
    bool reading;
    bool eof;
    bool shutting_down;
    bool shutdown_done;
} px_peer;

struct px_proxy {
    uv_loop_t *loop;
    px_config config;
    px_flow_callback callback;
    void *context;
    uv_tcp_t listener;
    bool initialized;
    bool stopping;
    unsigned port;
    unsigned count;
    uint64_t next_id;
    px_connection *first;
    px_capture_budget capture_budget;
    struct sockaddr_in listen_address;
    struct sockaddr_in client_address;
    uint64_t rejected_clients;
    uint64_t next_client_id;
    px_client_access clients[PX_CLIENT_LIMIT];
};

struct px_connection {
    px_proxy *proxy;
    px_connection *next;
    px_connection *previous;
    unsigned references;
    px_peer client;
    px_peer upstream;
    uv_timer_t timer;
    uv_getaddrinfo_t resolver;
    uv_connect_t connect;
    bool timer_initialized;
    bool resolving;
    bool connected;
    bool closing;
    bool finishing;
    bool response_started;
    bool inspecting;
    bool admitted;
    uint64_t pending_client_id;
    struct sockaddr_storage addresses[PX_ADDRESS_LIMIT];
    unsigned address_count;
    unsigned address_index;
    px_http request;
    px_http response;
    px_target target;
    char pending[PX_READ_SIZE];
    size_t pending_length;
    unsigned informational_count;
    uint64_t started;
    px_flow flow;
    px_capture capture;
};

typedef struct {
    uv_write_t request;
    px_peer *destination;
    size_t length;
    char bytes[];
} px_write;

static void close_connection(px_connection *connection, const char *result);
static void fail_connection(px_connection *connection, unsigned status, const char *result);
static void start_reading(px_peer *peer);
static void connect_next(px_connection *connection);
static void process_client(px_connection *connection, const char *data, size_t length);
static void pump_tls(px_peer *peer);
static void shutdown_peer(px_peer *peer);

static void retain(px_connection *connection) { ++connection->references; }

static void release(px_connection *connection) {
    if (--connection->references == 0) {
        --connection->proxy->count; /* Admission includes connections still draining callbacks. */
        px_tls_free(connection->client.tls);
        px_tls_free(connection->upstream.tls);
        px_capture_dispose(&connection->capture);
        free(connection);
    }
}

static px_peer *opposite(px_peer *peer) {
    px_connection *connection = peer->connection;
    return peer == &connection->client ? &connection->upstream : &connection->client;
}

static void stop_reading(px_peer *peer) {
    if (peer->reading) {
        uv_read_stop((uv_stream_t *)&peer->tcp);
        peer->reading = false;
    }
}

static void closed_peer(uv_handle_t *handle) {
    px_peer *peer = handle->data;
    peer->initialized = false;
    release(peer->connection);
}

static void closed_timer(uv_handle_t *handle) {
    release(handle->data);
}

static void close_peer(px_peer *peer) {
    if (peer->initialized && !uv_is_closing((uv_handle_t *)&peer->tcp)) {
        stop_reading(peer);
        uv_close((uv_handle_t *)&peer->tcp, closed_peer);
    }
}

static void close_connection(px_connection *connection, const char *result) {
    if (connection->closing) return;
    connection->closing = true;
    px_proxy *proxy = connection->proxy;
    connection->flow.duration_ms = uv_now(proxy->loop) - connection->started;
    connection->flow.result = result;
    connection->flow.method = px_http_method(&connection->request);
    connection->flow.host = connection->target.host;
    connection->flow.port = connection->target.port;
    connection->flow.tunnel = connection->target.tunnel;
    connection->flow.tls_inspected = px_tls_ready(connection->client.tls);
    connection->flow.tls_version = px_tls_version(connection->upstream.tls);
    connection->capture.request.complete = connection->request.complete;
    connection->capture.response.complete = connection->response.complete;
    connection->flow.capture = &connection->capture;
    if (connection->admitted && proxy->callback) proxy->callback(&connection->flow, proxy->context);
    if (connection->previous) connection->previous->next = connection->next;
    else proxy->first = connection->next;
    if (connection->next) connection->next->previous = connection->previous;
    if (connection->resolving) uv_cancel((uv_req_t *)&connection->resolver);
    close_peer(&connection->client);
    close_peer(&connection->upstream);
    if (connection->timer_initialized) uv_close((uv_handle_t *)&connection->timer, closed_timer);
    release(connection);
}

static void timed_out(uv_timer_t *timer) {
    px_connection *connection = timer->data;
    if (!connection->admitted) {
        px_proxy_decide_client(connection->proxy, connection->pending_client_id, PX_CLIENT_DENY);
        return;
    }
    if (connection->finishing) close_connection(connection, "timeout");
    else fail_connection(connection, 504, "timeout");
}

static void touch(px_connection *connection) {
    uint64_t timeout = connection->proxy->config.idle_timeout_ms;
    /* A trickling header cannot keep a slot forever. Body/tunnel traffic has an idle deadline. */
    if (!connection->request.headers_complete || (connection->inspecting && !px_tls_ready(connection->client.tls))) {
        uint64_t elapsed = uv_now(connection->proxy->loop) - connection->started;
        uint64_t remaining = elapsed < PX_HEADER_TIMEOUT_MS ? PX_HEADER_TIMEOUT_MS - elapsed : 1;
        if (remaining < timeout) timeout = remaining;
    }
    uv_timer_start(&connection->timer, timed_out, timeout, 0);
}

static size_t pending_bytes(const px_peer *peer) {
    return peer->pending_bytes + px_tls_pending(peer->tls);
}

static void track_pending(px_peer *peer) {
    px_connection *connection = peer->connection;
    size_t pending = pending_bytes(&connection->client) + pending_bytes(&connection->upstream);
    if (pending > connection->flow.peak_pending_bytes) connection->flow.peak_pending_bytes = pending;
    if (pending_bytes(peer) >= PX_WRITE_HIGH) stop_reading(opposite(peer));
}

static void written(uv_write_t *request, int status) {
    px_write *write = (px_write *)request;
    px_peer *destination = write->destination;
    px_connection *connection = destination->connection;
    destination->pending_bytes -= write->length;
    free(write);
    if (!connection->closing) {
        if (status < 0) close_connection(connection, "write_error");
        else {
            if (destination->tls) pump_tls(destination);
            if (!connection->closing && pending_bytes(destination) <= PX_WRITE_LOW) {
                px_peer *source = opposite(destination);
                if (source->tls) pump_tls(source);
                start_reading(source);
            }
        }
    }
    release(connection);
}

static bool send_wire(px_peer *destination, const char *data, size_t length) {
    px_connection *connection = destination->connection;
    if (!length) return true;
    if (connection->closing) return false;
    px_write *write = malloc(sizeof(*write) + length);
    if (!write) {
        close_connection(connection, "allocation_error");
        return false;
    }
    write->destination = destination;
    write->length = length;
    memcpy(write->bytes, data, length);
    uv_buf_t buffer = uv_buf_init(write->bytes, (unsigned int)length);
    retain(connection);
    int status = uv_write(&write->request, (uv_stream_t *)&destination->tcp, &buffer, 1, written);
    if (status < 0) {
        free(write);
        close_connection(connection, "write_error");
        release(connection);
        return false;
    }
    destination->pending_bytes += length;
    track_pending(destination);
    return true;
}

static int tls_wire(void *context, const char *data, size_t length) {
    px_peer *peer = context;
    if (peer->pending_bytes >= PX_WRITE_HIGH) return 0;
    return send_wire(peer, data, length) ? 1 : -1;
}

static bool send_bytes(px_peer *destination, const char *data, size_t length) {
    if (!destination->tls) return send_wire(destination, data, length);
    if (!px_tls_write(destination->tls, data, length)) {
        close_connection(destination->connection, "tls_write_error");
        return false;
    }
    track_pending(destination);
    return true;
}

static void shutdown_finished(uv_shutdown_t *request, int status) {
    px_peer *peer = request->data;
    px_connection *connection = peer->connection;
    peer->shutdown_done = true;
    if (!connection->closing) {
        if (connection->finishing) close_connection(connection, connection->flow.result);
        else if (status < 0) close_connection(connection, "shutdown_error");
        else if (connection->client.shutdown_done && connection->upstream.shutdown_done) close_connection(connection, "complete");
    }
    release(connection);
}

static void shutdown_peer(px_peer *peer) {
    if (peer->shutting_down) return;
    px_connection *connection = peer->connection;
    if (peer->tls) {
        if (!px_tls_shutdown(peer->tls)) { close_connection(connection, "tls_shutdown_error"); return; }
        if (!px_tls_shutdown_done(peer->tls)) return;
    }
    peer->shutting_down = true;
    peer->shutdown.data = peer;
    retain(connection);
    int status = uv_shutdown(&peer->shutdown, (uv_stream_t *)&peer->tcp, shutdown_finished);
    if (status < 0) {
        close_connection(connection, "shutdown_error");
        release(connection);
    }
}

static void finish_response(px_connection *connection, const char *result) {
    if (connection->closing || connection->finishing) return;
    connection->finishing = true;
    connection->flow.result = result;
    stop_reading(&connection->client);
    stop_reading(&connection->upstream);
    shutdown_peer(&connection->client); /* libuv drains queued writes before sending FIN. */
}

static void fail_connection(px_connection *connection, unsigned status, const char *result) {
    if (connection->closing) return;
    if (connection->response_started || connection->finishing ||
        (connection->client.tls && !px_tls_ready(connection->client.tls))) {
        close_connection(connection, result);
        return;
    }
    char response[160];
    int length = snprintf(response, sizeof(response),
        "HTTP/1.1 %u Proxy Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", status);
    connection->flow.status = status;
    connection->response_started = true;
    if (length > 0 && (size_t)length < sizeof(response) && send_bytes(&connection->client, response, (size_t)length)) {
        finish_response(connection, result);
        touch(connection);
    }
}

static void process_upstream(px_connection *connection, const char *data, size_t length) {
    if (connection->target.tunnel) {
        send_bytes(&connection->client, data, length);
        return;
    }
    while (length && !connection->closing && !connection->finishing) {
        size_t used = 0;
        if (!connection->response.headers_complete) {
            int status = px_http_headers(&connection->response, data, length, &used);
            if (status < 0) { fail_connection(connection, 502, "invalid_response"); return; }
            data += used;
            length -= used;
            if (status == 0) return;
            unsigned code = connection->response.parser.status_code;
            if (code < 100 || code == 101 || (code < 200 && ++connection->informational_count > PX_INFORMATIONAL_LIMIT)) {
                fail_connection(connection, 502, "unsupported_response");
                return;
            }
            char headers[PX_HEADER_LIMIT + 1024];
            size_t header_length = 0;
            if (px_http_render(&connection->response, &connection->target, headers, sizeof(headers), &header_length) != 0) {
                fail_connection(connection, 502, "invalid_response");
                return;
            }
            if (!send_bytes(&connection->client, headers, header_length)) return;
            if (code < 200) {
                px_http_init(&connection->response, true, connection->request.parser.method == HTTP_HEAD);
                continue;
            }
            connection->response_started = true;
            connection->flow.status = code;
            if (connection->proxy->config.body_limit) px_capture_headers(&connection->capture.response, &connection->response);
        }
        if (px_http_body(&connection->response, data, length, &used) != 0) {
            close_connection(connection, "invalid_response_body");
            return;
        }
        if (!send_bytes(&connection->client, data, used)) return;
        if (connection->response.complete) finish_response(connection, "complete");
        return; /* Surplus upstream bytes never become a second downstream response. */
    }
}

static void end_plaintext(px_peer *peer) {
    px_connection *connection = peer->connection;
    stop_reading(peer);
    peer->eof = true;
    if (connection->target.tunnel && connection->connected) shutdown_peer(opposite(peer));
    else if (peer == &connection->upstream) {
        if (connection->response.headers_complete && px_http_eof(&connection->response)) finish_response(connection, "complete");
        else fail_connection(connection, 502, "truncated_response");
    } else if (!connection->request.headers_complete || !px_http_eof(&connection->request)) {
        fail_connection(connection, 400, "truncated_request");
    }
}

static bool establish_inspection(px_connection *connection) {
    static const char established[] = "HTTP/1.1 200 Connection Established\r\n\r\n";
    if (!send_wire(&connection->client, established, sizeof(established) - 1)) return false;
    connection->client.tls = px_tls_create(connection->proxy->config.tls, connection->target.host, true,
                                           tls_wire, &connection->client);
    if (!connection->client.tls) { close_connection(connection, "tls_identity_error"); return false; }
    connection->target.tunnel = false;
    px_http_init(&connection->request, false, false);
    if (connection->pending_length) {
        bool fed = px_tls_feed(connection->client.tls, connection->pending, connection->pending_length);
        connection->pending_length = 0;
        if (!fed) { close_connection(connection, "tls_input_limit"); return false; }
        pump_tls(&connection->client);
    }
    start_reading(&connection->client);
    return !connection->closing;
}

static void pump_tls(px_peer *peer) {
    px_connection *connection = peer->connection;
    if (peer->pumping || connection->closing || !peer->tls) return;
    peer->pumping = true;
    if (!px_tls_flush(peer->tls)) {
        fail_connection(connection, 502, peer == &connection->upstream ? "upstream_tls_error" : "client_tls_error");
        goto done;
    }
    if (peer == &connection->upstream && px_tls_ready(peer->tls) && !connection->client.tls) {
        if (!establish_inspection(connection)) goto done;
    }
    if (connection->finishing) {
        if (peer == &connection->client) shutdown_peer(peer);
        goto done;
    }
    char bytes[PX_READ_SIZE];
    while (!connection->closing && !connection->finishing && !peer->eof &&
           pending_bytes(opposite(peer)) < PX_WRITE_HIGH) {
        if (peer == &connection->client && connection->request.complete) break;
        int count = px_tls_read(peer->tls, bytes, sizeof(bytes));
        if (count == 0) break;
        if (count == -2) { end_plaintext(peer); break; }
        if (count < 0) {
            fail_connection(connection, 502, peer == &connection->upstream ? "upstream_tls_error" : "client_tls_error");
            break;
        }
        if (peer == &connection->client) process_client(connection, bytes, (size_t)count);
        else process_upstream(connection, bytes, (size_t)count);
    }
done:
    peer->pumping = false;
}

static void allocate_read(uv_handle_t *handle, size_t suggested, uv_buf_t *buffer) {
    (void)handle;
    (void)suggested;
    buffer->base = malloc(PX_READ_SIZE);
    buffer->len = buffer->base ? PX_READ_SIZE : 0;
}

static void received(uv_stream_t *stream, ssize_t count, const uv_buf_t *buffer) {
    px_peer *peer = stream->data;
    px_connection *connection = peer->connection;
    retain(connection);
    if (!connection->closing && count > 0) {
        touch(connection);
        if (peer == &connection->client) {
            connection->flow.client_bytes += (uint64_t)count;
        } else {
            connection->flow.upstream_bytes += (uint64_t)count;
        }
        if (peer->tls) {
            if (!px_tls_feed(peer->tls, buffer->base, (size_t)count)) close_connection(connection, "tls_input_limit");
            else pump_tls(peer);
        } else if (peer == &connection->client) process_client(connection, buffer->base, (size_t)count);
        else process_upstream(connection, buffer->base, (size_t)count);
    } else if (!connection->closing && count < 0) {
        stop_reading(peer);
        peer->eof = true;
        if (count != UV_EOF) close_connection(connection, "read_error");
        else if (peer->tls) fail_connection(connection, 502, "truncated_tls");
        else end_plaintext(peer);
    }
    free(buffer->base);
    release(connection);
}

static void start_reading(px_peer *peer) {
    px_connection *connection = peer->connection;
    if (connection->closing || connection->finishing || peer->reading || peer->eof) return;
    if (connection->request.headers_complete && !connection->connected) return;
    if (peer == &connection->client && connection->inspecting && !connection->client.tls) return;
    if (peer == &connection->upstream && !connection->connected) return;
    if (peer == &connection->client && connection->request.complete && !connection->target.tunnel) return;
    if (pending_bytes(opposite(peer)) >= PX_WRITE_HIGH) return;
    int status = uv_read_start((uv_stream_t *)&peer->tcp, allocate_read, received);
    if (status < 0) close_connection(connection, "read_error");
    else peer->reading = true;
}

static int initialize_peer(px_connection *connection, px_peer *peer) {
    int status = uv_tcp_init(connection->proxy->loop, &peer->tcp);
    if (status < 0) return status;
    peer->initialized = true;
    peer->connection = connection;
    peer->tcp.data = peer;
    retain(connection);
    return 0;
}

static void retry_closed(uv_handle_t *handle) {
    px_peer *peer = handle->data;
    px_connection *connection = peer->connection;
    peer->initialized = false;
    if (!connection->closing && !connection->finishing) {
        if (initialize_peer(connection, peer) < 0) fail_connection(connection, 502, "connect_error");
        else connect_next(connection);
    }
    release(connection);
}

static void connected(uv_connect_t *request, int status) {
    px_connection *connection = request->data;
    if (connection->closing || connection->finishing) { release(connection); return; }
    if (status < 0) {
        if (connection->address_index < connection->address_count) uv_close((uv_handle_t *)&connection->upstream.tcp, retry_closed);
        else fail_connection(connection, 502, "connect_error");
        release(connection);
        return;
    }
    connection->connected = true;
    uv_tcp_nodelay(&connection->upstream.tcp, 1);
    if (connection->inspecting) {
        connection->upstream.tls = px_tls_create(connection->proxy->config.tls, connection->target.host, false,
                                                 tls_wire, &connection->upstream);
        if (!connection->upstream.tls) fail_connection(connection, 502, "tls_identity_error");
        else {
            pump_tls(&connection->upstream);
            start_reading(&connection->upstream);
        }
        release(connection);
        return;
    } else if (connection->target.tunnel) {
        static const char established[] = "HTTP/1.1 200 Connection Established\r\n\r\n";
        connection->flow.status = 200;
        connection->response_started = true;
        if (!send_bytes(&connection->client, established, sizeof(established) - 1)) { release(connection); return; }
    } else {
        char headers[PX_HEADER_LIMIT + 1024];
        size_t length = 0;
        if (px_http_render(&connection->request, &connection->target, headers, sizeof(headers), &length) != 0) {
            fail_connection(connection, 400, "invalid_request");
            release(connection);
            return;
        }
        if (!send_bytes(&connection->upstream, headers, length)) { release(connection); return; }
    }
    if (connection->pending_length) {
        size_t length = connection->pending_length;
        connection->pending_length = 0;
        process_client(connection, connection->pending, length);
    }
    start_reading(&connection->upstream);
    start_reading(&connection->client);
    release(connection);
}

static void connect_next(px_connection *connection) {
    connection->connect.data = connection;
    const struct sockaddr *address = (const struct sockaddr *)&connection->addresses[connection->address_index++];
    retain(connection);
    int status = uv_tcp_connect(&connection->connect, &connection->upstream.tcp, address, connected);
    if (status < 0) connected(&connection->connect, status);
}

static bool self_address(px_connection *connection, const struct sockaddr *address) {
    if (connection->target.port != connection->proxy->port) return false;
    if (address->sa_family == AF_INET) {
        return ((const struct sockaddr_in *)address)->sin_addr.s_addr == connection->proxy->listen_address.sin_addr.s_addr;
    }
    if (address->sa_family != AF_INET6) return false;
    const unsigned char *bytes = ((const struct sockaddr_in6 *)address)->sin6_addr.s6_addr;
    static const unsigned char mapped_prefix[12] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff};
    return memcmp(bytes, mapped_prefix, sizeof(mapped_prefix)) == 0 &&
        memcmp(bytes + 12, &connection->proxy->listen_address.sin_addr, 4) == 0;
}

static void resolved(uv_getaddrinfo_t *request, int status, struct addrinfo *addresses) {
    px_connection *connection = request->data;
    connection->resolving = false;
    if (!connection->closing && !connection->finishing) {
        if (status < 0) fail_connection(connection, 502, "dns_error");
        else {
            unsigned examined = 0;
            for (const struct addrinfo *a = addresses; a && examined++ < PX_ADDRESS_LIMIT; a = a->ai_next) {
                if (a->ai_family != AF_INET && a->ai_family != AF_INET6) continue;
                if ((size_t)a->ai_addrlen > sizeof(struct sockaddr_storage) || self_address(connection, a->ai_addr)) continue;
                memcpy(&connection->addresses[connection->address_count++], a->ai_addr, (size_t)a->ai_addrlen);
            }
            if (!connection->address_count) fail_connection(connection, 502, "unavailable_address");
            else connect_next(connection);
        }
    }
    if (addresses) uv_freeaddrinfo(addresses);
    release(connection);
}

static void resolve_target(px_connection *connection) {
    /* Numeric targets need no blocking system resolver work, including when its pool is busy. */
    struct sockaddr_storage numeric;
    memset(&numeric, 0, sizeof(numeric));
    int status = connection->target.ipv6
        ? uv_ip6_addr(connection->target.host, (int)connection->target.port, (struct sockaddr_in6 *)&numeric)
        : uv_ip4_addr(connection->target.host, (int)connection->target.port, (struct sockaddr_in *)&numeric);
    if (status == 0) {
        if (self_address(connection, (const struct sockaddr *)&numeric)) {
            fail_connection(connection, 502, "unavailable_address");
            return;
        }
        connection->addresses[0] = numeric;
        connection->address_count = 1;
        connect_next(connection);
        return;
    }
    if (connection->target.ipv6) {
        fail_connection(connection, 400, "unsupported_target");
        return;
    }
    char service[6];
    snprintf(service, sizeof(service), "%u", connection->target.port);
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    hints.ai_flags = AI_NUMERICSERV;
    connection->resolver.data = connection;
    connection->resolving = true;
    retain(connection);
    status = uv_getaddrinfo(connection->proxy->loop, &connection->resolver, resolved, connection->target.host, service, &hints);
    if (status < 0) resolved(&connection->resolver, status, NULL);
}

static void process_client(px_connection *connection, const char *data, size_t length) {
    if (!connection->request.headers_complete) {
        size_t used = 0;
        int status = px_http_headers(&connection->request, data, length, &used);
        if (status < 0) { fail_connection(connection, 400, "invalid_request"); return; }
        if (status == 0) return;
        int target_status = connection->inspecting
            ? px_http_tls_target(&connection->request, &connection->target)
            : px_http_target(&connection->request, &connection->target);
        if (target_status != 0) {
            fail_connection(connection, 400, "unsupported_target");
            return;
        }
        px_http_init(&connection->response, true, connection->request.parser.method == HTTP_HEAD);
        if (!connection->target.tunnel && connection->proxy->config.body_limit) {
            px_capture_headers(&connection->capture.request, &connection->request);
        }
        data += used;
        length -= used;
        if (connection->inspecting) {
            char headers[PX_HEADER_LIMIT + 1024];
            size_t header_length = 0;
            if (px_http_render(&connection->request, &connection->target, headers, sizeof(headers), &header_length) != 0) {
                fail_connection(connection, 400, "invalid_request");
                return;
            }
            if (!send_bytes(&connection->upstream, headers, header_length)) return;
            process_client(connection, data, length);
            return;
        }
        connection->inspecting = connection->target.tunnel &&
            px_tls_policy_has(connection->proxy->config.tls, connection->target.host);
        memcpy(connection->pending, data, length);
        connection->pending_length = length;
        stop_reading(&connection->client);
        resolve_target(connection);
        return;
    }
    if (connection->target.tunnel) { send_bytes(&connection->upstream, data, length); return; }
    size_t used = 0;
    if (px_http_body(&connection->request, data, length, &used) != 0) {
        fail_connection(connection, 400, "invalid_request_body");
        return;
    }
    send_bytes(&connection->upstream, data, used);
    if (connection->request.complete) stop_reading(&connection->client);
}

static void admit_client(px_connection *connection) {
    connection->pending_client_id = 0;
    connection->admitted = true;
    connection->started = uv_now(connection->proxy->loop);
    uv_tcp_nodelay(&connection->client.tcp, 1);
    touch(connection);
    start_reading(&connection->client);
}

bool px_proxy_decide_client(px_proxy *proxy, uint64_t id, px_client_decision decision) {
    if (!proxy || proxy->stopping || !id) return false;
    px_client_access *access = NULL;
    for (size_t i = 0; i < PX_CLIENT_LIMIT; ++i) {
        if (proxy->clients[i].state == CLIENT_PENDING && proxy->clients[i].id == id) access = &proxy->clients[i];
    }
    if (!access) return false;
    bool timely = uv_now(proxy->loop) < access->deadline;
    if (!timely) decision = PX_CLIENT_DENY;
    access->state = decision == PX_CLIENT_DENY ? CLIENT_DENIED :
        decision == PX_CLIENT_SESSION ? CLIENT_ALLOWED : CLIENT_UNUSED;
    px_connection *connection = proxy->first;
    while (connection) {
        px_connection *next = connection->next;
        if (connection->pending_client_id == id) {
            if (decision == PX_CLIENT_DENY) {
                ++proxy->rejected_clients;
                close_connection(connection, "client_not_allowed");
            } else admit_client(connection);
        }
        connection = next;
    }
    return timely;
}

size_t px_proxy_pending_clients(px_proxy *proxy, px_client_request requests[PX_PENDING_CLIENT_LIMIT]) {
    if (!proxy || proxy->stopping) return 0;
    size_t count = 0;
    for (size_t i = 0; i < PX_CLIENT_LIMIT; ++i) {
        px_client_access *access = &proxy->clients[i];
        if (access->state != CLIENT_PENDING) continue;
        if (uv_now(proxy->loop) >= access->deadline) {
            px_proxy_decide_client(proxy, access->id, PX_CLIENT_DENY);
            continue;
        }
        px_client_request *request = &requests[count++];
        request->id = access->id;
        request->connections = 0;
        struct sockaddr_in address;
        memset(&address, 0, sizeof(address));
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = access->address;
        uv_ip4_name(&address, request->address, sizeof(request->address));
        for (px_connection *connection = proxy->first; connection; connection = connection->next) {
            if (connection->pending_client_id == access->id) ++request->connections;
        }
    }
    return count;
}

static bool await_client_approval(px_connection *connection, uint32_t address) {
    px_proxy *proxy = connection->proxy;
    px_client_access *access = NULL, *empty = NULL;
    unsigned pending = 0;
    for (size_t i = 0; i < PX_CLIENT_LIMIT; ++i) {
        px_client_access *item = &proxy->clients[i];
        if (item->state == CLIENT_PENDING) ++pending;
        if (item->state == CLIENT_UNUSED) empty = item;
        else if (item->address == address) access = item;
    }
    if (access && access->state == CLIENT_ALLOWED) { admit_client(connection); return true; }
    if (access && access->state == CLIENT_DENIED) return false;
    if (!access) {
        if (!empty || pending == PX_PENDING_CLIENT_LIMIT) return false;
        access = empty;
        *access = (px_client_access){CLIENT_PENDING, address, ++proxy->next_client_id, uv_now(proxy->loop) + CLIENT_APPROVAL_TIMEOUT_MS};
    }
    unsigned connections = 0;
    for (px_connection *item = proxy->first; item; item = item->next) {
        if (item->pending_client_id == access->id) ++connections;
    }
    if (connections == PX_CLIENT_CONNECTION_LIMIT || uv_now(proxy->loop) >= access->deadline) return false;
    connection->pending_client_id = access->id;
    uv_timer_start(&connection->timer, timed_out, access->deadline - uv_now(proxy->loop), 0);
    return true; /* No read, TLS, DNS or upstream connection before approval. */
}

static void free_rejected(uv_handle_t *handle) { free(handle); }

static void accept_client(uv_stream_t *server, int status) {
    px_proxy *proxy = server->data;
    if (status < 0 || proxy->stopping) return;
    if (proxy->count == proxy->config.max_connections) {
        uv_tcp_t *rejected = malloc(sizeof(*rejected));
        if (!rejected) return;
        if (uv_tcp_init(proxy->loop, rejected) < 0) { free(rejected); return; }
        uv_accept(server, (uv_stream_t *)rejected);
        uv_close((uv_handle_t *)rejected, free_rejected);
        return;
    }
    px_connection *connection = calloc(1, sizeof(*connection));
    if (!connection) return;
    connection->proxy = proxy;
    px_capture_init(&connection->capture, &proxy->capture_budget, proxy->config.body_limit);
    connection->references = 1;
    connection->started = uv_now(proxy->loop);
    connection->flow.id = ++proxy->next_id;
    connection->flow.result = "complete";
    connection->next = proxy->first;
    if (proxy->first) proxy->first->previous = connection;
    proxy->first = connection;
    ++proxy->count;
    px_http_init(&connection->request, false, false);
    if (initialize_peer(connection, &connection->client) < 0 || initialize_peer(connection, &connection->upstream) < 0 ||
        uv_timer_init(proxy->loop, &connection->timer) < 0) {
        close_connection(connection, "initialization_error");
        return;
    }
    connection->timer_initialized = true;
    connection->timer.data = connection;
    retain(connection);
    if (uv_accept(server, (uv_stream_t *)&connection->client.tcp) < 0) { close_connection(connection, "accept_error"); return; }
    struct sockaddr_storage address;
    int length = sizeof(address);
    char client_address[16];
    bool valid = uv_tcp_getpeername(&connection->client.tcp, (struct sockaddr *)&address, &length) == 0 &&
        address.ss_family == AF_INET && uv_ip4_name((struct sockaddr_in *)&address, client_address, sizeof(client_address)) == 0 &&
        px_proxy_valid_address(client_address);
    if (valid) {
        uint32_t source = ((const struct sockaddr_in *)&address)->sin_addr.s_addr;
        if (proxy->config.ask_clients && await_client_approval(connection, source)) return;
        if (!proxy->config.ask_clients && source == proxy->client_address.sin_addr.s_addr) { admit_client(connection); return; }
    }
    ++proxy->rejected_clients;
    close_connection(connection, "client_not_allowed");
}

bool px_proxy_valid_address(const char *text) {
    struct sockaddr_in address;
    char canonical[16];
    if (!text || uv_ip4_addr(text, 0, &address) < 0 ||
        uv_ip4_name(&address, canonical, sizeof(canonical)) < 0 || strcmp(text, canonical) != 0) return false;
    uint32_t value = ntohl(address.sin_addr.s_addr);
    return (value >> 24) == 10 || (value >> 24) == 127 ||
        (value >> 20) == 0xac1 || (value >> 16) == 0xc0a8 || (value >> 16) == 0xa9fe;
}

px_proxy *px_proxy_create(uv_loop_t *loop, px_config config, px_flow_callback callback, void *context) {
    if (!config.max_connections || config.max_connections > PX_MAX_CONNECTIONS || config.port > 65535 || !config.idle_timeout_ms) return NULL;
    if (!px_proxy_valid_address(config.listen_address) || !px_proxy_valid_address(config.client_address)) return NULL;
    px_proxy *proxy = calloc(1, sizeof(*proxy));
    if (!proxy) return NULL;
    proxy->loop = loop;
    proxy->config = config;
    proxy->callback = callback;
    proxy->context = context;
    uv_ip4_addr(config.listen_address, (int)config.port, &proxy->listen_address);
    uv_ip4_addr(config.client_address, 0, &proxy->client_address);
    return proxy;
}

int px_proxy_start(px_proxy *proxy) {
    struct sockaddr_in address;
    int status = uv_tcp_init(proxy->loop, &proxy->listener);
    if (status < 0) return status;
    proxy->initialized = true;
    proxy->listener.data = proxy;
    status = uv_tcp_bind(&proxy->listener, (const struct sockaddr *)&proxy->listen_address, 0);
    if (status < 0) return status;
    status = uv_listen((uv_stream_t *)&proxy->listener, PX_MAX_CONNECTIONS, accept_client);
    if (status < 0) return status;
    int length = sizeof(address);
    status = uv_tcp_getsockname(&proxy->listener, (struct sockaddr *)&address, &length);
    if (status == 0) proxy->port = ntohs(address.sin_port);
    return status;
}

unsigned px_proxy_port(const px_proxy *proxy) { return proxy->port; }
uint64_t px_proxy_rejected_clients(const px_proxy *proxy) { return proxy ? proxy->rejected_clients : 0; }

static void listener_closed(uv_handle_t *handle) {
    px_proxy *proxy = handle->data;
    proxy->initialized = false;
}

void px_proxy_stop(px_proxy *proxy) {
    if (proxy->stopping) return;
    proxy->stopping = true;
    if (proxy->initialized) uv_close((uv_handle_t *)&proxy->listener, listener_closed);
    while (proxy->first) close_connection(proxy->first, "stopped");
}

bool px_proxy_drained(const px_proxy *proxy) { return proxy->stopping && !proxy->initialized && !proxy->count; }

void px_proxy_destroy(px_proxy *proxy) { free(proxy); }
