/* SPDX-License-Identifier: GPL-3.0-only */
#include "tls.h"
#include "proxy_limits.h"

#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/pk.h>
#include <mbedtls/platform_util.h>
#include <mbedtls/base64.h>
#include <mbedtls/oid.h>
#include <psa/crypto.h>
#include <uv.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { TLS_INPUT_LIMIT = 65536, TLS_FILE_LIMIT = 65536, TLS_CA_LIMIT = 2 * 1024 * 1024,
       TLS_QUEUE_LIMIT = PX_WRITE_HIGH + PX_HEADER_LIMIT + 2 * PX_READ_SIZE };

typedef struct {
    char host[PX_HOST_LIMIT + 1];
    mbedtls_x509_crt certificate;
    mbedtls_pk_context key;
    mbedtls_ssl_config config;
} px_identity;

struct px_tls_policy {
    mbedtls_x509_crt trust;
    mbedtls_ssl_config client;
    size_t count;
    px_identity identities[PX_TLS_IDENTITIES];
    char root_fingerprint[65];
    char root_base64[10928];
    char root_profile[16384];
};

typedef struct px_plaintext {
    struct px_plaintext *next;
    size_t length, offset;
    unsigned char bytes[];
} px_plaintext;

struct px_tls {
    mbedtls_ssl_context ssl;
    px_tls_sink sink;
    void *context;
    px_identity *identity;
    unsigned char input[TLS_INPUT_LIMIT];
    size_t input_start, input_length;
    px_plaintext *first, *last;
    size_t pending;
    bool ready, failed, closing, close_sent;
};

static const char *const alpn[] = {"http/1.1", NULL};

static unsigned char *read_file(const char *path, size_t limit, size_t *length) {
    FILE *file = fopen(path, "rb");
    if (!file) return NULL;
    unsigned char *bytes = malloc(limit + 1);
    if (!bytes) { fclose(file); return NULL; }
    *length = fread(bytes, 1, limit, file);
    bool valid = !ferror(file) && *length > 0 && fgetc(file) == EOF;
    fclose(file);
    if (!valid) { mbedtls_platform_zeroize(bytes, limit + 1); free(bytes); return NULL; }
    bytes[*length] = 0;
    return bytes;
}

static bool load_certificates(mbedtls_x509_crt *certificates, const char *path, size_t limit) {
    size_t length = 0;
    unsigned char *bytes = read_file(path, limit, &length);
    if (!bytes) return false;
    /* PEM parser needs its terminating NUL; DER parser needs the exact byte count. */
    bool pem = length >= 10 && memcmp(bytes, "-----BEGIN", 10) == 0;
    int result = mbedtls_x509_crt_parse(certificates, bytes, length + (pem ? 1u : 0u));
    free(bytes);
    return result == 0; /* A partially parsed trust bundle is an error, too. */
}

static bool valid_time(const mbedtls_x509_crt *certificate) {
    return !mbedtls_x509_time_is_past(&certificate->valid_to) &&
           !mbedtls_x509_time_is_future(&certificate->valid_from);
}

static int64_t certificate_seconds(const mbedtls_x509_time *value) {
    /* Parsed X.509 dates are Gregorian UTC. Only differences are used, so no OS time-zone API. */
    static const int month_days[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    int64_t prior_year = value->year - 1;
    int64_t days = prior_year * 365 + prior_year / 4 - prior_year / 100 + prior_year / 400;
    for (int month = 1; month < value->mon; ++month) days += month_days[month - 1];
    if (value->mon > 2 && value->year % 4 == 0 && (value->year % 100 != 0 || value->year % 400 == 0)) ++days;
    days += value->day - 1;
    return ((days * 24 + value->hour) * 60 + value->min) * 60 + value->sec;
}

static bool exact_leaf(const mbedtls_x509_crt *certificate, const char *host) {
    if (mbedtls_x509_crt_get_ca_istrue(certificate) || !valid_time(certificate)) return false;
    int64_t lifetime = certificate_seconds(&certificate->valid_to) - certificate_seconds(&certificate->valid_from);
    if (lifetime <= 0 || lifetime > 7 * 86400 ||
        mbedtls_x509_crt_check_key_usage(certificate, MBEDTLS_X509_KU_DIGITAL_SIGNATURE) != 0 ||
        mbedtls_x509_crt_check_extended_key_usage(certificate, MBEDTLS_OID_SERVER_AUTH,
                                                 MBEDTLS_OID_SIZE(MBEDTLS_OID_SERVER_AUTH)) != 0) return false;
    const mbedtls_x509_sequence *san = &certificate->subject_alt_names;
    if (san->next || !san->buf.p) return false; /* One exact SAN, never a wildcard/multi-host identity. */
    struct sockaddr_in ip4;
    struct sockaddr_in6 ip6;
    if (uv_ip4_addr(host, 0, &ip4) == 0) {
        return (san->buf.tag & 31) == MBEDTLS_X509_SAN_IP_ADDRESS && san->buf.len == 4 &&
               memcmp(san->buf.p, &ip4.sin_addr, 4) == 0;
    }
    if (uv_ip6_addr(host, 0, &ip6) == 0) {
        return (san->buf.tag & 31) == MBEDTLS_X509_SAN_IP_ADDRESS && san->buf.len == 16 &&
               memcmp(san->buf.p, &ip6.sin6_addr, 16) == 0;
    }
    return (san->buf.tag & 31) == MBEDTLS_X509_SAN_DNS_NAME && san->buf.len == strlen(host) &&
           memcmp(san->buf.p, host, san->buf.len) == 0;
}

static int check_sni(void *context, mbedtls_ssl_context *ssl, const unsigned char *name, size_t length) {
    (void)ssl;
    const px_identity *identity = context;
    if (length != strlen(identity->host)) return -1;
    for (size_t i = 0; i < length; ++i) {
        unsigned char c = name[i];
        if (c >= 'A' && c <= 'Z') c = (unsigned char)(c + ('a' - 'A'));
        if (c != (unsigned char)identity->host[i]) return -1;
    }
    return 0;
}

static bool configure(mbedtls_ssl_config *config, bool server) {
    if (mbedtls_ssl_config_defaults(config, server ? MBEDTLS_SSL_IS_SERVER : MBEDTLS_SSL_IS_CLIENT,
                                    MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT) != 0) return false;
    mbedtls_ssl_conf_min_tls_version(config, MBEDTLS_SSL_VERSION_TLS1_2);
    return mbedtls_ssl_conf_alpn_protocols(config, alpn) == 0;
}

px_tls_policy *px_tls_policy_load(const char *ca_bundle, const px_tls_identity *identities, size_t count) {
    if (!ca_bundle || !count || count > PX_TLS_IDENTITIES || psa_crypto_init() != PSA_SUCCESS) return NULL;
    px_tls_policy *policy = calloc(1, sizeof(*policy));
    if (!policy) return NULL;
    mbedtls_x509_crt_init(&policy->trust);
    mbedtls_ssl_config_init(&policy->client);
    if (!load_certificates(&policy->trust, ca_bundle, TLS_CA_LIMIT) || !configure(&policy->client, false)) goto fail;
    mbedtls_ssl_conf_authmode(&policy->client, MBEDTLS_SSL_VERIFY_REQUIRED);
    mbedtls_ssl_conf_ca_chain(&policy->client, &policy->trust, NULL);
    for (size_t i = 0; i < count; ++i) {
        const px_tls_identity *source = &identities[i];
        px_identity *identity = &policy->identities[policy->count++];
        mbedtls_x509_crt_init(&identity->certificate);
        mbedtls_pk_init(&identity->key);
        mbedtls_ssl_config_init(&identity->config);
        size_t host_length = strlen(source->host);
        if (!host_length || host_length > PX_HOST_LIMIT) goto fail;
        for (size_t j = 0; j < host_length; ++j) {
            char c = source->host[j];
            if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == ':')) goto fail;
        }
        for (size_t j = 0; j < i; ++j) if (strcmp(policy->identities[j].host, source->host) == 0) goto fail;
        memcpy(identity->host, source->host, host_length + 1);
        if (!load_certificates(&identity->certificate, source->certificate, TLS_FILE_LIMIT) ||
            !exact_leaf(&identity->certificate, identity->host)) goto fail;
        size_t key_length = 0;
        unsigned char *key = read_file(source->key, TLS_FILE_LIMIT, &key_length);
        if (!key) goto fail;
        bool pem = key_length >= 10 && memcmp(key, "-----BEGIN", 10) == 0;
        int result = mbedtls_pk_parse_key(&identity->key, key, key_length + (pem ? 1u : 0u), NULL, 0);
        mbedtls_platform_zeroize(key, key_length + 1);
        free(key);
        if (result != 0 || mbedtls_pk_check_pair(&identity->certificate.pk, &identity->key) != 0 ||
            !configure(&identity->config, true)) goto fail;
        mbedtls_ssl_conf_authmode(&identity->config, MBEDTLS_SSL_VERIFY_NONE); /* No downstream client certificate. */
        mbedtls_ssl_conf_sni(&identity->config, check_sni, identity);
        if (mbedtls_ssl_conf_own_cert(&identity->config, &identity->certificate, &identity->key) != 0) goto fail;
    }
    return policy;
fail:
    px_tls_policy_free(policy);
    return NULL;
}

void px_tls_policy_free(px_tls_policy *policy) {
    if (!policy) return;
    for (size_t i = 0; i < policy->count; ++i) {
        mbedtls_ssl_config_free(&policy->identities[i].config);
        mbedtls_pk_free(&policy->identities[i].key);
        mbedtls_x509_crt_free(&policy->identities[i].certificate);
    }
    mbedtls_ssl_config_free(&policy->client);
    mbedtls_x509_crt_free(&policy->trust);
    free(policy);
}

static px_identity *find_identity(const px_tls_policy *policy, const char *host) {
    if (!policy) return NULL;
    for (size_t i = 0; i < policy->count; ++i) {
        if (strcmp(policy->identities[i].host, host) == 0) return (px_identity *)&policy->identities[i];
    }
    return NULL;
}

bool px_tls_policy_has(const px_tls_policy *policy, const char *host) { return find_identity(policy, host) != NULL; }
size_t px_tls_policy_count(const px_tls_policy *policy) { return policy ? policy->count : 0; }
const char *px_tls_policy_host(const px_tls_policy *policy, size_t index) {
    return policy && index < policy->count ? policy->identities[index].host : NULL;
}

bool px_tls_policy_set_root(px_tls_policy *policy, const char *certificate) {
    if (!policy || policy->root_fingerprint[0]) return false;
    mbedtls_x509_crt root;
    mbedtls_x509_crt_init(&root);
    bool valid = false;
    if (!load_certificates(&root, certificate, TLS_FILE_LIMIT) || root.next || root.raw.len > 8192 ||
        !mbedtls_x509_crt_get_ca_istrue(&root) || !valid_time(&root) ||
        root.issuer_raw.len != root.subject_raw.len || memcmp(root.issuer_raw.p, root.subject_raw.p, root.issuer_raw.len)) goto done;
    for (size_t i = 0; i < policy->count; ++i) {
        uint32_t flags = 0;
        if (mbedtls_x509_crt_verify(&policy->identities[i].certificate, &root, NULL,
                                   policy->identities[i].host, &flags, NULL, NULL) != 0) goto done;
    }
    unsigned char digest[32];
    size_t length = 0;
    if (psa_hash_compute(PSA_ALG_SHA_256, root.raw.p, root.raw.len, digest, sizeof(digest), &length) != PSA_SUCCESS || length != 32) goto done;
    if (mbedtls_base64_encode((unsigned char *)policy->root_base64, sizeof(policy->root_base64), &length, root.raw.p, root.raw.len) != 0) goto done;
    for (size_t i = 0; i < sizeof(digest); ++i) snprintf(policy->root_fingerprint + 2 * i, 3, "%02x", digest[i]);
    const char *hash = policy->root_fingerprint;
    char certificate_uuid[37], profile_uuid[37];
    snprintf(certificate_uuid, sizeof(certificate_uuid), "%.8s-%.4s-%.4s-%.4s-%.12s", hash, hash + 8, hash + 12, hash + 16, hash + 20);
    snprintf(profile_uuid, sizeof(profile_uuid), "%.8s-%.4s-%.4s-%.4s-%.12s", hash + 32, hash + 40, hash + 44, hash + 48, hash + 52);
    int size = snprintf(policy->root_profile, sizeof(policy->root_profile),
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        "<plist version=\"1.0\"><dict>"
        "<key>PayloadType</key><string>Configuration</string>"
        "<key>PayloadVersion</key><integer>1</integer>"
        "<key>PayloadIdentifier</key><string>app.threading.proxy.%s</string>"
        "<key>PayloadUUID</key><string>%s</string>"
        "<key>PayloadDisplayName</key><string>Threading development proxy</string>"
        "<key>PayloadDescription</key><string>Public development CA for HTTPS inspection. Install only for your own Threading host. Remove after debugging.</string>"
        "<key>PayloadRemovalDisallowed</key><false/>"
        "<key>PayloadContent</key><array><dict>"
        "<key>PayloadType</key><string>com.apple.security.root</string>"
        "<key>PayloadVersion</key><integer>1</integer>"
        "<key>PayloadIdentifier</key><string>app.threading.proxy.%s.root</string>"
        "<key>PayloadUUID</key><string>%s</string>"
        "<key>PayloadDisplayName</key><string>Threading development CA</string>"
        "<key>PayloadCertificateFileName</key><string>threading-proxy-ca.cer</string>"
        "<key>PayloadContent</key><data>%s</data>"
        "</dict></array></dict></plist>\n", hash, profile_uuid, hash, certificate_uuid, policy->root_base64);
    valid = size > 0 && (size_t)size < sizeof(policy->root_profile);
done:
    mbedtls_x509_crt_free(&root);
    if (!valid) {
        policy->root_fingerprint[0] = policy->root_base64[0] = policy->root_profile[0] = 0;
    }
    return valid;
}

const char *px_tls_root_fingerprint(const px_tls_policy *policy) { return policy ? policy->root_fingerprint : ""; }
const char *px_tls_root_base64(const px_tls_policy *policy) { return policy ? policy->root_base64 : ""; }
const char *px_tls_root_profile(const px_tls_policy *policy) { return policy ? policy->root_profile : ""; }

static int receive_wire(void *context, unsigned char *bytes, size_t length) {
    px_tls *tls = context;
    if (!tls->input_length) return MBEDTLS_ERR_SSL_WANT_READ;
    if (length > tls->input_length) length = tls->input_length;
    memcpy(bytes, tls->input + tls->input_start, length);
    tls->input_start += length;
    tls->input_length -= length;
    return (int)length;
}

static int send_wire(void *context, const unsigned char *bytes, size_t length) {
    px_tls *tls = context;
    int result = tls->sink(tls->context, (const char *)bytes, length);
    return result > 0 ? (int)length : (result == 0 ? MBEDTLS_ERR_SSL_WANT_WRITE : MBEDTLS_ERR_SSL_INTERNAL_ERROR);
}

px_tls *px_tls_create(px_tls_policy *policy, const char *host, bool server, px_tls_sink sink, void *context) {
    px_identity *identity = find_identity(policy, host);
    if (!identity || !valid_time(&identity->certificate)) return NULL;
    px_tls *tls = calloc(1, sizeof(*tls));
    if (!tls) return NULL;
    tls->sink = sink;
    tls->context = context;
    tls->identity = identity;
    mbedtls_ssl_init(&tls->ssl);
    if (mbedtls_ssl_setup(&tls->ssl, server ? &identity->config : &policy->client) != 0 ||
        (!server && mbedtls_ssl_set_hostname(&tls->ssl, host) != 0)) {
        px_tls_free(tls);
        return NULL;
    }
    mbedtls_ssl_set_bio(&tls->ssl, tls, send_wire, receive_wire, NULL);
    return tls;
}

void px_tls_free(px_tls *tls) {
    if (!tls) return;
    mbedtls_ssl_free(&tls->ssl);
    while (tls->first) {
        px_plaintext *next = tls->first->next;
        mbedtls_platform_zeroize(tls->first->bytes, tls->first->length);
        free(tls->first);
        tls->first = next;
    }
    mbedtls_platform_zeroize(tls, sizeof(*tls));
    free(tls);
}

bool px_tls_feed(px_tls *tls, const char *bytes, size_t length) {
    if (tls->failed || length > sizeof(tls->input) - tls->input_length) return false;
    if (tls->input_start + tls->input_length + length > sizeof(tls->input)) {
        memmove(tls->input, tls->input + tls->input_start, tls->input_length);
        tls->input_start = 0;
    }
    memcpy(tls->input + tls->input_start + tls->input_length, bytes, length);
    tls->input_length += length;
    return true;
}

static bool pending_io(int result) {
    return result == MBEDTLS_ERR_SSL_WANT_READ || result == MBEDTLS_ERR_SSL_WANT_WRITE;
}

bool px_tls_flush(px_tls *tls) {
    if (tls->failed) return false;
    if (!tls->ready) {
        int result = mbedtls_ssl_handshake(&tls->ssl);
        if (pending_io(result)) return true;
        if (result != 0) { tls->failed = true; return false; }
        tls->ready = true;
    }
    while (tls->first) {
        px_plaintext *chunk = tls->first;
        int result = mbedtls_ssl_write(&tls->ssl, chunk->bytes + chunk->offset, chunk->length - chunk->offset);
        /* A read may have moved TLS 1.3 into post-handshake ticket processing. A write
         * can finish that transition and report its notification before writing bytes. */
        if (result == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET) continue;
        if (pending_io(result)) return true;
        if (result <= 0) { tls->failed = true; return false; }
        chunk->offset += (size_t)result;
        tls->pending -= (size_t)result;
        if (chunk->offset == chunk->length) {
            tls->first = chunk->next;
            if (!tls->first) tls->last = NULL;
            mbedtls_platform_zeroize(chunk->bytes, chunk->length);
            free(chunk);
        }
    }
    if (tls->closing && !tls->close_sent) {
        int result = mbedtls_ssl_close_notify(&tls->ssl);
        if (pending_io(result)) return true;
        if (result != 0) { tls->failed = true; return false; }
        tls->close_sent = true;
    }
    return true;
}

bool px_tls_write(px_tls *tls, const char *bytes, size_t length) {
    if (tls->failed || tls->closing || length > TLS_QUEUE_LIMIT - tls->pending) return false;
    while (length) {
        size_t size = length < PX_READ_SIZE ? length : PX_READ_SIZE;
        px_plaintext *chunk = malloc(sizeof(*chunk) + size);
        if (!chunk) return false;
        chunk->next = NULL;
        chunk->length = size;
        chunk->offset = 0;
        memcpy(chunk->bytes, bytes, size);
        if (tls->last) tls->last->next = chunk;
        else tls->first = chunk;
        tls->last = chunk;
        tls->pending += size;
        bytes += size;
        length -= size;
    }
    return px_tls_flush(tls);
}

int px_tls_read(px_tls *tls, char *bytes, size_t capacity) {
    if (!px_tls_flush(tls)) return -1;
    if (!tls->ready) return 0;
    int result;
    do { result = mbedtls_ssl_read(&tls->ssl, (unsigned char *)bytes, capacity); }
    while (result == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET ||
           (result == MBEDTLS_ERR_SSL_WANT_READ && mbedtls_ssl_check_pending(&tls->ssl)));
    /* WANT_READ can mean a held-back post-handshake message, not an empty socket.
     * Drain that message now: another network callback is not guaranteed to arrive. */
    if (pending_io(result)) return 0;
    if (result == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) return -2;
    if (result <= 0) { tls->failed = true; return -1; }
    return result;
}

bool px_tls_ready(const px_tls *tls) { return tls && tls->ready; }
size_t px_tls_pending(const px_tls *tls) { return tls ? tls->pending : 0; }
bool px_tls_shutdown(px_tls *tls) { tls->closing = true; return px_tls_flush(tls); }
bool px_tls_shutdown_done(const px_tls *tls) { return tls->close_sent; }
const char *px_tls_version(const px_tls *tls) { return tls && tls->ready ? mbedtls_ssl_get_version(&tls->ssl) : ""; }
