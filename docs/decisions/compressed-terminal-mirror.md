# Compressing the terminal mirror's wire

> Status: **decision record** (2026-08-20). **Wait for demand.** Deflate would cut a cellular
> join from ~150 KB to somewhere between ~50 KB and ~5 KB depending on what the ring holds, and
> nothing else: every cost that made "entering a chat is very much slower" (issue report
> `f718a8dc`) was parse and PTY churn, which compression does not touch and which the
> 2026-08-20 fixes already removed. Our WebSocket stack cannot negotiate standard
> permessage-deflate, so this is an application-level frame format on both ends plus the browser
> client — a real project, parked until a non-LAN transfer is measured as the thing a person is
> waiting on.

Part of the [decisions index](README.md). Grew out of the bounded-replay work
(`2ce3664e`, "Replay to a joining phone only what it can keep"); read alongside
[`REMOTE_ACCESS.md`](../REMOTE_ACCESS.md)'s join-replay section and the mobile terminal
scaling contract in [`performance.md`](../architecture/performance.md).

**The one-sentence version.** Compression shrinks bytes, and bytes stopped being the scarce
resource the moment the replay was bounded — reopen this when a diagnostics trace shows a
join waiting on transfer rather than on parse.

---

## 1. User problem and concrete cases

1. **A cellular join.** The phone away from the Mac's LAN opens a chat over the remote route.
   The join replay is now at most ~150 KB (128 KB tail + repaint + seeds); on a weak cellular
   link that is a perceptible fraction of a second of transfer, and it is metered data.
2. **A long mirrored sitting over cellular.** An agent working for an hour streams its repaints
   to a watching phone. The steady state is bursty and small (KB/s), but it is continuous, and
   on metered data an hour adds up.
3. **A guest share over the tunnel.** Same bytes, plus a third-party hop; latency is dominated
   by the relay, not by our frame sizes.

Case 1 is the only one with a user-visible wait, and the bounded replay already cut it 3.4×.

## 2. What Threading already does that overlaps

- **The replay is already bounded** (`2ce3664e`): a phone states `replayBudget` in its auth
  frame and receives at most that tail plus a fresh repaint — 512 KB → ~150 KB on the wire and
  348–357 ms → 103–105 ms of parse. Compression cannot repeat that win; parse operates on the
  *inflated* bytes.
- **Viewport leases settle and themes install once** (4dbf5ed4, 9584ba6d): the event storms
  that actually made entry slow are gone. Compression reduces bytes per event, never events.
- **The negotiation seam exists.** `hello.features` advertises host capabilities and the auth
  frame carries additive client statements (`deviceName`, `replayBudget`); a compression opt-in
  is one more of each, no protocol bump.
- **TLS on every route** already costs CPU per byte; frames are small and the sockets are long-
  lived, so there is no connection-setup amplification to save.

## 3. Platform facts and measurements

- `URLSessionWebSocketTask` (the phone) negotiates **no WebSocket extensions**, and the Mac's
  server is our own RFC 6455 framing on `NWConnection` — so standard permessage-deflate is
  unavailable end to end. Any compression is an application-level payload format.
- The browser client can inflate `deflate-raw` natively via `DecompressionStream`
  (Safari 16.4+); the phone via the Compression framework (`COMPRESSION_ZLIB`); the Mac
  likewise. No third-party dependency on any end.
- Measured deflate ratios (zlib level 1 / level 6, 2026-08-20, synthetic fixtures from the
  bounded-replay probe plus one real-entropy sample):

  | Sample | Bytes | ×, level 1 | ×, level 6 |
  |---|---|---|---|
  | 512 KB colored-line ring fixture | 524,304 | 33.6 | 34.7 |
  | Cut replay (CAN + 128 KB tail + repaint) | 136,013 | 29.7 | 31.2 |
  | One 70×59 repaint | 4,940 | 12.0 | 12.9 |
  | 512 KB of a real session transcript (JSONL, includes base64) | 524,288 | 2.5 | 2.8 |

  The fixtures overstate (repeated filler compresses absurdly well) and the transcript
  understates (base64 attachments). Real PTY output sits in between: SGR-heavy repaints near
  the high end, prose transcript near 3–4×. **Capturing a real ring and measuring it is the
  first task of any implementation** — if a real ring lands under ~3×, the case collapses.
- Level 1 is within ~10% of level 6 on every sample; the CPU choice is not interesting.
- The alternative that reduces *work* rather than bytes is mosh-shaped state sync: a client
  that falls behind gets its backlog dropped and a fresh `RemoteScreenSeed` instead. Deferred
  separately while the product is effectively single-viewer; it composes with, and partly
  obsoletes, compression for the backlog case.

## 4. The contract, if built

- Client opt-in: `acceptsCompressedFrames: true` on the auth frame (additive, like
  `replayBudget`); host advertisement: a `compressedFrames` entry in `hello.features`. Both
  absent → today's raw frames, byte for byte.
- When both ends opt in, every **host→client binary frame** becomes `[1 tag byte][payload]`:
  tag `0x00` raw, tag `0x01` deflate-raw of the terminal bytes. The host compresses only
  frames above a threshold (~4 KB) so keystroke echoes and small bursts skip the overhead.
  Client→host input stays raw; it is tiny.
- **Per-frame compression, no shared window.** A shared dictionary would compress the steady
  state better but makes every frame depend on every earlier one (reconnect and replay get
  fragile) and widens the compressed-length side channel; per-frame keeps frames independent
  and bounds decompressor memory.
- Inflation happens before the bytes reach `feed`/the ring-replay path; everything downstream
  is unchanged. The ring itself stays raw — it is re-sliced per client (`replayBudget`), which
  a compressed ring could not do.
- A malformed compressed frame is a protocol error: close the socket, let the ordinary
  reconnect path re-seed. Never feed partially inflated bytes to an emulator.
- Bound the inflated size (e.g. 8× the ring, matching `Reassembler`'s spirit) so a hostile
  peer cannot zip-bomb the host's memory; the host compresses but also *decompresses nothing*
  in this design (input stays raw), which keeps the host's attack surface unchanged.

## 5. Security, privacy, scaling

- **Length side channel.** TLS already exposes frame lengths; compression makes those lengths
  content-dependent (CRIME-family). Terminal output regularly contains secrets. Per-frame
  compression with no cross-frame state and no attacker-chosen prefix inside the same frame
  keeps this to the same class as TLS-with-compression-of-one-document; worth stating in
  `REMOTE_ACCESS.md`'s disclosure if built, not worth a design contortion.
- **CPU/memory.** Level-1 deflate runs far faster than the sockets ever feed it; the join blob
  costs single-digit milliseconds; per-frame windows bound memory on both ends.
- **Scaling gate.** Per-byte work already exists (TLS); compression adds a constant factor on
  an already-bounded path. No unbounded cardinality is introduced.

## 6. Smallest shippable slice, non-goals, tests

- **Slice:** compress only the join-replay binary frames (ring/tail/repaint) when negotiated —
  the largest frames, one code path, no steady-state behavior change. Steady-state frame
  compression is a follow-up once a real ring's ratio is known.
- **Non-goals:** compressing client→host input; a shared compression window; compressing JSON
  control frames (small, and their sizes are not content-shaped in interesting ways);
  mosh-style state sync (its own record when multi-viewer demand exists).
- **Tests:** tag-byte framing round-trip against fixture bytes; negotiation matrix (old client,
  old host, both new); inflated-size bound refusal; the browser client inflating a fixture via
  `DecompressionStream` in the existing recorded-traffic harness.

## 7. Recommendation and what should reopen it

**Wait for demand.** The measured costs this would address are currently ~150 KB per join and
KB/s while watching — real on metered cellular, invisible on LAN, and no longer what anyone is
waiting on.

Reopen when any of these appears:

- a diagnostics trace or issue report where join-to-first-paint on a non-LAN route is dominated
  by transfer rather than parse (the journal's `Remote replay bounded` size against the
  socket timing gives this directly);
- a metered-data complaint from real cellular use;
- a relay/WAN transport being promoted to a headline path, where every byte crosses a paid hop;
- or a real captured ring measuring ≥5× under deflate, which would make the join slice cheap
  insurance rather than speculation.

First implementation task either way: capture a real session's ring bytes and replace §3's
fixture numbers with its ratio.
