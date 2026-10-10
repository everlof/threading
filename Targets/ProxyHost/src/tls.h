/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef THREADING_PROXY_TLS_H
#define THREADING_PROXY_TLS_H

#include <stdbool.h>
#include <stddef.h>

typedef struct px_tls_policy px_tls_policy;
typedef struct px_tls px_tls;
enum { PX_TLS_IDENTITIES = 16 };
typedef struct { const char *host, *certificate, *key; } px_tls_identity;

/* Loaded before serving requests. Only leaf keys; the signing authority stays with the host.
 * CA bundle is explicit and independent of the interception certificates. No insecure mode. */
px_tls_policy *px_tls_policy_load(const char *ca_bundle, const px_tls_identity *identities, size_t count);
void px_tls_policy_free(px_tls_policy *policy);
bool px_tls_policy_has(const px_tls_policy *policy, const char *host);
size_t px_tls_policy_count(const px_tls_policy *policy);
const char *px_tls_policy_host(const px_tls_policy *policy, size_t index);
/* Optional public root for host/device onboarding; must validate every supplied leaf. */
bool px_tls_policy_set_root(px_tls_policy *policy, const char *certificate);
const char *px_tls_root_fingerprint(const px_tls_policy *policy);
const char *px_tls_root_base64(const px_tls_policy *policy);
const char *px_tls_root_profile(const px_tls_policy *policy);

/* Wire sink: positive = all bytes accepted, zero = backpressure, negative = failure. */
typedef int (*px_tls_sink)(void *context, const char *bytes, size_t length);
px_tls *px_tls_create(px_tls_policy *policy, const char *host, bool server, px_tls_sink sink, void *context);
void px_tls_free(px_tls *tls);
bool px_tls_feed(px_tls *tls, const char *bytes, size_t length);
bool px_tls_write(px_tls *tls, const char *bytes, size_t length);
bool px_tls_flush(px_tls *tls);
/* Positive = plaintext, zero = needs I/O, -1 = failure, -2 = authenticated close_notify. */
int px_tls_read(px_tls *tls, char *bytes, size_t capacity);
bool px_tls_ready(const px_tls *tls);
size_t px_tls_pending(const px_tls *tls);
/* Flush queued plaintext, then close_notify. Call again after wire writes complete. */
bool px_tls_shutdown(px_tls *tls);
bool px_tls_shutdown_done(const px_tls *tls);
const char *px_tls_version(const px_tls *tls);

#endif
