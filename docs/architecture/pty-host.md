# The PTY host

Status: **the wire, the daemon and the app's client exist; nothing in the product uses them yet.**
`Packages/ThreadingPTYHostKit` holds the contract, `Targets/PTYHost` is the daemon, and
`Sources/Threading/Core/PTYHost` can connect to it, refuse an incompatible one and say why it
did not. No session's PTY has moved: `TerminalSession` still calls `forkpty` in-process, and
`AppSettings.ptyHostEnabled` is off. The feature it serves — sessions that outlive the app — is
`docs/feature-drafts/durable-sessions.md` §4.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

The daemon will be one process per user, registered through `SMAppService.agent`, owning each
session's `forkpty` child, its raw output ring, its last window size, its exit status and its
launch record — and owning nothing else. No projects, no themes, no transcripts, no accounts, no
policy, no settings, no SQLite store, no `EventLog`, and no terminal emulation of any kind. It
parses nothing. Registration is attempted and never required: every way it can be unavailable
degrades to today's in-process `forkpty` behaviour, unchanged.

**§6 of the draft is not a promise.** `ScheduledMessageScheduler`, `LimitRecoveryCoordinator` and
`UsageWindowPoker` are `@MainActor` singletons in the app; a daemon *unlocks* scheduled work
without a window and does not deliver it. Likewise the mirror unification (turning the Mac's own
view into one more watcher of `RemoteSessionMirrorRegistry`) is a named follow-up contingent on
the daemon having shipped and settled, not part of this work.

## The protocol

`kind` is the framing header's byte. `→` app-to-daemon, `←` daemon-to-app. The Swift definitions
are `PTYHostFrame.swift`; this table is the same set in prose.

| Frame | Dir | kind | Fields |
|---|---|---|---|
| `hello` | → ← | 0 | `protocol`, `minimumSupported`, `build`, `pid` |
| `helloRefused` | ← | 0 | `compatibility`, `update` |
| `list` | → | 0 | — |
| `sessions` | ← | 0 | `[PTYHostSessionSummary]` — `id`, `pid`, `startedAt`, `executable`, `grid`, `isAttached`, `exit` |
| `spawn` | → | 0 | `id`, `channel` (`.pty(grid:)` \| `.pipes`), `executable`, `arguments`, `execName`, `environment`, `cwd` |
| `spawned` | ← | 0 | `id`, `pid`, `startTime` |
| `spawnRefused` | ← | 0 | `id`, `reason` (`alreadyExists`, `executableUnavailable`, `retiring`, `capacity`) |
| `attach` | → | 0 | `id`, `replayBudget` |
| `attached` | ← | 0 | `id`, `pid`, `grid`, `replay` (`.exact(fromOffset:)` \| `.cut` \| `.none`), `totalBytesWritten` |
| *(replay bytes)* | ← | 1 | screen seed ‖ ring slice ‖ mode seed, in that order |
| `output` | ← | 1 | raw bytes, no envelope |
| `input` | → | 2 | raw bytes, no envelope |
| `resize` | → | 0 | `id`, `grid` (cols, rows, xpixel, ypixel) |
| `detach` | → | 0 | `id`, `screenSeed`, `modeSeed`, `ringOffset` |
| `kill` | → | 0 | `id`, `escalate` |
| `exited` | ← | 0 | `id`, `status`, `signalled` |
| `lost` | ← | 0 | `ids`, `since` |
| `retire` | → | 0 | — |
| `journalTail` | → | 0 | `maxBytes` |
| `journal` | ← | 0 | `lines` |
| `error` | ← | 0 | `code`, `detail` |

Session ids are `TerminalInstanceIdentity` from `ThreadingDomain` — a daemon that minted its own
session numbers would be a second identity space to reconcile. The domain type is not `Codable`,
and conforming it from this package would be a retroactive conformance that a later `Codable` in
`ThreadingDomain` would collide with, in whatever shape the compiler had synthesised. So
`PTYHostSessionIdentity` wraps it and writes the shape out: a `kind` token (the case names, so a
reordered enum cannot rename a session's owner) beside the same UUID string the rest of the app
persists. Version 1 hosts `agentSession` only; the other three are spelled out so hosting them
later is a daemon change and not a protocol change.

**Not in the protocol, deliberately.** No token and no capability — the `0700` directory is the
authorization boundary, exactly as `MCPBridgeDefaults` records for `bridge/`. No theme. No
sequence number: stream delivery is ordered and the seeds are idempotent, and here that is a
stronger claim than the remote mirror's, because the ring *is* the stream rather than lagging it
by a main-queue hop. No viewport lease: `resolvedViewport(of:)`, the device-keyed grace and the
whole `ViewportLeases` structure are remote-access authorization concerns, and the daemon
receives one resolved grid and never learns there were leases. No title, cwd or activity — the
app parses those, from the emulator it still owns.

**Deferred but shaped for.** `channel: .pipes` for native conversations over pipes; the
compression bit in `flags`; a `foreground` push frame (the daemon holds the master fd, so
`tcgetpgrp` is one syscall it *can* answer) which is what would let standalone terminals and
shell drawers be hosted too. Each is a frame or a field that already exists, so none of them
bumps the protocol.

### Two rules the frames encode

**A `resize` sets the durable grid; an `attach` does not.** A new watcher inherits the grid, it
does not impose one. That is what makes "reattaching a Threading that has just restarted must not
reflow an agent that kept working the whole time" true by construction rather than by care. A
session with no watcher keeps its last grid indefinitely — there is no Mac frame to restore to.
On `spawn` the frame's grid is the initial `winsize`, and the app must not send a placeholder:
SwiftTerm clamps an unlaid-out grid to 2×1 rather than to zero, and `forkpty` takes 2×1 at face
value, so the agent's TUI boots into a two-column window.

**The daemon uses `spawn`'s environment and argv verbatim, adding nothing.** It inherits
*launchd's* environment, not the user's, and the composition rules — the measured leakage list in
[`sessions.md`](sessions.md), `AgentEnvironment.inheritedIdentityPrefixes`, `AgentLauncher`'s
login-shell command line — are one decision that stays in one place in the app.

## Framing

A `SOCK_STREAM` unix socket has no message boundaries, so the transport needs its own. Eight
little-endian bytes, then payload:

```
[u8 kind][u8 flags][u16 reserved][u32 length]     length ≤ 1 MiB
kind   0 = JSON control frame   1 = raw output bytes   2 = raw input bytes
flags  bit 0 reserved for the [tag][payload] compression byte in
       docs/decisions/compressed-terminal-mirror.md §4
```

Control frames are JSON so they are `Codable`, versionable and testable. Bulk terminal bytes
travel outside JSON so the hot path pays no base64 tax. The 1 MiB bound matches
`RemoteAccessDefaults.maximumFrameBytes`, because the same terminal bytes cross both transports
and a burst the remote mirror accepts must not be one the host link refuses.

`PTYHostFrameDecoder` takes **bytes**, not frames, and answers with however many complete frames
those bytes finished — a frame split across three reads is as ordinary as two frames in one read.
Two things about it are load-bearing:

- **The length is refused from the header alone**, before a payload byte is buffered. A cap on
  what is delivered is not a cap on what is read; without this a peer could make the buffer grow
  by declaring a huge frame and then going quiet. The decoder therefore holds at most one header
  plus one maximum payload, whatever arrives.
- **A refusal is terminal and closes that one connection.** There is no resynchronisation point
  in a length-prefixed stream — once the length or the kind is wrong, "skip this frame" means
  guessing where the next header starts — so `PTYHostFramingRefusal` has exactly two cases
  (`oversizePayload`, `unknownKind`), both meaning *close this connection*, and the decoder stays
  refused afterwards. It never exits the daemon: a poisoned frame from one client must not take
  the other sessions with it, and `KeepAlive` plus a restart storm is the failure this avoids.

The reserved `u16` is written as zero and **ignored** on the way in, so a later build can give it
a meaning without every earlier build refusing the frame. `flags` is carried through
uninterpreted for the same reason — turning compression on later is a change in one consumer, not
a change to the header.

## Why not the remote DTOs

The draft says the protocol already exists and to reuse `ThreadingRemoteKit`'s DTOs. Half of that
is right and the half that is wrong matters.

What exists in `RemoteSessionMirrorRegistry` is the *job description* — tap the PTY byte stream,
keep a ring for late joiners, fan output to every watcher, route input back — and it is proven
daily by the phone. What does not exist is the frames. Terminal output is a **bare binary
WebSocket frame with no envelope, no id and no length of our own**; detach is a socket close; exit
is `RemoteEndedDTO(reason: "sessionClosed")` followed by `sendClose`. So there is no output frame
and no exit frame to reuse, and the framing the mirror leans on is WebSocket's, which a unix
stream socket does not have.

The frames that do exist carry remote-access concepts the daemon must never own: a bearer token,
a `RemoteCapability` set, an app theme, a terminal theme, advertised features. Putting those in
front of a process whose whole safety argument is "it holds no authorizations and parses nothing"
is how that argument stops being true. `RemoteClientMessage`'s input is UTF-8 text and cannot
carry arbitrary bytes at all, which a PTY's input must.

One type is copied rather than reused. `ProcessStartTime` — the kernel start time that is the
other half of a pid's identity — lives in the app module (`Core/Session/ProcessUtility.swift`),
not in a package, and the daemon must not link the app. `PTYHostProcessStartTime` is a minimal
copy with identical field names, so the JSON is the same on both sides, and the app maps between
the two at the client boundary. Moving the app's type into a package would be a wider change than
this slice, and duplicating a two-field value with the reason written down is the smaller debt.

So: **reuse the value types, not the DTOs.** `RemoteScreenSeed`, `RemoteTerminalModeSeed`,
`RemoteTerminalModes`, `RemoteTerminalGrid` and `terminalReplay(ring:budget:)` stay app-side and
are used unchanged. `RemoteRingBuffer` moved into `ThreadingPTYHostKit` because both processes
need the same ring and the daemon cannot link the app; the mirror goes on using it through the
package. `RemoteProtocol` is reused in *shape* only, as `PTYHostProtocol`. Every `Remote*DTO`
stays where it is.

## The ring, and the exact rejoin

`RemoteRingBuffer` keeps its header claim — replaying the raw byte stream "is the only
representation guaranteed to reproduce what SwiftTerm itself rendered" — and gains two members:

- `totalBytesWritten`, monotonic, counting bytes the ring itself no longer holds.
- `snapshot(from:) -> Data?`, which answers with exactly the bytes written since an offset when
  `totalBytesWritten - offset` still fits inside the ring, and **nil** when it does not.

The refusal is the whole point. The daemon cannot synthesise a screen: a repaint is derived from
a live emulator and it has none. But the app is present at exactly the moment the last watcher
leaves, so `detach` carries `screenSeed`, `modeSeed` and the `ringOffset` the watcher had applied,
and the daemon stores three opaque values. On the next `attach` it computes how far behind the
watcher is:

- within the ring → `replay: .exact(fromOffset:)`, and the bytes are screen seed, then
  `snapshot(from:)`, then mode seed. No cut marker, no loss, no repaint gamble.
- past the ring, or no seed stored (a session spawned while the app was closed) → `.cut`:
  `CAN` (0x18) then the ring tail, and the app re-derives its own screen. CAN first, because
  cutting the head off the ring means the replay can now *begin* inside an escape sequence too.

**Modes are always the last word**, in both branches: the ring is replayed history, and history
holds modes that stopped being true. The ordering asymmetry the remote mirror discovered — tail
first, repaint after — is *not* needed here and must not be copied; it exists because the mirror's
ring lags the emulator by one main-queue hop, and in the daemon every byte is appended before it
is fanned out.

A partial answer that looks complete is the failure this design refuses: a watcher is owed either
every byte it missed or an explicit cut, and `snapshot(from:)` returning nil is what forces the
caller to say which.

## Versioning

`PTYHostProtocol.current` and `minimumSupported` are `RemoteProtocol`'s rule, deliberately copied
rather than shared: the two protocols version independently, so a remote-access frame change must
not retire a working daemon and a daemon frame change must not tell every installed iPhone to
update. `PTYHostCompatibility.evaluate(peerVersion:peerMinimum:)` gives the same three answers —
`compatible`, `peerTooOld`, `selfTooOld`.

**The protocol pair is the gate; the build string is not.** `hello` carries a build, and it is
reported and journalled and never compared for admission. The reason is local to this repository:
a commit on `master` rebuilds and reinstalls `/Applications/Threading.app`, so a build-gated
daemon would be retired and drained several times a day for changes that touch no frame. macOS
keeps a running executable's text pages valid after the file underneath is replaced, so an
already-running daemon goes on executing the code it started with — which is exactly what is
wanted, provided the protocol still matches.

**Bump policy, verbatim.** Additive changes bump nothing; a breaking change bumps `current` while
still speaking the old version; `minimumSupported` rises only in its own later release. A frame
added to `PTYHostFrame` is additive — the `type` discriminator and the nested `body` make it so —
and therefore bumps nothing. `PTYHostProtocolTests` pins both numbers so a bump fails a test once,
deliberately.

On a mismatch the app **refuses to attach, refuses to spawn, and never signals anything**. It
sends `retire` and falls back to in-process PTYs for new sessions.
`PTYHostCompatibility.updateTarget(evaluatedBy:)` names which side has to move, and takes the
evaluator as a parameter because `peerTooOld` means the app when the daemon evaluates and the
daemon when the app evaluates — a fixed mapping would be right on one side and exactly backwards
on the other.

`retire` means: stop accepting new connections, `close()` the listener and `unlink()` the socket
path **immediately** so a new binary can bind it, keep serving already-attached connections, and
`exit(0)` when the last session ends. Killing the old daemon on a bundle change is not an option
under consideration — that is killing working agents, which is the bug the feature exists to fix.

## Availability and degradation

Registration is attempted and never required, so **every way the host can be missing has to be a
value the app can act on**, and there is exactly one of them: `PTYHostAvailability`, either
`.available(socketPath:)` or `.unavailable(PTYHostUnavailability)`. Every unavailable case
degrades to the same thing — today's in-process `forkpty`, unchanged — which is what makes §7's
"removing it must degrade to today's behaviour rather than to a broken app" structural rather than
a promise. The reasons are separate anyway, because a journal, the Advanced page and a support
report all need to *say* which one it was, and a `Bool` is how a feature that quietly stopped
working becomes unexplainable.

| Reason | What it means | Degrades to |
|---|---|---|
| `disabled` | `AppSettings.ptyHostEnabled` is off | in-process PTY |
| `socketPathTooLong(bytes:)` | the rendezvous does not fit `sockaddr_un.sun_path` | in-process PTY |
| `helperMissing` | no `Contents/Helpers/threading-ptyd` in the bundle | in-process PTY |
| `notRunning` | no socket file, or the kernel refused the connect | in-process PTY |
| `protocolMismatch(_)` | a daemon answered and the gate refused it | in-process PTY |
| `notRegistered` | launchd knows the label and the service is off | in-process PTY |
| `notFound` | launchd has never seen the label | in-process PTY |

The last two are **set by registration, not by the probe**. `PTYHostAvailability.resolve` has no
`SMAppService` and deliberately none — a launch-path call into a framework that can block is not
what a probe is for — so they are spelled out now and filled in by the registration slice. They
are two cases rather than one because P2 measured the difference: launchd binds a registration to
a *path*, so "seen, currently off" and "never seen" want different fixes and only one of them is
re-registering.

**The order is the design, not tidiness.** `disabled` is decided first and touches nothing at all
— while the feature is off, which is every launch until R1 is answered, asking costs a
`UserDefaults` read the app has already taken. The path bound is arithmetic on a string. The
helper is one `stat`. Only after all three does anything open a socket. `PTYHostAvailabilityTests`
asserts the probe is *not called* on each of the first three, because an ordering claim nobody
checks is an ordering claim that drifts.

The split is also a concurrency boundary. `PTYHostDecision.live(settings:bundle:)` is
`@MainActor` and reads only values — the setting, the bundle's helper path, the rendezvous, the
build string — in `MCPBridgeDecision.live`'s shape, every dependency named by the caller and
nothing recovered from a singleton inside. `PTYHostAvailability.resolve(_:probing:)` is not
main-actor isolated and is where the connect happens. A caller that wants both in one call has
`PTYHostAvailability.live(settings:bundle:probe:)`, and the probe is still the caller's, because
`PTYHostProbe.connecting()` blocks for up to `connectTimeout + helloTimeout`.

`pty/` is `0700` and is a **sibling** of `bridge/`, not a room-mate: the two are owned by
different processes with different lifetimes, and a daemon able to write `session-tokens.json`
would be a daemon holding an authorization. The app only ever *resolves* paths there and creates
the directory; unlinking a stale socket and binding a new one are the daemon's, because it is the
only process that may be listening. Under a hosted test bundle the whole directory redirects
through `StateManager.isHostedTest`, for the reason `MCPBridgeLocation` gives one line further
down the same argument: a test that started a daemon on the real rendezvous would be a second
listener at the address the developer's running app is using.

## The client

One `PTYHostClient` is one connection, and **one connection is one session**. After a successful
`spawn` or `attach` it is bound, which is what lets output and input travel as bare bytes with no
envelope and no id — a terminal's hot path must not pay for a header the socket already implies.
The client enforces the binding locally as well as trusting the daemon to: a second `attach`
answers `PTYHostClientError.alreadyBound`, a `resize` naming another session answers
`sessionMismatch`, and raw input before any binding answers `notBound`, because input carries no
id and guessing would type into somebody else's agent.

**The client speaks first.** `hello` goes out before a byte is read, carrying the protocol pair,
this build's version string and `getpid()`. Speaking first is what makes a wrong-version daemon
cheap: the app has committed to nothing when the answer arrives, so a refusal is a close rather
than an unwind. The gate is `PTYHostProtocol.evaluate`, and its three answers do three different
things:

- `compatible` — ready. The daemon's `build` is recorded and journalled; it is never compared for
  admission.
- `peerTooOld` — the daemon is behind. It is sent `retire` and the connection closes. `retire`
  unlinks the socket immediately so the new binary can bind, drains what is attached, and exits;
  `KeepAlive` then starts the current binary, which is the upgrade. Killing it instead would be
  killing working agents.
- `selfTooOld` — this app is behind. **Nothing further is sent.** Retiring a daemon newer than us
  would take working agents down in order to install an older host.

A `helloRefused` is the daemon having evaluated *us*, so its answer is the mirror of ours — its
`peerTooOld` is our `selfTooOld` — and the client flips it at the boundary so no caller has to
know which side did the arithmetic. This is the same trap `updateTarget(evaluatedBy:)` exists to
avoid, one process further out.

After the gate a `DispatchIO` read loop on the client's own serial queue feeds
`PTYHostFrameDecoder`, and **every delivery happens on that queue and never on main**. The
coalescing hop to main belongs to the caller, in `installProcessOutputObserver`'s existing shape;
a client that hopped per frame would put a terminal's whole output rate on the main queue, which
is the shape that makes a mirror slow. The handshake itself blocks — with a `poll` deadline on the
connect and another on the `hello`, so it is bounded — and therefore runs off the main actor too.

**A frame this build does not know is logged and ignored.** The protocol is additive, so a
well-framed control frame with an unrecognised `type` means a peer the gate already admitted has
something new to say; reading past it is the only correct move, and it is what lets a frame be
added without every older app refusing the connection. Only a `PTYHostFramingRefusal` closes,
because once a length or a `kind` is wrong there is no resynchronisation point to skip to.

**The write queue is bounded and closes rather than grows.** `DispatchIO` accepts whatever it is
given and reports completion later, so how much is unwritten is a number only the caller can keep;
without it, a daemon that stopped reading would drive an unbounded allocation in the app from
outside. Past `PTYHostDefaults.maximumQueuedWriteBytes` — four frames of the 1 MiB wire maximum —
the connection closes with `writeQueueOverflow`, and the session degrades like any other
unavailability. A queue that grows quietly is the failure this refuses.

`EventLog` sees lifecycle edges only, in `.session`: connected (with the peer's build), the
compatibility answer and whether the daemon was retired, a reported `lost` set, a framing refusal,
a write-queue overflow, and the close. Never a frame. The daemon has its own journal in `pty/` and
the app pulls a bounded tail of it through `journalTail` rather than sharing a file — `EventLog`'s
descriptor is `O_APPEND` precisely because more than one process writes it and interleaving has
damaged it once already.

`PTYHostClientTests` drives all of this against an in-process fake that binds a real unix socket
and speaks the real codec: no daemon binary, no `SMAppService`, no PTY, no window.
`PTYHostDaemonIntegrationTests` is the thin layer above it that meets the real
`threading-ptyd`, and skips when the helper is not in the bundle.

## What is not decided here

Registration and retirement, the `TerminalSession` host-backed mode, and the visibility surface
(the quit question, the launch band, the Background Sessions list) are later slices. When they
land, each adds its section here rather than a new document.
