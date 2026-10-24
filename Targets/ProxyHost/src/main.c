/* SPDX-License-Identifier: GPL-3.0-only */
#include "proxy.h"
#include "output.h"
#include "platform.h"
#include "mcp.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uv_loop_t loop;
    px_proxy *proxy;
    px_mcp *mcp;
    px_output output;
    px_platform platform;
    uv_pipe_t input;
    bool input_initialized;
    bool stopping;
    char command[65537];
    size_t command_length;
} px_application;

static void stop(px_application *application) {
    if (application->stopping) return;
    application->stopping = true;
    if (application->proxy) px_proxy_stop(application->proxy);
    px_mcp_stop(application->mcp);
    if (application->input_initialized) uv_close((uv_handle_t *)&application->input, NULL);
    px_platform_stop(&application->platform);
    px_output_stop(&application->output);
}

static void signal_received(uv_signal_t *signal, int number) {
    (void)number;
    stop(signal->data);
}

static void output_failed(void *context) { stop(context); }

static void report_flow(const px_flow *flow, void *context) {
    px_output *output = context;
    char line[PX_EVENT_SIZE];
    /* Every string is a protocol constant or validated ASCII authority, never raw HTTP data. */
    int length = snprintf(line, sizeof(line),
        "{\"version\":%d,\"event\":\"flow\",\"id\":\"%" PRIu64 "\",\"method\":\"%s\","
        "\"host\":\"%s\",\"port\":%u,\"status\":%u,\"tunnel\":%s,"
        "\"tls_inspected\":%s,\"mocked\":%s,\"tls_version\":\"%s\","
        "\"client_bytes\":%" PRIu64 ",\"upstream_bytes\":%" PRIu64 ",\"duration_ms\":%" PRIu64 ","
        "\"peak_pending_bytes\":%zu,\"result\":\"%s\",\"dropped_events\":%" PRIu64 "}\n",
        PX_PROTOCOL_VERSION, flow->id, flow->method, flow->host, flow->port, flow->status,
        flow->tunnel ? "true" : "false", flow->tls_inspected ? "true" : "false",
        flow->mocked ? "true" : "false", flow->tls_version,
        flow->client_bytes, flow->upstream_bytes, flow->duration_ms,
        flow->peak_pending_bytes, flow->result, output->dropped);
    if (length > 0 && (size_t)length < sizeof(line)) px_output_send(output, line);
}

static void allocate_input(uv_handle_t *handle, size_t suggested, uv_buf_t *buffer) {
    (void)handle;
    (void)suggested;
    buffer->base = malloc(4096);
    buffer->len = buffer->base ? 4096 : 0;
}

static void read_input(uv_stream_t *input, ssize_t count, const uv_buf_t *buffer) {
    px_application *application = input->data;
    if (count < 0) stop(application); /* The parent's inherited pipe is the lifetime lease. */
    for (ssize_t i = 0; i < count && !application->stopping; ++i) {
        char c = buffer->base[i];
        if (c == '\n') {
            application->command[application->command_length] = '\0';
            if (application->mcp) {
                if (!px_mcp_receive(application->mcp, application->command, application->command_length)) stop(application);
            } else if (strcmp(application->command, "stop") == 0) stop(application);
            application->command_length = 0;
        } else if (application->command_length + 1 < (application->mcp ? sizeof(application->command) : 16)) {
            application->command[application->command_length++] = c;
        } else stop(application);
    }
    free(buffer->base);
}

static bool number(const char *text, unsigned maximum, unsigned *value) {
    if (!*text) return false;
    unsigned result = 0;
    for (const char *p = text; *p; ++p) {
        if (*p < '0' || *p > '9') return false;
        unsigned digit = (unsigned)(*p - '0');
        if (result > maximum / 10 || (result == maximum / 10 && digit > maximum % 10)) return false;
        result = result * 10 + digit;
    }
    *value = result;
    return true;
}

static void usage(void) {
    puts("threading-proxyd 0.3.0 (GPL-3.0-only)\n"
         "Usage: threading-proxyd [--port 0..65535] [--max-connections 1..128]\n"
         "       [--idle-timeout-ms 100..300000] [--stdio | --mcp] [--body-limit 1..1048576]\n"
         "       [--upstream-ca PEM --tls-identity HOST LEAF_CERT LEAF_KEY] (up to 16 hosts)\n"
         "       [--inspection-ca PUBLIC_ROOT_CERT] (public certificate/profile export over MCP)\n"
         "       [--listen-address LOCAL_IPV4 (--client-address DEVICE_IPV4 | --mcp --ask-clients)]\n"
         "Explicit HTTP/1 proxy; defaults to 127.0.0.1. Device mode requires an explicit source or host approval,\n"
         "private/link-local/loopback IPv4 only, no wildcard binds. Clients require the source filter or host approval.\n"
         "stdout: bounded versioned JSONL metadata. --stdio: stop on stdin EOF or stop\\n.\n"
         "--mcp: native MCP stdio server; capture starts with traffic_start and ends on stdin EOF.\n"
         "Licenses and corresponding source: share/threading-proxyd beside the installed bin directory.");
}

int main(int argc, char **argv) {
    px_config config = {0, PX_MAX_CONNECTIONS, PX_IDLE_TIMEOUT_MS, NULL, 0, "127.0.0.1", "127.0.0.1", false, NULL};
    bool explicit_listener = false, explicit_client = false;
    px_tls_identity identities[PX_TLS_IDENTITIES];
    size_t identity_count = 0;
    const char *ca_bundle = NULL;
    const char *inspection_ca = NULL;
    bool stdio_control = false;
    bool mcp_control = false;
    unsigned body_limit = PX_BODY_DEFAULT;
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "--version") == 0) { usage(); return 0; }
        if (strcmp(argv[i], "--stdio") == 0) { stdio_control = true; continue; }
        if (strcmp(argv[i], "--ask-clients") == 0 && !config.ask_clients) { config.ask_clients = true; continue; }
        if (strcmp(argv[i], "--mcp") == 0) { mcp_control = true; continue; }
        if (strcmp(argv[i], "--listen-address") == 0 && i + 1 < argc && !explicit_listener) {
            config.listen_address = argv[++i];
            explicit_listener = true;
            continue;
        }
        if (strcmp(argv[i], "--client-address") == 0 && i + 1 < argc && !explicit_client) {
            config.client_address = argv[++i];
            explicit_client = true;
            continue;
        }
        if (strcmp(argv[i], "--upstream-ca") == 0 && i + 1 < argc && !ca_bundle) {
            ca_bundle = argv[++i];
            continue;
        }
        if (strcmp(argv[i], "--inspection-ca") == 0 && i + 1 < argc && !inspection_ca) {
            inspection_ca = argv[++i];
            continue;
        }
        if (strcmp(argv[i], "--tls-identity") == 0 && i + 3 < argc && identity_count < PX_TLS_IDENTITIES) {
            identities[identity_count++] = (px_tls_identity){argv[i + 1], argv[i + 2], argv[i + 3]};
            i += 3;
            continue;
        }
        unsigned value = 0;
        const char *option = argv[i];
        if (++i == argc || !number(argv[i], PX_BODY_MAX, &value)) { usage(); return 2; }
        if (strcmp(option, "--port") == 0 && value <= 65535) config.port = value;
        else if (strcmp(option, "--max-connections") == 0 && value > 0 && value <= PX_MAX_CONNECTIONS) config.max_connections = value;
        else if (strcmp(option, "--body-limit") == 0 && value > 0) body_limit = value;
        else if (strcmp(option, "--idle-timeout-ms") == 0 && value >= 100 && value <= 300000) config.idle_timeout_ms = value;
        else { usage(); return 2; }
    }
    config.body_limit = mcp_control ? body_limit : 0;
    if ((config.ask_clients ? (!mcp_control || explicit_client || !explicit_listener) : explicit_listener != explicit_client) || !px_proxy_valid_address(config.listen_address) ||
        !px_proxy_valid_address(config.client_address)) {
        fputs("threading-proxyd: supply --listen-address with either --client-address or --mcp --ask-clients; exact private/link-local/loopback IPv4 only\n", stderr);
        return 2;
    }
    if (stdio_control && mcp_control) { usage(); return 2; }
    if (identity_count || ca_bundle) {
        config.tls = px_tls_policy_load(ca_bundle, identities, identity_count);
        if (!config.tls) {
            fputs("threading-proxyd: invalid TLS policy (CA bundle and exact-host non-CA leaf identities required)\n", stderr);
            return 2;
        }
    }
    if (inspection_ca && !px_tls_policy_set_root(config.tls, inspection_ca)) {
        fputs("threading-proxyd: inspection CA must be a public root validating all supplied leaf identities\n", stderr);
        px_tls_policy_free(config.tls);
        return 2;
    }
    px_application application;
    memset(&application, 0, sizeof(application));
    int status = uv_loop_init(&application.loop);
    if (status < 0) return 1;
    status = px_platform_start(&application.platform, &application.loop, signal_received, &application);
    if (status == 0) status = px_output_init(&application.output, &application.loop);
    if (status == 0 && mcp_control) {
        application.output.on_error = output_failed;
        application.output.error_context = &application;
        application.mcp = px_mcp_create(&application.loop, config, &application.output);
        if (!application.mcp) status = UV_ENOMEM;
    }
    if (status == 0 && (stdio_control || mcp_control)) {
        if (uv_guess_handle(0) != UV_NAMED_PIPE) status = UV_EINVAL;
        else {
            status = uv_pipe_init(&application.loop, &application.input, 0);
            if (status == 0) {
                application.input_initialized = true;
                application.input.data = &application;
                status = uv_pipe_open(&application.input, 0);
                if (status == 0) status = uv_read_start((uv_stream_t *)&application.input, allocate_input, read_input);
            }
        }
    }
    if (status == 0 && !mcp_control) {
        application.proxy = px_proxy_create(&application.loop, config, report_flow, &application.output);
        status = application.proxy ? px_proxy_start(application.proxy) : UV_ENOMEM;
    }
    if (status < 0) {
        fprintf(stderr, "threading-proxyd: startup failed: %s\n", uv_strerror(status));
        stop(&application);
    } else if (!mcp_control) {
        char ready[256];
        snprintf(ready, sizeof(ready),
            "{\"version\":%d,\"event\":\"ready\",\"host\":\"%s\",\"port\":%u,"
            "\"http\":\"1.1\",\"tls_inspection\":%s,\"capture\":\"metadata\"}\n",
            PX_PROTOCOL_VERSION, config.listen_address, px_proxy_port(application.proxy), config.tls ? "true" : "false");
        px_output_send(&application.output, ready);
    }
    uv_run(&application.loop, UV_RUN_DEFAULT);
    int closed = uv_loop_close(&application.loop);
    px_proxy_destroy(application.proxy);
    px_mcp_destroy(application.mcp);
    px_tls_policy_free(config.tls);
    if (closed < 0) {
        fprintf(stderr, "threading-proxyd: handles remained at shutdown\n");
        return 1;
    }
    return status < 0 ? 1 : 0;
}
