# Hosted remote service

> Status: draft, researched 2026-08-11. This is a product and architecture proposal, not an
> implementation commitment. Re-check vendor limits and prices before procurement.

## Decision

Operate one official Threading service for account identity, subscriptions, push delivery,
rendezvous, invitations and bounded widget/Live Activity state. Users must not need to run a
server, hold an APNs provider key or provision public tunnel infrastructure.

This does **not** remove Tailscale. The supported transports remain deliberately different:

- **Local** keeps working without an account, subscription or Internet service.
- **Tailscale** remains the private, peer-to-peer remote path. The user owns their tailnet and
  Threading incurs no tunnel bandwidth charge.
- **Threading Relay** is the operated public fallback for people who cannot or do not want to use
  Tailscale. It receives a stable endpoint and is included in the hosted subscription subject to
  fair-use limits.
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

The zero-setup hosted mode should therefore select routes in this order:

1. local network when appropriate;
2. Threading's built-in ICE/STUN direct path;
3. TURN or the managed reverse relay only when a direct path cannot be established.

Tailscale remains an optional private mode. When the user has selected it, Threading prefers that
route and uses the public hosted fallback only if the user has also enabled fallback.

The hosted service is still useful on a direct path for identity, endpoint discovery, push,
invitations, entitlements and widget snapshots. Those control-plane messages are tiny; terminal
bytes do not need to pass through it.

Before committing to a reverse-tunnel vendor, run a transport spike for a Threading-owned
ICE/STUN direct path with a TURN-style relay fallback. That would give users who do not install
Tailscale the same "rendezvous, then direct" shape. It is a separate transport implementation,
not a configuration of Cloudflare Tunnel or ngrok. If it preserves the existing security and
semantic protocol, survives network changes and produces a strong direct-connection rate in a
representative network matrix, it should become the default hosted transport; managed reverse
tunneling then remains a launch fallback rather than the primary data path.

### Native transport spike: first result

The isolated `Packages/ThreadingPeerTransport` spike passed its first gate on 2026-08-11. It is
not linked into either shipping app yet.

| Check | Result |
| --- | --- |
| macOS native data channel | Passed: offer/answer, DTLS/SCTP open and bidirectional binary data |
| Physical iPhone | Passed on iPhone 16 Pro: 32 KiB verified Mac → iPhone → Mac, host → host UDP, no relay; 103 ms phone-side negotiation/data and 474 ms coordinated host round trip |
| iOS compatibility | Passed: the same sources compile against the arm64 iOS Simulator SDK and a signed device app builds and runs |
| Ordered-data fixture | 1,024 × 2 KiB messages plus a reverse reply, 0.39–0.42 seconds locally |
| Selected route | host → host over UDP; no relay |
| Trickle ICE and live STUN | Complete-SDP gathering hit the 15-second bound; bounded trickle signaling then gathered a Cloudflare server-reflexive candidate in 0.15 seconds |
| Wi-Fi → cellular physical path | Passed: 32 KiB verified bidirectionally with service-mediated one-use signaling and no TURN configured, proving application bytes used direct ICE rather than the signaling tunnel |
| Scaling bounds | 64 KiB/message, 2 MiB inbound/outbound bytes, 4,096 unread messages, 64 ICE candidates and 256 KiB SDP |
| Strict concurrency | Package builds and five deterministic tests pass with complete concurrency checking; the live STUN probe is opt-in |
| Binary input | Community Google WebRTC M151 XCFramework: about 28.4 MB macOS universal and 12.2 MB iOS device before app slicing/compression |

This is a **provisional direct-path pass**, not a complete NAT matrix. Bonjour advertised on the
test Mac but did not surface to the iPhone on the test access point, so the successful physical
LAN run used an isolated fixed-endpoint fallback; production cannot depend on multicast discovery.
A second run used a memory-bounded, token-protected rendezvous over a one-use HTTPS tunnel, with
the Mac on home Wi-Fi and iPhone on cellular. It passed without any configured TURN server. The
next gate is a TURN configuration forced to relay-only, additional NATs, sleep/wake and
Wi-Fi/cellular handoff. Record selected-pair statistics before teardown, setup time, reconnect time
and bytes relayed. The community binary also needs either a reproducible build pipeline or
replacement before production adoption.

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

- **Identity and entitlement:** Firebase Authentication with Sign in with Apple, plus StoreKit 2
  receipts and App Store Server Notifications.
- **Host and device registry:** opaque host/device identifiers, public keys, protocol version,
  enabled transports, last successful registration and revocation state.
- **Rendezvous:** stable endpoint metadata and a short-lived answer to "how can this paired device
  reach this Mac?" It never returns an authority broader than the Mac-issued device capability.
- **Tunnel provisioner:** one least-privilege tunnel credential per Mac, kept in that Mac's
  Keychain and revocable without touching any other host.
- **Push broker:** APNs device, ActivityKit and future WidgetKit tokens; deduplication, collapse
  identifiers, expiry and bounded delivery diagnostics. The existing native APNs path should move
  from the Mac to this service. Firebase Cloud Messaging is not required: a direct APNs provider
  supports all three Apple token types without adding a second registration model.
- **Widget snapshot store:** an opt-in, size-capped semantic projection with a generation number
  and observation time. A widget reads this store rather than activating the public relay. Stale
  data remains visibly stale when the Mac is sleeping.
- **Invitation metadata:** inviter, recipient, host/session opaque ID, expiry and acceptance state.
  The Mac still creates and revokes the actual scoped capability.
- **Operations:** abuse limits, cost budgets, structured metadata-only logs, deletion/export,
  service status and support tooling.

A Firebase/Google Cloud control plane is the smallest first implementation because Authentication,
App Check, Firestore and serverless execution cover the low-volume metadata path. Keep the service
API behind one narrow repository interface so the tunnel vendor and even the control-plane vendor
can be replaced independently.

### Stored data boundary

The service may store account and entitlement identifiers, host/device public metadata, APNs
tokens, invitation membership, tunnel credential references, delivery results and a bounded
widget/Live Activity projection chosen for remote display.

It must not store provider API credentials, raw transcripts, prompts, terminal output, attachments,
filesystem paths, browser pixels or permission evidence. The public tunnel vendor carries remote
protocol traffic; under the current tunnel architecture it may terminate TLS. Before a paid launch,
either document that vendor trust clearly or add application-layer end-to-end encryption between a
paired device and its Mac.

## Cost model

All figures are USD per month, use public list prices observed on 2026-08-11, exclude tax/VAT and
round only in the summary. They are planning estimates, not vendor quotes.

### Cost buckets

| Bucket | What drives it | Expected shape |
| --- | --- | --- |
| Identity, metadata and push | active accounts, registrations, safe events | Near free at first; low tens to hundreds of dollars at 10,000 users |
| Tailscale transport | the user's tailnet | $0 to Threading per GB |
| Managed public relay | active endpoint-hours, transfer and requests | The principal variable infrastructure cost |
| Widget snapshots | bounded writes and reads, not tunnel traffic | Small Firestore/serverless usage |
| Operations | logs, alerts, status/support systems | A budgeted reserve; human support is not included |
| App Store | subscription proceeds | 15% if eligible for Apple's Small Business Program; not a server bill, but material to margin |

Firebase lists Authentication for most providers, App Check, Cloud Messaging and Crashlytics as
no-cost products. Firestore's current free tier includes 50,000 reads and 20,000 writes per day,
1 GiB storage and 10 GiB monthly egress. Beyond that, default list prices begin at $0.03 per
100,000 reads and $0.09 per 100,000 writes. A metadata-only implementation therefore does not
need a meaningful database budget at pilot scale. Reserve money for serverless compute, logging
and mistakes rather than designing around an exact $0 estimate.

### Conservative public-relay ceiling

This section prices the fallback path when it actually proxies traffic. It is not the expected
cost for a Tailscale-direct user.

Cloudflare Named Tunnels are the smallest change from the current `cloudflared` implementation and
have no separately listed tunnel-transfer fee. However, Cloudflare documents a default limit of
1,000 tunnels and 1,000 routes per account. That is sufficient for a private beta, not an
unqualified scale plan. We need a written Enterprise limit increase and price before relying on it
for launch.

Until that quote exists, use ngrok's public pay-as-you-go prices as a conservative, independently
calculable ceiling. Current public rates are:

- $20 monthly with $20 of included usage;
- $0.02 per active endpoint-hour; an hour becomes active only when traffic reaches the agent;
- $0.01 per active hour for a custom domain;
- $0.10 per GB after 5 GB monthly;
- $1 per 100,000 HTTPS requests after 100,000 monthly.

The estimate conservatively charges the custom-domain hour per active host. An enterprise Device
Gateway contract may price a wildcard or device fleet differently; ngrok explicitly offers
per-device/per-customer contracts.

| Scenario | Public-relay Macs | Assumption per Mac | Relay estimate | Control plane + operations reserve | Total infrastructure |
| --- | ---: | --- | ---: | ---: | ---: |
| Pilot | 100 | 20 active h, 1 GB, 2,000 requests | $70.50 | $25–75 | **$96–146** |
| Growth | 1,000 | 20 active h, 2 GB, 3,000 requests | $828.50 | $50–200 | **$879–1,029** |
| Scale | 10,000 | 25 active h, 3 GB, 5,000 requests | $10,998.50 | $250–750 | **$11,249–11,749** |

The relay formula is:

```text
max(
  $20 monthly minimum,
  active host-hours × ($0.02 endpoint + $0.01 custom domain)
    + max(0, outbound GB - 5) × $0.10
    + max(0, HTTPS requests - 100,000) / 100,000 × $1
)
```

These all-relay scenarios are intentionally pessimistic. If 30% of 1,000 hosted users use the
managed relay and the rest use Tailscale/local access, the same model produces about **$248** of
relay usage and **$298–448 total infrastructure**, or roughly **$0.30–0.45 per hosted user**.
At 10,000 hosted users and 30% relay usage, it is about **$3,299** for relay and **$3,549–4,049
total**, around **$0.35–0.40 per hosted user**.

### Sensitivities that can break the model

- **Background polling:** one request in an otherwise idle hour can create a whole active
  endpoint-hour. Do not health-check every public host or let widgets poll the Mac. Observe tunnel
  agent sessions, use event-driven state and serve widgets from the bounded snapshot store.
- **The current three-second iOS dashboard poll:** at 20 visible hours it produces about 24,000
  requests per user. Before a paid rollout, replace session-catalogue polling with deltas on the
  existing authenticated event socket. This is a battery and scalability requirement even where
  request charges remain smaller than endpoint-hour charges.
- **Heavy transfer:** every additional 10 GB through ngrok's self-serve tier costs about $1. A
  user moving 20 GB/month adds roughly $2 before request/hour costs. The subscription needs a
  visible fair-use transfer allowance or a higher tier for sustained heavy use.
- **Always-hot endpoints:** 720 active hours per host would cost $21.60/month in endpoint and
  custom-domain hours before a byte of transfer. An idle agent may stay connected, but no service
  component should manufacture traffic merely to prove it is alive.
- **Attachments and browser snapshots:** the existing 24 MiB response ceiling bounds one request,
  not monthly transfer. Preserve it and add per-account usage metering without logging content.
- **Logs:** terminal or payload logging would create both a privacy problem and a potentially
  unbounded storage bill. Log identifiers, sizes, timing and result categories only, with short
  retention.

### Unit economics

Under the all-relay ceiling, ordinary infrastructure is roughly $0.90–$1.20 per active relay Mac
at 1,000–10,000 scale. At a hypothetical $5 monthly subscription and a 15% App Store commission,
proceeds before tax/refunds are $4.25. That is viable for ordinary use but leaves much less room
for human support and transfer-heavy users than an $8 plan ($6.80 after the same commission).
Pricing should be decided from observed beta distributions, not the average alone.

The Apple Developer Program fee, tax/VAT, payment refunds, legal/DPA work, security review,
engineering and human support are outside the infrastructure totals. Apple's current Developer
Program fee is $99/year. These costs still belong in the business forecast.

## Vendor decision

| Option | Advantage | Blocking issue | Recommendation |
| --- | --- | --- | --- |
| Built-in ICE/STUN with TURN fallback | Most successful sessions send bytes directly; lower latency, relay cost and vendor visibility | Native host-path proof passed; NAT matrix, signaling, recovery, browser compatibility and production dependency remain | **Continue as the priority architecture path**; make it the default only if the network matrix passes |
| Cloudflare Named Tunnels | Reuses current process and protocol; no listed tunnel egress fee | 1,000-tunnel/route account limit; scaled price unknown | Use for a capped beta only after provisioning/security review; obtain Enterprise quote before 500 hosts |
| ngrok Device Gateway | Unlimited agents/endpoints on public tier; explicit per-device contracts | Higher public ceiling; binary redistribution, DPA, regional routing and rate limits need written answers | Cost and procurement fallback; request a 1k/10k/100k-device quote |
| Build a Threading relay | Full control; commodity egress can be cheaper | We would own tunnel protocol, routing, abuse, upgrades, availability, backpressure and on-call security | Reject for v1 even though raw VM/egress prices look cheaper |

For comparison, Fly.io currently lists Europe/North America public egress at $0.02/GB, one fifth of
ngrok's public transfer rate. That does not make a custom relay cheaper as a product: it prices
only the commodity bytes, not the engineering and operational system ngrok or Cloudflare supplies.

Procurement must get written answers for 10,000 and 100,000 provisioned Mac agents, concurrent
agents, rate limits, wildcard routing, WebSocket and response limits, EU routing/data processing,
credential revocation, signed-binary redistribution, abuse handling, support SLA and volume price.

## Implementation sequence

1. **Measure before choosing:** add local-only, content-free counters for remote active hours,
   request count, response bytes and Tailscale-versus-relay selection. Collect an opt-in beta
   distribution and cost its 50th, 90th and 99th percentiles.
2. **Direct-transport feasibility gate:** prototype an authenticated WebRTC data channel (or an
   equivalently mature ICE implementation) between macOS, native iOS and the browser, using the
   control plane only for candidate signaling. Test STUN-direct and TURN-fallback paths across
   home NAT, carrier networks, blocked UDP, IPv4/IPv6, VPNs, sleep/wake and Wi-Fi/cellular handoff.
   Measure connection success, time to first byte, binary size, memory, recovery and relay share.
   The isolated native host path, signed physical iPhone, bounded trickle signaling and one
   Wi-Fi-to-cellular STUN-direct sub-gate passed on 2026-08-11; TURN, broader NAT coverage,
   recovery, browser and production service-signaling work remains.
3. **Fallback procurement and security:** in parallel with evaluating the spike, prototype stable
   per-Mac endpoints with Cloudflare and ngrok and decide the tunnel trust/E2E story. Commit to a
   primary reverse-tunnel vendor only if the direct transport fails its release gate; otherwise
   retain one as the rollout safety path.
4. **Control plane:** Sign in with Apple, host/device registry, App Check, deletion, StoreKit
   entitlement and server notifications. Keep Local and Tailscale available without entitlement.
5. **Hosted transport:** ship the proven ICE/direct path with TURN fallback, or replace Quick
   Tunnel provisioning with a scoped stable reverse-tunnel credential if the gate failed.
   Preserve the loopback-only remote server's capabilities above the transport adapter.
6. **Push:** move the APNs signer and provider secret from the Mac environment into the service;
   rotate tokens, deduplicate events and fail closed on revoked hosts/devices.
7. **Event-driven mobile state:** replace the three-second session-dashboard poll with an initial
   snapshot plus bounded socket deltas before charging for the relay.
8. **Widgets and Live Activities:** publish size-capped semantic snapshots and activity events to
   the service; add clear stale timestamps and deep links back to the authenticated app.
9. **Account-backed sharing:** store invitation membership metadata while the Mac remains the
   authority that issues the session capability.
10. **Rollout:** internal, 100, 500 and 1,000-host gates. Do not cross 500 Cloudflare hosts without
   a signed scale path. Track cost per active relay Mac, connection success, push latency,
   bandwidth percentiles and service-induced wakeups at every gate.

## Performance, failure and test requirements

- Apply the repository scaling gate to accounts, hosts, devices, invitations, tokens, sessions,
  pending pushes and widget snapshots. Every query is owner-scoped, paginated and capped.
- Coalesce high-frequency agent changes before sending safe events. One streaming token must not
  become one server request, database write, push or widget update.
- Presence is connection-derived; do not write a Firestore heartbeat on a short interval.
- Give push events stable IDs, collapse keys and short expiries. Duplicate or reordered delivery
  must be harmless.
- Revoke a host, device or tunnel credential independently and prove that cached rendezvous cannot
  broaden or revive authority.
- Bound APNs/activity/widget token counts per account and rotate them transactionally.
- Load-test at least 10,000 simultaneously connected tunnel agents and slow/hostile clients with
  the same frame, connection and high-water limits as production.
- A control-plane outage leaves local agents and Tailscale sessions working. Managed relay and
  push show a clear degraded/offline state; no fallback opens a listening interface.
- Budget alerts must fire before 50%, 80% and 100% of the monthly relay and control-plane budget.
- Test account deletion, invitation expiry, device loss, subscription lapse and restored purchase
  without retaining remote authority or private payloads.

## Research sources

- [Cloudflare Tunnel overview](https://developers.cloudflare.com/tunnel/)
- [Cloudflare One account limits](https://developers.cloudflare.com/cloudflare-one/account-limits/)
- [Cloudflare Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)
- [ngrok pricing](https://ngrok.com/pricing)
- [ngrok agent](https://ngrok.com/docs/agent/)
- [IETF ICE specification](https://datatracker.ietf.org/doc/html/rfc8445)
- [IETF TURN specification](https://datatracker.ietf.org/doc/html/rfc8656)
- [IETF WebRTC data channels](https://datatracker.ietf.org/doc/rfc8831/)
- [Firebase pricing plans](https://firebase.google.com/docs/projects/billing/firebase-pricing-plans)
- [Firestore pricing](https://cloud.google.com/firestore/pricing)
- [Fly.io pricing](https://fly.io/docs/about/pricing/)
- [Apple Developer Program enrollment and fee](https://developer.apple.com/help/account/membership/program-enrollment/)
- [Apple Small Business Program](https://developer.apple.com/app-store/small-business-program/)
