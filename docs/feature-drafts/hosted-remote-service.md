# Hosted remote service

> Status: native hosted transport and the stateless APNs alert broker are implemented; production
> deployment and the broader widget/subscription product remain gated below. Re-check vendor
> limits and prices before procurement.

## Decision

Operate one official Threading service for account identity, subscriptions, push delivery,
rendezvous, invitations and bounded widget/Live Activity state. Users must not need to run a
server, hold an APNs provider key or provision public tunnel infrastructure.

This does **not** remove Tailscale. The supported transports remain deliberately different:

- **Local** keeps working without an account, subscription or Internet service.
- **Tailscale** remains the private, peer-to-peer remote path. The user owns their tailnet and
  Threading incurs no tunnel bandwidth charge.
- **Hosted Direct** is the zero-install default: Threading's service introduces the peers, ICE
  sends ordinary traffic directly when possible, and Cloudflare TURN relays only failed direct
  paths.
- **Threading Relay** remains the compatibility path for browser sharing and an optional fallback.
- **Private + Sharing** may prefer Tailscale for the owner while using Threading Relay for a guest
  or as a fallback.

"No self-hosting" means no user-operated Threading backend. It does not mean that local use or
user-managed private networking becomes dependent on Threading's service.

### "Tunnel" means two different things

A Cloudflare/ngrok reverse tunnel is an always-available proxy route. The Mac opens the connection
outward, but every remote request and response continues through the vendor's edge. It does not
use the vendor only for discovery and then become peer-to-peer.

Tailscale behaves differently. Its coordination/DERP path introduces the peers and attempts NAT
traversal; after that, a successful direct connection sends application traffic from the iPhone
straight to the Mac. DERP or a peer relay carries the traffic only when a direct path cannot be
established.

The implemented zero-setup hosted mode selects routes in this order:

1. local network when appropriate;
2. Threading's built-in ICE/STUN direct path;
3. TURN or the managed reverse relay only when a direct path cannot be established.

Tailscale remains an optional private mode. When the user has selected it, Threading prefers that
route and uses the public hosted fallback only if the user has also enabled fallback.

The hosted service is still useful on a direct path for identity, endpoint discovery, push,
invitations, entitlements and widget snapshots. Those control-plane messages are tiny; terminal
bytes do not need to pass through it.

The transport is a separate native implementation, not a configuration of Cloudflare Tunnel or
ngrok. Both apps adapt its encrypted data channel back to a loopback TCP origin, so the existing
remote protocol, capability checks and bounded semantic payloads remain authoritative. A
one-time hosted QR credential also bootstraps a new phone without Tailscale or `cloudflared`;
after the Mac-issued owner bootstrap is redeemed, the temporary route is revoked and the phone
uses its durable device credential.

### Native transport result

`Packages/ThreadingPeerTransport` is linked into both application targets behind the existing
loopback remote interface.

| Check | Result |
| --- | --- |
| macOS native data channel | Passed: offer/answer, DTLS/SCTP open and bidirectional binary data |
| Physical iPhone | Passed on iPhone 16 Pro: 32 KiB verified Mac → iPhone → Mac, host → host UDP, no relay; 103 ms phone-side negotiation/data and 474 ms coordinated host round trip |
| iOS compatibility | Passed: the same sources compile against the arm64 iOS Simulator SDK and a signed device app builds and runs |
| Ordered-data fixture | 1,024 × 2 KiB messages plus a reverse reply, 0.39–0.42 seconds locally |
| Selected route | host → host over UDP; no relay |
| Trickle ICE and live STUN | Complete-SDP gathering hit the 15-second bound; bounded trickle signaling then gathered a Cloudflare server-reflexive candidate in 0.15 seconds |
| Wi-Fi → cellular physical path | Passed: 32 KiB verified bidirectionally with service-mediated one-use signaling and no TURN configured, proving application bytes used direct ICE rather than the signaling tunnel |
| Scaling bounds | 64 KiB/message, 2 MiB inbound/outbound bytes, 4,096 unread messages, 64 ICE candidates, 256 KiB SDP, eight pending sessions per host and a 30-second first-message deadline |
| First-install pairing | Passed in code: QR-carried rendezvous-only credential → ICE tunnel → one-time Mac bootstrap → durable device credential; no Tailscale or `cloudflared` dependency |
| Strict concurrency | Peer transport 17 tests (15 passed; opt-in live STUN and credentialed TURN probes skipped without environment credentials), shared remote protocol 87/87, Worker 37/37 plus deployment verifier 3/3 and local 100-object hibernation gate 1/1; macOS and physical-iOS targets build with complete concurrency checking |
| Binary input | Community Google WebRTC M151 XCFramework: about 28.4 MB macOS universal and 12.2 MB iOS device before app slicing/compression |

This is a **provisional direct-path pass**, not a complete NAT matrix. Bonjour advertised on the
test Mac but did not surface to the iPhone on the test access point, so the successful physical
LAN run used an isolated fixed-endpoint fallback; production cannot depend on multicast discovery.
A second run used a memory-bounded, token-protected rendezvous over a one-use HTTPS tunnel, with
the Mac on home Wi-Fi and iPhone on cellular. It passed without any configured TURN server. The
remaining network gate is a production TURN configuration forced to relay-only, additional NATs,
sleep/wake and repeated Wi-Fi/cellular handoff. Record selected-pair statistics before teardown,
setup time, reconnect time and bytes relayed. The community binary is exact-version and checksum
pinned with its upstream WebRTC source commit recorded in the
[dated dependency audit](../archive/audits/DEPENDENCY_AUDIT-2026-08-12.md); repeat that
provenance and advisory review on every update.

## Product contract

The paid service should make these features dependable without making Threading's server the
source of truth for a terminal session:

1. Sign in with Apple, account recovery and subscription entitlement.
2. Stable discovery of a user's Macs and their currently reachable transports.
3. Native APNs notifications while the iOS app is suspended.
4. Live Activity updates for a selected agent and WidgetKit refresh signals where the OS supports
   them.
5. Small, sanitized widget snapshots such as Usage, reset time, aggregate agent state and last
   update time.
6. Account-backed invitations and revocation.
7. A managed public relay when Tailscale is unavailable.

The Mac remains authoritative for sessions, permissions, usage evidence, files, provider
credentials and tool decisions. Losing the hosted service must not stop local agents or local
Threading UI.

## Service shape

```text
                                  safe event / widget snapshot
                         +----------------------------------------+
                         |                                        v
iPhone -- built-in ICE/STUN direct ----------------------------> Mac
   |                                                             ^
   +-- optional Tailscale ---------------------------------------+
   |                                                             |
   +-- TURN / managed tunnel fallback -- remote protocol --------+
   |
   +<-- APNs <-- Threading control plane <-- host event ----------+
   |
   +--> Threading control plane --> bounded widget snapshot
```

The control plane does not proxy ordinary terminal traffic. It consists of:

- **Identity:** Sign in with Apple authorization-code exchange, rotating app sessions, encrypted
  Apple refresh tokens, bounded daily grant validation, server-to-server revocation notifications
  and in-app account deletion.
- **Host and device registry:** D1-backed opaque host/device identifiers, independently scoped
  credentials, bounded active/retained rows, expiry and revocation state.
- **Rendezvous:** stable endpoint metadata and a short-lived answer to "how can this paired device
  reach this Mac?" It never returns an authority broader than the Mac-issued device capability.
- **TURN provisioner:** Cloudflare Realtime credentials are generated on demand from a Worker-only
  long-lived key. Clients never receive the provisioning secret.
- **Push broker:** implemented for iOS alerts as one host-authenticated, size-capped Worker call.
  The Mac keeps the authorized subscription and forwards one target/event; the Worker stores
  neither device token nor notification content, signs a cached APNs provider JWT, and returns
  bounded delivery diagnostics. Stable IDs, hashed collapse identifiers and expiry make retries
  harmless. ActivityKit and future WidgetKit tokens remain later slices. Firebase is not required.
- **Widget snapshot store:** an opt-in, size-capped semantic projection with a generation number
  and observation time. A widget reads this store rather than activating the public relay. Stale
  data remains visibly stale when the Mac is sleeping.
- **Invitation metadata:** inviter, recipient, host/session opaque ID, expiry and acceptance state.
  The Mac still creates and revokes the actual scoped capability.
- **Operations:** abuse limits, cost budgets, structured metadata-only logs, deletion/export,
  service status and support tooling.

The implemented transport control plane is a Cloudflare Worker, D1 database and one hibernating
Durable Object per Mac. The native clients depend on one narrow service interface so identity,
TURN or the hosting vendor can still be replaced independently. Alert push is implemented;
subscriptions, invitation metadata and widget snapshots are later service slices, not hidden
dependencies of direct access.

### Stored data boundary

The service may store account and entitlement identifiers, host/device public metadata, APNs
tokens, invitation membership, tunnel credential references, delivery results and a bounded
widget/Live Activity projection chosen for remote display.

It must not store provider API credentials, raw transcripts, prompts, terminal output, attachments,
filesystem paths, browser pixels or permission evidence. WebRTC encrypts the peer path end to end;
the service sees signaling metadata and, only when TURN is selected, forwards encrypted packets.

## Cost model

All figures are USD per month, use public list prices observed on 2026-08-12, exclude tax/VAT and
round only in the summary. They are planning estimates, not vendor quotes.

### What is actually billed

| Bucket | Public list price and implemented behavior |
| --- | --- |
| Worker | $5 monthly minimum includes 10 million requests and 30 million CPU-ms; excess is $0.30/million requests and $0.02/million CPU-ms |
| Hibernating rendezvous objects | Included 1 million requests and 400,000 GB-s; excess requests are $0.15/million and duration is $12.50/million GB-s |
| D1 identity/credential rows | Included 25 billion rows read, 50 million written and 5 GB stored on the paid plan; the schema is indexed and every owner collection is capped |
| STUN/direct traffic | Cloudflare STUN is free; application bytes on a successful direct ICE path do not enter the service |
| TURN fallback | First 1,000 billable GB each month are free, then $0.05/GB sent from TURN to clients, including TURN overhead |
| Tailscale/local traffic | $0 to Threading per GB; these paths do not enter the hosted service |
| Push/widgets | APNs alert brokerage is implemented and has no Apple per-message line item; its bounded Worker calls use the same included pool. Widgets/Live Activities remain later slices. |
| Operations | Logs, alerts, backup exercises, status/support systems and human support need a separate budget |

The Durable Object uses WebSocket hibernation and automatic ping/pong. An idle signed-in Mac
therefore does not accrue wall-clock duration merely because its signaling socket remains open.
Cloudflare bills the initial WebSocket upgrade as a request and applies a 20:1 ratio to incoming
WebSocket messages for Durable Object request billing. The data channel closes its short-lived
signaling sockets after negotiation; it does not send terminal frames through the object.
Scheduled Apple grant validation adds at most one outbound Apple request per stored client grant
per day, plus bounded D1 claim/result updates. At 10,000 users and the two native client IDs this
is about 600,000 validations per month, still within the listed Worker/D1 pools; Apple publishes
no per-validation charge.

### Working budget

The table below is intentionally based on **bytes**, not a guessed number of connected hours. It
assumes 80% of remote bytes go direct and 20% require TURN, then adds 15% to the relayed portion
for protocol overhead. “Remote GB/user” is total bidirectional application traffic before that
split. Replace both assumptions with Realtime analytics from each rollout gate.

| Scenario | Hosted users | Remote GB/user | Estimated TURN billable GB | TURN charge | Cloudflare metered subtotal |
| --- | ---: | ---: | ---: | ---: | ---: |
| Pilot | 100 | 2 | 46 | $0 | **about $5** |
| Growth | 1,000 | 5 | 1,150 | $7.50 | **about $12.50** |
| Scale | 10,000 | 10 | 23,000 | $1,100 | **about $1,105** |

At the scale row, even an intentionally busy signaling estimate—30 negotiations per user per
month and 30 inbound signaling messages per negotiation—lands around 1.06 million Durable Object
requests after the 20:1 message ratio. That is only about one cent above the included request
pool. Worker requests remain below their included 10 million, and bounded D1 metadata remains far
below its paid-plan inclusions. TURN is therefore the cost driver, as intended.

Use this formula for the live forecast:

```text
turn_billable_GB = total_remote_GB × observed_TURN_byte_share
turn_cost = max(0, turn_billable_GB - 1,000) × $0.05
hosted_subtotal = $5 + turn_cost + measured Worker/DO/D1 overages
```

An all-TURN stress ceiling under the same traffic assumptions and 15% overhead is $0 for the
100-user pilot, about $237.50 at 1,000 users, and about $5,700 at 10,000 users, plus the $5 Worker
minimum. That is a failure/restrictive-network ceiling, not the expected route mix.

### Sensitivities that can break the model

- **Background polling:** it manufactures requests, wakes radios and may keep a rendezvous object
  active. Do not health-check every host or let widgets poll the Mac. Use event-driven state and
  serve widgets from a bounded snapshot store.
- **Mobile catalogue invalidations:** the former three-second iOS poll produced about 24,000
  requests over 20 visible hours. The implemented path now uses the authenticated event socket,
  scoped O(changed) session deltas, coalesced structural refreshes and 1–60 second recovery only
  after a socket failure. Preserve that zero-poll healthy state for widgets and future surfaces.
- **Heavy transfer:** after the shared 1 TB allowance, every additional 20 TURN GB costs about $1.
  A transfer-heavy user is cheap while direct and materially different while relayed, so fair-use
  decisions must use relayed bytes rather than total session time.
- **Broken hibernation:** accepting a socket with the non-hibernating API would turn idle presence
  into wall-clock Durable Object duration. Preserve `acceptWebSocket`, auto-response ping/pong and
  a test/metric that catches objects remaining active without application messages.
- **Attachments and browser snapshots:** the existing 24 MiB response ceiling bounds one request,
  not monthly transfer. Preserve it and add per-account usage metering without logging content.
- **Logs:** terminal or payload logging would create both a privacy problem and a potentially
  unbounded storage bill. Log identifiers, sizes, timing and result categories only, with short
  retention.

### Unit economics

Under the expected 20% TURN-byte assumption, the 10,000-user infrastructure subtotal is roughly
$0.11/user before observability and support. The all-TURN ceiling is about $0.57/user. At a
hypothetical $5 monthly subscription and a 15% App Store commission, proceeds before tax/refunds
are $4.25. The service margin is therefore driven more by support, refunds and pathological relay
use than by normal signaling. Pricing still needs observed p50/p90/p99 TURN bytes, not the average
alone.

The Apple Developer Program fee, tax/VAT, payment refunds, legal/DPA work, security review,
engineering and human support are outside the infrastructure totals. Apple's current Developer
Program fee is $99/year. These costs still belong in the business forecast.

## Vendor decision

| Option | Advantage | Blocking issue | Recommendation |
| --- | --- | --- | --- |
| Built-in ICE/STUN with TURN fallback | Most successful sessions send bytes directly; lower latency, relay cost and vendor visibility | Production TURN and broader recovery matrix remain | **Implemented as the native owner-device default** |
| Cloudflare Named Tunnels | Reuses the legacy relay process and browser-compatible protocol | Every application byte remains proxied and fleet limits/pricing need separate review | Keep only as a compatibility fallback, not the native owner default |
| Build a Threading relay | Full control; commodity egress can be cheaper | We would own tunnel protocol, routing, abuse, upgrades, availability, backpressure and on-call security | Reject for v1 even though raw VM/egress prices look cheaper |

Before a large rollout, procurement still needs written answers on Realtime and Worker limits, EU
routing/data processing, abuse handling, support SLA and volume price.

## Release sequence

1. **Completed — native transport:** bounded WebRTC data channel, stream multiplexer, loopback
   adapters, first-install hosted pairing, credential renewal/revocation, reconnect and background
   teardown in macOS and iOS.
2. **Completed — control-plane code:** Sign in with Apple, host/device enrollment, hibernating
   signaling, TURN provisioning, replay protection, race-safe quotas, Worker-native abuse limits,
   daily Apple grant validation, account deletion and scheduled bounded cleanup.
3. **Deployment gate:** apply the Terraform/OpenTofu D1/R2/Queue/WAF resources, create Realtime
   TURN and Apple keys, install independent secrets,
   attach `remote.threading.codes`, confirm the rate-limit namespaces and Apple server-to-server
   notifications, then run the guarded deploy. It tests before applying ordered D1 migrations,
   deploys, and requires the custom-domain readiness probe to pass. Deployment renders D1's
   Terraform output into a temporary Wrangler config; the checked-in placeholder remains inert.
4. **Network release gate:** force TURN-only, then cover representative home/carrier NATs, blocked
   UDP, IPv4/IPv6, VPN, sleep/wake and repeated Wi-Fi/cellular handoff.
5. **App release gate:** complete Apple encryption-export determination, signed archive/device
   tests, dependency/advisory refresh and account deletion/revocation verification against production.
6. **Later product slices:** widgets/Live Activities, subscriptions and
   account-backed sharing. None may turn the service into a transcript store or reintroduce
   healthy-state polling; mobile session state is already event-driven.
7. **Rollout:** internal, 100, 500 and 1,000-host gates. Track direct/TURN share, setup/reconnect
   time, encrypted bytes relayed, push latency and service-induced wakeups.

## Performance, failure and test requirements

- Apply the repository scaling gate to accounts, hosts, devices, invitations, tokens, sessions,
  pending pushes and widget snapshots. Every query is owner-scoped, paginated and capped.
- Coalesce high-frequency agent changes before sending safe events. One streaming token must not
  become one server request, database write, push or widget update.
- Presence is connection-derived; do not write a D1 heartbeat on a short interval.
- Give push events stable IDs, collapse keys and short expiries. Duplicate or reordered delivery
  must be harmless.
- Revoke a host, device or tunnel credential independently and prove that cached rendezvous cannot
  broaden or revive authority.
- Bound APNs/activity/widget token counts per account and rotate them transactionally.
- Load-test at least 10,000 simultaneously connected host signaling sockets and slow/hostile clients with
  the same frame, connection and high-water limits as production.
  The checked-in local gate covers 100 separate hibernating objects. Cloudflare's local Vitest
  helper overflows internally before 1,000 objects, so the unchanged full gate belongs on the
  provisioned staging account and is not considered passed by the local result.
- A control-plane outage leaves local agents and Tailscale sessions working. Managed relay and
  push show a clear degraded/offline state; no fallback opens a listening interface.
- Budget alerts must fire before 50%, 80% and 100% of the monthly relay and control-plane budget.
- Test account deletion, invitation expiry, device loss, subscription lapse and restored purchase
  without retaining remote authority or private payloads.

## Research sources

- [Cloudflare Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)
- [Cloudflare Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/)
- [Cloudflare D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/)
- [Cloudflare Workers Rate Limiting API](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/)
- [Cloudflare Realtime TURN pricing](https://developers.cloudflare.com/realtime/turn/faq/)
- [Cloudflare Tunnel overview](https://developers.cloudflare.com/tunnel/)
- [IETF ICE specification](https://datatracker.ietf.org/doc/html/rfc8445)
- [IETF TURN specification](https://datatracker.ietf.org/doc/html/rfc8656)
- [IETF WebRTC data channels](https://datatracker.ietf.org/doc/rfc8831/)
- [Apple Developer Program enrollment and fee](https://developer.apple.com/help/account/membership/program-enrollment/)
- [Apple Small Business Program](https://developer.apple.com/app-store/small-business-program/)
- [Apple TN3194: account deletion and token lifecycle](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple)
- [Apple Sign in with Apple token validation](https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens)
