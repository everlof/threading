# Application-level UI scenarios

The XCUITest boundary, recorded provider traffic, deterministic mock agents, and the rule for
which product promises require a complete user journey.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

## The quality contract

Every **critical user journey** has one deterministic application-level UI scenario. The unit of
coverage is a user promise, not every method, menu item, or provider/UI combination.

A critical journey is one whose failure can lose or misattribute work, strand a conversation,
perform an unintended side effect, hide a refusal, or prevent the user from recovering. Examples
include creating and resuming a session, sending and cancelling a turn, brokering permission,
reviewing an agent's file change, surviving provider failure, and restoring state after relaunch.

The scenario must launch the shipping `Threading.app` through `XCUIApplication`, interact through
accessibility, and assert the durable result. In-process AppKit tests remain the right tool for
component behavior, rendering, themes, layout, and exhaustive state combinations; provider
adapter tests remain the right tool for every protocol shape. A shared product journey is tested
with one representative provider, while a provider-specific visible behavior earns its own UI
scenario. This prevents the suite from becoming the cross-product of every feature and runtime.

## Current foundation

`ThreadingUITests` is a real UI-testing bundle with its own `ThreadingUI` scheme and
`Threading-UI.xctestplan`. Both it and `ThreadingTests` use Xcode filesystem-synchronized groups,
so a new source under either target's directory is compiled automatically without per-file
project registration.

Run it with:

```bash
scripts/test.sh ui
# or directly
scripts/ui-test.sh
```

The launch harness assigns a fresh `CFFIXED_USER_HOME` and matching `HOME` before the application
process starts. Foundation preferences, Application Support, the instance lock, provider account
discovery, and child processes therefore see one disposable scenario home rather than the
developer's state. Cleanup refuses any directory that lacks both the exact generated shape and
the harness marker.

`THREADING_UI_SCENARIO_HOME` is that home's name, and it is also how the application recognises
that a machine rather than a person is driving it. `AutomatedRun` reads it, so the refusal beep an
unavailable command makes, and any bell a fixture agent rings, stay silent for the whole lane: a scenario clicks and
types its way through states where an action legitimately cannot proceed, and there is nobody in
the room those beeps are for. The scenario marker is used rather than a flag of its own because
`UIScenarioBootstrap` already fails closed without it, so the two cannot disagree about whether a
scenario is running. See [`session-activity.md`](session-activity.md) for the gate itself.

After the first window appears, the harness gives it a 1,400×900 point target, bounded by the
current screen's visible frame, and verifies the resulting frame through XCUITest. Feature
scenarios therefore exercise the full multi-pane layout instead of accidentally testing the
product's compact 800×600 first-launch window.

The first smoke test proves only that the shipping executable reaches a real main window through
that isolation boundary. It is foundation, not yet feature coverage.

The UI lane needs an interactive macOS test host with automation mode available. A machine that
can compile the runner but cannot enable UI automation reports an infrastructure failure before
any scenario method starts; that is not converted into a skipped or passing test.

Every feature journey records named screenshots at semantic checkpoints with `keepAlways`.
Captures are rendered by Threading from its own AppKit window rather than read back from the
display, so a successful result neither retains pixels from unrelated applications nor needs the
macOS Screen Recording grant. A small JSON attachment beside each PNG carries its journey name,
checkpoint order, title and description; the report never has to infer meaning from a filename.

Every UI run gets a unique result bundle and a static HTML gallery under
`.build/ui-test-reports/`. The runner prints the exact `index.html` path and an `open` command.
The report has one navigable section per test, status and duration, lazy-loaded full-size images,
descriptions, and a click-to-enlarge view. The `.xcresult` remains beside it for Xcode diagnostics.
To choose a known location instead:

```bash
scripts/test.sh ui -resultBundlePath /tmp/ThreadingUI.xcresult
# report: /tmp/ThreadingUI/report/index.html
```

Result and report paths must be new for each run; generated output is never silently replaced.

Xcode 26 otherwise starts a continuous full-display diagnostic recording for every UI test and
keeps the MP4 only on failure. On an ad-hoc-signed Debug build, every rebuild changes the code
requirement macOS associates with the capture, so the Screen Recording prompt can recur instead
of behaving like a one-time grant. `Threading-UI.xctestplan` deliberately sets **Preferred Capture
Format** to screenshots: passing runs use only Threading's in-process checkpoint renderer and do
not start that recording. Xcode can still attempt its own full-display screenshot when a test
fails, which may ask for the grant on that failure run. A diagnostic video remains possible by
temporarily selecting video in the test plan, but it is explicitly opt-in because it can include
unrelated private content.

`scripts/ui-test.sh` builds the fixture-agent executable and asks Xcode to seal it into the Debug
app's `Contents/Helpers` directory before code signing. The application will accept only that
exact bundled executable and mutable fixture files below the isolated scenario home. This is a
load-bearing split: macOS refuses to execute code copied into the XCUITest runner's temporary
container, and allowing an arbitrary executable path would let a malformed test launch a real
provider. Non-UI and Release builds remove any helper left in a reused products directory.

## The combined UI evidence catalogue

Application journeys are only one of three kinds of review evidence. Component behavior and
complete layout states stay in the fast, in-process AppKit lane, where the product can cover
themes and sizes without multiplying fixture-agent processes. The checked-in
`Tests/UIEvidence/coverage.json` is the inventory for all three kinds:

- **component** entries capture every independently named Component Gallery story under System
  light and dark;
- **surface** entries select real controller and window render tests for the composer, sidebar,
  native conversation, Git Review, browser, collaboration, audit and recovery surfaces;
  independently navigable Settings destinations remain separate entries so adding one page does
  not make the broad Settings label look more complete than it is;
- **journey** entries name both implemented critical promises and the next known gaps. A journey
  stays visible as implemented even when its slower result was not included in a particular
  render run, and a planned journey is visible as a gap rather than disappearing from the list.

Generate the component and surface catalogue with:

```bash
scripts/ui-evidence.sh
```

The command creates a unique directory under `.build/ui-evidence-reports/`, runs only the render
tests selected by the manifest, and writes two static workflows beside `evidence.json`:

- `report/review.html` (also `index.html`) is the design-review gallery. An annotation records a
  stable artifact id, the exact image hash, normalized image coordinates, severity, description
  and status. Export `annotations.json` to hand the review to an agent; importing it into the same
  or a regenerated report draws markers only when the reviewed pixels still match.
- `report/regression.html` is the approval gate. It defaults to changed, new and unbaselined
  images, shows current/baseline/exact-difference-mask modes, and records Approve, Investigate or
  Reject. The generator derives the mask from the same 16-bit decoder as the acceptance result;
  it does not rely on a browser's lower-precision canvas.
  Exported `decisions.json` is tied to the report id and the current hash of every reviewed image.

All processing remains local. Browser state is convenient working state, not the durable record;
export a JSON file before handing the review to another person or task.

`scripts/ui-test.sh` also writes `evidence.json` beside every journey gallery. Include one or more
such runs in the combined report without rerunning their XCUITests:

```bash
scripts/ui-evidence.sh \
  --journey-evidence .build/ui-test-reports/<run>/report
```

Approved references live under `Tests/UIEvidence/Baselines/` and mirror stable evidence paths;
xcresult attachment UUIDs never become baseline names. Equality is exact after decoding both PNGs
to RGBA, so compression and metadata do not matter while one changed rendered pixel does. Changed
reports state the pixel count, percentage and bounding rectangle.

Apply reviewed decisions with:

```bash
python3 scripts/approve_ui_evidence.py \
  --report .build/ui-evidence-reports/<run>/report \
  --decisions ~/Downloads/decisions.json \
  --baseline Tests/UIEvidence/Baselines \
  --require-complete
```

The approval tool checks the report id, platform, artifact id, baseline path and current SHA-256
before copying. An old decision cannot approve a newer capture. Investigated and rejected images
never modify baselines. The copied PNGs remain visible source changes that must be reviewed and
committed with the UI change.

`--accept-new-baselines` is only a first-baseline bootstrap: it copies missing references and
never overwrites an existing reference. `--require-accepted` is the strict local/CI gate and exits
nonzero when any generated image is changed, new or unbaselined.

### Complete and targeted visual passes

The coverage manifest, not a hand-maintained test command, selects the canonical feature states.
Run the full macOS catalogue before merging a broad design-system or layout change. For an isolated
iteration, select a coverage entry without making partial output look like a complete run:

```bash
scripts/ui-evidence.sh --only conversation-timeline
scripts/ui-evidence-ios.sh --only ios-native-conversation
```

macOS additionally catalogues `app-theme-chrome-matrix`: one rich conversation under every
`AppThemeLibrary.stock` value, with both appearances for adaptive themes. The test derives its
matrix from the product registry, so adding a stock theme adds evidence automatically. During one
theme's polish loop, avoid paying for the whole matrix:

```bash
scripts/ui-evidence.sh --theme cyberpunk
```

iOS catalogues `ios-chrome-matrix`, the same rich conversation under every deterministic
Mac-supplied `RemoteThemeDTO` fixture. These fixtures intentionally exercise materially different
palette and material families; they do not pretend that iOS locally owns the Mac's complete stock
registry. A new Mac theme that is expected to be a distinct supported mobile chrome needs a DTO
fixture, its id in the manifest-level `themeIDs` contract, and a capture in that entry. The runner
validates every requested fixture theme against that contract. Any individual iOS capture or entry
remains targetable with `--only`.

Use the two passes differently:

1. While changing one surface/theme, run the narrow selection and use `review.html` for polish.
2. When the implementation is ready, run the relevant complete platform catalogue and resolve
   every item in `regression.html`.
3. Apply only approved decisions, inspect the baseline diff in Git, and rerun with
   `--require-accepted` to prove the checked-in references and current renderer agree.
4. Commit approved baselines. Generated `.build` reports are not source artifacts. Commit an
   annotation JSON only when it is an intentionally open design-review handoff; delete it when the
   notes are resolved so it cannot become a stale shadow backlog.

The opt-in component walk is bounded by the fixed developer-authored gallery. Product surfaces
whose data comes from transcripts, sessions, files or usage history still use their ordinary
virtualized fixture controllers; the evidence runner does not build an unbounded visual stack to
make a screenshot.

The report/approval machinery itself is covered by
`scripts/tests/test_ui_evidence_tools.py`, which is part of `scripts/ci.sh`. It proves decoded
16-bit PNG equality independent of compression, one-pixel strict failure with a written report,
and refusal to apply an approval after its reviewed asset changes.

### iOS evidence catalogue

`Tests/UIEvidence/ios-coverage.json` is the companion inventory for the native iOS app. Its
capture plan names DEBUG-only deterministic scenes that route through the shipping
`ThreadingMobile` view tree: welcome and pairing, the populated session dashboard, the real UIKit
conversation timeline, permissions, collaboration, SwiftTerm, Git Review, Workspace, Usage,
session creation, Settings and its independently navigable destinations, browser-follow privacy,
attachments, share links, dialogs and issue reporting. It deliberately does not recreate those
screens in a snapshot-only target. Native chat fixtures also cover rich row kinds and streaming;
terminal fixtures cover ANSI colour, Unicode, wrapping and longer scrollback.

Run it on the booted iPhone simulator with:

```bash
scripts/ui-evidence-ios.sh
# choose an already installed simulator explicitly when needed
scripts/ui-evidence-ios.sh --simulator <UDID>
```

By default the script briefly clones the selected iPhone, restores the template to its prior
boot state, clears the cloned app data, and deletes the clone on exit. That gives software-keyboard
captures a clean Simulator menu state without changing a developer's persistent keyboard setting.
The script builds one Debug app in its own Derived Data directory, installs it once, and launches
each declared scene with a fresh evidence identifier. The app repeatedly renders its own key
window and publishes a marker from its temporary container only after asynchronous fixture data
has arrived and adjacent rendered frames agree. A focused UIKit text field is allowed to keep its
system caret blink: the coordinator observes longer than one blink interval and asks for two
equal adjacent frames, rather than requiring the entire screen to stop owning time forever. A
timeout or an unstabilized marker fails the run; it never becomes a screenshot with a successful
label.

Text-entry captures may declare `keyboardState` as `closed`, `open`, or
`dismissed-after-open`. The coordinator sends one semantic focus request through each real
SwiftUI `FocusState` (or focuses the UIKit-owned conversation/terminal editor directly), observes
UIKit's keyboard show/hide lifecycle notifications, and records named checks in the marker.
Dismissal fixtures fail unless the keyboard was visible first, no editor remains focused, and the
safe area plus the surface's typed `keyboardLayout` contract (`frame` for fixed composers,
`origin` for a platform Form editor) return to their stable pre-keyboard geometry. App-owned
dismissed captures then have to become pixel-stable too. This is a shared lifecycle contract, not
a per-screen delay.

The canonical iPhone 17 Pro capture is 402×874 points / 1206×2622 pixels. Every image in one run
must have that exact native scale. The ordinary capture is app-owned, so it does not start a
full-display recording or require the macOS Screen Recording grant. A fixture whose
`captureMode` is `display` uses `simctl io screenshot` after the app publishes its ready marker;
this is reserved for the keyboard-open state where OS-owned pixels are required and still captures
only the simulator display. Keyboard-dismissed evidence returns to app-owned, pixel-stable capture.
Simulator status furniture is fixed for repeatability.

Each run writes a unique static report under `.build/ui-evidence-ios-reports/` using the same
design-review and regression-approval pages as macOS. Approved iOS references live separately under
`Tests/UIEvidence/iOSBaselines/`; `--accept-new-baselines` has the same create-only rule and never
overwrites an approved image. Do the explicit image-review lap first. Generated run images remain
in `.build` and are not committed merely because capture succeeded.

Apply iOS decisions with the iOS baseline root:

```bash
python3 scripts/approve_ui_evidence.py \
  --report .build/ui-evidence-ios-reports/<run>/report \
  --decisions ~/Downloads/decisions.json \
  --baseline Tests/UIEvidence/iOSBaselines \
  --require-complete
```

The current catalogue is surface evidence, not a substitute for application journeys. The
manifest keeps the adaptive compact/Dynamic-Type/iPad matrix and the owner-only workspace detail
recovery journey (file and attachment previews plus extension panels) visible as planned gaps
until they have deterministic host payloads, interaction and durable-result assertions.

## A session tape is not a transcript

A transcript records the eventual conversation. It does not preserve the ordering that exposes
most integration bugs: streaming replacement, permission round trips, partial tool output,
cancellation, process exit, lifecycle hooks, or malformed traffic.

`Packages/ThreadingScenarioKit` therefore defines a versioned **session tape** below the shared
`StreamEvent` model:

```text
real provider process
        │
        ▼
provider-wire recorder
        │ normalize known dynamic values
        ▼
bounded session tape
        │
        ▼
deterministic fixture-agent process
        │ real stdin/stdout/PTY protocol
        ▼
shipping transport and parser → application UI → accessibility assertions
```

Steps are typed as an expected host write, emitted agent bytes, a fixture file mutation, a named
checkpoint, or a final process exit. File mutations are root-relative, reject traversal and
symlinks, and cannot escape the disposable scenario home. Illegal mixtures are not representable.
A tape always has a final exit and cannot place anything after it. The format currently recognizes
only fixed placeholders:
`${SCENARIO_ROOT}`, `${SESSION_ID}`, `${PROJECT_ID}`, `${TURN_ID}`, and `${PORT}`. An unknown
placeholder fails validation instead of silently resolving to an empty string or a machine-local
value.

The recorded boundary depends on the provider:

| Surface | Tape transport |
| --- | --- |
| Terminal session | PTY bytes |
| Claude Native Chat | Claude stream JSON stdin/stdout |
| Codex Native Chat | app-server JSON-RPC stdin/stdout |
| Grok Native Chat | ACP stdin/stdout |

Injecting `[StreamEvent]` directly is useful for model and rendering tests but is not an
application-level scenario: it bypasses the parser, framing, child ownership, launch failure,
and exactly-once completion paths the scenario exists to prove.

## Scaling and determinism

Tapes are untrusted recorded files. `AgentScenarioTape.load` reads one byte past a 4 MiB
opened-file cap and then validates at most 4,096 steps, 256 KiB per payload, 3 MiB aggregate
payload, 30 seconds per delay, and 120 seconds aggregate delay. Replay applies the per-payload
ceiling again after placeholder expansion. Those are protocol safety ceilings, not ordinary
fixture targets: a normal critical journey should be tens of steps and complete in seconds. Long
stress streams remain opt-in performance fixtures.

UI assertions wait for semantic accessibility state. They do not sleep for guessed rendering or
provider durations. Tape delays reproduce only a behavior where time itself is part of the
contract; ordinary ordering uses host-write expectations and named checkpoints. Failure artifacts
should carry the last checkpoint, unmatched host write, application screenshot, and isolated
scenario logs.

## Recording and privacy

A real-agent recording is always made against a disposable synthetic repository. Never record a
user checkout and never use a production conversation as a fixture source.

Normalization happens while the recorder still knows the meaning of a value. Session, project,
turn and port values become the fixed placeholders; the synthetic repository becomes
`${SCENARIO_ROOT}`. Timestamps and request identifiers that carry no product meaning are removed
or stabilized. The committed tape is minimized to the exchange needed for the named user promise;
the raw recording is evidence for authoring, not automatically a test specification.

Before commit, `threading-scenario validate` applies structural limits and a conservative privacy
audit. It rejects credential-shaped values, private keys, literal `/Users/<name>/` and
`/home/<name>/` paths, and any additional forbidden fragment supplied by the recorder. This is a
rejection gate rather than an automatic redactor: silently rewriting an unclassified value can
make a fixture safe-looking while changing its behavior.

Both the ordinary CI gate and the UI lane run `scripts/check_agent_scenarios.sh`, so every JSON
tape under `Fixtures/AgentScenarios` is structurally validated and privacy-audited even when the
GUI lane itself is not running.

## Scenario ownership

Each important feature records its scenario in the feature's definition of done:

1. The named user journey and why it is critical.
2. The representative provider, plus any provider-specific variants.
3. The synthetic starting repository and application state.
4. The versioned, validated session tape.
5. Accessibility checkpoints for each user-visible transition.
6. Durable-store and filesystem assertions for the promised result.
7. At least one refusal or failure path when the feature can cause a side effect or lose work.

The UI suite is a separate lane because it launches a GUI and is materially slower than the
off-screen plan. `scripts/ci.sh` validates the Foundation-only tape contract on every run. Add the
UI lane to required hosted CI after the first fixture agent and critical journey run reliably on a
clean machine; until then `scripts/test.sh ui` is the explicit local gate and must not be described
as ordinary CI coverage.

## Implemented journeys

### File change and relaunch recovery

`CodexFileChangeJourneyUITests` is the first complete scenario. Its minimized Codex app-server
tape came from one real Codex 0.147.0 exchange against a disposable synthetic repository; account,
startup, rate-limit and machine-path traffic was deliberately not copied into the fixture. It:

1. launch an isolated project and native conversation;
2. submit a prompt;
3. stream an assistant response with one tool/file mutation;
4. open an empty panel on Overview's right-hand Info section, switch to Activity, and show the Git Review result;
5. quit, relaunch into the same isolated home, and prove transcript recovery.

The test crosses the shipping child-process boundary, JSON-RPC parser, conversation renderer,
checkout watcher, Overview's Activity/Info lifecycle, Git Review surface, provider transcript
importer, and durable project store.
Permission, provider failure, rate-limit, and remote/mobile promises remain future
journeys rather than variants of this one.

### Stop and continue

`CodexStopTurnJourneyUITests` sends a real `turn/start`, waits until the composer exposes its
accessible Stop action, and presses it. The fixture requires the resulting `turn/interrupt` for
the exact active turn before reporting an interrupted completion. The test proves the checkout is
unchanged, the composer becomes ready again, and a second prompt completes in the same process.
This is the user promise behind cancellation: Stop neither becomes a silent local reset nor leaves
the retained conversation stranded.
