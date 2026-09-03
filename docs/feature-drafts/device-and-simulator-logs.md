# Device and Simulator Logs

> **Shipped 2026-09-02**, as the first tenant of the native plugin tier. The pane lives in
> `Plugins/DeviceLogsPlugin`; the tier's own decisions are in
> [`docs/architecture/plugins.md`](../architecture/plugins.md). This file remains as the
> measurement record and the source matrix — research done on 2026-09-01 against a real iPhone 16
> Pro (iOS 26.6) and an iPhone 17 Pro simulator (iOS 26.5).
>
> **The opt-in tap is the remaining slice.** Its consent and `DeviceLogTap` stay in the application
> deliberately, for the reasons under "Where the pane lives" at the end of this file. The rendering
> gap this draft was written around is closed, so the "Open question: where it renders" section
> below is history rather than an open question.

## The problem

An agent working on an iOS app inside Threading cannot see what the app is saying. The app's own
`print()` output, its `os_log` entries, and the system's account of what happened around it all
live outside Threading. Today the only routes are leaving for Xcode, or a shell drawer command
whose output is unstructured text.

This is not a ThreadingMobile problem. It is true of every iOS project a session is opened on, and
the same shape applies to macOS apps.

## What was measured

Every number here came from running the thing, not from documentation. Commands are reproducible.

### Simulator: complete, structured, live, free

```bash
xcrun simctl spawn <udid> log stream --style=ndjson --level=debug
```

One JSON object per line, with `timestamp`, `processID`, `processImagePath`, `subsystem`,
`category`, `messageType`, `eventMessage`, `threadID`, `traceID`, `backtrace`. Every process on the
device, not just the app under test.

**Private data is not redacted on the simulator.** A string logged with default (`.private`)
privacy came back in the clear:

```
total=200  redacted=0  clear=200
sample: probe burst 0 plain=SENSITIVE-VALUE-42 pub=SENSITIVE-VALUE-42
```

`log config --mode private_data:on` fails there ("Simulator unable to set system mode"), so there is
nothing to configure either. This removes the single strongest argument for an in-app shim on the
simulator.

`simctl launch --console-pty` additionally relays the app's `stdout`/`stderr` and **stays
attached** for the app's lifetime (verified: still streaming at a 20s timeout, rc=124).

### Real device: the obvious paths are blocked, one works

| route | result |
|---|---|
| `log stream --device…` | **does not exist**. `--device`/`--device-name`/`--device-udid` are `log collect` options only |
| `log collect --device-name …` | `Must be root to collect logs from attached device`. Dead end for a GUI app |
| `idevicesyslog -u <udid>` | **works**, live, no root, no tunnel, USB or Wi-Fi, iOS 26.6. Text lines: process, sender image, level, message. **No subsystem or category**, and its `-m`/`-p` filters are client-side string matches, so nothing bounds the daemon's work on this route. **Single-client — see below** |
| `idevicesyslog archive - --age-limit N` | **works**, no root, pulls a real `.logarchive` as a tar on stdout |
| `devicectl device process launch --console` | **the best device route, and it was nearly missed.** See below |

#### The relay is single-client, and a leaked reader looks exactly like a dead device

**Read this before concluding anything about a device that will not stream.**

`com.apple.os_trace_relay` behaves as a single-client service. A second reader connects, is
acknowledged, prints `[connected:<udid>]`, and then receives **nothing at all**. No error, no
refusal, no timeout — silence indistinguishable from a quiet device.

This cost most of a day. Three `idevicesyslog` processes had been orphaned to `launchd` by earlier
test runs:

```
1795   ppid 1  Tue Sep  1 22:13  idevicesyslog -u 00008140… --no-colors -n
41493  ppid 1  Wed Sep  2 07:57  idevicesyslog -u 00008140… --no-colors
45374  ppid 1  Wed Sep  2 07:59  idevicesyslog -u 00008140… --no-colors
```

Killing them restored streaming on the next command. Everything below that reads as "the live device
route is broken" was this, and the misdiagnosis drove a redesign around archive pulls and a tap
whose stated purpose was to reach output the unified log supposedly could not carry.

Two things made it convincing, and both are worth distrusting next time:

- **A second implementation agreed.** `pymobiledevice3 syslog live` also received nothing, which
  read as proof the fault was device-side. It only proved both clients were being starved by the
  same holder. Independent tools agreeing tells you the *resource* is contended, not that it is
  broken.
- **The archive route worked.** `idevicesyslog archive` pulled 275 MB happily through the same
  service, which made "live is broken, archive is fine" look like a real distinction. It was one
  request shape being free while the other was occupied.

**The leak is ours.** A source spawns `idevicesyslog` as a child; `Process.terminate()` only runs
from `stop()`. Force-quit the app, kill a probe, crash — and the child reparents to `launchd` and
holds the relay indefinitely. So: use the device source once, exit uncleanly, and the device source
is silently broken for every later reader until somebody finds the orphan.

`DeviceRelayReclaim` now sweeps before connecting, bounded to processes orphaned to `launchd` whose
arguments name this exact tool and device — a reader started in the user's own terminal has their
shell as its parent and is left alone. `DeviceLogLineReader` also terminates its child on `deinit`.
`DeviceRelayReclaimTests` holds the bound.

#### `--console` is the device answer

Written off in one word above — "only" — and it is the entire thing you want. Measured 2026-09-02
against Lotus on a real iPhone:

```
$ xcrun devicectl device process launch --device <id> --console --terminate-existing com.lotus.watch
rc=124 (still streaming when cut at 40s)   81 lines
lines containing <private>: 0
```

| | `idevicesyslog` | `--console` |
|---|---|---|
| live | broken on this phone; connects and sends nothing | **works** |
| redacted | **94%** of app lines | **0** |
| needs libimobiledevice (GPL, unbundlable) | yes | **no**, `devicectl` ships with Xcode |
| size | 280 MB archive pulls | a stream |
| stopping the reader | n/a | **does not stop the app** (verified: pid survived) |

`stdout` has no privacy model, which is why the redaction column reads as it does: `<private>` is a
*unified log* reader-privilege concept and simply does not apply. The same fact that makes printed
output invisible to every log reader is what makes it unredactable once you read the stream itself.

Its one constraint: `devicectl` must **launch** the app, so output begins at that launch and an
already-running app cannot be attached to. For watching a build you just made, that is what Xcode
does too.

**How this was missed.** One phone's `os_trace_relay` accepted a live connection and then sent
nothing, twice, from two independent implementations. That was read as "device streaming is dead"
and the whole design bent around it: archive pulls, and a tap whose purpose was to smuggle `print()`
into the unified log because the unified log looked like the only readable channel. The row above
had been written and dismissed. **A route dismissed in a table cell is not a route that was tried.**

The archive route is the one that produces **byte-identical field structure to the simulator
stream**, so one parser serves the simulator and a device archive. It is not, as an earlier revision
of this draft claimed, the *valuable* one: the live stream works, and the reason it appeared not to
is recorded above. The live device row is a poorer shape — the row model carries subsystem and
category as optional, and a device live row never has them — but it is live, and it is the only
route that shows the system's account of the app as it happens.

`idevicesyslog` is not Xcode's. It is libimobiledevice (1.4.0 here, from Homebrew), GPL-2.0 tools
over an LGPL library, so it is **never bundled**: Threading resolves it on the user's login-shell
`PATH` the way `AgentCLIProbe` and `OnePasswordCLI` resolve theirs, and an absent binary is a
named, actionable state carrying the install command, not a silent empty pane. The device also
needs an existing pairing record; any Mac that has run Xcode against it has one. Its default
service is `os_trace_relay` (`--syslog-relay` exists to force the legacy one).

Cost: `--age-limit 60` produced a **284 MB** archive; `--age-limit 600` produced **296 MB**.
`--size-limit` was ignored. This is a deliberate one-shot pull, never a poll.

### Rates and composition

Unfiltered live capture from the real device: **69,807 lines in ~12 seconds (~5,800 lines/sec)**.

Of a 22,661 line capture taken around a ThreadingMobile launch:

| | lines |
|---|---|
| total | 22,661 |
| attributable to the app's process | 2,123 (9%) |
| of those, from Apple frameworks (`CoreFoundation`, `CoreMotion`, `UIAccessibility`, `FrontBoardServices`, `BacklightServices`, `Network`) | 100% |
| of those, containing `<private>` | **2,004 (94%)** |
| **from the app's own binary** | **0** |

Own-binary logging *is* relayed in general (`bluetoothd`, `locationd`, `configd`, `SpringBoard` all
appear as `Proc[pid]`), but the zero does **not** mean ThreadingMobile is silent.
`Sources/ThreadingMobile/RemoteDiagnostics.swift` has a `Logger` under `codes.threading.mobile`
that records every connectivity event, at `info` by default and `warning`/`error` for failures,
beside the share-safe `RemoteDiagnosticJournal` file. A clean cold launch that reached its Mac
should therefore have produced own-binary lines. Two readings fit, and both are worth knowing:

- the relay carries `default` and above and drops `info`, which would make the live device route
  blind to exactly the level an app's structured logging tends to use; or
- the attribution missed them, because with the debug-dylib split the app's own entries name
  `ThreadingMobile.debug.dylib` as their sender image, not the main executable.

Neither was separated in the capture; both are listed under *Not proven*. Nothing about the
`<private>` ratio changes either way.

**Conclusion: on a real device the live host-side reader gives you the system's account of the app —
framework noise, 94% redacted — and little or none of the app's own signal.** That is a statement
about *what the unified log carries*, not about whether the route works. It works. What it cannot
give you is the app's own printed output, because printed output never enters the unified log at
all; for that, read the stream directly with `--console` or make it durable with the tap.

### OSLogStore is not a tailing mechanism

Measured inside the simulator against `OSLogStore(scope: .currentProcessIdentifier)` (available at
the iOS 17 deployment target; currently unused anywhere in the repo):

| call | entries | time |
|---|---|---|
| no predicate, 30s window | 51 | 1636 ms (cold) |
| subsystem `NSPredicate` | 50 | **779 ms** |
| no predicate again | 55 | **780 ms** |
| 2 second window | 57 | **777 ms** |

**~780 ms fixed floor per call.** Narrowing the window does not help. Pushing a predicate in does
not help. The cost is scanning the tracev3 store, not producing results, which is this repository's
own "a cap on output is not a cap on work" rule appearing inside an Apple API.

So `OSLogStore` is unusable for a live tail: best case ~1.3 polls/sec, each burning CPU on a phone,
distorting the behaviour being observed. It remains correct for one job: an on-demand "snapshot the
last N seconds" at incident time, which matches the capture shape
[`ios-local-diagnostics.md`](../architecture/ios-local-diagnostics.md) already describes.

Two further facts from the same probe: `print()` **never** reaches the store
(`STDOUT-IN-STORE false`), and a process reading **its own** entries gets them **un-redacted**
(`REDACTED-ENTRIES 0`), so `<private>` is a reader-privilege property rather than a storage one.

## The tap

A ~70 line C file, linked or injected, that emits a marker and copies `stdout`/`stderr` into
`os_log` while still writing them through to the original descriptors. The redirect was proven on
both a real device and the simulator; the write-through is a revision after that run, because the
measured version swallowed the original console (see *Not proven*).

```c
// Threading log tap. Linked with -force_load (device) or injected as a dylib (simulator).
#include <os/log.h>
#include <pthread.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>

static os_log_t tap_log;

typedef struct { int source; int passthrough; } tap_channel;

static void *tap_pump(void *ctx) {
    tap_channel *ch = ctx;
    char buf[4096];
    size_t used = 0;
    for (;;) {
        ssize_t n = read(ch->source, buf + used, sizeof(buf) - used - 1);
        if (n <= 0) break;
        // The console the launcher attached (Xcode, --console-pty) still sees every byte. This
        // runs on the pump thread, so bytes written immediately before an abort can still be
        // lost; see gotchas.
        (void)write(ch->passthrough, buf + used, (size_t)n);
        used += (size_t)n;
        buf[used] = '\0';
        char *start = buf, *nl;
        while ((nl = memchr(start, '\n', used - (size_t)(start - buf)))) {
            *nl = '\0';
            if (*start) os_log(tap_log, "[stdio] %{public}s", start);
            start = nl + 1;
        }
        used -= (size_t)(start - buf);
        memmove(buf, start, used);
        if (used == sizeof(buf) - 1) used = 0; // oversized line, drop
    }
    free(ch);
    return NULL;
}

static void tap_capture(int target_fd) {
    int p[2];
    if (pipe(p) != 0) return;
    tap_channel *ch = malloc(sizeof *ch);
    if (!ch) { close(p[0]); close(p[1]); return; }
    ch->source = p[0];
    ch->passthrough = dup(target_fd);   // keep the console the launcher attached
    dup2(p[1], target_fd);
    close(p[1]);
    pthread_t t;
    if (pthread_create(&t, NULL, tap_pump, ch) != 0) { free(ch); return; }
    pthread_detach(t);
}

__attribute__((constructor))
static void threading_log_tap_init(void) {
    tap_log = os_log_create("codes.threading.logtap", "tap");
    tap_capture(STDOUT_FILENO);
    tap_capture(STDERR_FILENO);
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IOLBF, 0);
}
```

### Three delivery mechanisms, one source

| target | mechanism | build change | works if Xcode/user launches |
|---|---|---|---|
| simulator | `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` at launch | none | no |
| simulator / device | xcconfig `-Wl,-force_load,…` static archive | yes | **yes** |
| macOS | `DYLD_INSERT_LIBRARIES` | none | no |

The build-time route is what reaches a real device: you cannot insert a dylib into a signed app
there. Static archive plus `-force_load` was chosen over a dylib deliberately — the constructor
compiles into the app binary, so normal automatic signing covers it and there is nothing to embed,
sign or ship.

The xcconfig gates exactly like [`injection-next.xcconfig`](../../scripts/config/injection-next.xcconfig),
which is the working in-repo precedent for modifying a build without touching the project:

```
THREADING_TAP_ARCHIVE = <abs path>/libthreadingtap.a
THREADING_TAP_ACTIVE_Debug = YES
THREADING_TAP_PLATFORM_iphoneos = YES
THREADING_TAP_FLAGS_app_YES_YES = -Wl,-force_load,"$(THREADING_TAP_ARCHIVE)"
OTHER_LDFLAGS = $(inherited) $(THREADING_TAP_FLAGS_$(WRAPPER_EXTENSION)_$(THREADING_TAP_ACTIVE_$(CONFIGURATION))_$(THREADING_TAP_PLATFORM_$(PLATFORM_NAME)))
```

`simulator-pane.md` already has the seam: the agent runs `xcodebuild` itself through the ordinary
shell permission flow rather than hidden inside an MCP call, so `-xcconfig` is a natural addition.

### What the tap does to privacy

The tap emits `%{public}s`, so every Debug `print()` becomes a **public** entry in the device's
persistent log store: readable by any host-side reader, retained until the store rolls, and
included in a sysdiagnose. An app that prints a token in Debug now writes it where the unified log
keeps it. That is acceptable only because the xcconfig gate is `Debug` and `.app`, and the archive
is never linked into a Release, TestFlight or App Store build. The gate is the privacy control, so
a test proves a Release link line does not contain the archive and a Debug one does.

This is a different subject from the boundary in
[`ios-local-diagnostics.md`](../architecture/ios-local-diagnostics.md), which excludes iOS unified
logs from Threading's *own* phone diagnostics and issue reports because those cross machines and
reach a maintainer. Here the logs are the developer's app under test, they stay on the developer's
Mac, and nothing in this draft puts a unified-log line into a report or an attachment.

### What the tap found, first try

Built into ThreadingMobile, installed on the real device over Wi-Fi, one cold launch:

| count | line |
|---|---|
| **228** | `=== AttributeGraph: cycle detected through attribute N ===` |
| 3 | `Info: SwiftTerm: Unknown EXECUTE code` |
| 2 | `0.5` |

None of these were reachable by any host-side reader, because they go to `stdout`. The bare `0.5`
is a leftover debug print. The cycles are a real bug and are characterised below.

### Appendix: the AttributeGraph cycles, resolved

Investigated 2026-09-01 and fixed the same day, once source inspection was abandoned for a
debugger-shaped answer. Kept because the *method* is the lesson, and because the tap is what made
the defect visible at all.

What was established, and still holds:

- **46** `cycle detected` lines per burst on every scene activation, **25** after every keychain
  write, deterministic. The 46 are one structural cycle met repeatedly: eight attribute ids repeat
  across the burst, and the same id offsets recur in a second range later in the launch, i.e. one
  view subtree instantiated twice.
- They **did not reproduce in the simulator fixtures tried** — but not because the phone's paired
  state is required. See below.

What it was: `MorphingLabel.morph(to:)` in the LabelMorph fork called `window?.layoutIfNeeded()`
to resolve the label's final geometry before building a morph. `MobileConnectionStatusLine` and
`MobileMorphingTitle` are `UIViewRepresentable`s and reach `setText` from `updateUIView`, which is
SwiftUI's own graph update. `UIView.layoutIfNeeded` lays out from the topmost dirty ancestor, so
that call ran `_UIHostingView.layoutSubviews` → `ViewGraph.updateOutputs` while the graph was
still updating, and AttributeGraph reported every attribute it met on the way round.
`MobileConnectionStatusLineView.update` made the same shape of call one line later, a
`layoutIfNeeded()` on itself to place its mark; scoped to its own subtree it was not seen to
re-enter, and it only marks itself for layout now. The path is taken only for an *animated* change of a label
already in a window: the status phrase changes on every activation (`model.refresh()`) and after a
host is saved, which is what tied the bursts to FrontBoard and to `SecItemUpdate`, and a
simulator fixture whose status never changes never takes it. It **does** reproduce in the
simulator: `MobileNavigationTitleMorphTests` drove exactly this path — 36 lines under the
status-change test, 14 under each rename — with every assertion passing, because nobody reads the
test host's `stderr`.

What found it, in one launch: the installed tapped build relaunched with a switch AttributeGraph
reads from the environment (`strings` on the dyld shared cache lists `AG_TRAP_CYCLES`,
`AG_PRINT_CYCLES`, `AG_TRACE`, `AG_TRACE_STACK_FRAMES`, `AG_DEBUG_SERVER`):

```bash
xcrun devicectl device process launch --device <id> --terminate-existing \
  -e '{"AG_TRAP_CYCLES":"1"}' codes.threading.mobile
pymobiledevice3 crash pull --udid <udid> crashes   # ThreadingMobile-<date>.ips, thread 0
```

The app aborted 340 ms after launch and the crash report carried the whole chain, symbolicated
by the device: `updateUIView` → `MobileConnectionStatusLineView.update` →
`MobileMorphingTitleLabel.configure` → `MorphingLabel.morph(to:)` → `layoutBelowIfNeeded` →
`_UIHostingView.layoutSubviews` → `ViewGraph.updateOutputs` → `AG::Graph::print_cycle`.
`AG_PRINT_CYCLES=1` printed nothing extra on iOS 26.6. `lldb` can also `device select` and
`device process attach` to the phone with a breakpoint on
`AG::Graph::print_cycle(AG::data::ptr<AG::Node>) const`; the trap made that unnecessary.

The fix, and the rule it left: the label builds its morph in its own layout pass (`setText`
records the change and asks for layout; `layout()` / `layoutSubviews()` builds the morph in the
settled bounds), and the status line only marks itself for layout. Both are recorded under
LabelMorph in [`dependencies.md`](../architecture/dependencies.md): **nothing reached from
`updateUIView` calls `layoutIfNeeded`.**
`MobileNavigationTitleMorphTests/testAStatusChangeAndARenameReenterNothingInSwiftUI` captures
the test host's standard streams around a status change and a rename and fails on the report
(`stdout` alone missed it: AttributeGraph writes the report to `stderr`).

The two candidates found by inspection earlier were not the cause and were reverted; neither
has been re-applied. (1) `SessionDetailView.wantsLoaderTimer` reading the `presentation` that
carries `waitedLongEnough` while being the `id:` of the `.task` that writes it is still a latent
cycle by inspection. (2) `RemoteNotificationManager.scenePhase` being `@Published` still
invalidates views for nobody's benefit, since both readers are notification-delivery decisions.

## Gotchas that cost time

- **The debug-dylib split.** A modern Debug build puts your code in `ThreadingMobile.debug.dylib`
  (57 MB); the main executable is a 92 KB launcher stub. Verifying the tap by inspecting the main
  executable reports a false negative. Check every Mach-O in the bundle.
- **`devicectl` and `idevicesyslog` fight.** Live capture collapsed from 22,661 lines to 166 as
  soon as devicectl acquired its tunnel and usage assertion. Pull the archive afterwards instead of
  streaming across a devicectl operation.
- **USB versus network.** A device silently moves to `ConnectionType: Network` when unplugged.
  `idevicesyslog` needs `-n` then, and everything including install still works, more slowly.
- **`log stream` hides info level by default.** A predicate that matches nothing may simply need
  `--level=debug`; this produced one false "the mechanism is broken" conclusion during the research.
- **The CoreSimulator lane lock applies.** Source `scripts/coresimulator_lane_lock.sh` before
  driving a simulator, or another agent's evidence run and yours will collide.
- **A tapped descriptor is one thread away from the console.** The pass-through write runs on the
  pump thread, so the last bytes an app writes to `stderr` before an abort can be lost from both
  the console and `os_log`. Swift's runtime failure text also lands in the crash report, which is
  why the tap still takes `stderr`; an app whose crash prose matters more than its `stderr`
  chatter should tap `stdout` only.

## Not proven

- **Where `os_log` cuts a long line.** The pump accepts lines up to 4 KB; `os_log` truncates a
  long formatted message, and the limit on iOS 26 was not measured. An app that prints a 3 KB JSON
  dump may arrive cut, and the tap should split rather than lose the tail. (An earlier version of
  this list asked whether the tap could "un-redact `%@`"; there was nothing to establish. `%s` and
  `%@` are both private by default, and the tap only touches stdio, so it cannot change how the
  app's own `os_log` calls are redacted.)
- **Why the launch capture held zero own-binary lines.** Whether the device relay drops `info`,
  or the attribution missed `ThreadingMobile.debug.dylib` as the sender image; see *Rates and
  composition*. One capture with `idevicesyslog` beside a forced `warning` from the app, then the
  same window from the archive with `--info`, separates the two.
- **The write-through revision of the tap on a real device.** The measured run used the version
  that swallowed the original descriptors; the pass-through above has been reasoned about, not
  re-run.
- **A direct `os_trace_relay` client.** `idevicesyslog` prints text, but the service it speaks by
  default carries subsystem and category, and other tooling (pymobiledevice3's `syslog live`)
  renders them live without root or a tunnel. Not measured here. If it holds, the live device
  route gets the NDJSON shape and the archive pull stops being the only structured device source.
- **Runtime `DYLD_INSERT_LIBRARIES` on a real device.** `devicectl` accepts env vars (`DEVICECTL_CHILD_`
  prefix, or `--environment-variables` JSON) but the dylib must still be signed and readable inside
  the bundle. Untested; the build-time route made it unnecessary.
- **macOS with Developer ID plus hardened runtime.** Injection succeeded in all three signing modes
  tested, but host and dylib were both ad-hoc signed, which is the lenient library-validation case.
  A Developer ID signed app would reject an ad-hoc dylib.

## The two halves are complementary

The tap only ever sees its own process. The host-side reader sees the whole system: of 22,661
device lines only 2,123 were the app, and the other ~20,000 (`SpringBoard`, `bluetoothd`,
`mDNSResponder`, `CommCenter`, `locationd`) are exactly what diagnosing pairing or connectivity
needs, which is much of what ThreadingMobile does.

So the product is both:

- **Baseline, any app, no cooperation:** host-side `log stream` (simulator) or archive pull /
  `idevicesyslog` (device). Never asks anything of the user's project.
- **Opt-in depth:** the tap, when Threading builds or launches the app, turning `stdout` into
  first-class unified-log entries in the same stream.

One row model either way; the device live route fills only the fields it has. The renderer does
not need to know which source produced a row.

## Scaling contract

Stated up front per the [Scaling Gate](../../CLAUDE.md#scaling-gate).

- **Expected** a few hundred rows/sec filtered; **stress** ~5,800 rows/sec unfiltered, measured.
  A native in-process pane has since been measured at **22,800 rows/sec with zero drops** and
  flat memory against a replayed device capture, so the renderer is not the constraint for that
  tier; see [`native-extension-tier.md`](native-extension-tier.md).
- Rows are externally sized and unbounded, and one row is too: an NDJSON entry with a `backtrace`
  runs to kilobytes. They stay a value model in a ring bounded in **bytes as well as rows** (the
  probe's 50,000-row ring is a row cap only, which is a per-item cap, not an aggregate bound).
  When the byte ceiling is hit the oldest rows go first and the view says how many it dropped. The
  view owns viewport rows only.
- **Push the predicate into the source.** `log stream --predicate` is evaluated by the log daemon,
  so a subsystem or process filter bounds the *scan*, not just the result. Filtering in the UI is
  the wrong place and the measured rates say so.
- Archive pulls are hundreds of MB and are an explicit user action with a progress surface, never
  automatic and never a poll.
- Decode off the main actor; coalesce appends; preserve bottom-pinning and exact scroll position.
- **The child process has an owner.** The simulator `log stream` runs under the session's
  `SimulatorDeviceLease` from [`simulator-pane.md`](../architecture/simulator-pane.md): it starts
  under the lease, is killed when the lease is released or the device shuts down, and never
  outlives the session. The device archive pull is one cancellable task with a progress surface.

## Open question: where it renders

The host gap is real and is **not** specific to logs. `network-inspector-extension.md` reached the
identical conclusion for HTTP flows and stated it precisely: semantic panels are bounded snapshots
updated by whole-panel replacement over JSONL, and companion `remoteSurface` pixels "lose text
selection, native accessibility, agent-readable structure, theme adaptation and mobile fallback."

The complete extension node vocabulary today is `text`, `image`, `button`, `textInput`, `picker`,
`scene`, `media`, `status`, `disclosure`, `proceed`, `overlay`, `customSurface`, `divider`,
`spacer`, `flexibleSpacer`, `stack`. There is no table, list or stream. `customSurface` is
Metal-shader-only. So a log view cannot be expressed today, and this draft does not propose one
until that tier is decided.

Whatever tier wins, the split should follow `.media`, which is the existing precedent for a node
whose content moves on its own: **the extension names a source, Threading owns the buffer,
virtualization, filtering, search, theme, accessibility and the ceilings.** Rows cross through an
opaque host handle, never through the node tree.

## Smallest shippable slice

1. Host-side simulator reader behind the existing shell drawer or a bare pane: `log stream
   --style=ndjson`, NDJSON decode off-main, ring buffer, viewport-only rows. No new SDK surface.
2. The device archive pull as an explicit action, reusing the same parser.
3. The tap, injected on the simulator first (no build change), then the xcconfig route for device.
4. Only then the extension source seam, once the rendering tier is settled.

## Reopen / revisit triggers

- Apple adds a supported live device log stream, or lifts the root requirement on
  `log collect --device`. Both would remove the archive pull's size cost.
- `OSLogStore` gains an incremental or streaming read, which would make an in-app readback viable
  and change the tap's job.
- The rendering tier lands for the Traffic Inspector; this feature should adopt it rather than
  invent a second one.

## Where the pane lives

**It is a plugin.** `DeviceLogPaneViewController` and `DeviceLogSources` moved out of the
application into `Plugins/DeviceLogsPlugin`, which Threading builds as a native bundle target and
ships in `Contents/PlugIns`. The host loads it through `NativePluginCatalog` — the same path a
third-party bundle takes — so the plugin tier carries a real feature rather than only a probe, and
device logs can grow without adding to the app.

Nothing about the user's route changed: **Device logs** is still an entry in the panel's new-tab
menu, still one pane per session, and `device_log_prepare` still reveals it. What changed is that
`activateDeviceLog` now opens the bundled plugin, and the persisted `.deviceLog` tab kind restores
as that plugin so an older row opens the pane it always did.

Two things stayed in the application deliberately. The **tap consent** is a security grant about
the user's own product, so it belongs to the host and is asked by the agent command rather than by
the pane. `DeviceLogTap` stays with it, because compiling the tap is the agent's build step, not
the pane's.

The plugin is trusted by **location**: code inside the app bundle is sealed by the app's own
signature, so altering it invalidates the app the operating system already checked. That is a
stronger guarantee than the team allowlist, which continues to govern everything installed outside
the app. See [`native-extension-tier.md`](native-extension-tier.md).

## The store

The pane keeps a bounded ring so a firehose cannot grow memory, and that ring is why "what happened
at 14:02" had no answer once 50,000 rows had gone by. `DeviceLogStore` is the other half: every row
is written to SQLite as well as shown, so search, a time range, and hiding rows that can come back
are **queries** rather than scans of whatever is still in memory.

Its design is Timber's `LogDatabase` — WAL, `synchronous=NORMAL`, a reused prepared statement, one
transaction per batch, and FTS5 with the **trigram** tokenizer. Trigram is the load-bearing choice:
a log is searched for `0x16f95`, `fCli`, `com.apple.xpc` — fragments inside identifiers — and the
default word tokenizer finds none of them. Two things differ from Timber. The RAG half (chunks,
embeddings) is not here, because nothing asks for it yet. And the instant is stored in
**milliseconds** rather than Timber's whole seconds, which would throw away exactly the sub-second
ordering the relay's six fractional digits provide.

`instant_ms` and `severity` carry their own indexes. An FTS5 table indexes its text and nothing
else, so a range or level filter would otherwise be a table scan on the column the query actually
filters by.

**Measured before anything was built on it**, which was the point of doing this before the UI:

| | Debug build | Against |
|---|---|---|
| Insert | **34,572 rows/sec** (batches of 580, the shape a 100 ms drain produces) | ~5,800 rows/sec from a paired device — 6× headroom |
| Search | **0.5 ms** for 1,000 hits | over 100,000 rows |

Release would be faster; Debug is the pessimistic case and it already clears the bar by six times.

`DeviceLogRecorder` owns the store on a serial queue, because 580 rows is ~17 ms of SQLite and the
drain runs on the main actor ten times a second. Recording is **best effort**: a store that will not
open leaves the pane exactly as it was, since the rows are on screen either way and only history is
lost. Nothing on that path throws at the caller, and there is a test that an unusable directory does
not take the stream down.

Retention is 500,000 rows, trimmed every 50,000 written rather than on every batch. The FTS index
follows deletions through a trigger — an index row left behind would return an id whose row no
longer exists, which is a test.
