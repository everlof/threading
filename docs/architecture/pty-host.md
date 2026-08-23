# The PTY host

Status: **design landed, daemon not yet built.** `Packages/ThreadingPTYHostKit` holds the whole
wire contract between Threading and the future `threading-ptyd`; nothing speaks it yet. The
feature it serves — sessions that outlive the app — is `docs/feature-drafts/durable-sessions.md`
§4.

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

## What is not decided here

The daemon itself, its socket location under `Application Support/Threading/pty/`, its journal,
its registration and retirement, the app-side client, the `TerminalSession` host-backed mode, and
the visibility surface (the quit question, the launch band, the Background Sessions list) are all
later slices. When they land, each adds its section here rather than a new document.
