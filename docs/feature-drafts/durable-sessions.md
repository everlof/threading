# Durable sessions

> Status: **feature draft, low priority** (2026-08-21). Nothing scheduled. The durability work is in
> two parts and only the second is expensive: a **reconnectable bridge** that stops a session's
> hooks, permissions and MCP tools from being bound to one app launch, and a **PTY host** that
> lets the agent process outlive the app entirely. Part one stands alone, is small, and fixes
> real degradation today; part two is a new always-on process and a rewrite of how
> `TerminalSession` owns its child, and should not start until part one has shipped and settled.
> A third slice — the viewport lease's grace period (§5) — depends on neither and is the
> cheapest thing here: a timer and a device key in the mirror registry.

Part of the [drafts index](README.md). Read alongside
[`crash-recovery.md`](../architecture/crash-recovery.md) (what a launch decides and what it
sweeps), [`mcp-and-display.md`](../architecture/mcp-and-display.md) (the listener, tokens and
tool routing), [`session-activity.md`](../architecture/session-activity.md) (what the hooks are
for), [`sessions.md`](../architecture/sessions.md) (launch and resume) and
[`REMOTE_ACCESS.md`](../REMOTE_ACCESS.md) plus
[`compressed-terminal-mirror.md`](../decisions/compressed-terminal-mirror.md) (the ring, the
seed and the join replay this would reuse wholesale).

**The one-sentence version.** Restarting Threading kills every running turn, and the reason it
cannot simply stop doing that is not the PTY — it is that a session's whole bridge to the app is
addressed by a port and a token that exist only for the lifetime of one launch.

---

## 1. User problem and concrete cases

1. **A build lands while an agent is working.** The user commits to master, the auto-install hook
   has a Release build ready, and taking it means quitting an app with four agents mid-turn.
   Today the hook works around this by waiting for a quit that the user then postpones for hours.
2. **An update, a crash, or a settings change that needs a relaunch.** Same shape. Every one of
   them currently costs whatever turn was in flight, and the quota it had already spent.
3. **A session parked on a rate limit overnight.** `limit-recovery.md`'s scheduled continuation
   fires at the reset — if the app is still open at 07:00. It is not, so the recovery the user
   set up does not happen.
4. **A phone watching a session.** The Mac app is the host, so quitting it drops the connection
   and ends the work the phone was watching, from a device that cannot restart it.
5. **A phone entering the same chat twice.** Every arrival and departure reflows the shared PTY,
   so a glance at a notification and a return repaints a working agent twice. Backgrounding the
   iOS app does it too, which makes this the most frequent case on the list and the only one that
   costs nothing to fix.

The narrow loss is worth stating exactly, because it is smaller than it feels and it is what
sizes the payoff. `applicationShouldTerminate` records `AgentRuntime.shared.runningSessionIDs`
before `terminateAll()` (`AppDelegate.swift:781`), and `relaunchSessionsFromLastQuit()` brings
them back next launch. Transcripts resume by agent-assigned id. **What a restart actually costs
is the in-flight turn and the scrollback** — but the in-flight turn is the expensive half, and
`COMPETITORS.md`'s "durable process after client disconnect" row is a conceded gap.

## 2. Why the obvious answer does not work

Running each TUI under `tmux` addresses the PTY, which is the part the kernel already handles
correctly and the part that costs least to rebuild. It does not address the coupling that
actually breaks, and it adds three problems of its own.

**The bridge is addressed by a launch, not by a session.** `MCPServer` binds `port: .any`
(`MCPServer.swift:253`) and `MCPSessionRegistry.token(for:)` mints a UUID into an in-memory
dictionary, documented as "stable for the app's lifetime" (`MCPSessionRegistry.swift:32`). Both
are baked into the launch command line as environment words
(`AgentLauncher.hookEnvironmentWords`, `AgentLauncher.swift:913`) and into Claude's per-session
settings file, whose hook base is the literal `http://127.0.0.1:<port>`
(`MCPSessionRegistry.writeHookSettings`). A process that survives a restart holds the old port
and the old token for the rest of its life. It is alive and unaddressable: no lifecycle hooks, so
`working` / `needsAttention` / `limitReached` go stale; no permission brokering; every
`mcp__threading__*` tool failing.

**It puts a second emulator in the path.** SwiftTerm is the emulator. tmux re-parses and
re-encodes everything through its own, which lands on kitty keyboard encoding, OSC 52 and OSC 8,
mouse reporting, bracketed paste, and on the OSC 0/2 titles `TerminalNaming` depends on
(`TerminalNaming.swift:18`) and tmux rewrites. Its resize rule — a detached window pinned to the
last attached client's size — leaves permanently wrapped scrollback behind an agent that
rendered wide output while nobody was attached.

**It inverts an ownership decision that was made deliberately.** `AgentChildLedger` excludes PTY
sessions on purpose: the `forkpty` child "already leads its own session with a controlling
terminal and dies of `SIGHUP` when the master descriptor closes with the app… the kernel already
owns the ending." Under tmux nothing owns the ending, so orphan cleanup becomes ours — and
`OrphanedAgentChildSweep`, which `crash-recovery.md` runs in Recovery Mode because "a leftover
child holding a PTY is a plausible cause", would be killing an agent that is legitimately still
working.

**And it is not on macOS**, so a core behaviour would depend on Homebrew.

If a multiplexer is ever the answer, the right one is a pass-through PTY holder in the shape of
`dtach` or `abduco` — no terminal emulation of its own, therefore none of the translation
category above. But that is §4 with somebody else's C, and it still needs §3 first.

## 3. Part one — the reconnectable bridge

Three changes. They ship together, are invisible to the user, and are worth doing on their own
merits: they delete a degradation branch, stabilise Codex's trust hash, and tighten the
endpoint's security boundary. **Nothing else in this draft is possible before them**, and after
them any durability mechanism — daemon, `dtach`, even tmux — becomes viable, because a surviving
agent can be re-adopted by a new launch.

### (a) Durable per-session tokens

`MCPSessionRegistry` keeps `tokensBySession` in memory. Persist it beside the per-session
configuration file the registry already writes. The token becomes a property of the session,
minted once and rotated only when the session is deleted. A hook that arrives after a restart —
or during one, before the listener is up — then routes to the right session instead of being
dropped.

The registry's existing constraint holds: the token must not be derived from the session
identifier, which is written to disk in readable places. It is a persisted secret, so it belongs
in the support directory under owner-only permissions, not in the store.

### (b) A stable rendezvous instead of a port

Add a second `NWListener` bound to `NWEndpoint.unix(path:)` at
`~/Library/Application Support/Threading/mcp.sock`, sharing the existing handler and path
prefixes, unlinked and re-bound at launch, in a `0700` directory. Both endpoints coexist through
the migration. (`NWEndpoint.unix(path:)` and `NWParameters.requiredLocalEndpoint` are available;
macOS ships curl 8.18 with `--unix-socket`.)

Hooks become `curl --unix-socket <path> http://localhost/lifecycle/$THREADING_SESSION_TOKEN?…`.

This is an improvement independent of durability:

- **It stabilises Codex's trust hash.** `CodexHookInstaller.swift:23` records the whole reason
  today's `hooks.json` interpolates `$THREADING_MCP_PORT` rather than a literal: "today's port
  would change every launch and invalidate the trust every launch." A fixed socket path is a
  literal that never changes, so the shared `hooks.json` stops being rewritten and the port
  environment export can eventually be dropped.
- **It deletes the "no port" branch.** `writeHookSettings` has an error path for a session
  launched before the listener has a port, which silently costs that session accurate activity
  and, for a rendered session, blocks its tools outright. A path is available before the listener
  is.
- **It is a tighter boundary.** A loopback TCP port is reachable by any local process that
  guesses a token; a `0700` socket is not.

### (c) An MCP stdio shim for the tool channel

The one part a stable path cannot fix by itself. `--mcp-config` is written as
`{"type": "http", "url": …}` (`MCPSessionRegistry.writeConfiguration`) and the CLI resolves it
once, at startup. Replace it with a stdio server — a small helper in `Contents/Helpers`, which is
an established pattern here (three `product-type.tool` targets ship that way, resolved by
`HelperLaunchPolicy`):

```json
{"mcpServers": {"threading": {"type": "stdio",
  "command": "…/Contents/Helpers/threading-mcp-bridge",
  "args": ["--socket", "…", "--token", "…"]}}}
```

The shim forwards MCP frames over the socket and owns exactly three behaviours:

1. answers `initialize` and `tools/list` from a catalogue cached on first connect, so the CLI's
   startup handshake succeeds even when the app is not running;
2. returns a typed refusal for a tool call in that window — the model reads "Threading is not
   running" and moves on, rather than hanging on a dead socket;
3. re-sends `notifications/tools/list_changed` after a reconnect.

The honest costs are a second hop on every tool call and a binary that must not drift from
`MCPToolCatalog`. The drift is answered by fetching the catalogue on connect rather than
compiling it in; the hop is a local socket and is not expected to be measurable, which is a claim
the rollout should check rather than assume.

## 4. Part two — the PTY host

`threading-ptyd`: one per user, shipped in `Contents/Helpers`, registered through
`SMAppService.agent` (macOS 13+, matching the deployment target) and unregisterable from
Settings. It is not a child of the app.

**What it owns, per session:** the `forkpty` child, the raw output ring, the last window size,
the exit status, the launch record. **What it must never own:** projects, themes, transcripts,
accounts, policy, or any terminal emulation. It parses nothing. A daemon that needs more than a
page to describe is the wrong daemon.

**Its protocol already exists.** `RemoteSessionMirrorRegistry` is documented as "taps the PTY
byte stream, keeps a ring for late joiners, fans output out to every watcher, and routes remote
input back in" — which is the daemon's entire job description, already written and already
carrying the phone. The frames needed are the ones already shipped: attach, detach, output,
input, resize, exited, plus the bounded join replay assembled from `RemoteRingBuffer`,
`RemoteScreenSeed` (for a session already running when capture began) and
`RemoteTerminalModeSeed`. Reuse `ThreadingRemoteKit`'s DTOs over a unix connection rather than
inventing a second dialect for the same job.

`RemoteRingBuffer`'s own header carries the load-bearing claim for this whole part: replaying the
raw byte stream "is the only representation guaranteed to reproduce what SwiftTerm itself
rendered". That is not a new assumption being introduced here — it is the one the phone has been
exercising daily.

**What changes in the app.** `TerminalSession.startProcess` (`TerminalSession.swift:359` and
`:393`) stops calling `LocalProcessTerminalView.startProcess`. SwiftTerm's `LocalProcess` is
`forkpty`-only by construction (`LocalProcess.swift:57`), so the host-backed path feeds a plain
`TerminalView` from the socket and sends keystrokes back as input frames.
`EmojiFixedTerminalView` keeps its rendering fixes; only process ownership moves.

**Invariants that have to move with it**, each of which is a decision that belongs in its
architecture document when the work starts:

- `AgentChildLedger`'s "PTY sessions are deliberately absent" stops being true, because the
  kernel no longer owns the ending. The ledger and the pid/start-time probe move into the daemon,
  which knows rather than infers, and `OrphanedAgentChildSweep` becomes a query.
- **Recovery Mode must stop sweeping PTY children.** `crash-recovery.md` runs the sweep in
  recovery deliberately; under a daemon that is killing a working agent. The exception has to
  land before the daemon does, not after.
- `runningSessionIDs` on quit and `relaunchSessionsFromLastQuit` become a *reattach*. The
  daemon's live set is the source of truth and the recorded list becomes a hint — including all
  the careful reasoning at `AppDelegate.swift:789` about not writing an empty list over a real
  one, which mostly stops mattering.
- `confirmQuitIfAgentsRunning()` changes meaning. Quitting interrupts nothing, so the question
  becomes "leave these running in the background, or stop them?" This is the visible win.

## 5. The viewport lease, and attachment churn

The same idea one level down: **a program should not be reflowed because a viewer arrived or
left.** This half needs no daemon and can ship first.

### What is there today

A remote viewport is a lease, not a preference (`RemoteSessionMirrorRegistry.swift:1128`). Each
interactive phone posts a `viewportRequest`; the shared grid is the intersection of the attached
remote leases; the last release calls `clearRemoteViewport()` and the Mac's own frame decides
again. The Mac says so while it is held — `RemoteViewportBannerView` reads *"Fit to iPhone / Mac
size returns when the remote view closes"*.

**The intersection rule is a scar and must stay.** `resolvedViewport` records what happened when
the most recent request won instead: "the Mac broadcast each new grid to everyone, and a client
that could not show it answered by re-asking for its own, so the agent was reflowed and repainted
several times a second for as long as both stayed open." Nothing in this section touches that
rule; it changes only *when a lease ends*.

### The problem

A lease change is a real `SIGWINCH` and a full TUI repaint, and the joining client has to wait
for that repaint — which is what `expectsResizeOutput` and `beginTerminalHydration` exist for,
because "PTY programs do not expose a resize-repaint acknowledgement"
(`RemoteSessionMirrorRegistry.swift:7`). So a phone entering a chat, leaving it and entering
again costs two reflows per round trip, each one paid for by whoever is watching. Backgrounding
the iOS app drops the socket the same way a deliberate close does, which makes this ordinary
rather than rare: a glance at a notification and a return is a full reflow of a working agent in
each direction.

### The rule

**Hold a released lease for a grace period instead of dropping it.** On release the request is
marked expiring and stays in `viewportRequests`, so `resolvedViewport` still counts it. A request
from the same device inside the window cancels the expiry and costs *zero* resizes. On expiry it
drops and the Mac restores exactly as the banner promises.

The alternative considered and rejected was to keep the last grid indefinitely — "the phone set
it, so leave it there." It trades a flap for a stuck state: the Mac pinned to iPhone width with
no phone attached, a banner that is either a lie or has nothing left to close it, and no obvious
way for the user to work out what happened. A grace period gets the whole benefit for the case
that actually hurts and expires on its own.

Three details decide whether it works:

- **Key the pending lease by device, not by connection.** Today the key is
  `ObjectIdentifier(connection)`; a reconnecting phone is a new object and would fail to match
  its own pending release, which is precisely the case this exists for. Device identity is
  already on the wire — `sendInput` carries it and the mirror already tracks `inputSeenDevices`.
- **The grace holds a grid, never a subscriber and never an authorization.** Nothing about a
  held lease may keep a socket subscribed or a peer permitted. Archival, revocation and
  `closeUnavailableSessions` drop it immediately rather than after a delay; the timer is not a
  place where access outlives its check.
- **The banner copy changes**, because the promise it makes becomes "shortly after" rather than
  "when the remote view closes".

### Configuring it

The window is a **behavioural setting with no Settings row**: registered in
`AppSettingDefinitions` like everything else, with no `presentations` and
`remotePolicy == .hidden`, so it produces no row (`SettingsPages.entries(for:)` projects rows
from `presentations` and filters `.hidden`) and does not cross to the phone's settings mirror.
Reachable by `defaults write` for somebody who needs it, and by us in a test.

**Default 120 seconds.** Long enough to cover a notification glance, an app switch, a lock and
unlock, or a walk between rooms — the sequence the feature exists for. Short enough that a phone
genuinely put down leaves the Mac wrong for at most two minutes, and the user has a banner on
screen telling them why.

Two notes for whoever implements it:

- Validation is a **clamp, not a refusal** — the nearest allowed duration is what somebody typing
  a number meant, which is the line `TypedAppSettingValidation.refusingRange` draws for the case
  where the number *is* the meaning. A port is that case; a delay is not.
- The existing `.range` helper folds `value <= 0` to the absence value, so `0` cannot mean
  "disable the grace and release immediately". Either give this key its own validation where `0`
  is a legal floor, or accept that today's behaviour is unreachable through the key. It should be
  reachable: it is the one-line kill switch if the hold turns out to be wrong.

### Where "keep the last grid" *is* right

Under the host in §4, and only there. A session whose app has gone has no Mac frame to fall back
to, so there is nothing for a released lease to restore *to*; and reattaching a Threading that
has just restarted must not reflow an agent that kept working the whole time. That is why the
host's per-session state includes the last window size: with it, the grid stops being derived
from whoever happens to be attached and becomes durable session state that clients ask to
change. The lease rule above is then the same rule with one more participant, not a second one.

## 6. What else this unlocks

The reason the second part is worth its cost is not only the reboot case.

1. **Updates and crashes stop costing work.** The auto-install hook currently waits for a quit
   that never comes, and Sparkle needs a relaunch. Both become a reattach. A crash then loses the
   window rather than the work, and Recovery Mode becomes usable for what it is for: entering it
   to fix something while the agents keep going.
2. **Scheduled work stops needing a window.** `scheduled-messages.md`'s durable clock,
   `limit-recovery.md`'s parked continuation and `UsageWindowPoker` — which starts a real agent
   turn on a schedule — all currently require the app to be open at the moment they fire. A
   session parked at 03:00 on a rate limit and resumed at 07:00 with the app closed is a product
   behaviour that only this makes possible.
3. **The phone stops depending on the Mac app.** Moving PTY ownership out (and, later, the
   serving door beside it) means quitting Threading no longer drops a connected phone. It pairs
   with `RemoteWakeOnDemand` and flips the `COMPETITORS.md` row.
4. **The local terminal becomes a mirror client — one path where there are two.** Today the
   mirror is a second path bolted beside the local view: tap, ring, seed, fan-out, route input
   back. Afterwards the Mac view is simply another watcher, so there is one ring, one seed, one
   input route, tested once. The class of bug the `getBufferAsData` "staircase of run-together
   words" belonged to can then only exist in one place. Multiple simultaneous watchers — Mac,
   phone, a detached terminal window on the same session — come for free.
5. **Full scrollback across restarts, and session replay.** Once one process owns a session's
   byte stream for its whole life, it can spill to disk instead of holding a bounded ring. The
   accepted cost in §4 ("what wrapped while you were detached is gone") becomes optional, and
   asciinema-shaped recording and playback is nearly free from a stream that is already being
   captured. It is the same tap `execution-audit.md` wants a durable record from.
6. **A local API seam that outlives a launch — the `threading` CLI.** Part one alone produces a
   stable, authenticated, owner-only local endpoint that is not tied to one app process. That is
   exactly what a command-line tool would need to list sessions, send to one, or open a project,
   and what would let a script or a CI job post into a session. The typed vocabulary already
   exists in `control-plane.md` (`list_sessions`, `send_to_session`); what is missing is a door
   that survives a restart.
7. **Faster relaunch with a real working set.** Restoring N sessions today is N process launches
   plus N transcript reads through `--resume`. Reattaching is N socket attaches and a bounded
   replay. This is a launch-time claim and therefore owes a measurement and a
   `performance.md` entry rather than an assertion.
8. **Orphan handling stops being a heuristic.** `OrphanedAgentChildSweep` reasons from pid plus
   kernel start time because a dead app leaves nothing better. A live daemon knows. The failure
   mode its header describes — "alive, unowned, holding a model conversation open and burning
   quota, with nothing on screen to say so" — stops being reachable.
9. **Terminal behaviour becomes testable without a window.** A frame protocol over a socket can
   drive real PTY sessions from a test with no hosted app and nothing on screen.

## 7. Scope boundaries and risks

- **Native conversations are a separate transport.** They are ordinary children with pipes
  (`AgentChildProcess`), not PTYs, so a PTY-only daemon leaves half the sessions still dying on
  quit. Owning pipes as well is not much more code and should be decided on day one rather than
  discovered.
- **The daemon is the new single point of failure.** Its children are its own session leaders, so
  if it dies they die. It needs `KeepAlive` and it needs to persist enough to *say* what it lost.
  This is where the durability actually lives and therefore where the tests go.
- **Version skew is routine here, not exotic.** The post-commit hook replaces
  `/Applications/Threading.app` under whatever is running. Frames must be versioned, an
  incompatible peer must be refused rather than misread, and the app must be able to ask a
  running daemon to exit after its last session detaches.
- **Unattended permissions.** For terminal sessions this is already safe:
  `writeHookSettings` states that a terminal session "asks the user through the CLI's own prompt
  and must not be intercepted", so a detached agent blocks at its own prompt and waits. The
  question only arises if the daemon later owns native conversations, where the broker is the
  only path — and there the answer must be to **deny**, never to allow.
- **A wedged agent becomes less visible.** Work that continues with no window is work nobody is
  watching. Whatever surface reports "3 sessions running in the background" is part of the
  feature, not a follow-up.
- **A new always-on process is a user-visible cost** — a login item, a consent, a row in Activity
  Monitor. It must be removable, and removing it must degrade to today's behaviour rather than to
  a broken app.

## 8. Tests

- The registry's token survives a synthetic restart and routes a hook posted afterwards.
- A hook posted at the unix path reaches the right session; the same posted with a stale port
  fails loudly rather than silently.
- The Codex `hooks.json` written twice across two launches is byte-identical (the trust-hash
  claim).
- The shim answers `initialize` and `tools/list` with no app behind it, refuses a tool call in
  that window with a typed error, and recovers on reconnect.
- Frame-protocol round trips: attach, replay, resize, exit, reattach after the writer's death.
- A ring that wrapped while detached replays a repaint the emulator recovers from — the same
  property the join replay already asserts.
- Recovery Mode does not kill a daemon-held child.
- A released lease re-requested by the same device inside the window applies **no** viewport
  change — asserted on the applied grid, not on the request count.
- A lease released and left alone expires and restores the Mac's grid.
- A reconnecting phone with a new connection object matches its own pending lease (the device-key
  claim).
- Archiving a session, or revoking the peer, drops a held lease immediately rather than at expiry.
- The window's default holds at 120s, an out-of-range `defaults write` clamps, and whatever value
  means "release immediately" reproduces today's behaviour exactly.
- Launch-time and per-tool-call measurements against the matched before case, per the
  performance workflow.

## 9. Rollout

0. **The lease grace period** (§5) — independent of everything below, and the only slice here a
   user would notice next week.
1. **(a) + (b)** — durable tokens and the unix listener, both endpoints live. Small, invisible,
   removes a degradation branch.
2. **(c)** — the shim, behind a setting, HTTP still available as the fallback while it settles.
3. **Retire the TCP endpoint** once nothing launches against it.
4. **The daemon**, off by default and per-session opt-in first, with the Recovery Mode exception
   landing ahead of it. Native conversations decided at this point, not later.
5. **Then, and only then**, the things §6 lists — scheduled work without a window, phone
   independence, persisted scrollback — each on its own slice.
