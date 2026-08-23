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
| `spawnRefused` | ← | 0 | `id`, `reason` (`alreadyExists`, `executableUnavailable`, `retiring`, `capacity`, `unsupportedChannel`) |
| `attach` | → | 0 | `id`, `replayBudget` |
| `attached` | ← | 0 | `id`, `pid`, `grid`, `replay` (`.exact(fromOffset:)` \| `.cut` \| `.none`), `totalBytesWritten` |
| *(replay bytes)* | ← | 1 | screen seed ‖ ring slice ‖ mode seed, in that order |
| `output` | ← | 1 | raw bytes, no envelope |
| `input` | → | 2 | raw bytes, no envelope |
| `resize` | → | 0 | `id`, `grid` (cols, rows, xpixel, ypixel) |
| `detach` | → | 0 | `id`, `screenSeed`, `modeSeed`, `ringOffset` |
| `kill` | → | 0 | `id`, `escalate` |
| `exited` | ← | 0 | `id`, `status`, `signalled` |
| `foreground` | ← | 0 | `id`, `processGroup` |
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

**Deferred but shaped for.** `channel: .pipes` for native conversations over pipes, and the
compression bit in `flags`. Each is a frame or a field that already exists, so neither bumps the
protocol. `foreground` was deferred too and then was not: the app decides title ownership from
`tcgetpgrp` on a descriptor a host-backed session does not have, so the frame landed in v1 — the
daemon holds the master, and one syscall with no parsing in it is a question it can answer.
Hosting `.projectTerminal`, `.sessionShell` and `.ephemeral` terminals is what that unblocks, and
stays out of these slices.

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

## The daemon

`Targets/PTYHost` builds `threading-ptyd`, embedded in `Contents/Helpers` beside the other
helpers. **It builds and is tested; it is not registered with launchd and nothing in the app
starts it.** `PTYHostDaemonTests` runs the shipping binary by hand against a scratch socket, and
`SMAppService` is a later slice.

Its command line is `--socket <path> --state <dir>`, both required, anything else `exit(64)`. The
daemon has no path policy of its own for the same reason `threading-mcp-bridge` has none: where
the rendezvous and the state directory live is one decision, made in the app beside the other
owner-only directories, and a daemon that derived either would be a second place for that decision
to be wrong. It is also what lets a test start one without going anywhere near the socket the
developer's running app is listening on.

Everything after startup happens on **one serial queue**. Accepts, decoded frames, bytes read off
a master, and every timer land there, so none of the state needs a lock and the two orderings that
matter — a replay before the live output that follows it, a ring append before the fan-out that
reads it — are answered by construction rather than by care. The only work elsewhere is the kernel
I/O itself: each session's master is a `DispatchIO` channel with its own queue that hands its
bursts back.

### What it owns, and what it must never own

Per session: the `forkpty` child (pid, process group, master descriptor), the raw output ring, the
last window size, the exit status, the launch record, the detach seed, and the spawn environment
it was given. That is the list. It never owns projects, themes, transcripts, accounts, policy,
settings, the SQLite store, the app's journal, or any terminal emulation, and **it parses nothing**
— bytes are copied into a ring and copied out to watchers. The one syscall it makes *about* a
terminal is `tcgetpgrp`, which has no bytes in it.

`scripts/check_architecture_boundaries.sh` enforces both halves: files under `Targets/PTYHost` may
import only `Foundation`, `Darwin`, `Dispatch` and `ThreadingPTYHostKit`, and may not name
`SwiftTerm`, `AppKit`, `ProjectStore`, `AppSettings`, `TerminalTheme` or `EventLog` outside a
comment. It is a lint rather than a paragraph because "the daemon should just log where the app
logs" is a one-line change that reads as an improvement, and this repository has already paid for
that mistake twice — a concurrent `ProjectDatabase.save` deleted a user's real projects, and two
processes appending to one journal left 23 unparseable lines.

### Connection binding

The 8-byte header carries no session id, so the connection carries it instead. A connection is
either **unbound** — it may send `hello`, `list`, `spawn`, `attach`, `retire` and `journalTail` —
or **bound to exactly one session** by a successful `spawn` or `attach`. After that, raw `output`
and `input` frames on it belong to that session, and `resize`, `detach` and `kill` must name the
bound id. Naming a different one is an `error(notAttached, sessionMismatch)` and a close: a
connection and an app that disagree about what is attached would send every later keystroke to
whichever of them is wrong.

A session may have several bound connections — the app, a test, later the phone's mirror — and
output fans out to all of them.

**`hello` is the first frame on every connection**, in both directions. Anything before it is
refused with `malformedFrame` / `beforeHello` and the connection closes, so the version gate
cannot be got around by asking a question first. An incompatible peer gets `helloRefused` naming
which side has to move, and then the close.

A close **flushes what is already queued**. Almost every close here follows an `error` frame
explaining it, and a close that discarded the queue would deliver the disconnection without the
reason. The one exception is the backpressure close below, where the peer is by definition not
draining.

### Spawn and the environment

`spawn` with `channel: .pty(grid:)` forks under a new pseudo-terminal sized by that grid — never a
placeholder, for the 2×1 reason above — using `executable`, `arguments`, `execName`, `environment`
and `cwd` **verbatim**. The daemon adds nothing and removes nothing: it inherits launchd's
environment rather than the user's, and the composition rules stay in the app where the measured
leakage list and the login-shell command line already live. `.pipes` is refused with
`spawnRefused(unsupportedChannel)` until native conversations are hosted; a duplicate id is
`alreadyExists`; a missing or non-executable file is `executableUnavailable`, checked before the
fork so the answer is a refusal rather than an exit status.

The reply is `spawned(id, pid, startTime)`, where the start time is read straight back out of the
kernel with `proc_pidinfo` — the same pair the app's orphan sweep uses, because a pid on its own
does not identify a process. The spawning connection becomes bound and attached.

`forkpty` gives the child its own session, so the child is a session leader and its process group
id is its pid; the daemon never has to track a group separately. Between fork and exec the child
does only async-signal-safe work: it puts every terminal-relevant signal disposition back to the
default (an ignored disposition survives `exec`, and a child that inherited the daemon's ignored
`SIGPIPE` would be a terminal where ^C does nothing), enters the working directory, and execs. A
working directory that cannot be entered **ends the child** with status 126 rather than starting it
somewhere else: an agent writing files into whatever `/` happens to be is worse than a launch that
failed and said so.

Every long-lived descriptor is `FD_CLOEXEC` — the listener, each master, the journal and the state
file. This is not hygiene: `crash-recovery.md` records ten agent CLIs each holding a descriptor of
the app's long after the app was gone, and this process is about to become the parent of exactly
that kind of child.

### Output, the ring and backpressure

A master is read on its own channel in bursts of at most 64 KiB, well inside the wire's 1 MiB
bound, so a repaint crosses as several frames rather than one a slow watcher cannot use yet. Each
burst is **appended to the ring first** and then fanned out: the ring is the stream, and a byte
that reached a watcher without reaching the ring is a byte a rejoin cannot account for. A burst for
a **detached** session therefore costs one append and one comparison — the frame is never built and
nothing is allocated per watcher, because there are none.

**The PTY read never waits for a watcher.** A connection whose queued writes pass
`maximumPendingWriteBytes` (4 MiB — eight full rings) is closed and journalled. The alternative is
waiting for it, which stops the child producing the bytes, and a stalled agent is a worse outcome
than a terminal that has to reattach.

Input is bounded the same way and in the other direction: a session with more than
`maximumPendingInputBytes` (1 MiB) outstanding towards its child has a child that has stopped
reading, and a larger buffer would only move the failure, so the input is dropped and journalled.

The ring is 512 KiB per session with a **32 MiB aggregate cap**, because a per-item cap is not an
aggregate bound: 64 detached sessions at half a mebibyte each is 32 MiB resident in a process the
user can see in Activity Monitor. Past the cap the **oldest detached** session's ring is halved
towards a 32 KiB floor and every shrink is journalled. An attached session is never shrunk —
somebody is watching it, and the cost is a rejoin they can see — so if everything is attached the
cap is exceeded and the journal says so, which is the honest answer.
`RemoteRingBuffer.resized(to:)` carries `totalBytesWritten` across the shrink, because that count
is a rejoining watcher's whole notion of where it was.

### The join replay

`attach(id, replayBudget)` answers `attached(id, pid, grid, replay, totalBytesWritten)` and then
writes the replay bytes as `output` frames, on that connection, before any live output. The
ordering needs no barrier: every frame is queued from the one serial queue and a channel performs
its writes in the order they were submitted.

- A stored detach seed whose offset the ring can still prove → `.exact(fromOffset:)`, and the
  bytes are the screen seed, then `snapshot(from:)`, then the mode seed.
- Otherwise → `.cut`: `CAN` (0x18) then the ring tail within the stated budget, and a stored mode
  seed still goes last if there is one.
- An empty ring → `.none`.

**A close without a `detach` clears the seed**, so the next attach is a cut. The daemon cannot know
how much of the ring a watcher that vanished had applied, and an honest cut the app re-derives from
is better than a replay of a screen nobody handed over.

**The daemon answers no terminal query.** A `DA2`, an `XTGETTCAP` or an `OSC 11` from the child
lands in the ring like any other byte and is answered, once and late, by the app's own emulator on
the exact-replay branch — those bytes have never reached an emulator, and `ringOffset` is what
proves it. On the cut branch the app feeds the tail with its replies suppressed, because history is
not a live query and a stale `DA` reply sent to a program that already got one is worse than
silence. This is affordable only because **v1 never spawns while detached**: the app composes and
spawns every session with its emulator attached, so a startup query is answered then, as it is
today. Spawning with the app closed is the slice that would have to decide between a fixed query
table in the daemon and `COLORFGBG`/`TERM` in the spawn environment; it is out of scope until then.

A session that has already exited is still worth attaching to: the watcher gets `attached`, the
replay, and then `exited`. It is owed the ending *after* the history rather than instead of it.

### The last window size

`resize` sets the grid, applies `TIOCSWINSZ` and raises `SIGWINCH` on the foreground group; the
grid is then the session's durable window size, kept indefinitely while nobody is attached. **An
attach never resizes** — the watcher is told the grid and adopts it. `PTYHostDaemonTests` asserts
both halves by asking the child what `stty size` says, which is the only assertion that can tell a
daemon that resized the terminal from one that sent the right frames.

### Foreground

`foreground(id, processGroup)` is pushed whenever `tcgetpgrp` changes: after each coalesced output
burst, and on a 1 Hz timer while at least one watcher is attached, never while detached, because a
detached session has nobody to tell. It exists because `TerminalSession` decides title ownership
from `tcgetpgrp` on a descriptor it owns, and a host-backed session has no descriptor to read —
the daemon holds the master, so this is the one question it can answer for the app without
learning anything about the byte stream.

### Exit, kill and release

`kill(id, escalate)` sends `SIGTERM` to the process **group**, and `SIGKILL` to the group after a
2-second grace when asked to escalate. The group rather than the process, because an agent CLI's
own children are in it and signalling the leader alone is how orphans are made.

An exit is noticed through `EVFILT_PROC`/`NOTE_EXIT` and reaped with a non-blocking `waitpid`,
retried on the queue rather than waited for. **The `exited` frame waits for the output that
preceded it**: the child's last write is usually still in the terminal buffer when the kernel
reports the exit, and a watcher told "it ended" before it is shown the ending has lost exactly the
bytes it most wanted. The wait ends at end of file on the master, or after a bounded grace, because
a surviving grandchild can hold the slave open indefinitely.

The session is then **held**, not dropped: for five seconds once somebody has seen the ending, so a
watcher that reconnects a moment later still learns how it ended rather than being told the id is
unknown; for half an hour if nobody was attached, because the app may be closed; and at once if the
daemon is retiring, since it is being replaced and the app has already been told. Release closes
the master, cancels the timers, unbinds any watcher still holding it, and is journalled.

### Retire

`retire` stops accepting, closes the listener and **unlinks the socket immediately** so a
replacement binary can bind the path, keeps serving what is already attached, and `exit(0)`s when
the last session ends — after a short flush, because writes are asynchronous and exiting the
instant the last session is released can truncate the frame that said so.

**A daemon that has not been asked to retire never exits on its own**, however idle it is. launchd
binds the registration to the path rather than to the code, so an exit is an upgrade only when
somebody asked for one; a daemon that exited when it went idle would be replaced by whatever binary
is on disk at a moment nobody chose.

### The state file, and what a restart lost

`sessions.jsonl` in the state directory is append-only over `O_APPEND`, one versioned record per
lifecycle edge — `spawned`, `exited`, `lost` — written **synchronously, before the edge is reported
to anybody**. The record that matters most is always the one written immediately before the process
died, and a child nobody wrote down is a child a restart cannot even say it lost. It is read
leniently: a line that does not parse is skipped and counted, because the file exists to be
readable after a crash truncated a write, and refusing it whole would throw away every session
before the damaged line.

On start, every `spawned` with no ending is probed by pid **and** kernel start time. Neither outcome
is "carry on": a child of a dead daemon has no master anybody holds, so there is nothing to attach
to it and nothing to read from it. Each is recorded as `lost` and reported in a `lost` frame after
every `hello`, for this daemon's whole life — repeatedly rather than once-and-acknowledged, because
an acknowledgement is a fourth state to get wrong for no gain: the app's answer is idempotent, and a
second Threading or a support tool is owed the same answer as the first.

**A survivor's process group is killed there.** "They all died with the host" turned out to be
false: measured on 2026-08-23, a `sleep` spawned by this daemon and orphaned by `kill -9` of it went
on running as `Ss+`, session leader of a terminal nothing holds, reparented to launchd — the
`SIGHUP` the failure model assumed does not reach a process that never touches the tty. This is the
only place that can end it, because the app's orphan sweep skips host-held children by design
(Slice 1's `heldByHost`), and an agent still working in a session no surface can reach is worse
than one that ended. It is R4 in the design's risk register, answered.

### Failure model

- **A restart restores the service, not the work.** The honest goal is to say what was lost, which
  is what `sessions.jsonl` and the `lost` frame are for.
- **A bad frame closes one connection.** A malformed control frame, an oversize length, an unknown
  kind, a frame the daemon is supposed to be the one sending — each is journalled and ends that one
  connection. The process never exits on input, because `KeepAlive` plus a poisoned frame is a
  restart storm, and the other sessions are somebody's working agents.
- **`SIGPIPE` is ignored process-wide** and `SO_NOSIGPIPE` is set on every socket. Either alone is
  one edit away from being removed by somebody who saw only the other.
- **The daemon unlinks a stale socket, not the app.** It is the only process that may be listening
  there, so it is the only one that can tell a leftover file from a live listener without a race.
- **The state directory is created `0700` and set `0700` again**, because it may already exist from
  a run with a different mask. That directory is the whole authorization boundary: no frame carries
  a token, and this is why none needs to.
- **The daemon's journal is its own**, in its own directory, pruned by itself after seven days, and
  read by the app only as a bounded tail through `journalTail`. The app's journal prunes any
  `.jsonl` it finds in its own directory, and two processes appending to one file has damaged a
  journal here before.

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
| `requiresApproval` | registered, and waiting for the user in System Settings ▸ Login Items | in-process PTY |

The last three are **set by registration, not by the probe**. `PTYHostAvailability.resolve` has no
`SMAppService` and deliberately none — a launch-path call into a framework that can block is not
what a probe is for — so they are spelled out now and filled in by the registration slice. They
are separate cases rather than one because P2 measured the difference: launchd binds a
registration to a *path*, so "seen, currently off" and "never seen" want different fixes and only
one of them is re-registering — and `requiresApproval` wants neither, only the user's switch.
[Registration and retirement](#registration-and-retirement) is where they are filled in.

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

## Registration and retirement

The daemon starts itself, or it does not and every PTY runs in-process. Registration is
`SMAppService.agent(plistName:)` against
`Contents/Library/LaunchAgents/codes.threading.ptyd.plist`, which the app bundle ships through a
**Copy Files** phase and seals as an ordinary resource — it is not nested code and is not signed
separately, unlike anything under `Contents/Helpers`, which `codesign` treats as code even when
it is a shell script.

Measured on 2026-08-23 from a Debug, ad-hoc-signed bundle, which is the least favourable case:
`register()` returns without throwing, `status` goes straight to `enabled`, launchd starts the
helper as a child of pid 1, and there is **no approval step at all** — the Background Task
Management record is already `[enabled, allowed, notified]`, so the user is told afterwards rather
than asked first. `unregister()` is clean and **kills the running helper**, which is a fact the
"turn it off" path is built around rather than a detail.

### The plist, key by key

| Key | Value | Why |
|---|---|---|
| `Label` | `codes.threading.ptyd` | what launchd addresses; the file name is what `SMAppService` addresses, and both have to name one service |
| `BundleProgram` | `Contents/Helpers/threading-ptyd` | bundle-relative, so replacing the whole bundle leaves the registration valid. launchd accepts `Contents/Helpers` exactly as readily as `Contents/MacOS` — both arms of the probe reported `program identifier = … (mode: 2)` and ran |
| `ProgramArguments` | `[Contents/Helpers/threading-ptyd, --default-locations]` | see below; `argv[0]` is the bundle-relative program, which is what launchd passes anyway |
| `KeepAlive` | `true` | the upgrade mechanism, not only resilience — it is what execs the new binary after a `retire` |
| `RunAtLoad` | `false` | kept beside `KeepAlive` to state the intent. `KeepAlive` already starts the job at load (`immediate reason = speculative`); this is a daemon that is kept running, not one that runs once at login |
| `ThrottleInterval` | `10` | crash-loop containment; reported as `minimum runtime = 10`. The other half is the daemon's own rule that a bad frame closes one connection and never the process |
| `ExitTimeOut` | `10` | how long launchd waits after `SIGTERM` before `SIGKILL`, at logout or unregister. The daemon does not trap `SIGTERM`: its children are the user's agents and the session is going with them |
| `ProcessType` | `Interactive` | a process holding somebody's working agents must not sit in the throttled background band. Reported as `spawn type = interactive (4)`, jetsam priority 40 |
| `AssociatedBundleIdentifiers` | `[codes.threading]` | what makes the Login Items row read as Threading rather than as a loose helper nobody recognises |
| `StandardOutPath` / `StandardErrorPath` | **absent** | the daemon keeps its own dated journal in `pty/` and prunes it after seven days; a launchd redirect would be a second file nothing reads and no retention rule covers |

### `--default-locations`, and why the daemon has one derivation after all

The daemon requires `--socket <path> --state <dir>` and refuses a half-named command line, because
where those live is the app's decision and a daemon listening somewhere nobody is looking is
indistinguishable from one that never started. launchd cannot express that decision: the plist is
a file **inside the signed bundle**, one copy shared by every account on the machine and
unwritable at runtime without breaking the seal, and `ProgramArguments` reaches `execvp` verbatim
with no `~` expansion.

The two ways out were to write a per-user plist outside the bundle at registration time — which
forfeits `SMAppService`, whose whole contract is a plist the bundle ships — or to let the program
derive the paths when it is asked to. It is the second, and the ask is explicit: a
`--default-locations` flag that the plist uses and **nothing else does**, mutually exclusive with
`--socket`/`--state` rather than a fallback for them, so a typo cannot quietly become "the default
one". Every test still names its own scratch rendezvous, which is what keeps a test daemon off the
socket the developer's running app is listening on.

The names both processes derive from live in `PTYHostDefaultLocations`, in the package both ends
link, so "where is the socket" has one answer even though two processes ask it. The app composes
its own paths from those names through `PTYHostLocation` (which additionally redirects under a
hosted test bundle); the daemon derives
`~/Library/Application Support/Threading/pty` from `FileManager` rather than from `$HOME`, because
a launchd agent's environment is whatever launchd chose to hand it. A test pins the two
derivations to each other, because nothing else does.

Verified end to end on 2026-08-23: launched with `--default-locations` the daemon created the
`0700` directory, bound `…/pty/ptyd.sock` and journalled it; `--default-locations --socket …`,
`--socket` alone and a repeated flag each exit `64` with the usage line.

### Where registration happens in a launch

In `applicationDidFinishLaunching`, **after** `SingleInstanceLock.acquire()` and **after** the
launch-mode decision, below the `plan.startsBackgroundServices` guard. Recovery therefore never
reaches it, and `PTYHostRegistration` refuses recovery again on its own — a guard that exists only
at the call site is a guard the next call site does not have. A recovery launch that registered
would be installing something that outlives it at the exact moment the last launch did not come
back.

A **hosted test bundle never registers either**, and that refusal is sharper than it looks: the
bundle a test runs in *is* the shipping app, so `SMAppService.agent(plistName:)` from a test would
address the developer's own Threading, register their login item, and start a daemon on their
machine — and `unregister()` would then kill it. `PTYHostRegistrationCoordinator` refuses before it
so much as reads `status`, and `PTYHostRegistrationTests` asserts the call count is zero. The one
real registration this feature has ever performed was from a throwaway bundle with a `-probe`
label, unregistered afterwards.

Registration is **idempotent**: an `enabled` status is answered without calling `register()`, so
the ordinary launch costs one status read. The setting is followed with `AppSettingsDidChange`,
reconciled from the current value, the way every other behavioural key is — so turning the key on
takes effect without a restart.

`SMAppService.Status` becomes a `PTYHostUnavailability` in one place:

| Status | Availability | Note |
|---|---|---|
| `enabled` | *candidate* — nothing to report | whether a daemon is listening is the socket probe's question |
| `requiresApproval` | `.requiresApproval` | the one reason with an action attached: `PTYHostRegistration.openLoginItemsSettings()`. Never seen on this machine; a managed Mac can require it |
| `notRegistered` | `.notRegistered` | launchd has seen the label and it is off — registering again is the fix |
| `notFound` | `.notFound` | launchd has never seen it |
| anything newer | `.notRegistered` | journalled with its raw value; `@unknown default` is handled once |

### Retiring a daemon the last bundle left behind

**launchd binds a registration to a path, not to a code identity.** Measured: replacing the whole
bundle leaves `status` at `enabled` and the running daemon executing the deleted binary's image;
launchd execs the new binary only on the next start. Nothing in the OS will end it, and this
repository replaces `/Applications/Threading.app` several times a day.

So the app asks, once per launch, off the main actor: connect, `hello`, `list`, and then one pure
decision.

| `hello` build | protocol gate | sessions held | Decision |
|---|---|---|---|
| same as the app's | compatible | any | leave — replacing a process with its own image buys nothing, and this is the ordinary answer |
| different | compatible | 0 | **`retire`** — the daemon unlinks its socket, exits, and `KeepAlive` starts the binary on disk. That is the upgrade |
| different | compatible | *n* > 0 | leave, journalled as "a stale PTY host holds *n* sessions; it retires when idle" |
| any | `peerTooOld` | any | refuse. The handshake has already sent `retire`; saying it twice is a second retirement |
| any | `selfTooOld` | any | refuse, and **never retire**. Retiring a daemon newer than this app would take working agents down in order to install an older host |

`PTYHostUpgradePolicy.decide(peerBuild:ownBuild:compatibility:heldSessions:)` is that table and
nothing else — no I/O, four value arguments, because every interesting case is a combination
rather than a code path. `PTYHostUpgradeCheck` is its one caller with a socket: it uses the
shipping `PTYHostClient` rather than a simplified dialect, because a check that spoke less than the
link does could reach a conclusion about a daemon the link then refuses. Nothing listening, a
refused connect, or a `list` that misses its deadline are all "no decision", and every caller's
response to that is to leave the daemon alone.

After sending `retire` the check waits for the daemon to hang up rather than closing on top of the
frame: the write is asynchronous and `close()` stops the channel. A retiring daemon with nothing
to drain exits immediately, so the wait is the ending rather than a delay.

### Turning it off

`unregister()` kills the running helper, and the running helper may be holding a person's agents.
Turning a hidden preference off must not be a way to end somebody's turn, so the off path counts
first:

- **nothing held, or nothing answered** — unregister. There is no daemon to kill.
- **sessions held** — leave the registration in place, journal `leftForRunningSessions`, and stop
  using the host. With the key off, `AppSettings.ptyHostEnabled` short-circuits the availability
  decision before anything connects, so the app is already on the in-process path; the next launch
  that finds the daemon idle removes the registration.

Deliberately **not** `retire` in that second case. Retiring unlinks the socket, and a user who
turns the key back on would then be unable to reach the sessions still running under it — the
opposite of what the daemon is for.

Nothing new goes on disk for any of this. The registration's state is launchd's: the Background
Task Management record and the Login Items row, both keyed by the label, and neither of them
Threading's to write.

### What registration does not cover

No UI. The Advanced page's controls, the Background Sessions list and the quit question are the
visibility surface, and they are the next slice. And the hidden key stays **off by default** until
R1 — TCC attribution of a launchd agent's children — has been run on a SIP-enabled Mac; see
[`permissions.md`](permissions.md#the-pty-host-daemon-breaks-the-parent-relationship-and-that-is-unverified).

## What is not decided here

Registration and retirement, the `TerminalSession` host-backed mode, and the visibility surface
(the quit question, the launch band, the Background Sessions list) are later slices. When they
land, each adds its section here rather than a new document.
