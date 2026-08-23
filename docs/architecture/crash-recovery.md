# A Launch That Did Not Come Back

The app has three ways of knowing something went wrong before it could say so: a marker that
outlives the process, a ledger of how far each launch got, and a policy that reads the two. This
file holds all of it, plus what the app now *does* about it.

It exists because the mechanism spans six other documents and none of them owns it.
[`persistence.md`](persistence.md) keeps the ledger's file format and durability;
[`sessions.md`](sessions.md) keeps what a launch after a crash restores;
[`themes.md`](themes.md) keeps how a theme is restored; the window deferral it has to live beside
is in [`onboarding.md`](onboarding.md). Read this one before changing what a launch decides.

## The three records

**The marker** (`EventLog`) answers one question and answers it once: did the last launch come
back. It is written after the single-instance lock and removed only by the quit path, so a marker
still lying there means the process did not live long enough to quit.
`EventLog.PreviousLaunchOutcome` names the four answers, and `unclean` carries the `.ips` macOS
filed for that launch when one matched.

**The ledger** (`LaunchLedger`) answers how far each launch got: a `begin`, a line per startup
checkpoint, and an ending. Append-only JSONL over `O_APPEND` in its own directory under the
support folder. Its format, durability, tombstones and budget are `persistence.md`'s.

**The policy** (`CrashLoopPolicy`) is a pure function from that history to a typed decision. It
walks backwards from the newest launch and stops at a different build, at a launch that reached
`stable`, or at a pair outside the five-minute window. A clean quit, a logout, a reset relaunch and
an ending this build cannot name are skipped *through* rather than resetting the count: a quit
thirty seconds into a launch is not evidence that anything was fixed, and only ten interactive
minutes is.

The marker also gates the main window's frame. A clean, first or intentional-relaunch outcome may
restore the autosaved size; an `unclean` outcome may not use either its size or position. The main
window starts at `WindowDefaults` in the centre instead. `MainWindowInitialFramePlan` makes that
decision before the controller is built, and `applyInitialFrame` replaces the stale autosave before
registering its name because `setFrameAutosaveName` otherwise reapplies it as a side effect. This
is separate from `LaunchRestorationPlan`: an intentional recovery relaunch holds back the workspace
but is still a clean source of window geometry.

## A launch that could not get in at all

Everything above is about a launch that started. This section is about the one that could not,
because another Threading held the single-instance lock and would not answer.

`SingleInstanceLock` is an `flock` on `~/Library/Application Support/Threading/threading.lock`,
held for the process's lifetime and released by the kernel. That is exactly right for a process
that *dies* and exactly nothing for a process that *wedges*: the lock is real, the owner is alive,
nothing is on screen, and every fresh launch could only put up a one-button alert and quit.

There are **two** failures here, they look identical from the outside, and only one of them is
about a wedged app.

### The lock the children were holding

An `flock` belongs to the *open file description*, not to the process, and it is held while any
duplicate of that description exists. `fork` copies the whole descriptor table and `exec` keeps
whatever is not marked close-on-exec, so a lock file opened without `O_CLOEXEC` is inherited by
every child — and Threading's children are `forkpty` agent CLIs that outlive a crash by
reparenting to launchd. Measured on a live instance: ten `claude` and `node` children, every one
of them holding fd 6 on the lock file.

So when Threading *died*, its orphaned children went on holding its lock. Indefinitely. The user
came back in the morning to "Threading is already running" with no Threading running, and no way
out short of Activity Monitor or a restart.

**`O_CLOEXEC` on the lock open is the fix, and it is the whole fix for that failure.** The same
flag is now on `EventLog`'s journal handle and `LaunchLedger`'s append handle for the same reason
— neither blocks a relaunch the way an `flock` does, but both are long-lived descriptors that were
leaking into every agent process. The rule is that a long-lived descriptor is closed on exec
unless a child is meant to have it.

It is not retroactive. Children spawned by a build that shipped without the flag keep the
inherited descriptor across the upgrade, so the triage below still has to have an answer for them,
and does.

### The lock the wedged owner was holding

The other failure is a live owner that stopped answering: main thread hung, nothing on screen,
`flock` perfectly valid. No flag fixes that one, and the rest of this section is about it.

### The owner card

On a successful acquire the lock file — which used to hold nothing at all — receives a small JSON
card through the descriptor already held: pid, the kernel's own start timestamp for that pid, the
owning bundle's absolute path, the version, and when it was written. `ftruncate` first, so a
shorter card cannot leave the tail of a longer one behind.

`SingleInstanceLock.readOwnerCard(at:)` opens the file read-only and **without** `flock`, so
asking costs the owner nothing and the question can be put by the very process the owner has
locked out. It is bounded, and absent, empty, torn, oversized and garbage all answer the same
`nil`.

**The card is information, never authority.** A card that cannot be written does not fail the
acquire, and a card that cannot be read only costs the loser its extra choices. The fail-open
acquire semantics are unchanged: a lock file that cannot be opened still lets the launch through.

The bundle path is there for one reason. "Another Threading is already running" is unhelpful when
the other Threading is a Debug copy under DerivedData that the user has no idea is running, so the
alert names the path whenever it is not our own.

Neither a hosted test bundle nor a losing instance can ever write a card, by construction rather
than by a guard: the acquire that writes one sits below `applicationDidFinishLaunching`'s
`XCTestCase` return, and a loser's acquire failed. That matters because a card is what authorises
the *offer* to end a process.

### The heartbeat

`SingleInstanceHeartbeat` rewrites `threading.heartbeat` beside the lock every five seconds, and
staleness is judged from the file's modification time rather than from anything in it.

**The timer is on the main queue, deliberately**, for the reason
`LaunchLedger.armStabilityCheckpoint` gives: a timer on a utility queue keeps ticking straight
through a hang, and would certify an app nobody can use. A wedged main thread stops producing the
heartbeat, which is the whole signal. It is also touched on `NSWorkspace.didWakeNotification`,
because a Mac that slept for an hour wakes with an hour-old heartbeat and a fast prober would read
a perfectly live owner as wedged.

It starts immediately after the lock is taken and stops on the quit path, so only the process that
owns the state ever writes it. **It runs in recovery mode too**: a wedged recovery instance locks
the user out exactly as a wedged normal one does, and this observes rather than acts.

### The triage

`SingleInstanceTriage.verdict(card:cardIdentityStillValid:heartbeatAge:)` is a pure function, in
the shape `OrphanedAgentChildSweep` already uses and for the same reason — the whole table can be
asserted without a lock, a process or a window.

| card | owner identity | heartbeat age | verdict |
|---|---|---|---|
| absent | — | — | `alertOnly(.noOwnerCard)` |
| present | `unreadable` | — | `alertOnly(.ownerIdentityUnreadable)` |
| present | `gone` | — | `orphanedLockHolders(ownerPID:bundlePath:)` |
| present | `confirmed` | absent | `alertOnly(.heartbeatMissing)` |
| present | `confirmed` | ≤ 30 s | `activateOwner(pid:bundlePath:)` |
| present | `confirmed` | > 30 s | `offerTakeover(pid:bundlePath:staleness:)` |

Fail closed at every ambiguity. `confirmed` is the sweep's exact guard — pid alive *and* the
kernel's start timestamp equal to the card's — because pids are handed out again and a card
written an hour ago may name a browser now. A missing heartbeat under a healthy card is silence,
not evidence of death, and silence is what an owner from before this mechanism existed produces.

**The identity is three answers rather than a `Bool`,** because "the owner is gone while its lock
is still held" is a different situation from "the owner is unrecognisable" and has a different
remedy. Collapsing them was how the inherited-descriptor lockout had no answer at all. A recycled
pid counts as `gone`: the *owner* is certainly not running, which is the fact the verdict turns
on, and nothing downstream ever signals that number.

`orphanedLockHolders` is reachable only because our own acquire was refused, so the lock is
demonstrably held while the process that took it is demonstrably dead. Only one thing can do that.

`activateOwner` brings the owner to the front and quits quietly with no alert: the user
double-clicked the Dock icon and meant to switch to it. Only if activation fails does the alert go
up. On `alertOnly(.noOwnerCard)` there is one courtesy first — activate whatever else is running
under our bundle identifier — because an owner from before the card says nothing about itself and
the system can still answer that much. Nothing destructive hangs off it.

### The takeover

`offerTakeover` puts up a confirmation through `ConfirmationAlert`
(`ConfirmationPrompt.takeOverSingleInstanceLock`, `alwaysAsks(.irreversible)`, so Return is on
Quit and the affirmative is destructive). **Never a kill without that confirmation, never a kill
on an identity mismatch, and never an automatic takeover.** The prompt can never be switched off:
suppressed, it would silently end a running Threading on every launch that found a slow one.

On confirmation, `SingleInstanceTakeover.run(owner:actions:)`:

1. **Waits two heartbeat periods and re-reads the mtime.** The alert was on screen for as long as
   the user took to read it, which is long enough for a paused debugger or a disk stall to come
   back. A heartbeat that has ticked means the owner is alive after all, and the answer becomes
   activate rather than kill.
2. **Verifies the identity again**, because that wait is itself a window in which the owner could
   exit and its pid be handed on.
3. **`SIGTERM`, poll for the lock, `SIGKILL`, poll again.** The signal is not the success
   condition; holding the lock is. A process that survives both leaves the launch exactly where it
   started — an alert and a quit — rather than earning a third escalation.

An owner the probe reports as already gone is never signalled at all; the lock is simply polled
for.

Acquiring goes through the ordinary `SingleInstanceLock.acquire`, so a takeover leaves this
process holding the descriptor for its lifetime and having written its own card, exactly as a
normal launch does. `ownsSingleInstanceLock` is then set and the launch continues from the line
below the guard.

### Releasing a lock the children inherited

`orphanedLockHolders` reads the **previous launch's** `AgentChildLedger` — the record of what it
had running when it died — and offers to end the entries whose identity still checks out, naming
their executables. `ConfirmationPrompt.endOrphanedAgentProcesses`, on the same
`alwaysAsks(.irreversible)` branch as the takeover: those are somebody's conversations, and
whatever they were mid-turn on is lost.

The ledger is read **without consuming it**. `OrphanedAgentChildSweep` consumes it, and the sweep
runs *after* the lock is acquired — which is precisely the deadlock when those children are what
is holding the lock. A launch that is about to quit must not empty the list the launch that gets
in will need.

Each candidate is verified on the pair the ledger recorded, through `OrphanedAgentChildSweep`'s
own `verdict`. A run that verifies nothing signals nothing and takes nothing: the lock is then
held by something this launch cannot name, and the alert says so rather than claiming Threading is
already running, which is the one thing that is definitely not true.

`verdict` is the **single gate**, which is why both this path and `verifiedHolders` go through it
rather than re-deriving the rule: a record whose `owner` is the PTY host is skipped as
`heldByHost` before the probe is even consulted, so the exception reaches the launch sweep, a
recovery launch and this takeover by construction rather than by three checks agreeing. It is in
the sweep ahead of the host that will write those records, because the launch sweep runs
unconditionally: a host that landed first would have its children ended by the next launch.

### Why the taken-over launch reads as unclean, and why that is right

The takeover necessarily happens **before** `EventLog.beginLaunch()` — nothing may write into the
state directory until this process owns it. So the killed owner's marker is still on disk when
this launch consumes it, and the previous launch reads as `.unclean`. Held-back restoration and
the crash-loop counter then apply to the wedged instance.

That is intended. It *was* an instance that did not come back, and a launch that had to step over
a body is the last one that should be relaunching that body's workspace automatically. `SIGKILL`
writes no `.ips`, and the report matcher below pins candidates to the marker's pid, so nothing
stray can be attached to it either.

Immediately after `beginLaunch` the launch journals one line — "Took over the single-instance lock
from an unresponsive instance", with the owner's pid, its bundle path, the staleness in seconds,
and whether the kill was needed — so the story is reconstructable from the journal alone.

## Pinning the crash report to a pid

`EventLog`'s matcher used to attach the newest `Threading-*.ips` in
`~/Library/Logs/DiagnosticReports` whose modification time fell at or after the marker's start.
The time window alone is not enough, and not theoretically: **the unit-test bundle is hosted in
this app**, so a test that traps writes `Threading-<stamp>.ips` under the same process name as the
shipping app. A suite run while the real app is open drops several of those into exactly the
window a genuine launch would match, and the report hung off the user's crash is then a stack from
a test host — a plausible wrong answer, which is worse than none.

A candidate is now attached only when the pid it records equals the pid the marker named:

- **parseable and different** → skipped, and the scan continues, because the real report may be
  older than the stranger's.
- **unparseable** → skipped (fail closed), and said out loud once per launch. A format change that
  made every report unreadable would otherwise look exactly like macOS having written none.
- **marker with no pid** → the old time-window behaviour for that one launch. Compatibility, not a
  standing exception; every marker written from now on carries a pid.

Only a bounded prefix of the file is read (512 KB). The pid is a top-level key of the body a few
hundred bytes in, whatever the report's size, so the body is parsed as JSON when it fits and
scanned for the quoted `"pid"` key when it does not — a spin report runs to tens of megabytes and
must not be loaded to answer this. The key is quoted precisely so the scan cannot land on
`"byPid"`.

## Opening a launch happens in two steps

The `begin` record carries the **mode**, and the mode is decided from the history the ledger
returns. One call could not do both without either deciding the mode before the history was read
or writing the record before the mode was known. So:

```
openLaunch(previousOutcome:) -> LaunchLedgerOpening    // read, tombstone, compact
        ↓ CrashLoopPolicy.decide, flags, Option, --recovery-mode
beginLaunch(opening, id:mode:)                          // append the one begin record
```

`LaunchLedgerOpening` carries its boot id and validity `fileprivate`, so it can be constructed only
inside `LaunchLedger.swift`: a `begin` cannot be appended by a caller who has not first read,
tombstoned and compacted. `beginLaunch` also requires that *this* ledger did the opening, which is
academic with one shared instance and exact once a supervisor holds a second one over the same
file. Both refusals are logged at error level — a sequencing regression otherwise leaves only the
*absence* of a record, which is what nobody notices during a live diagnosis.

Everything between the two steps reads and decides. Nothing between them writes.

## What the modes are

`LaunchModeResolver.resolve(decision:optionHeld:arguments:forceNormalOnce:)` is the whole entry
rule, pure and table-tested. Its precedence, in order, and why:

1. `--recovery-mode` on the command line.
2. Option held at launch (`NSEvent.modifierFlags`, read once — at
   `applicationDidFinishLaunching` no key event has been delivered, and the class property needs
   no accessibility grant).
3. The `forceNormalNextLaunch` one-shot.
4. `recommendRecoveryMode` / `recommendStoppingAutomaticWork`.
5. Normal.

The two explicit requests come first because somebody is standing there asking. **The one-shot
beating the crash-loop decision is the load-bearing one**: without it, the decision that put the
user into recovery would immediately overrule the button they pressed to leave it, and "Try Normal
Launch Once" would be inert. The one-shot is spent *before* the resolver is asked, whichever branch
wins, so one that was outranked is still one-shot.

Both manual paths work when the ledger cannot be read at all. That is most of why they exist: a
damaged or newer-format history stands the policy down, and a mode somebody asks for out loud must
not depend on a file being parseable.

`recommendStoppingAutomaticWork` enters **the same mode** with a different reason. The only thing
stronger than recovery is to start less, and recovery already starts nothing; a third mode would be
one nobody tested, and `CrashLoopPolicy` reads `launch.mode == .recovery` on a two-valued enum.
What changes is the sentence on screen and the demotion of the leading offer.

## What a recovery launch starts

`LaunchPlan` is the answer, built once and read at each step, so
`applicationDidFinishLaunching` names the reason it is skipping rather than restating the mode
twenty times — and so the whole rule is one table a test asserts without an application, a window
or a store.

| Still runs | Why |
|---|---|
| The single-instance lock, the marker, the ledger, the policy | Recovery owns the state like any other launch |
| `OrphanedAgentChildSweep` | It kills leftovers, which is recovery-aligned, and a leftover child holding a PTY is a plausible cause — **except one recorded as the PTY host's**, which `verdict` skips as `heldByHost`: that child is running because it was told to keep running while the app was away, so it is neither a leftover nor a plausible cause, and a recovery launch is the last one that should end work it did not start |
| `MetricKitDiagnostics`, `MainThreadStallMonitor` | Pure observation, and this is when it matters most |
| `AppThemeRefresh`'s observers, `AppIconPresenter` | Cheap; a recovery screen that ignores Increase Contrast is worse for its reader, and under System the icon resolves to the shipped one with no special case |
| The menu bar | Gated by `RecoveryModeCommandPolicy` |
| The legacy Application Support adoption | **Weighed, not refused** — see below |
| Sparkle | Unchanged: `AppUpdater` is lazily built on the first Help-menu validation, and a new build is a legitimate fix for a crash loop |

| Skipped | Why |
|---|---|
| Extension appearance contributions, the host service, enabled packages, the three MCP/identity slots | Recovery starts no extensions; an unfilled slot means every component draws its own answer |
| `AttentionAlertCenter` | It can raise a permission dialog, and nothing here can produce an alert to justify one |
| `AgentWorkloadMonitor`, `LimitRecoveryCoordinator` | They watch live sessions; there are none |
| `cleanupOrphanedHistoryFiles`, `clearLegacySessionState` | Both delete |
| `ProjectIconDiscovery`, `CheckoutBranchFollower`, `SessionNaming.backfillLegacyNames` | All three write into the store or the support directory |
| `AccountUsageMenu.prefetch`, `AccountEmailProbe`, `ProjectStatsService` | Subprocesses and network for information nothing here shows |
| `UsageWindowPoker` | It starts a real agent turn on a schedule, which is the clearest "automatic work" in the launch |
| `PTYHostRegistrationCoordinator` | Registering the PTY host's launch agent installs a process that **outlives the app**, at the exact moment the last launch did not come back. The refusal is `RecoveryMode.refuse`d by name rather than silent, and `PTYHostRegistration` refuses recovery again on its own, because a guard that exists only at the call site is a guard the next call site does not have. It sits below the `startsBackgroundServices` guard, after the single-instance lock and after the launch-mode decision — see [`pty-host.md`](pty-host.md#where-registration-happens-in-a-launch) |
| `RemoteAccessCoordinator`, `RemoteWorkspaceBridge` | A tunnel child and a socket, plus the seam a phone drives the window through |
| `ArtifactScanService` | A disk survey |
| The MCP listener, its handler, the permission presenter, `HookLifecycleRelay` | No session will ever read `--mcp-config`. Skipping the listener also means `restoreSelectedSessionIfReady` never runs, so no restoration and neither scheduled-message service starts. That gate carries its own `plan.restoresWorkspace` guard anyway, because it is where a future third caller would arrive |
| The onboarding walkthrough | Recovery wins over a first launch that crash-loops; the completion flag is untouched, so it returns next launch |
| The stability timer | `stable` is a claim that the app works, and a launch that started nothing has not made it. Arming it would mean ten minutes in recovery erases the count that put the user there |
| `ProjectStore` writes | Seeded at construction, because `load()` takes a write of its own |

**The migration is weighed rather than refused.** Skipping the pre-rename adoption would open on an
empty sidebar, which reads as data loss and is the worst possible message on a crash screen — but
it is also the one part of a launch that moves someone's database around. So the ledger decides: a
counted launch that recorded no checkpoint at all never reached `migrationDone`, which is the one
shape of evidence that makes the adoption itself the suspect. The checkpoint is recorded either
way, with a detail saying which happened.

## What a recovery launch does not write

Two records are load-bearing here and both are left exactly as found.

**The running-sessions record.** The quit path skips `saveRunningSessionIDs` in recovery. Nothing
was running, so the list it would write is empty — and writing an empty list over what the last
clean quit recorded is how a user who dropped into recovery to look at something loses the sessions
the *next* normal launch was going to bring back. It is not consumed here either, because the read
hangs off the MCP listener's callback. Leaving it alone at both ends is what preserves it end to
end.

**That record is now a hint rather than the only truth, and every word above still applies to it.**
A session whose pty lives in `threading-ptyd` is *detached* on the quit rather than terminated, so
the daemon's own list is what is actually running when the next launch starts;
`relaunchSessionsFromLastQuit` therefore runs **after** `PTYHostReattach`, and plans only the
sessions the host does not hold. Relaunching one it does hold would start a second agent on a
conversation whose first has been working the whole time. The record stays written, and stays
guarded exactly as above, because it is the whole of the degraded path: the hidden key is off by
default, the daemon may be missing or refused for any of `PTYHostAvailability`'s reasons, and every
one of those cases is today's launch, unchanged — with the feature off the reattach step answers on
the calling turn without opening anything. A session the daemon reports as `lost` is deliberately
*not* held back, because the daemon cannot hand it over; the ordinary relaunch resumes it by its
agent-assigned identifier, at the cost this has always had. See
[`pty-host.md`](pty-host.md#detach-and-reattach).

**`SessionRestorationLedger` gains a `reattached` outcome** beside `restored`, so a row can tell
"it came back" from "it never went away". They are different facts and only one of them cost a turn
in flight. The dormant hover card says so without naming Settings ▸ General, because launch restore
did not decide it: a `reattached` row is dormant only because the agent that kept running has since
ended, and `PTYHostReattach` recorded that ending off the daemon's own exit status.

**The theme.** `AppThemeLibrary.restore(_:)` pins System under `.recovery`, in memory. Nothing in
`restore` writes, today or after — the write lives in `apply`, which records even a pick that
changes nothing on screen — so "recovery cannot re-persist the theme" is bought by taking that path
and never this one. System rather than "the stored choice if it happens to be stock": a stock theme
carrying a `WindowChromeStyle` opts the window into the app-drawn frame, which is a great deal of
launch-time machinery and a plausible place to die.

**The Appearance page therefore selects the stored choice, not what is in force.** That is the trap
this decision exists to avoid: with the ring on System, clicking the entry that already looks
selected would record System over the user's theme. A pick made deliberately on that page still
records — what recovery forbids is the *launch* writing a theme nobody chose — and a note under the
card says which theme is saved.

## The one-shot flags

`Launch/launch-flags.json`, beside the ledger. Two flags, both one-shot:
`forceNormalNextLaunch` and `disableExtensionsNextLaunch`.

**A file, not `PreferenceStore`.** The onboarding flag's rule is about a preference set on a
settings page with the app running normally; these are written immediately before the prepared
relauncher commits and deliberately leaves without the quit path every store hangs its final save
on. `UserDefaults` is asynchronous to disk, `cfprefsd` holds the domain, and
`synchronize()` is deprecated. The file also has to survive Reset Settings while being taken by
Reset Everything, which a file under `Launch/` does by construction — and it inherits that
directory's hosted-test redirection, so a test cannot arm the developer's own next launch.

The helper is started *before* the one-shot is armed and waits behind a private commit pipe. A
launch failure leaves this process alive and reports the error; a helper that dies before commit
causes the flag to be disarmed again. Thus a failed button press cannot make some later ordinary
launch unexpectedly consume “Try Normal Launch Once.”

**Consumption rewrites rather than deletes**, leaving both booleans explicitly false plus
`consumedByLaunch`. There is no "cleared versus never set" question to answer here; what the
positive record buys is a support report that can say a forced-normal launch was armed by one
launch and spent by another, which is the whole "and then *that* one crashed too" story.

**A clear that fails means the flag is not honoured.** A one-shot that cannot be cleared is a
permanent setting, and a permanent "always launch normally" is the crash-loop protection switched
off with nothing on screen to say so. Failing this way costs one more crash and one more press.

The extensions flag **never touches `enabledIdentifiers`**. That is what makes "for the next launch
only" true by construction rather than by a promise: no extension is disabled, so there is no state
for a later launch to inherit. The next normal launch that honours it puts a band in the pane
saying so, because an app whose extensions have silently stopped appearing is indistinguishable
from one that lost them.

## If the forced-normal launch also crashes

Its `begin` says `mode: normal`, because it was. The policy counts it as an ordinary consecutive
unexpected exit — two crashes plus this one is three — and answers `recommendRecoveryMode`, **not**
`recommendStoppingAutomaticWork`, since the newest counted launch was not the recovery one. The
recovery launch in between ended `intentional(.recoveryRelaunch)` and is skipped transparently. The
flag is spent, so the app returns to recovery rather than looping through normal launches.

`LaunchRestorationPlan` treats that exit reason as **holding the workspace back**, which is the
opposite of what it does for `.reset`. Both are deliberate restarts; the difference is that the
reason for this one is that the app has been dying, so the launch comes up normally with the
workspace one press away rather than reopening, under the user, whatever took it down. This is why
`IntentionalExitReason` is an enum and not a `Bool`.

## The surface

`RecoveryModeView`, in `UI/Views` and composed from `UI/Design` — not added to it. A component
under `UI/Design` owes an interactive Component Gallery story, and rightly: that directory is
vocabulary a second pane repeats. This is one screen, in one place, under one condition, which is
`SessionPlaceholderView`'s position exactly.

It lives **inside the main window**, in the terminal pane. `applicationShouldTerminateAfterLastWindowClosed`
answers true, so a window of its own would recreate the trap onboarding's completion order exists to
avoid; the main window is always built here, and only its `showWindow` is gated. Living in the pane
also keeps the sidebar beside it, which is the point — the first thing somebody in a crash loop
wants is evidence that their projects are still there.

A `PaneNoticeView` band with **no dismissal** sits above it. That is the most standing condition
there is: the only thing that ends it is a relaunch, and without the band the surface would be a
screen the user could navigate away from and never get back.

The screen says why it came up (one sentence per reason), how far the launch that died got (the
checkpoint, in words — the raw case name is a fact about this code, not copy), and offers, in
order: **Try Normal Launch Once** · **Continue in Recovery Mode** · Reveal Crash Report when there
is one · then, under a rule, **Disable Extensions for Next Launch** · **Reset Window Layout** ·
**Create Support Report** · **Move App Data Aside**. Every offer maps to a primitive that already
existed; none required a new subsystem.

**Cut: a support *bundle*.** A zip of journals, ledger and `.ips` files is a new subsystem with its
own redaction question — the journals hold prompts, commands and paths — and getting redaction
wrong in a file people email is the worst place to be quick. The existing share-safe support report
already carries the crash-loop decision, the ledger read, MetricKit payloads and the privacy
grants.

## What the pane does with a click

Recovery lists and selects but opens nothing: a row that could not be clicked would be a list
pretending to be a picture, so the pane says so in words instead. The composer is diverted to the
surface, because a form whose one button starts a session is worse than the screen explaining why.

That is the *visible* refusal. The load-bearing one is at each surface's own start —
`AgentSessionViewController.launch`, `ConversationViewController.launch`,
`ProjectTerminalViewController.startIfNeeded`, `ShellDrawerViewController.startIfNeeded` — which is
the last line before a process exists and the one line every other route crosses: a remote resume,
a scheduled send, a relaunch, an MCP tool. A route recovery did not anticipate stops there.

`RecoveryModeCommandPolicy` is asked only about `AppCommand`s. The platform's own group is allowed
wholesale rather than enumerated, because a recovery mode that could ever disable Quit or Copy is a
worse failure than any it is trying to contain; the menu bar's non-command items are untouched by
construction. What survives of ours: the sidebar toggle and its three arrangement switches, and
Check for Updates.

## The checkpoint that is not readiness

`recoverySurfaceShown` is recorded one run-loop turn after the surface is in the window, so a launch
that dies drawing its own recovery screen is distinguishable from one that died before the window —
the two are the same absence otherwise, and telling them apart is the whole reason a supervisor
would read this file.

It answers **false** to `isReadiness`. Readiness stays keyed from `firstWindowVisible` alone: this
one says which *kind* of window came up, not that one did, and readiness must have exactly one
claimant or `CrashLoopPolicy.isWithinWindow` depends on which record a reader happened to look at.
A trail carrying the recovery checkpoint without `firstWindowVisible` is a launch whose window never
proved itself, and the conservative reading of such a trail is the window-exempt one.
