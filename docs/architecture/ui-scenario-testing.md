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
`Threading-UI.xctestplan`. Its folder is an Xcode synchronized group, so a new source under
`Tests/ThreadingUITests` is compiled automatically; this is intentionally different from the
manually registered `Tests/ThreadingTests` target.

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
Captures are scoped to the Threading window rather than the full display, so a successful result
does not retain pixels from unrelated applications. To keep and export them from a known path:

```bash
scripts/test.sh ui -resultBundlePath /tmp/ThreadingUI.xcresult
xcrun xcresulttool export attachments \
  --path /tmp/ThreadingUI.xcresult \
  --output-path /tmp/ThreadingUIAttachments
```

Both paths must be new for each run. Xcode 26 also attaches a full-display MP4 to a failed UI test,
with `deleteOnSuccess` lifetime. That is useful failure triage, but it is neither durable evidence
for a passing journey nor scoped to Threading; it can include unrelated private content. A video
of a successful journey is possible with macOS `screencapture -v`, but it has the same full-display
privacy boundary and requires Screen Recording permission for the invoking shell. Persistent video
therefore remains an explicit local diagnostic while window-only screenshots are the automatic
passing artifact.

`scripts/ui-test.sh` builds the fixture-agent executable and asks Xcode to seal it into the Debug
app's `Contents/Helpers` directory before code signing. The application will accept only that
exact bundled executable and mutable fixture files below the isolated scenario home. This is a
load-bearing split: macOS refuses to execute code copied into the XCUITest runner's temporary
container, and allowing an arbitrary executable path would let a malformed test launch a real
provider. Non-UI and Release builds remove any helper left in a reused products directory.

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
4. show the completed turn and Git Review result;
5. quit, relaunch into the same isolated home, and prove transcript recovery.

The test crosses the shipping child-process boundary, JSON-RPC parser, conversation renderer,
checkout watcher, Git Review surface, provider transcript importer, and durable project store.
Permission, provider failure, rate-limit, and remote/mobile promises remain future
journeys rather than variants of this one.

### Stop and continue

`CodexStopTurnJourneyUITests` sends a real `turn/start`, waits until the composer exposes its
accessible Stop action, and presses it. The fixture requires the resulting `turn/interrupt` for
the exact active turn before reporting an interrupted completion. The test proves the checkout is
unchanged, the composer becomes ready again, and a second prompt completes in the same process.
This is the user promise behind cancellation: Stop neither becomes a silent local reset nor leaves
the retained conversation stranded.
