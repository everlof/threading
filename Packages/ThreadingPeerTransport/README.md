# ThreadingPeerTransport

This package provides Threading's bounded native WebRTC data channel, hosted rendezvous clients,
and loopback stream bridge for macOS and iOS. It prefers direct ICE and uses TURN only when direct
connectivity fails.

It is linked into both shipping targets and runs in the default CI package loop. The community
Google WebRTC M151 XCFramework is exact-version and checksum pinned; its upstream source commit,
license inventory and update gate are recorded in
`docs/archive/audits/DEPENDENCY_AUDIT-2026-08-12.md` and
`docs/architecture/dependencies.md`.

Run the local host-candidate proof with:

```sh
THREADING_PERF=1 swift test --package-path Packages/ThreadingPeerTransport
```

An opt-in live STUN probe is also present. Supply the STUN URL from the environment so no
third-party server becomes an implicit production default:

```sh
THREADING_STUN_URL='stun:your-stun-host:3478' swift test \
  --package-path Packages/ThreadingPeerTransport \
  --filter PeerTransportTests/testConfiguredSTUNServerGathersServerReflexiveCandidate
```

The forced-relay release probe is opt-in as well. It applies WebRTC's relay-only policy to both
peers, transfers 32 KiB in one direction and a reply in the other, and fails unless both selected
routes report a TURN relay candidate. Run it once for each transport returned by the production
TURN provisioner; keep the ephemeral credential values in the environment rather than shell
history or repository files:

Prompt for the credential without echoing or recording it, and clear it after the three probes:

```sh
read -r -s -p 'TURN credential: ' THREADING_TURN_CREDENTIAL
export THREADING_TURN_CREDENTIAL

THREADING_TURN_URL='turn:your-turn-host:3478?transport=udp' \
THREADING_TURN_USERNAME='ephemeral-username' \
swift test --package-path Packages/ThreadingPeerTransport \
  --filter PeerTransportTests/testConfiguredTURNServerOpensRelayOnlyChannel

THREADING_TURN_URL='turn:your-turn-host:80?transport=tcp' \
THREADING_TURN_USERNAME='ephemeral-username' \
swift test --package-path Packages/ThreadingPeerTransport \
  --filter PeerTransportTests/testConfiguredTURNServerOpensRelayOnlyChannel

THREADING_TURN_URL='turns:your-turn-host:443?transport=tcp' \
THREADING_TURN_USERNAME='ephemeral-username' \
swift test --package-path Packages/ThreadingPeerTransport \
  --filter PeerTransportTests/testConfiguredTURNServerOpensRelayOnlyChannel

unset THREADING_TURN_CREDENTIAL
```

## Scaling contract

- Expected: 1-3 peer connections per Mac host. The hosted rendezvous enforces eight concurrent
  sessions per host; the transport keeps independent byte/message bounds below that service cap.
- ICE negotiation: tens of events per reconnect; candidate count is capped at 64 and SDP at
  256 KiB.
- Data path: potentially thousands of messages per second. Work is O(message bytes), each message
  is capped at 64 KiB, and unread inbound/outbound buffering is capped at 2 MiB per connection.
  Unread message count is independently capped at 4,096 so zero-length frames cannot grow state.
- Hidden/collapsed UI is irrelevant here: no UI or main-actor work exists in the transport.
- Route telemetry records only candidate kind and protocol, never peer addresses or credentials.

## What the tests prove

- Offer/answer negotiation both with a complete SDP and with bounded trickle candidates.
- DTLS/SCTP data-channel setup using host candidates.
- Ordered, bidirectional binary messages under a multi-megabyte stress fixture.
- Backpressure and input bounds.
- Selected-route inspection, including whether TURN was used.
- A credentialed, forced relay-only probe that cannot pass by falling back to a direct candidate.

Physical Wi-Fi-to-cellular direct NAT traversal has passed without TURN. Release still requires
the full matrix below, including a forced TURN-only route, with route and setup time recorded:

| Mac network | iPhone network | Expected route |
|---|---|---|
| Same Wi-Fi | Same Wi-Fi | host/direct |
| Home Wi-Fi | Cellular | server-reflexive/direct where NAT permits |
| Corporate Wi-Fi | Cellular | direct or relay |
| IPv6 network | Different IPv6 network | direct where policy permits |
| Any pair, relay-only policy | Any | relay |

Waiting for a complete SDP timed out against public STUN from the current build environment. The
bounded trickle path added after that finding gathered a Cloudflare server-reflexive candidate in
0.15 seconds and subsequently passed the physical Wi-Fi-to-cellular test. Production signaling
must keep trickling candidates and race the direct path with a TURN-over-TCP/TLS fallback rather
than waiting for every STUN transaction to finish.

## Remaining release gates

1. Deploy the authenticated production rendezvous and TURN provisioner.
2. Force and verify TURN-over-UDP, TCP and TLS, then complete the network matrix above.
3. Measure direct success rate, TURN byte share, negotiation time and reconnect time at each rollout
   gate.
4. Re-run the pinned binary provenance, checksum, license and advisory audit for every WebRTC
   update. The framework is about 28.4 MB for macOS and 12.2 MB for iOS before app slicing and
   App Store compression.
