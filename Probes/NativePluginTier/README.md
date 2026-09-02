# Native Plugin Tier probe

A working, standalone spike of **Plan A** from
[`docs/feature-drafts/native-extension-tier.md`](../../docs/feature-drafts/native-extension-tier.md):
a host application that loads a third-party code bundle at runtime and hosts its **native AppKit
view**, themed by tokens the host supplies.

Its plugin is the log viewer from
[`docs/feature-drafts/device-and-simulator-logs.md`](../../docs/feature-drafts/device-and-simulator-logs.md),
so the two drafts meet here.

Nothing in this directory is referenced by `Threading.xcodeproj`. It builds with `swiftc` and
touches no application target.

## Run it

```bash
./build.sh
./build/probe-host build/LogStreamPlugin.bundle
```

It finds its own sources and offers them in a popup: every booted simulator, every paired iPhone
(USB or Wi-Fi), and a replay file if one is given. Pick one and it streams. There is a text filter
over message/process/subsystem, a level filter, Clear, and Rescan.

Everything is also drivable from the environment, so a run can be scripted rather than clicked:

| variable | effect |
|---|---|
| `PROBE_SOURCE` | preselect the source whose title contains this |
| `PROBE_FILTER` | preset the text filter |
| `PROBE_REPLAY` / `PROBE_REPLAY_RATE` | offer a captured NDJSON file as a source, at a stated rate |
| `THREADING_PLUGIN_TEAMS` | comma-separated allowlist; empty (default) accepts any bundle |

A third command-line argument is an `NSPredicate` pushed into `log stream` for simulator sources.
Progress goes to stderr as `[probe]` lines, so nothing needs photographing.

Take the CoreSimulator lane first (`scripts/coresimulator_lane_lock.sh`); the plugin spawns
`simctl`.

`kill -USR1 <pid>` flips the theme. That exists so the probe can be driven from a script without
synthesising a click at guessed coordinates, which is how the theme path was actually verified.

Set `THREADING_PLUGIN_TEAMS=TEAMID1,TEAMID2` to turn on signature enforcement. Empty (the default)
accepts any bundle so the probe runs unsigned.

## What it demonstrates

- A `.bundle` is `dlopen`ed into a hardened-runtime host and its principal class instantiated,
  through the real [`ThreadingPluginKit`](../../Packages/ThreadingPluginKit) package that both
  sides link. The contract is typed: `PluginContext` and `PluginTheme` are `@objc` classes rather
  than a `[String: Any]` bag.
- **Three live sources behind one dropdown**, all reaching the same table: `log stream` from a
  booted simulator, `idevicesyslog` from a paired iPhone, and a replayed capture. Discovery runs
  off the main thread with a deadline on every child process.
- The plugin returns a real `NSView`: `NSTableView`, real column headers, real text selection,
  real accessibility, real scrolling.
- Rows arrive from `xcrun simctl spawn <udid> log stream --style=ndjson --level=debug`, are decoded
  off the main thread, and land in a bounded ring (50,000 rows, a row cap only) that is drained on
  a 100 ms timer. A live simulator offered 332 rows/sec; the ceiling was measured separately by
  replay, below.
- Only viewport rows are ever constructed, through ordinary `makeView(withIdentifier:)` reuse.
- The bottom stays pinned only when it was already pinned, so scrolling back to read something is
  not fought by the stream.
- The filter predicate is pushed into `log stream` rather than applied here, so the log daemon
  bounds the scan and not just the result.
- `applyTheme` re-themes the live view, verified light and dark.


## Measured ceiling

The scaling contract in the logs draft claims a real device produces ~5,800 rows/sec unfiltered.
`PROBE_REPLAY=<capture.ndjson> PROBE_REPLAY_RATE=<n>` replays a captured device log at a stated
rate so that number can be exercised rather than assumed. Make a fixture with:

```bash
log show --archive <pulled>.logarchive --style ndjson --last 5m --info --debug > capture.ndjson
PROBE_REPLAY=capture.ndjson PROBE_REPLAY_RATE=30000 ./build/probe-host build/LogStreamPlugin.bundle
```

Stats go to stderr once a second, so a stress run needs no screenshot. Replaying a real 24,546-row
device capture on an M-series Mac, `-O` build:

| asked | sustained | dropped | worst tick | CPU | RSS |
|---|---|---|---|---|---|
| 6,000/s | 4,560/s | **0** | 31.5 ms | 53% | 199 MB |
| 12,000/s | 9,120/s | **0** | 31.9 ms | 53% | 202 MB |
| 30,000/s | **22,800/s** | **0** | 31.2 ms | 57% | 207 MB |

And against the **live real device**, which is the case the contract is actually about:

```
[probe] selected: 00008140… (Wi-Fi)
[probe] stats rows=69937 shown=3000 rate=2778/s peak=6580/s worstTick=42.5ms ring=50000
        dropped=0 filter="locationd" minLevel=0
```

69,937 rows off a paired iPhone over Wi-Fi, **peaking at 6,580 rows/sec with zero drops**, while
filtering to `locationd`. That is the real firehose, not a synthetic one.

The replay thread is the limiter, not the pane: `dropped` stays 0 at every rate, so the UI consumed
everything offered. **22,800 rows/sec is roughly four times the real device firehose**, which
settles the scaling question for this tier.

Two honest readings of that table:

- **CPU barely moves** between 9,120/s and 22,800/s (53% to 57%), so most of it is the fixed 10 Hz
  `reloadData`, not per-row work. A real slice should coalesce differently and will be much cheaper.
- **The 31 ms worst tick is not a rate effect.** It appears in the third second, exactly when the
  ring first reaches 50,000, and does not grow across another 250,000 rows. It is
  `Array.removeFirst(n)` at the cap being O(n). A proper ring removes it. It is a *max*, not a
  steady state.

## What it found

**Two `@objc protocol` declarations in two binaries are two protocols.** The first version compiled
`ThreadingNativePlugin.swift` into both host and plugin, expecting the Objective-C runtime to match
them by name. The loader refused with `principal class does not conform to ThreadingNativePlugin`,
correctly. A real tier needs one shared, versioned framework that both sides link, which is what
`build.sh` now produces as `libThreadingPluginKit.dylib`. This is a load-bearing fact for the draft:
the shared framework is not a convenience, it is the mechanism.

**The OS enforces nothing about who may be loaded, for this app as shipped.** Threading ships
hardened runtime (`flags=0x10000(runtime)`) with the `disable-library-validation` entitlement in
both configurations, so `dlopen` accepts a bundle from any team. Measured separately: forcing
`-o runtime,library` makes the same load fail with *"mapping process and mapped file (non-platform)
have different Team IDs"*. Every trust check in `PluginLoader` is therefore ours and must run before
the code is mapped. One measurement in the draft, a host with *no* entitlements still loading an
ad-hoc bundle, was taken on this Mac with System Integrity Protection disabled and is not yet a
platform fact; the draft says so.

**Setting `tableView.backgroundColor` alone leaves the old ground showing.** The clip view paints
the region the rows sit in, and `reloadData()` rebuilds cells rather than the background behind
them. A live re-theme has to set the scroll view, the clip view and the table, then mark all three
dirty. This is the kind of thing a real `ThreadingDesignKit` component would own once instead of
every plugin rediscovering it.

## What it deliberately does not do

- Use the real Design system. Tokens cross as `[String: Any]`, standing in for a typed
  `ThreadingPluginKit` facade over `ThreadingDesignKit`. Proving the mechanism came first so the
  146-file extraction is not committed to before the shape is known.
- Quarantine a crashing plugin. The loader records identity for it; the policy belongs with
  `crash-recovery.md`.
- Handle the real-device source. That path is an archive pull, not a stream; see the logs draft.
- Bound the ring in **bytes**. It caps rows only, so one pathological 10 MB line is still 10 MB.
- Replace the array with a real ring. `rows.removeFirst(n)` at the cap is what the 31 ms tick is.
