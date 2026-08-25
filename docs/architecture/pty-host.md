# The PTY host

Status: **a session survives a quit and a relaunch, on a terminal or on pipes, and the app now
says so.** `Packages/ThreadingPTYHostKit` holds the contract, `Targets/PTYHost` is the daemon and
launchd starts it, `Sources/Threading/Core/PTYHost` can connect to it, refuse an incompatible one
and say why it did not, an **agent session** runs its child there instead of in this process,
a **native conversation** runs its CLI there over three pipes, and quitting Threading hands those
children over rather than killing them — the next launch takes the terminals back, replays exactly
what they missed where it can, does not reflow an agent that kept working, and resumes each
conversation from what its CLI wrote while nobody was watching. Three surfaces report it: the quit
question, a once-per-launch band, and the Background Sessions list on the Advanced page.
`AppSettings.ptyHostEnabled` ships off, so every session runs in-process exactly as before unless
somebody turns it on. The feature it serves — sessions that outlive the app — is
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
| `sessions` | ← | 0 | `[PTYHostSessionSummary]` — `id`, `pid`, `startedAt`, `executable`, `grid`, `isAttached`, `exit`, `channel` |
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
| `closeInput` | → | 0 | `id` |
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

**Deferred but shaped for.** The compression bit in `flags`. `channel: .pipes` was the other one
and is now implemented — see [Pipes](#pipes) — which cost the protocol one frame (`closeInput`), one
`flags` bit and one optional summary field, and bumped nothing, which is exactly what deciding the
discriminator in version 1 bought. `foreground` was deferred too and then was not: the app decides
title ownership from `tcgetpgrp` on a descriptor a host-backed session does not have, so the frame landed in v1 — the
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
leakage list and the login-shell command line already live. `.pipes` forks the same way through
`posix_spawn` — see [Pipes](#pipes); a duplicate id is `alreadyExists`; a missing or
non-executable file is `executableUnavailable`, checked before the fork so the answer is a refusal
rather than an exit status. `unsupportedChannel` survives with no channel to refuse, because the
refusal is the rule rather than the case: an unimplemented channel is always a refusal and never a
substitution, since a conversation transport quietly given a pseudo-terminal would look like a
working session producing unparseable output.

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
daemon that resized the terminal from one that sent the right frames. The app's half of that rule —
adopting a grid rather than imposing one, and not sending it straight back — is
[The durable grid](#the-durable-grid).

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

The controls that drive it. The Advanced page's switch, the Background Sessions list and the quit
question are [the visibility surface](#the-visibility-surface). And the key stays **off by
default** until
R1 — TCC attribution of a launchd agent's children — has been run on a SIP-enabled Mac; see
[`permissions.md`](permissions.md#the-pty-host-daemon-breaks-the-parent-relationship-and-that-is-unverified).

## What changes in the app

**The terminal view does not change class.** `EmojiFixedTerminalView` carries the emoji and
background compositing fixes, the two resize gates, `onOutput`/`onOutputBytes`, `onBell`,
`onUserInput`, `acceptsLocalInput`, `onLocalInputBlocked`, `onMouseReportForwarded`,
`onInputBytes`, `onLowContrastText`, the drag-and-drop registration and the context menu; feeding
a plain `TerminalView` instead would re-litigate all of it. So the class stays and
**`startProcess` is simply never called on a host-backed instance**. With no child,
`process.running` is false, and `LocalProcess.send` and `LocalProcess.updateWindowSize` guard on
exactly that — so the inherited path is inert rather than wrong, and only four seams move.

| Seam | In-process | Host-backed |
|---|---|---|
| `EmojiFixedTerminalView.send(source:data:)` | `super.send` → `process.send` | `hostTransport.sendInput` — an `input` frame |
| output | `setProcessOutputBytesHandler` → main hop → `onOutput`, `onOutputBytes` | `feedFromHost(_:answersQueries:)` → `feed(byteArray:)`, then **the same two callbacks in the same order on main** |
| `sendWindowSize(_:)` | `process.updateWindowSize` | a `resize` frame carrying the whole `winsize` |
| `TerminalSession.terminate()` | `terminalView.terminate()` | a `kill` frame; the view's process is never touched |

The third is the one SwiftTerm fork change this whole design needs, and it is recorded in
[`dependencies.md`](dependencies.md).

`TerminalHostTransport` is those three operations as a value of closures, held by the view;
`PTYHostTerminalLink` is what fills them in, owning the connection and turning the daemon's frames
into the session's edges. The link coalesces output into **one main-queue hop per burst** — the
client's read loop never touches main, which is the scaling gate's rule for a callback whose
frequency is a terminal's output rate — and it delivers a `spawned` pid, a `foreground` group and
one ending. **A link that is released kills its child**, because until detach and reattach land
there is no way to hand a session over, and an agent still working where no surface can reach it
is worse than one that stopped.

### Replayed history answers nothing

`feedFromHost` takes `answersQueries` because SwiftTerm replies to `DA`, `DSR` and `OSC` colour
queries by sending bytes back, and a replay is history: the program that asked has already had its
answer, and a second, stale one is worse than silence. The exact-replay branch carries bytes no
emulator has ever seen and **must** answer them; the cut branch must not. It is a property of the
feed rather than of the session for exactly that reason.

The scope closes one main-queue turn *behind* the feed rather than at the end of it, because
SwiftTerm's `TerminalDelegate.send` always hops through `DispatchQueue.main.async` — even when it
is already on main — so a reply provoked by a feed arrives on a later turn. And only the
emulator's own answers are swallowed: a keystroke arriving in that window runs inside
`withLocalUserInput`, and remote injection sets its own flag, so both are told apart from a reply
that has neither.

### The choice, and where it is made

`AgentSession.backgroundHost: Bool?` is the per-conversation opt-in, in the tri-state
`AgentSession.fastMode` and `remoteControl` established: nil inherits, and it survives to the JSON
rather than collapsing into a boolean on the way, so a record written before the field existed
reads as "no opinion" rather than as a decision to stay in-process. `PTYHostPolicy.hostsSession`
resolves session → `AppSettings.ptyHostEnabled` → false. A session that says yes while the
hidden global is off still runs in-process, and not because the policy lies to it:
`PTYHostAvailability` answers `.disabled` first and without touching anything, so the global is a
master switch *through availability* while staying an inheritable default in the policy.

**No new `AgentKind` capability.** Whether a session has a pty at all is already
`kind.supports(.terminalUI)`, withheld from one runtime for a reason of its own; a
`.backgroundHost` capability would be true for four runtimes and false for the same one, for the
same reason, which is a duplicated fact. `AgentCapabilities`' own rule refuses it: a capability
earns a member only when the difference is a static fact about the *runtime*, and host-backing is
a fact about the surface.

The composition happens once per launch, in `AgentSessionViewController.startIfTerminalIsSized` —
the surface that holds the conversation record, and the point at which the deferred-launch gate
has already laid the terminal out, so the grid the daemon is handed is a real one rather than
SwiftTerm's 2×1 clamp. Policy first (a `UserDefaults` read), then `PTYHostAvailability.live`, and
anything short of `.available` is an in-process launch and one journal line naming the
unavailability token. `TerminalSession` itself never reaches for the store or the settings: it is
handed a factory or it is not.

### What degrades, and what does not

- **Activity is unchanged while attached.** `SessionActivityTracker` reads `onOutput`'s byte
  count, which `feedFromHost` fires identically, and the hooks still route by durable token and
  reach the app whenever the app is running. While the app is *closed* a hook posts into a dead
  socket and is dropped, so a session that finished overnight can come back reading stale; the
  transcript boundary readers the code already has are the answer, and they arrive with reattach.
- **Titles keep working, through the emulator.** `TerminalNaming` reads OSC 0/2 through
  `setTerminalTitle`, which fires from the emulator, which is still here. The daemon parses
  nothing to make this work.
- **The foreground group is pushed, not polled.** `TerminalSession.ptyDescriptor` is
  `terminalView.process?.childfd`, which is `-1` host-backed, so `tcgetpgrp` has nothing to ask.
  `currentForegroundGroup()` is the one place that knows there are two sources: the descriptor for
  an in-process session, and the last `foreground` frame for a host-backed one. The nil rule is
  the same on both sides — the session's own command in the foreground is not another program —
  so `refreshForegroundProcess()`, `foregroundIsAnotherProgram()` and the title's owner all read
  one answer.
- **The working directory is preserved.** `spawned` reports the child pid, the session sets
  `shellPid` from it, and `effectiveWorkingDirectory()`'s `proc_pidinfo` fallback and
  `AgentRuntime.terminalRootProcessIdentifier` go on answering. OSC 7 is unaffected; it comes
  through the emulator.
- **The remote mirror is unaffected.** It taps `onOutputBytes`, which fires in the same place it
  did.

### What host-backing says on screen

[The visibility surface](#the-visibility-surface): the quit question, the launch band and the
Background Sessions list.

## Detach and reattach

This is the half that makes the feature a feature: quitting leaves the agents working, and
launching picks them back up into the same conversations.

### What a quit sends

`AppDelegate.applicationShouldTerminate` calls `AgentRuntime.detachHostBackedSessions()` **before**
`terminateAll`, which would otherwise kill exactly these children. Each host-backed session sends
one `detach` carrying three things only this process can produce:

- `screenSeed` — `RemoteScreenSeed.repaint(of:)` of the live emulator. The daemon cannot synthesise
  a screen because a repaint is derived from an emulator and it has none; the app is present at
  exactly the moment the last watcher leaves, which is what makes this possible at all.
- `modeSeed` — `RemoteTerminalModeSeed.bytes(for:)` of the modes read off the same snapshot.
- `ringOffset` — where this watcher had got to in the daemon's own `totalBytesWritten` units,
  tracked by `PTYHostTerminalLink` from the byte counts it has delivered.

The whole set is bounded by **one** deadline (`PTYHostSessionDefaults.detachDrainSeconds`), not one
per session: `DispatchIO` reports a write complete later and on this path the close is the process
exiting, so the frames are drained before the app goes — and forty host-backed sessions must cost
one wait rather than forty. Losing a `detach` is not losing the session: a close without one leaves
the child running and clears the seed, so the next attach is a cut.

`terminateAll` keeps the same guard for anything that reaches it another way, because tearing every
session down must not become a way to kill a child nobody asked to stop. **An explicit stop still
kills**: `TerminalSession.terminate()` sends `kill`, and only a released link — a watcher that
simply went away — closes and lets go. A deinit deliberately does *not* send `detach`, because a
deinit has no emulator to repaint from: the seeds would be empty, and an `.exact` replay of bytes
with no screen to put them on is worse than the honest cut a bare close produces.

The quit question's count excludes host-backed sessions, because its message says every open
session closes and only work in flight is lost, and neither is true of one the daemon keeps. The
*wording* is the visibility surface's; this is only the count refusing to overstate.

### What a launch takes back

`PTYHostReattach.run` connects, `list`s, and classifies what came back against what the app still
has. Five answers, because "the daemon has it" is not one fact:

| | What happens |
|---|---|
| running on a **pty**, and the conversation exists | taken back — a controller is built the way a dormant session's is, and its `TerminalSession` **attaches instead of spawning** |
| running on **pipes** | ended here, and the conversation resumed from its transcript — see [Pipes](#pipes) for why a request/response transport cannot be rejoined |
| `exit != nil` | the exit is recorded on the session record and the row stays dormant with that status, exactly as an in-process ending would have left it. `lastActiveAt` is untouched: nobody recorded when it ended |
| the conversation is gone or archived | `attach` then `kill(escalate:)`, journalled. Nothing can ever show that child again |
| in the daemon's `lost` set | journalled, and left to `relaunchSessionsFromLastQuit` to resume from its transcript. The daemon cannot hand it back, so holding it back from the relaunch would strand it |

The first and third are what the relaunch must skip; the other three are not. `relaunchSessionsFromLastQuit`
runs **after** this and plans only what the host does not hold — see
[`crash-recovery.md`](crash-recovery.md#what-a-recovery-launch-does-not-write) for what that does
to the running-sessions record, and [`sessions.md`](sessions.md#the-sessions-that-come-back-on-their-own)
for the launch set. With the hidden key off the whole step answers on the calling turn without
opening anything, so a launch with the feature off is the launch it has always been.

Taking eight sessions back costs about what starting eight bare children costs — roughly 3 ms
each, measured, with the numbers and the two things they deliberately leave out in
[`performance.md`](performance.md#taking-sessions-back-against-starting-them).

The survey's connect **is** the availability probe rather than a second one beside it:
`PTYHostAvailability.resolve` owns the order those questions are asked in, and the probe closure it
is handed keeps the client it made so the `list` goes out on the connection the gate has already
admitted.

### The feed rule, and the one thing the wire does not carry

`attached` says what the bytes that follow are, and the app feeds them accordingly:

- `.exact` — every byte is fed with `answersQueries: true`. Those bytes have never reached an
  emulator, so a `DA2` or an `OSC 11` in them is a question nobody has answered and **must** be
  answered, once, late. `ringOffset` is what proves they are new.
- `.cut` — the replay is fed with the emulator's replies suppressed. History is not a live query,
  and a stale `DA` reply reaching a program that already had one is worse than silence.

The boundary between the replay and the live output behind it is the one thing the wire does not
carry. The daemon queues the whole replay from its serial queue before it binds the connection, so
the replay is the head of what arrives; `PTYHostTerminalLink` therefore ends the suppression at its
**first coalesced flush**, which errs towards swallowing one live reply for one main-queue turn
rather than answering history. That is the safe direction, and it is stated here rather than left
to be discovered because the exact fix is one field: a replay byte count on `attached` (or a flags
bit marking replay frames) would make the boundary exact instead of prompt.

The same missing field has a second consequence, and it is the honest cost of this slice. A link
that attached with a replay counts the replay bytes along with the live ones, because it cannot
tell them apart — so its `ringOffset` is an **upper bound** rather than the exact value.
`RemoteRingBuffer.snapshot(from:)` refuses an offset ahead of its own count by design, so the
attach *after* a reattach is answered with a cut rather than with duplicated bytes: the first
restart replays exactly, and a second consecutive restart re-derives from a tail. Under-counting
would duplicate bytes into a live screen, so this is the direction to be wrong in, and it is a
daemon-side field away from not being wrong at all.

### What a reattach re-derives, and what it cannot

The tracker is a **new** one, so there is nothing stale to correct — the staleness R7 names comes
from hooks posted into a dead socket while the app was closed, and those never reached a tracker
that did not exist. From there the ordinary readings resume: output inference for every runtime,
and Claude's and Codex's transcript boundary readers as their own output callbacks re-arm them
(`resetTranscriptFallbackObservation` drops the previous process's paths, because a resumed
conversation and a migrated account both change the answer). Grok and OpenCode have no transcript
boundary to read and stay on output inference, which is R7's accepted cost; no second
reconciliation is invented for them.

`noteUnattendedLaunch` is granted for the same reason a background relaunch grants it: nobody is
looking, and a replay is a repaint — without it the rejoin's first burst reads as a finished turn
and marks every recovered session unread.

Titles and the working directory come back on their own: the pid arrives in `attached` and becomes
`shellPid`, and OSC 0/2 and OSC 7 come through the emulator, which is here again.

## The durable grid

**An attach never resizes**, and the app's half of that rule is to *adopt* rather than impose.
`TerminalSession.attachToHost(grid:)` puts the emulator on the daemon's grid **before** a byte of
the replay lands, so a screen written at 100×40 is rendered at 100×40; imposing this window's grid
first and reflowing afterwards would be a screen nobody ever saw.

Adopting a grid is itself an emulator resize, and SwiftTerm reports one through `onMain` — a
main-queue turn later, by which time the link is installed. Telling the daemon the size it has just
told us would raise `SIGWINCH` on an agent that has been working at that size all along, which is
precisely the reflow reattaching must not cause. So `EmojiFixedTerminalView` remembers the adopted
grid and refuses to send it back; a window size that differs — the user resized Threading while it
was closed — is a real change, is sent once, and ends the comparison. It is a comparison rather than
a timer because a timer is a guess about how long AppKit takes to lay out.

`PTYHostReattachDaemonTests` asserts both halves the only way they can be asserted: the child
installs a `SIGWINCH` handler that appends `stty size` to a file, and the file is still empty after
a whole detach-and-reattach cycle and has exactly one line after the window genuinely moves. The
screen cannot be the witness here, because a replay puts an earlier size line back on it.

## Pipes

A native conversation's CLI has no terminal. It is `posix_spawn`ed with three pipes, a process
group of its own, and `waitpid` — `AgentChildProcess`'s existing spawn contract minus the
`Process` object — and the daemon relays bytes across it without reading one. That was decided in
version 1 as `spawn`'s `channel` discriminator and shipped last, because the pipe path is not more
daemon code; it is a great deal more *app* code, and re-hosting three transports under a new
transport in the same change as the terminal one would be two risky changes wearing one commit.

### Three streams stay three

The daemon reads standard output and standard error on separate channels and keeps them separate
on the wire: stderr crosses as a `kind` 1 frame with `PTYHostFramingDefaults.standardErrorFlag`
set. Merging them would corrupt the newline-delimited JSON the transports parse, which is
`AgentChildProcess`'s own rule rather than a new one.

**A flag rather than a fourth `kind`.** An unknown `kind` byte is terminal to the decoder — there
is no resynchronisation point in a length-prefixed stream — so a stderr burst reaching a build that
predates it would close the connection rather than be ignored. `flags` is already carried through
untouched, so an older build reads diagnostics as ordinary output instead of dropping the link,
which is the milder of the two wrong answers.

**Only standard output reaches the ring.** A rejoining watcher parses one stream, and interleaving
the other into the replay would corrupt exactly what the replay exists to hand over; a second ring
would be a second `totalBytesWritten` for one `ringOffset` to mean two things by. Diagnostics are
live-only, which is also honest: a rejoin that replayed yesterday's stderr would be attributing an
old observation to a new one.

### What a pipes session does not have

Three things are absent rather than defaulted, and each is a refusal rather than a substitution:

- **No grid.** `resize` is answered `error(unsupportedChannel)` and the connection *survives* it —
  a well-formed frame for the wrong channel is not a frame that cannot be believed, and closing
  would end somebody's conversation over a caller's slip. The summary reports a 0×0 grid rather
  than a plausible 80×24, because a window size it does not have is a fact somebody would act on.
- **No `tcgetpgrp`.** No `foreground` frame is ever pushed. Not a degradation: the app asks that
  question only of a terminal, to decide whether a title belongs to the shell or to what it is
  running.
- **No screen.** A `detach` carries empty seeds, because a screen seed is a repaint derived from a
  live emulator and there is no emulator anywhere. So a rejoin is **always** a cut, and answering
  `.exact` off an empty screen would be a replay of bytes with nothing to render them into.

The cut tail is trimmed to a line boundary: everything before the first newline goes, leaving the
`CAN` alone on the first line and every line after it whole. A tail beginning mid-line would hand a
fresh parser one guaranteed malformed line — and, worse, one that reads as a provider protocol
error rather than as a cut. The daemon still parses nothing to do it: finding a byte is not reading
a stream.

### `closeInput`, and why it needs a frame

Every native transport ends a conversation by closing the CLI's standard input and letting it exit
on end of input. That is a *descriptor* event and has no representation in a byte stream, so
without a frame the only way to end a hosted conversation would be `kill`, which is the ungraceful
one. The daemon closes the channel rather than the descriptor — `DispatchIO`'s cleanup handler is
the descriptor's only owner — and closes it with `[]` rather than `.stop`, so whatever is still
queued reaches the child first: the last thing written before a goodbye is usually the request the
goodbye is about. On a `.pty` session the frame is answered `unsupportedChannel`, where the master
is one bidirectional descriptor and closing it is closing the terminal.

### The app's half: the same three descriptors

`AgentChildProcess.launch` gains a `host: PTYHostChildPlan?`. When it is set, the launch makes the
*same three pipes it always made* and hands the transport the identical ends — same `FileHandle`s,
same `F_SETNOSIGPIPE` on standard input, same end-of-file semantics — while `PTYHostPipeLink` owns
the other three and pumps them across the wire. So `ClaudeStreamSession`, `CodexStreamSession` and
`ACPStreamSession` see the same bytes, in the same order, through the same API, and the framing,
handshake deadlines, malformed-line counters and exactly-once exit callbacks each of them owns are
untouched. That is the property the whole slice rests on, and it is a property of the construction
rather than a claim.

**Nil is always "run it here instead".** No daemon, a version gate that refused, a `spawnRefused`,
a silence — each is a degradation to the launch this app performed before the daemon existed, each
is journalled with a structural cause, and none of them throws: a throw would be a launch failure
on a conversation that has a perfectly good way to start.

**The spawn is awaited, and the wait is bounded.** `AgentChildProcess.launch` is synchronous by
contract — the transports set `isRunning` on the line after it returns — so the host-backed path
has to know whether the child exists before it returns, which means waiting for `spawned` or
`spawnRefused`. The daemon answers straight out of `posix_spawn`, so this is a millisecond in
practice; `PTYHostPipeDefaults.spawnTimeout` exists so that a daemon which has stopped answering
costs a launch a fallback rather than a hang.

**One ending, delivered once.** An `exited` frame and the connection dropping under it are the same
fact seen twice. `PTYHostPipeLink.end(status:)` is guarded, closes the two output channels with
`[]` so the last of the child's output is read before the end of file that follows it, and only
then delivers the status on the main queue — a transport told "it exited" while its pipe was still
open would tear itself down with the child's last output unread. A link that ended without an
`exited` reports `128 + SIGHUP`, which is what a shell reports for a process that lost the thing it
was attached to, and is deliberately not the spawn-failure status: that means "it never started"
and would put a launch failure on a conversation that had been running for an hour.

### Why a conversation is not reattached

A quit hands the CLI over; the next launch **ends it and resumes the conversation from its
transcript**. That is the one asymmetry with terminals, and it is a property of the transport
rather than a shortcut. A terminal's whole state is a byte stream, which is why a replay can
reproduce it. A conversation's transport is a request/response protocol whose state — the
handshake, the thread identity, the turn in flight, the composer capabilities, the pending
permission — lives in the app, not on the wire, and a fresh app cannot pick up a stream that is
half-way through a turn it never started.

**What the child did while Threading was closed is not lost**, which is the point: it was written
to the provider's own transcript as it happened, and that is what the resume reads. So the cost of
a quit drops from "the turn in flight is lost" to "the turn in flight finishes without you", which
is the whole of what §4 asks for on this surface.

The end-and-resume is the reattach step's, not the relaunch's, and the relaunch **waits for it**:
each child is being ended precisely so a fresh CLI can start on the same conversation, and two CLIs
writing one provider transcript is the race that would make. An orphan has no conversation and
nothing waits on it, which is why that kill stays fire-and-forget.

Re-adopting a live conversation is the named follow-up, and it needs one thing this design does not
have: the transports' handshake state on the wire, or a way to re-derive it. Do not add it by
teaching the daemon to parse the stream.

## The visibility surface

Three places, no fourth. Work with no window has to be visible, and each of these answers a
different moment: what quitting will do, what a launch found, and where a wedged agent is.

**Rejected: an `NSStatusItem`.** The app has none, and a permanent menu-bar item is a new always-on
surface with its own icon, theme, accessibility and localisation burden for a fact that is only
interesting at two moments — quit and launch — both of which already have a place to say it.
Revisit only if the first two measurably fail.

### The quit question becomes a choice

`AppDelegate.quitConfirmation(runningSessionCount:inFlightTurnCount:)` still builds today's
two-answer `ConfirmationRequest`, and the three-answer overload **calls it** when nothing is
host-backed — so "the wording did not change for a launch without the background host" is true by
construction rather than by two copies being kept in step. With sessions in the daemon the question
becomes a `QuitQuestion.chooses`: *Leave 3 Running* / *Stop Them and Quit* / *Cancel*.

The counts are the whole difficulty. Sessions the daemon keeps are named as continuing; sessions it
**cannot** keep are counted separately and still described as closing, because that is what happens
to them; and the turns in flight are counted among the closing set only, since a turn being written
in a session the daemon keeps is not lost by quitting. Saying "3 sessions close" over a set where
two of them keep working is the exact overstatement this sheet already learned not to make once,
with agents that were merely idle.

**A choice cannot be suppressible.** `ConfirmationPrompt.quitWithBackgroundSessions` is
`.alwaysAsks(.newQuestionEachTime)`: a remembered answer has to be *an* answer, and a box beside
three of them says nothing about which one it would repeat — the question names a set of agents
that did not exist when the last answer was given. The user's switch on the *sibling* prompt is
still honoured at the call site and resolves to `.leaveRunning`: somebody who asked not to be
interrupted at a quit did not ask for their agents to be stopped, and the one thing a suppressed
prompt must never do is pick the destructive branch on their behalf.

`QuitAnswer.stopEverything` runs `AgentRuntime.terminateHostBackedSessions()` **before**
`detachHostBackedSessions()`, which then finds nothing left to hand over, and *after* the
running-sessions record is written: a session the user stopped at the quit is still a session the
next launch should offer to bring back.

### A launch band, once per launch

`PaneNoticeView` — the component `LaunchRestoration` already uses for the post-crash band, and for
its reason: this is a standing condition rather than a receipt, so it is explicitly not a
`ToastView`. `PTYHostLaunchNotice` is the decision as a value, so what the band says can be
asserted without a window, and `PTYHostLaunchNoticeCenter` holds the one-shot rule in memory.
Nothing goes on disk: the fact it reports is the daemon's own list, which the next launch asks for
again.

Two sentences and two answers:

- **"3 sessions kept running while Threading was closed."** Terminals taken back plus conversations
  the daemon kept working. `Reattach` appears only when this launch did *not* take something
  back — after a clean reattach they are ordinary running sessions and there is nothing left to
  press.
- **"2 sessions were lost while Threading was closed."** The daemon restarted and its children went
  with it (`KeepAlive` restores the service, not the work). `Resume` puts them back through the
  ordinary staggered relaunch, bypassing `sessionRestorePolicy` on purpose: the policy answers
  "what should come back on its own", and this is somebody pressing a button.

**A loss outranks a survival.** Only one band fits, and the kept-running sentence is good news that
needs nothing done about it while the lost one names work that is not coming back on its own. The
journal has both counts either way.

### The Background Sessions list

A section on the Advanced page, beside the "where is my data" paths: the list leads, and the two
controls follow, because the list is the subject and the switch is what you reach for after reading
it. The list is **not** a row inside the card — a `SettingsCard` is a retained stack of full-bleed
rows and a bounded table is not a row.

`PTYHostBackgroundSessionsInventory` surveys off the main actor — connect, `hello`, `list`, close —
and hands the page one value. The registration status is asked *between* the cheap refusals and the
connect, because "launchd has never seen the label" explains a silence the socket probe would report
only as `notRunning`. A hosted test bundle never reads `SMAppService.status`, for
`PTYHostRegistrationCoordinator`'s reason: the bundle a test runs in *is* the shipping app.

Each row is the daemon's vocabulary joined to the app's: the conversation's name, its project, its
runtime, an elapsed uptime — "started 4 hours ago" is the question a wedged agent raises — and the
pid a support answer needs. A child whose conversation has been deleted is still identifiable by
what it is running, which is exactly the row somebody hunting a wedged agent needs to see. **Stop**
is attach-then-kill on a connection of its own (`PTYHostSessionStop`, shared with the reattach
step's own kills): `kill` names a session and a connection may only name the one it is bound to, so
a watcher that wants to end a child it is not watching has to become its watcher first. An ended
child's Stop is disabled rather than dropped — a control that vanishes explains less than one that
waits.

The viewport caps at six rows and the table owns only what is inside it. The count comes from
another process and is unbounded as far as this page is concerned; the list hands the wheel back at
its own content ends, because the page below it is the scroller the user is driving.

The empty state carries the **reason**, which is the whole point of `PTYHostAvailability` having
separate cases rather than a `Bool`. `requiresApproval` is the one reason with a fix the app cannot
perform itself, so it is the one that grows a button —
`PTYHostRegistration.openLoginItemsSettings()`.

**Turn off the background host** drives `AppSettings.ptyHostEnabled` off and then says which way
the removal went, because the two outcomes are otherwise indistinguishable and the one that leaves
a daemon running is the one a user needs told. The removal itself is
[`PTYHostRegistration.removalDecision`](#turning-it-off)'s, unchanged: unregister when the daemon
holds nothing, leave it registered when it holds something, because `unregister()` kills the
running helper and turning a preference off must not be a way to end somebody's turn.

The switch itself stopped being a `defaults write` here. It is presented on the Advanced page and
is `.catalogueOnly` by construction — omitting `remotePolicy` is deliberate, so `list_settings` may
describe the row while neither the phone nor an agent can read or move the value. Starting a
background daemon on somebody's Mac from a phone is not a thing this switch is going to do.

## The command-line client

`threading-ptyd status`, `sessions`, `journal` and `stop`, run from any shell against the daemon
that is already listening. It is the **same binary**: the client has to speak the framing, the
frames and the version gate exactly as the daemon does, and a second executable would be a second
place for all three to drift, plus one more thing to sign, embed and keep in the bundle. The
verbs live in `PTYHostCLI.swift`, `PTYHostCLIClient.swift` and `PTYHostCLIFormatting.swift`, all
inside the same import fence as the daemon, so the client links Foundation, Darwin, Dispatch and
`ThreadingPTYHostKit` and nothing else.

**The two command lines cannot collide.** `PTYHostCLI.parse` declines anything whose first
argument begins with `-`, and declines an empty command line, so `--socket <path> --state <dir>`
and `--default-locations` reach the daemon's own parser exactly as they did before this existed.
Only a bare word reaches the verb table, which is what makes adding a verb later unable to shadow
a flag. `PTYHostCLITests/testTheDaemonCommandLineIsUnchanged` is that claim as a test.

| Verb | What it answers | Exit |
|---|---|---|
| `status` | whether a socket file is there, whether a daemon answers (`hello`: build, pid, protocol pair), how many sessions it holds split into attached / detached / exited, a `lost` set if the daemon reported one, whether the bundle carries the launch-agent plist, what launchd says about the label, and the path of today's journal file | 0 if a daemon answered and the gate admitted it, else 1 |
| `sessions` | one row per held session: short id, channel, pid, elapsed uptime, grid, state, exit status, executable basename. `--json` prints the same set with stable keys | 0 if the daemon answered, else 1 |
| `journal [N]` | the last N journal lines (default 50) through `journalTail`, bounded again by the daemon's own `maximumJournalTailBytes` | 0 if the daemon answered, else 1 |
| `stop <id-prefix>` | attach with the floor replay budget, then `kill(escalate: true)`, then wait for `exited` | 0 when the ending arrived, else 1 |
| `help`, `--help` | the usage, on standard output | 0 |
| a bad verb, an option on the wrong verb, a missing value | the usage, on standard error | 64 (`EX_USAGE`) |

Output is plain aligned text on standard output, one line per row, no colour and no progress; a
refusal is one sentence on standard error and nothing on standard output. Every wait is bounded by
a constant in `PTYHostCLIDefaults`, which is separate from `PTYHostDefaults` because the daemon's
numbers are load-bearing for a process holding somebody's agents and these bound a tool that
connects, asks once and exits.

**What it refuses to do, and why.**

- **Never `retire`.** Retiring unlinks the socket and drains, and it is the *app's* upgrade
  policy — decided by `PTYHostUpgradePolicy` from the build, the gate and the held count. A shell
  command that retired would be a way to interrupt working agents by hand, and on a mismatched
  daemon it would be worse: `selfTooOld` exists precisely so a newer daemon is never taken down to
  install an older host. An incompatible daemon is therefore reported and left alone, and `status`
  exits 1 because something is listening that nothing here can ask anything of.
- **Never `spawn`.** A session belongs to a conversation the app owns; a child started from a
  shell would be one no surface could ever show, and the daemon's own `sessions.jsonl` would carry
  a record the app can only classify as an orphan. Putting a session *in* the daemon is what
  `PTYHostCLITests`' own wire fixture does, because the tool must not grow a verb for it.
- **No follow mode.** `journal -f` is refused with the reason rather than silently accepted: the
  daemon's journal is an ordinary append-only file under the state directory, `status` prints its
  path, and `tail -f` on that file is better than a socket held open for the same bytes.

`stop` is the one verb that changes anything, and it is `PTYHostSessionStop`'s semantics rather
than a second dialect: attach first, because `kill` names a session and a connection may only name
the one it is *bound* to, so a watcher that wants to end a child it is not watching has to become
its watcher for as long as it takes to say so. The replay is bound to
`PTYHostReplayDefaults.minimumBudgetBytes` — something about to end a child has no use for its
history, and the daemon clamps anything smaller up to that anyway. An ambiguous prefix is
**refused rather than resolved**: the two sessions a prefix reaches are two different people's
turns. `PTYHostCLIDefaults.stopTimeout` is ten seconds rather than the page's three, because the
daemon's own arithmetic is `SIGTERM`, a two-second escalation grace, `SIGKILL` and up to half a
second of output drain, and a run of this measured 2.13 s between `killRequested` and `exited` for
a `sleep` that did not die on the first signal.

### The registration line, and the one thing the daemon cannot link

`status` reports whether `Contents/Library/LaunchAgents/codes.threading.ptyd.plist` is registered,
and it cannot ask `SMAppService`: the boundary lint holds this target to Foundation, Darwin,
Dispatch and the wire package, which is the rule that keeps "it owns the child, the ring, the grid
and the exit status, and parses nothing" true. `PTYHostRegistration` is the app's, and the app is
what the daemon must not link.

So it asks the way a person at a prompt would — `launchctl print gui/<uid>/codes.threading.ptyd` —
and `PTYHostCLIRegistration.parse` reads the answer. Three findings, kept apart because they send
somebody looking in different places: `registered` with launchd's own `state` word and the pid when
there is one, `notRegistered` when the text carries "Could not find service", and `unreadable`
carrying the first line when `launchctl` said something else. Two things in the parser are
deliberate:

- **The text decides, not the exit status.** `launchctl` exits non-zero for "no such service" and
  for a malformed domain alike, and those are not the same finding. It has also moved its refusal
  between standard output and standard error across releases, so both descriptors are read as one
  string.
- **A key is matched on the whole line.** `launchctl` prints `spawn type`, `program identifier` and
  a dozen other keys ending in the words being looked for, so a substring search for `state` or
  `pid` would answer with whichever came first.

The line names the label, because the answer is about `codes.threading.ptyd` rather than about
whichever socket the invocation was pointed at — and somebody who named a socket with `--socket` is
usually asking why the ordinary one is silent.

`PTYHostCLIDefaults.launchctlEnvironmentKey` (`THREADING_PTY_HOST_LAUNCHCTL`) names the program to
run, and is a test seam in `PTYHostDefaults.ringBudgetEnvironmentKey`'s sense: never a user
setting. The reason is sharper here than there. There is one registered label on a machine and it
belongs to the developer's own Threading, so a test that ran the real `launchctl print` would be
asserting about their login items rather than about this code — and the answer would change when
they toggled the setting. Every invocation in `PTYHostCLITests` therefore points the key at a
script replaying a captured `launchctl print`, which is how the parser is exercised over the text
it actually has to read.

### Tested as the process it is

`PTYHostCLITests` runs the shipping helper twice: once as a daemon on a scratch rendezvous, once as
a client pointed at it with `--socket`/`--state`. Nothing is stubbed on either side, because a
client tested against a fake daemon is a client that agrees with a fake. The assertions are what a
person reads and what the shell gets back — the text, the sentence on standard error, the exit code
— plus the one thing text cannot prove: after `stop`, the child's **pid** is gone, since a tool
that sent the right frames and left the child running would pass every text check above it.

Sessions are put into the daemon by a small wire fixture in that file rather than by the tool, and
the ambiguity case uses two hand-written UUIDs sharing a prefix rather than drawing random ones
until two collide.

One harness note worth keeping: a coverage build's instrumentation writes `LLVM Profile Error:
Failed to write file "default.profraw"` to the child's standard error when it cannot place the
file, and the test host's working directory is `/`. The fixture gives every child a writable
working directory, and the "help says nothing on standard error" assertion checks that the *tool*
wrote nothing there rather than that the stream is empty.

## What is not decided here

Re-adopting a **live** native conversation, rather than ending it and resuming from its transcript
— see [Why a conversation is not reattached](#why-a-conversation-is-not-reattached). The mirror
unification and scheduled work without a window are the other two named follow-ups, and both stay
contingent on this having shipped and settled.
