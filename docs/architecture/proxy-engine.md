# Portable proxy engine

`Targets/ProxyHost` is the portable C11 HTTP/CONNECT/TLS engine behind Threading's typed
`traffic_*` MCP tools. Xcode builds and signs the helper, retaining its complete source archives
and notices in the app bundle. Its independent CMake build also serves Linux and Windows.
The [Traffic Inspector draft](../feature-drafts/network-inspector-extension.md) still owns the
future visual workbench and extension presentation; those are not shipped by this increment.
Client proxy routing and certificate trust remain explicit setup steps.

## Boundaries

| Owner | Current responsibility | Future responsibility kept at this boundary |
|---|---|---|
| HTTP policy (`http.c`) | Strict message framing, absolute target parsing, header filtering, protocol support | Protocol-specific parsing; no OS capture or trust-store APIs |
| Relay (`proxy.c`) | Bounded connection lifecycle, async resolution, streaming, half-closes, cancellation | Additional transports without OS trust mutation |
| TLS (`tls.c`) | Nonblocking Mbed TLS, immutable exact-host leaf policy, verified upstream trust, public certificate/profile export | Host broker supplies leased leaf identities; root keys stay outside the helper |
| libuv | Socket I/O, polling, DNS, portable stream primitives | The same API on macOS, Linux and Windows |
| CLI/MCP (`main.c`, `mcp.c`, `output.c`) | Launch options, parent lifetime, bounded exchange history, paged payload reads, stdio MCP control | Adapter to Threading's real session and extension contracts |
| Process adapter (`platform.c`) | POSIX/Windows signal differences | Only concrete process differences; not an all-purpose platform vtable |
| Threading host | Session process leases, Keychain CA signing, short-lived leaf issuance, typed MCP tools and public certificate setup paths | System-proxy transactions, paired-device routing/delivery and visual workbench |

There is no `#ifdef` network implementation in the parser or relay, and no premature socket
interface that duplicates libuv. The engine takes an explicit worker loop, configuration and a
nonblocking borrowed flow/capture callback. It has no AppKit, Swift, filesystem, project or session dependency.
The callback receives borrowed values and must copy only bounded data before returning.

The customization-surface gate classifies this increment as a deliberately **host-owned developer
helper**, with no new public extension component or UI. The eventual Traffic presentation remains
an advanced extension as described by the draft. Capture authority, system mutation, root signing
keys and trust installation remain host-owned even when that presentation is customizable.
The standalone MCP server is not a substitute for manifest-declared companion operations or
Threading's existing session-scoped MCP permission routing. Its launch-time host scope is immutable.

## Current contract

The listener binds only `127.0.0.1`; port zero selects an ephemeral endpoint. Clients explicitly
opt into the proxy. Absolute-form HTTP is converted to origin form, Host is regenerated from the
target, and proxy credentials/hop-by-hop fields are stripped. Ambiguous framing and unsupported
protocol forms fail closed. The parser is pinned llhttp with no leniency flags enabled.

Each connection carries one HTTP exchange and explicitly closes afterward. This changes reuse
and timing, so it is a stated compatibility boundary, not an invisible claim of transparent
capture. Streaming fixed/chunked uploads, fixed/chunked/close-delimited responses, interim
responses, HEAD and no-body statuses are supported. Nonempty trailers and upgrades are rejected.
CONNECT forwards unselected hosts with independent half-closes. Selected hosts terminate TLS
1.2/1.3 on both legs, using only HTTP/1.1 ALPN. The upstream chain, name and validity must verify
before CONNECT succeeds. No insecure fallback exists. The inner Host and downstream SNI cannot
escape the selected CONNECT authority. Close-delimited TLS responses require close_notify;
unauthenticated EOF is truncation. TLS records, partial writes and shutdown stay inside `tls.c`.
Mbed TLS's `WANT_READ` can also mean that a complete post-handshake ticket is held internally.
The adapter checks pending TLS work before waiting for another socket callback and handles ticket
notifications from both read and write operations. A repeated-connection benchmark exposed a
write failure when the read adapter abandoned that transition; ordinary short socket tests had
not triggered the timing. Preserve the delayed-request ticket test and repeated TLS benchmark.

The host supplies up to 16 lowercase exact-host leaf identities and an independent upstream CA
bundle. Each leaf must have exactly one matching DNS/IP SAN, a matching key, no CA bit, valid
dates and a lifetime of at most seven days. The helper rechecks expiry when creating a connection.
The optional public inspection root must validate every leaf before it can be exported as DER,
SHA-256 fingerprint and an unsigned, removable Apple profile. A root private key is never needed.
The CLI reads bounded certificate/key files before serving. `ProxyCertificateAuthority` keeps
the reusable non-exportable key in Keychain; `ProxyProcess` stages only 24-hour leaves in an
owner-only temporary directory and deletes the private leaf files after initialization.

MCP stdio supports protocol `2025-11-25` initialization, ping, tools/list and tools/call. It starts
idle. Tools start/stop the listener, report immutable scope, page/read/clear completed exchanges,
read original headers and payload bytes, and return the public certificate/profile. Stop preserves history; process EOF ends the lease.
The tool schemas do not expose arbitrary file access, scope widening, OS proxy mutation or trust
installation. There is no HTTP MCP control listener. Hostnames and all network-derived metadata
remain untrusted input. HTTP targets, headers and bodies are now retained for debugging.
The legacy JSONL observation mode remains metadata-only; MCP capture is a separate explicit mode.

## Scaling contract

Expected development load is 1–16 concurrent connections and 5–50 exchanges/second. Stress is
128 admitted connections, long-lived tunnels, 8 MiB+ bodies, 10,000 sequential/parallel exchanges
and an event observer that stops reading entirely. These are workload shapes, not a throughput
promise. The implementation's aggregate limits are:

- At most 128 live connection allocations, including closing connections with outstanding
  callbacks. Excess accepted sockets close immediately. The kernel listen backlog is also bounded.
- Each direction reads chunks of at most 16 KiB. Pending writes pause the opposite reader at
  256 KiB and resume at 128 KiB. One in-progress callback/header expansion can exceed the high
  watermark; the integration assertion permits at most two times `(256 KiB + 33 KiB)` of owned
  queued socket payload per connection. Kernel socket buffers and allocator overhead are separate.
- Each connection has two 32 KiB header buffers, at most 128 fields per message, and one 16 KiB
  pre-connect buffer. Header scanning and body parsing are O(new bytes), without rescanning old
  prefixes or accumulating full bodies. A complete upstream body never has to fit in memory.
- An inspected connection adds a 64 KiB encrypted-input buffer per leg plus Mbed TLS state.
  Each leg's plaintext queue is capped at 320 KiB (256 + 32 + 2 × 16 KiB); reads pause based on
  combined plaintext/ciphertext pending bytes. Ciphertext writes stop at 256 KiB plus one record.
  The delayed-reader TLS test permits at most 640 KiB combined owned queued payload per connection.
- At most eight resolved addresses are examined and tried, and eight informational responses
  are forwarded. Request headers have a 15-second total deadline in addition to the idle timeout.
- At most 128 output records and 512 KiB total output payload are queued. Legacy observations
  remain under 1 KiB and may be dropped with a cumulative counter; MCP replies may be up to 64 KiB
  and overflow/failure closes the MCP lease. Neither can delay shutdown indefinitely.
- MCP stores at most 128 completed exchanges and 16 MiB of captured bytes, pages at most 20
  summaries and reports eviction. Active capture has a separate 16 MiB byte budget. Each body
  defaults to 64 KiB, configurable up to 1 MiB; exhausting capture never changes forwarding.
  Clearing frees retained headers/bodies without reusing IDs. These budgets cover owned byte
  buffers; fixed parser/header tables, TLS state, allocator and kernel memory are separate. Input is capped at 64 KiB, JSON nesting at 32 and each
  object's/array's entries at 128. Duplicate keys, invalid UTF-8 and invalid IDs are rejected.
- TLS handshakes and request headers share a 15-second total deadline, in addition to idle timeout.

All protocol/socket work runs in the helper's worker loop. Numeric addresses bypass DNS; names use
libuv's bounded worker pool. Cancellation can remove queued lookups, but a lookup already running
inside the OS resolver must return before its worker and connection allocation can be released.
Socket deadlines still close the exchange; an embedding host should retain its ordinary process
termination deadline for an unresponsive resolver. Explicit retains cover handles and in-flight resolver/connect/write/shutdown requests;
closing unlinks a connection immediately but releases its admission slot only after all callbacks
have drained. A reconnect replaces its closed upstream handle before trying the next address.
Parent-pipe EOF closes the entire generation; no orphaned system configuration needs restoring.

## Dependencies and distribution

libuv 1.53.0 supplies portability, llhttp 9.4.3 HTTP parsing, Mbed TLS 4.1.1 TLS/X.509, cJSON
1.7.19 bounded MCP serialization and zlib 1.3.2 content decoding. All are built statically
from retained hash-pinned source archives, without a network-fetching configure step. The llhttp
TypeScript generator source is retained alongside its generated C archive. Upstream source is
unmodified. The helper's own code follows the repository's GPLv3 license; upstream MIT/BSD/ISC
Apache-2.0 and Zlib notices are reproduced verbatim, including file-level libuv/Mbed TLS notices.
Archives also retain the separately licensed documentation.

The authoritative inventory and obligations are
[`Targets/ProxyHost/THIRD_PARTY_NOTICES.md`](../../Targets/ProxyHost/THIRD_PARTY_NOTICES.md).
The provenance test verifies archive hashes, build pins and exact notice contents. Installation
includes the helper, notices and corresponding source tree. The Xcode app bundle includes
`ProxySource` and its legal index; release signing covers both the helper and retained resources.

## Apple onboarding

Proxyman's public guides are a product-workflow reference, not reused implementation. Its
[Mac proxy helper](https://docs.proxyman.com/basic-features/proxy-setting-tool) demonstrates why
proxy snapshot/restore and authenticated helper callers belong to the host. Its
[simulator guide](https://docs.proxyman.com/debug-devices/ios-simulator) uses `simctl`; our setup
targets one explicit already-booted UDID and never resets all devices. Its
[physical-device guide](https://docs.proxyman.com/debug-devices/ios-device) distinguishes routing,
profile installation, full trust and per-host inspection.

`Targets/ProxyHost/tools/apple_certificate.py` is a development shortcut: default output is a
reviewable command plan. `--apply` checks the expected fingerprint, stages those exact public DER
bytes and invokes user-domain SSL trust on macOS or `simctl keychain <UDID> add-root-cert` on one
available booted simulator. Removal supports user-domain Mac trust only. `simctl` has no targeted
root-removal action, so this tool does not offer a destructive keychain reset as cleanup. The
installed Xcode/security command help was checked; tests exercise plans, not real trust changes.

The future app setup surface keeps four independent states: reachable route, installed certificate,
trusted certificate and approved inspection hosts. A successful test request must prove the full
path; installing a certificate alone must never produce a green capture-ready state.

ThreadingMobile can receive the public DER/profile and fingerprint through the authenticated paired
host channel, then hand installation to the system and explain the trust step. It must never carry
the reusable root key or leaf private keys. [Apple requires explicit full trust for manually
installed profiles](https://support.apple.com/en-us/102390); ordinary app delivery cannot silently
perform that step. This increment does not add the iOS delivery UI or a reachable device listener:
the proxy binds only loopback. A later authorized LAN listener or authenticated route is necessary
for physical-device capture, alongside client proxy configuration. Certificate-pinned clients,
clients that ignore proxy settings, HTTP/3 and upstream mutual TLS need truthful unsupported states.

## Verification

`python3 scripts/test-proxy.py` configures, builds and runs the actual-process integration and
provenance tests. `--sanitize` instruments both our code and the linked dependencies. The dedicated
CI matrix uses native macOS, Linux and Windows builds; Windows uses MSVC. A cross-compiled Windows
binary proves compilation only, not Windows runtime behavior.

The local-origin suite proves streaming before completion, framing rejection, credential removal,
metadata privacy, half-closes in either direction, end-to-end HTTPS tunneling when the OpenSSL
fixture generator is available, IPv6, DNS fallback, cancellation, limits, file/pipe event sinks and
stalled observers. TLS tests use two independent temporary CAs to prove inspection, rejection of
wrong roots/names/expiry, SNI/Host scope, opaque bypass and bounded encrypted streaming. MCP tests
drive actual initialization, lifecycle, eviction/paging, malformed input and public Apple profile
export. No test changes machine trust. The optional benchmark compares direct/proxied requests in
three alternating rounds and excludes fixture/process startup. Record measurements in
[`performance.md`](performance.md); do not infer performance from sanitizer timings.

Remaining product work is OS-proxy/trust lease recovery, HTTP connection reuse, HTTP/2, the
extension control/data adapter and the Traffic/paired-iOS setup UI. The host CA broker, bounded
payload capture and session lifecycle described below are implemented.

## Host integration and payload reads (October 2026)

The user explicitly requested useful debugging payloads rather than metadata-only capture. The
current command surface is deliberately host-only: `MCPProxyTools` declares typed built-ins in
one group, `AgentToolCoordinator` routes them, and `ProxyCaptureService` owns session authority.
There is no extension provider bypass or new UI component. Remote execution hosts do not receive
these Mac-local tools. Public certificate exports are not CA private-key exports.

`ProxyProcess` has one serial worker per admitted session. Pipe I/O is nonblocking with 15-second
RPC deadlines and a 64 KiB reply ceiling; cancellation is checked every 100 ms. Four helpers,
including draining processes, and four pending operations per owner bound work. Lifecycle events
revoke the lease; ordinary stop retains history, while explicit release destroys it. Capture UUIDs
prefix app-facing flow IDs/cursors; a stale ID fails without stopping a current capture.

TLS start uses exact host scope, a Keychain CA and 24-hour non-CA leaf certificates. Release and
restart renews expired leaves under the same root. Upstream validation uses Mbed TLS chain,
hostname and time checks over an anchor snapshot; native CT/revocation and per-app macOS trust
constraints are not evaluated inside the helper. The helper
validates all identities before replying. The host verifies the exported root fingerprint before
publishing the public profile, removes staged leaf keys after that handshake, and removes its
private staging directory on normal teardown. A crash can leave short-lived leaf files in the
owner-only OS temporary directory; the reusable signing key never enters that directory. Existing
missing/invalid Keychain pairs are errors, never silently replaced. Trust setup uses the bundled
fingerprint-checking Python shortcut for the current Mac user or one explicit booted simulator;
no trust store is changed by starting capture. Physical iOS routing/delivery remains future work.

`capture.c` observes llhttp's body callbacks, so chunk framing is removed without guessing at
socket boundaries. Retained headers describe the original client request and origin response,
including duplicate fields; generated proxy errors have no fabricated origin capture. Failed or
cut-off messages keep their observed prefix and explicit completeness. Data stays in memory.
`capture_view.c` pages bytes, inflates gzip/deflate up to 1 MiB and reports limits. Exact captured
bytes remain accessible as base64. UTF-8 split across pages also uses base64 to avoid byte loss.
Common credential headers/query/form/JSON fields are masked by default; unstructured content is
reported as unredacted. Invalid/incomplete JSON requires an explicit raw read. Redaction walks
a validated JSON tree and its source in linear time, replacing only sensitive value spans.
Unrelated bytes, whitespace and large numeric IDs retain their original precision. MCP formatting has
a bounded response budget; a too-large detail suggests paged reads rather than killing capture.

The payload increment passed 50 actual-process tests (26 HTTP, 11 TLS, 13 MCP) and provenance on
macOS arm64 and Linux aarch64 with ASan/UBSan, plus a Windows x86_64 cross-build. The native
Windows/MSVC runtime lane remains unexecuted locally. A 3,000-exchange inspected TLS benchmark
with body capture and matched direct controls also completed. App-host validation uses a temporary,
in-memory CA and independent Security.framework trust evaluation, never the user's login Keychain
or installed trust. The signed, bundled helper passed the four app capture tests alongside 17
session-registry and 32 MCP wire tests (53 total), with a successful Xcode build/test exit.
Certificate evaluation runs off-main in both the production worker and its independent test;
running that verifier synchronously on the test host's main thread caused Security.framework
warnings and stalled test-host shutdown. Real user-Keychain persistence, trust installation and
physical iPhone setup are intentionally not exercised by automated tests.
