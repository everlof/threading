# threading-proxyd

Standalone C11 development proxy for Threading, with a CMake build independent of Xcode.
It supports TLS inspection, request/response capture and native stdio MCP. Threading's Xcode
build bundles it; the app's typed `traffic_*` tools own one helper per capture session.
The portable executable also runs independently on Linux and Windows.

```sh
python3 scripts/test-proxy.py
.build/proxy/threading-proxyd --port 8080
curl --noproxy '' --proxy http://127.0.0.1:8080 http://example.com/
curl --noproxy '' --proxy http://127.0.0.1:8080 https://example.com/
```

The helper prints its actual loopback port in a versioned JSONL `ready` event. With no `--port`,
it chooses an ephemeral port. The HTTPS example uses an opaque CONNECT tunnel and keeps the
client's existing certificate validation. Inspection requires explicit per-host leaf identities.

On Windows use `python scripts/test-proxy.py` from a Visual Studio development environment;
the multi-configuration binary is `.build/proxy/RelWithDebInfo/threading-proxyd.exe`. CMake 3.25+,
a C11 compiler and Python 3.9+ are required; tests also require an OpenSSL CLI for temporary
certificates. The full cross-platform build can also be run directly:

```sh
cmake -S Targets/ProxyHost -B .build/proxy -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build .build/proxy --config RelWithDebInfo --parallel 4
ctest --test-dir .build/proxy -C RelWithDebInfo --output-on-failure
```

Dependency source archives are retained and hash checked. Normal builds make no network requests
and need neither a Python runtime for the helper nor a Node runtime for the HTTP parser.

## Supported protocol

- Explicit HTTP proxy requests with an absolute `http://` target, IPv4/IPv6 destinations and DNS
  address fallback (at most eight candidates examined).
- HTTP/1.0 and HTTP/1.1 responses; fixed-length, chunked and close-delimited response bodies;
  fixed-length/chunked uploads; HEAD, 204/304 and bounded informational responses including
  `100 Continue`. Bodies stream as they arrive.
- CONNECT with an explicit port, including early tunnel bytes and independent TCP half-closes.
- One HTTP exchange per downstream connection. Request and final response explicitly say
  `Connection: close`; pipelined surplus is discarded and never forwarded as another request.
- Hop-by-hop headers and proxy credentials are removed. Host is regenerated from the absolute
  target. End-to-end authorization/cookies are forwarded but never emitted as capture metadata.
- Strict framing validation, header/connection budgets, async DNS, timeout and cancellation,
  queue high/low watermarks, and independent bounded event delivery.

HTTP/2 inspection, HTTP/3, reverse proxying, WebSocket upgrades, nonempty chunked
trailers, transfer codings other than `chunked`, replay and mutation are not implemented.
CONNECT can carry protocols the helper does not inspect. Unsupported request forms fail before
forwarding; a malformed or unsupported body discovered after streaming begins terminates that
exchange and emits an error. Already forwarded bytes cannot be recalled.

## TLS inspection

```sh
.build/proxy/threading-proxyd --port 8080 \
  --upstream-ca /absolute/path/upstream-trust-bundle.pem \
  --tls-identity api.example.com /absolute/path/leaf.pem /absolute/path/leaf.key \
  --inspection-ca /absolute/path/public-development-root.pem
```

The host supplies up to 16 lowercase exact-host leaf identities, each with a single matching
DNS/IP SAN, matching private key and validity window of at most seven days. CA identities,
wildcards and multi-host leaves are rejected. The helper never receives a root signing key.
The optional **public** inspection CA must validate every leaf; it enables public certificate
export. Upstream trust is a separate explicit bundle. The host should lease identity files
privately and remove them when the helper exits.

Selected CONNECT hosts use TLS 1.2/1.3 on both legs. The upstream chain, hostname and dates must
validate before CONNECT succeeds. SNI and inner HTTP Host cannot widen the CONNECT scope. ALPN
advertises HTTP/1.1 only. Other hosts keep opaque tunnels. There is no skip-verification switch,
pinning bypass, client-certificate forwarding, or automatic OS trust-store import. The
single-exchange and protocol limits above also apply to inspected TLS.

## MCP

Use `--mcp` instead of `--stdio`, with the same TLS launch options. It implements newline-delimited
JSON-RPC MCP stdio, version `2025-11-25`, and starts idle. Initialize, then call `traffic_start`
to obtain its loopback endpoint and configure the client for it.

| Tool | Effect |
|---|---|
| `traffic_status` | Listener, fixed TLS hosts, public root fingerprint and history size |
| `traffic_start`, `traffic_stop` | Start/stop this process's listener and connections |
| `traffic_list` | Page completed flow metadata with `after` and `limit` (maximum 20) |
| `traffic_get` | URL/target, original request and response headers, sizes and completeness |
| `traffic_body` | Page request/response payload bytes; gzip/deflate preview or exact captured bytes |
| `traffic_headers` | Page one full original header value, or a long request target |
| `traffic_clear` | Erase completed exchanges and retained payloads |
| `traffic_certificate` | Public DER as base64, SHA-256 fingerprint and unsigned Apple `.mobileconfig` |

Capture retains original client request and final origin response headers and transfer-decoded
body prefixes, including error responses. Each body defaults to 64 KiB; `--body-limit` accepts
1–1048576. Active capture buffers and retained history each have a 16 MiB byte budget, in addition
to the 128-flow history ceiling. Large bodies continue forwarding after capture fills.
`complete`, `body_truncated`, `capture_truncated`, and `decode_truncated` distinguish framing,
retention and content-decoding limits. History evicts oldest exchanges and reports missing IDs.

`traffic_get` masks common credential headers and query parameters by default. `traffic_body`
uses `side: "request" | "response"`, byte `offset`, and `limit` up to 4096. `decode: true` expands
gzip/deflate up to 1 MiB; chunk framing has already been removed by llhttp. JSON and form views
mask common credential keys; unstructured text/binary is explicitly **not** automatically
redacted. Invalid/incomplete JSON refuses a redacted view instead of leaking a partial secret.
Use `redact: false` when exact values are needed, and `decode: false, redact: false` for lossless
base64 of the captured representation. Page offsets refer to that selected view. A UTF-8
character split across pages uses base64, preserving every byte. No payloads are written to disk.
`traffic_headers` uses the field's zero-based `index`; `index == header_count` pages the request
target. Common credential headers are masked unless `redact: false` is explicit.

Standalone IDs are decimal strings, monotonic across stop/start/clear for the process lifetime.
Threading prefixes IDs/cursors with a capture UUID, preventing stale references after release.
Captured network content is untrusted data, never instructions.
Control input is capped at 64 KiB and depth 32; responses at 64 KiB with a 512 KiB/128-message
queue. Output failure/overflow ends the MCP lease instead of silently losing replies. EOF closes
the listener and all connections. MCP cannot widen TLS scope, change trust or configure OS proxies.

Example external MCP configuration (substitute absolute paths):

```json
{"mcpServers":{"traffic":{"command":"/absolute/path/threading-proxyd","args":["--mcp","--upstream-ca","/absolute/path/upstream.pem","--tls-identity","api.example.com","/absolute/path/leaf.pem","/absolute/path/leaf.key","--inspection-ca","/absolute/path/public-root.pem"]}}}
```

In Threading, call `traffic_start({"hosts":["api.example.com"]})`. The host generates 24-hour,
single-host leaf identities using its non-exportable Keychain CA key and exports macOS trust
anchors (or an explicitly supplied `upstream_ca` PEM). `hosts: []` enables HTTP capture with
opaque HTTPS tunnels. Client proxy configuration remains explicit. Start/status/certificate
results include public `.cer`/`.mobileconfig` paths and targeted Mac/simulator setup argv.
`traffic_stop({"release":true})` erases history and releases the helper, allowing another scope.
Ordinary stop keeps the history. Session end, archival, removal, project move and app quit revoke
the lease. Four helpers (including draining workers) and four pending calls per owner are admitted.
A native Traffic workbench and paired iOS certificate-delivery UI are not implemented yet.

## Apple certificate setup

Decode `traffic_certificate.certificate_der_base64` into `public-root.cer`, or save its
`apple_mobileconfig` string as a `.mobileconfig` file. Compare its fingerprint with the owning
host. The profile contains only the public CA and remains removable.

```sh
# Print the exact plan. Add --apply to perform the chosen trust change.
python3 Targets/ProxyHost/tools/apple_certificate.py public-root.cer --sha256 EXPECTED_SHA256 --target macos
python3 Targets/ProxyHost/tools/apple_certificate.py public-root.cer --sha256 EXPECTED_SHA256 --target simulator --udid EXPLICIT_UDID
# macOS: remove user trust (the certificate remains in the keychain).
python3 Targets/ProxyHost/tools/apple_certificate.py public-root.cer --sha256 EXPECTED_SHA256 --target macos --action remove-trust
```

The shortcut uses user-domain SSL trust on macOS, or `simctl keychain <UDID> add-root-cert` for
one available, already-booted simulator. It does not restart/reset devices or set network proxies.
Actual trust mutations are opt-in and are not exercised by the test suite.

On iPhone, install the profile, then enable full trust under Settings → General → About →
Certificate Trust Settings. Delivery through ThreadingMobile and a reachable, authorized device
proxy route remain host integration work; this helper binds loopback only. See the
[Apple integration design](../../docs/architecture/proxy-engine.md#apple-onboarding).

## Process contract

`--stdio` makes the inherited stdin pipe the parent lifetime lease. EOF or the exact `stop\n`
command stops accepting and closes all active connections. SIGINT also stops the helper;
POSIX hosts additionally use SIGTERM. Standalone mode leaves stdin alone. No daemon registration,
system proxy changes, certificate trust changes, privileged capture or persistent traffic store
are performed.

Outside MCP mode, stdout is version 1 JSONL with records smaller than 1 KiB. The `ready` event states
the actual capabilities; one `flow` event is attempted when an exchange/tunnel closes. Its fields:

| Field | Meaning |
|---|---|
| `id` | Monotonic decimal string, scoped to this process generation |
| `method`, `host`, `port` | Validated routing metadata; hostname itself may still be sensitive |
| `status` | Final HTTP/CONNECT status, helper error status, or zero if none was available |
| `tunnel` | Opaque CONNECT; never a claim that TLS was decrypted |
| `tls_inspected`, `tls_version` | Whether the client TLS handshake completed; negotiated upstream TLS version |
| `client_bytes`, `upstream_bytes` | Bytes observed on each incoming socket, including framing |
| `duration_ms` | Monotonic time from accept through close initiation |
| `peak_pending_bytes` | Largest sum of owned socket-write payloads for this connection |
| `result` | `complete` or a fixed error/lifecycle code, never a raw upstream error string |
| `dropped_events` | Cumulative output-queue overflow count before this event |

URLs, paths, queries, header values and body bytes never enter this event stream. Events are
best effort: at most 128 records are pending, a slow/disconnected observer cannot block forwarding,
and shutdown may discard pending events. This is an observation protocol, not a lossless audit
log or the future extension companion protocol. File redirection uses bounded asynchronous writes;
pipe and terminal output use libuv streams. stderr contains startup/lifecycle failures only.

`--max-connections` can lower the hard 128-connection ceiling. `--idle-timeout-ms` accepts
100–300000 ms (default 60000); request headers and TLS handshakes also have a fixed 15-second total
deadline. Event policy and constants are in `src/proxy_limits.h`.

## Ownership and verification

`http.c` owns parsing/routing policy and sees only bounded byte spans. `proxy.c` owns connections
on a supplied libuv worker loop. It emits borrowed flow/capture values through a nonblocking
callback. The CLI composes that engine with the bounded JSONL writer. `platform.c` owns only
process signal differences; libuv owns socket, polling, DNS and stdio portability. Future system
capture and certificate trust belong to platform-specific hosts, not the parser or relay.

See [the architecture contract](../../docs/architecture/proxy-engine.md) for scaling and future
host/extension integration, and [third-party notices](THIRD_PARTY_NOTICES.md) for licenses and
distribution. The helper uses the repository's GPLv3 license.

```sh
python3 scripts/test-proxy.py --sanitize
python3 Targets/ProxyHost/tests/benchmark.py .build/proxy/threading-proxyd
python3 Targets/ProxyHost/tests/tls_benchmark.py .build/proxy/threading-proxyd
THREADING_PROXY_STRESS_FLOWS=10000 python3 Targets/ProxyHost/tests/integration.py .build/proxy/threading-proxyd
cmake --install .build/proxy --config RelWithDebInfo --prefix .build/proxy-install
```

The integration suite drives the actual executable against local origins: streaming, framing
ambiguities, IPv6, DNS fallback, tunnel half-closes, cancellation, timeout, admission, large bodies
and an observer that stops consuming. TLS/MCP tests generate temporary independent CAs, verify
inspection and failure paths, exercise bounded history/control, and parse the public Apple profile.
They never change machine trust. The provenance test checks
every archive and retained notice offline. The CI matrix runs macOS, Linux and Windows; Unix lanes
also instrument the helper and dependencies with address/undefined-behavior sanitizers.

Install output includes the executable, notices and complete retained source tree. Keep those
together when distributing it. Threading's Xcode build embeds the signed helper, its complete
source tree and third-party notices in the application bundle.
