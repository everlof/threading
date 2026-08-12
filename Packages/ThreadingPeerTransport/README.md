# ThreadingPeerTransport feasibility spike

This package answers one question before the WebRTC binary affects either shipping target: can
Threading establish an ordered, reliable native data channel, prefer a direct ICE path, force a
TURN path for fallback tests, and keep all peer-controlled state bounded?

It is deliberately not linked from `Threading.xcodeproj` and is not in the default CI package
loop yet. The current dependency is a community-built Google WebRTC M151 XCFramework. That makes
the spike fast, but it is not yet an acceptable production supply chain.

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

## Scaling contract

- Expected: 1-3 peer connections per Mac host. A production host cap is still required.
- ICE negotiation: tens of events per reconnect; candidate count is capped at 64 and SDP at
  256 KiB.
- Data path: potentially thousands of messages per second. Work is O(message bytes), each message
  is capped at 64 KiB, and unread inbound/outbound buffering is capped at 2 MiB per connection.
  Unread message count is independently capped at 4,096 so zero-length frames cannot grow state.
- Hidden/collapsed UI is irrelevant here: no UI or main-actor work exists in the transport.
- Route telemetry records only candidate kind and protocol, never peer addresses or credentials.

## What the local test proves

- Offer/answer negotiation both with a complete SDP and with bounded trickle candidates.
- DTLS/SCTP data-channel setup using host candidates.
- Ordered, bidirectional binary messages under a multi-megabyte stress fixture.
- Backpressure and input bounds.
- Selected-route inspection, including whether TURN was used.

It does **not** yet prove NAT traversal. Before integration, run the same transport between devices
on the network matrix below and record the route and setup time:

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

## Production gates

1. Replace the ad-hoc SDP handoff with authenticated, one-use signaling through our service.
2. Bridge bounded data-channel messages to the existing loopback HTTP/WebSocket server, keeping its
   capability token and protocol unchanged.
3. Measure the direct success rate and TURN bytes per connected hour across the matrix above.
4. Decide between a reproducible in-house WebRTC build and a smaller maintained data-channel
   implementation. The downloaded M151 framework is about 28.4 MB for macOS and 12.2 MB for iOS
   before app-store compression and slicing.
5. Add the accepted package to both app targets, legal notices, dependency documentation, and CI.
