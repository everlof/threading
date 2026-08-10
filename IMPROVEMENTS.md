# Reliability & Type-Safety Roadmap

> **Status:** the original July 2026 roadmap is complete and retained below as architectural
> history. The follow-up review on 31 July 2026 found and closed the smaller regressions that
> accumulated during the next refactoring wave.

## Risk-directed hardening review — 9–10 August 2026

This pass inspected the last 150 commits and followed fix/follow-up-fix clusters into their full
data and lifecycle paths. The ledger is grouped by failure shape rather than diff: each invariant
is intended to prevent the next spelling of the bug, not only the measured reproduction.

- [x] **Child-process ownership and completion.** Evidence: launch failures could leave a child
      running before the ledger knew its identity; pipe callbacks and termination handlers could
      race or complete twice; several helpers retained descriptors past teardown. Root cause:
      `Process`, pipes, process groups, timeout and completion were independent conventions.
      `ChildProcessSpawn`, `AgentChildProcess` and provider/extension/remote adapters now make
      enrollment part of launch, close every unused descriptor, own one termination state, bound
      output and complete once. Files: `ChildProcessSpawn.swift`, `AgentChildProcess.swift`,
      `GitProcess.swift`, `ExtensionChildSpawner.swift`, `RemoteTunnel.swift`,
      `TailscaleRemoteTransport.swift`. Verified by `AgentChildProcessTests`,
      `StreamSessionLifecycleTests`, extension lifecycle tests and focused remote suites.
      Remaining risk: real OS/process-group behavior still merits the existing opt-in E2E runs.

- [x] **Typed outcomes and capabilities instead of boolean/optional agreement.** Evidence:
      Playwright failures could carry a screenshot, account usage could expose halves from
      different refreshes, transcript support and terminal bridge policy were duplicated by
      runtime name. Root cause: invalid combinations were representable and consumers rebuilt
      policy. Algebraic outcomes, `AccountUsageReading`, `TranscriptReplayFormat` and distinct
      native/terminal capabilities now make those decisions exhaustive. Files:
      `PlaywrightAutomation.swift`, `AccountUsageService.swift`, `AgentModels.swift`,
      `TranscriptReplay.swift`, `SessionMigration.swift`, `AgentLauncher.swift` and
      `ConversationViewController.swift`. Native construction is now failable at the capability
      boundary, unsupported launch planning is a typed error instead of a precondition crash, and
      every provider defers planning/spawn failure through one exactly-once exit path rather than
      allowing a reentrant callback during `start()`. Verified by provider matrix, Playwright,
      account usage and continuation tests plus 97 focused native-lifecycle tests. Remaining risk:
      new provider behavior must still be added to the closed capability matrix deliberately.

- [x] **Project mutations commit as one durable candidate.** Evidence: icon replacement,
      archive/import, session removal and auxiliary cleanup could mutate memory or a second store
      before SQLite accepted the graph, leaving two truths after a refused write. Root cause:
      `save()` was an epilogue rather than the state transition. `ProjectStore` now builds a
      candidate, commits it, then publishes memory and performs rollback-safe side effects;
      typed mutation results surface refusal. Files: `ProjectStore.swift`, `Project.swift`,
      sidebar/session coordinators and `ProjectStoreMutationTests.swift`. Verified by mutation,
      import-batch, archive, attachment and icon transaction suites. Remaining risk: cross-store
      cleanup remains compensating rather than a single database transaction where the bytes are
      intentionally file-backed.

- [x] **Recoverable preferences are bounded and commit before publication.** Evidence:
      change-request policy and publish receipts treated corrupt bytes as an empty collection, so
      the next ordinary edit erased the only evidence; the shared recoverable defaults abstraction
      had no allocation ceiling. Root cause: quarantine, decode work and mutation ordering were
      separate conventions. Every `RecoverableDefaultsStore` now declares a 1 MiB compact-metadata
      policy checked before JSON materialization and before replacement. Change-request stores and
      the usage-window schedule and workspace-navigator choice use the versioned/quarantined
      envelope, validate repository cardinality, receipt URL authority, schedule bounds, weekday
      membership and stored identity, persist a candidate, then publish memory and notifications.
      Files: `DefaultsQuarantine.swift`, `ChangeRequestConfiguration.swift`,
      `ChangeRequestReceiptStore.swift`, `UsageWindowSettings.swift`, `AppSettings.swift` and all
      recoverable-defaults construction sites. Verified by 54 recovery/change-request/usage-window/
      navigator tests including corrupt, oversized, invalid-schedule/identity and unsafe-URL
      fixtures. Remaining risk: `UserDefaults` itself returns the source blob as one `Data`; the
      ceiling bounds app decode/materialization, not cfprefsd's read.

- [x] **SQLite recovery never moves a live WAL and never downgrades a future schema.** Evidence:
      the pinned-reader reproduction emitted SQLite's “vnode renamed while in use”; a schema
      above the supported version was previously accepted by `migrate(to:)`. Root cause: file
      movement was decided outside SQLite and schema monotonicity was checked too late.
      `prepareForFileMove()` transitions WAL to DELETE or refuses without moving anything;
      `user_version` is checked immediately after open, before configuration or migration.
      Files: `SQLiteDatabase.swift`, `ProjectDatabase.swift`, `StateManager.swift`. Verified by
      all 58 `StateManagerTests`/`ProjectDatabaseTests`, including byte-for-byte future-schema
      preservation and a pinned WAL owner, with no vnode warning. Remaining risk: recovery waits
      for an external owner to close by design.

- [x] **Relaunch/reset is a prepare–commit protocol.** Evidence: arming a next-launch flag or
      moving Application Support before `/bin/sh` successfully started could turn a failed button
      press into a later surprise relaunch; open SQLite handles survived directory moves. Root
      cause: irreversible state mutation preceded proof that the successor existed. The helper
      now waits on a private commit pipe, intent is armed only for a live helper and disarmed if it
      dies, and state owners close before reset movement. Files: `AppRelaunch.swift`,
      `AppDataResetFlow.swift`, `AppDelegate.swift`, `StateManager.swift`. Verified by relaunch,
      reset and recovery-mode startup suites. Remaining risk: launch-service behavior is covered
      by process fixtures, not a destructive test against the real Application Support directory.

- [x] **One authoritative bounded file reader.** Evidence: dozens of provider-named, selected or
      externally replaceable files used metadata preflight followed by `Data(contentsOf:)`, so a
      growth race bypassed the advertised cap. Root cause: reported size was mistaken for an
      allocation boundary. `BoundedFileReader` accepts only regular files and reads one byte past
      the allowance; transcript, credential/config, icon, theme, diagnostic, import and cache
      callers use it. `RecoverableFileStore` now requires a typed 1/32/64 MiB policy at every
      construction and verifies writes through the same boundary. Files:
      `BoundedFileReader.swift`, `DefaultsQuarantine.swift` and the owning stores. Extension Metal
      source and environment-selected APNs signing keys now cross the same opened-file boundary,
      rather than trusting a size preflight or allocating an arbitrary credential file. Verified by
      sparse-file regressions plus 128 representative store/configuration tests. Remaining risk:
      trusted bundle and generated resources retain a few whole-file reads; they are not externally
      replaceable persistence boundaries.

- [x] **Untrusted images have one byte-and-pixel decode policy.** Evidence: extension panels and
      navigator nodes promised a 4 MiB/1,024-pixel contract but only identity rows checked decoded
      dimensions; composer, attachment, inspector, account-avatar and pane-cache paths still used
      lazy `NSImage(contentsOf:)` after a metadata check. Root cause: path resolution, compressed
      bytes, source pixels and rendered allocation were separate conventions. Typed decode policies
      now pair byte, dimension, area and rendered-size ceilings; full previews re-read one byte past
      the cap, extension resources reject animation and validate again for remote delivery, and
      thumbnail rails decode only bounded thumbnails instead of every full image. Browser-baseline
      UI also reopens through the store's hash/dimension claim. Files: `MediaInspector.swift`,
      `ExtensionManager.swift`, extension renderers, attachment/composer/pane/avatar/baseline paths.
      Verified by 92 media/composer/attachment tests plus sparse-growth and extension-dimension
      regressions. Remaining risk: Quick Look/PDFKit are OS-owned document decoders and remain
      behind the existing 64 MiB preview refusal rather than this raster policy.

- [x] **Browser baselines are validated as one immutable claim.** Evidence: reload silently
      dropped a damaged revision and selected another; empty optional artifacts persisted as
      present; image byte checks happened after decode or only at capture. Root cause: record,
      manifest and pixels were validated independently and charitably. The store validates ids,
      uniqueness, active revision, hashes, sizes and dimensions together, canonicalizes empty
      optionals, quarantines the whole damaged bundle, preserves future formats, and enforces
      metadata/image/pixel ceilings before decode and again on use. Files:
      `BrowserBaselineStore.swift`, browser diagnostics/comparison controllers and commands.
      Verified by 29 baseline tests including tampered pixels and sparse oversized artifacts.
      Remaining risk: the library's eager rich-row rendering remains a measured performance item.

- [x] **Conversation exports and handoffs cannot become unbounded bootstrap state.** Evidence:
      provider export stdout and durable snapshots were loaded whole; the one-million-character
      rule did not bound encoded bytes, and synthesized decoding could directly assign an invalid
      retained lineage around its failable initializer. Root cause: presentation limits were
      reused as allocation limits and construction-time validation was assumed to govern decode.
      Exports now cap result bytes and retained stderr; handoff envelopes cap encoded and reopened
      bytes; `ConversationHandoff.init(from:)` re-enters the compacting, cross-runtime path
      validator; and oversized legacy data may use the streaming replay compatibility path. Files:
      `Project.swift`, `SessionMigration.swift`, `SideChatTests.swift`. Verified by 36 capability
      tests plus export/handoff failure-path suites. Remaining risk: provider CLIs can still spend
      their separately bounded process timeout before producing a refusal.

- [x] **Journals and caches enforce their caps on both sides.** Evidence: execution-audit,
      usage-cache/history and remote-diagnostic readers loaded whole files even though their
      eventual records or suffixes were bounded; addition-based rotation could overflow.
      Root cause: retention/output bounds were mistaken for read-work bounds. Opened-stream caps,
      subtraction-based rotation, per-record ceilings, explicit broken/miss outcomes and shallow
      entry-budgeted enumeration now make oversized input visible without allocating it. Both the
      remote journal and mobile issue outbox count every visible support-directory entry before
      filtering; overflow refuses rather than hiding valid files behind malformed names. Files:
      `ExecutionAudit.swift`, `UsageScanCache.swift`, `UsageLimitHistoryJournal.swift`, RemoteKit
      diagnostics and mobile issue reporting. Execution-audit removal now addresses the closed
      per-session filename set directly and rotation policy has an absolute ceiling, so deleting
      one session does not enumerate every other ledger. Verified by audit/usage suites, all 79
      RemoteKit tests and a generic iOS Simulator build. Remaining risk: none known at these
      persistence boundaries.

- [x] **Extensions keep host authority and resource ceilings at the actual boundary.** Evidence:
      storage quota checks trusted a prior file size; a `.wasm` module could grow between package
      validation and `Data(contentsOf:)`; package/provenance writes could diverge on failure.
      Root cause: installation validation, open-file authority and durable state were separate.
      Extension KV/cache reads stream through quota, WebAssembly reads through the 256 MiB opened
      module ceiling, package images enforce their documented single-frame byte/pixel contract at
      actual decode/delivery, Metal source is streamed through its 256 KiB limit before compilation,
      installed-package discovery stops at 1,024 visible directory entries/256 packages before
      filtering or eagerly inspecting manifests, and install/provenance/settings stores use bounded
      recoverable persistence. Files:
      `ExtensionStorage.swift`, `ThreadingWasmRuntime.swift`, extension
      manager/renderers and package/settings stores. Verified by ExtensionKit contracts, 4 Wasm
      runtime tests and 62 package-store tests. Remaining risk: native companions remain
      OS-sandbox/E2E territory by design.

- [x] **Git, paths and hooks fail closed at ownership boundaries.** Evidence: symlinks and packed
      refs bypassed path/name assumptions; provider hook updates reconstructed JSON and could erase
      unknown future keys; several Git subprocesses treated truncation as complete output. Root
      cause: convenience parsing replaced preservation and repository authority. Git reads now
      resolve within the checkout, understand loose/packed refs, bound process/file output and
      preserve unknown hook configuration while changing only owned entries. Files:
      `GitReviewReader.swift`, `GitInfo.swift`, `GitWorktree.swift`, `CodexHookInstaller.swift`,
      `StoredPathComponent` call sites. Verified by recovered `GitRepositoryFileAccessTests`, hook,
      staging and project-icon Git fixtures. Remaining risk: filesystem replacement after a
      resolved-path check remains an OS-level race where no descriptor-relative API is used.

- [x] **Security-sensitive entropy and destructive actions fail closed.** Evidence: random-byte
      failures could fall back to predictable identifiers, synthesized decoding could bypass a
      pairing link's failable initializer, and destructive cleanup could proceed after an ambiguous
      lookup. Root cause: “best effort” and construction-time checks were used where absence and
      decode-time revalidation are safer. Token/pairing generation returns typed failure;
      `RemoteConnectionLink` decodes through its authoritative initializer and derives a
      non-optional share URL only there; cleanup works only from validated scan results; and
      removal/archive flows commit their durable graph before deleting auxiliaries. Files:
      identifiers/remote auth, `RemoteConnectionLink.swift`, `AppDataReset`, cleanup and sidebar
      action paths. Verified by 81 RemoteKit tests plus pairing, reset and lifecycle confirmation
      suites. Remaining risk: users can still delete data after the intentionally irreversible
      confirmation.

- [x] **UI ownership workarounds were replaced by structural contracts.** Evidence: repeated
      delayed resets, independently inferred menu destinations, and theme rollback that restored
      only the document allowed stale controls or assets. Root cause: views and backing resources
      committed at different times. Menu destinations are algebraic, display geometry addresses
      split items rather than private subviews, theme edits transact document plus assets, and
      design controls own teardown/observer lifetimes. Files: `ThemedMenu.swift`, display-pane,
      theme library/editing and design components. Verified by themed-control, menu, display,
      theme transaction and rendered suites. Final CI also exposed a window-backed geometry
      fixture retaining AppKit's legacy release-on-close ownership under ARC; the fixture now
      makes ownership explicit and the whole class passes without process restarts. Remaining
      risk: none known at this boundary.

- [x] **A test file cannot exist without executing.** Evidence: a focused
      `ExecutionAuditTests` run reported success with **0 tests**; comparing the directory to the
      PBX Sources phase found 13 unregistered suites added across several recent commits. Root
      cause: registration was documented but unenforced, and `add_test_file.py` treated partial
      registration as success. All 13 files are registered (110 recovered tests pass), partial
      registration is refused, and `check_test_registration.py` runs from every app build,
      `scripts/test.sh` and `scripts/ci.sh`. The writer now validates the entire argument set before
      mutation and accepts only existing `.swift` files; the checker audits every Sources entry,
      including a typo without a `.swift` suffix. Files: Xcode project and test scripts. Remaining
      risk: Xcode selectors can still spell a nonexistent method; registration guarantees the
      suite is compiled, while final full-plan runs guarantee broad execution.

- [x] **Mobile callbacks cross the main-actor boundary explicitly.** Evidence: the simulator build
      exposed future Swift-6 data-race warnings in terminal KVO/delegate callbacks, notification
      observers, device identity and notification-center delegates. Root cause: UIKit ownership was
      implicit in callback provenance rather than expressed in signatures and hops. Coordinators,
      identity and preference values are main-actor isolated; nonisolated delegates extract
      sendable values before hopping to the actor; observer/token teardown is isolated. Files:
      `TerminalViewRepresentable.swift`, `RemoteNotifications.swift`, `RemoteClient.swift`, mobile
      issue reporting and timeline controllers. Verified by a generic iOS Simulator build.
      Remaining risk: notification delivery and terminal KVO still merit native-device E2E coverage.

- [x] **Device-local drafts and keyboards commit bounded candidates.** Evidence: mobile session
      continuity mutated its published archive before encoding or verifying the write, so a refused
      save left the running UI on state a restart could not recover; draft-bearing records and
      custom keyboard actions also had no aggregate storage ceiling. Root cause: quarantine was
      treated as a complete persistence contract while mutation ordering and allocation remained
      independent. Both archives now enforce a 1 MiB encoded boundary plus structural cardinality,
      identity, draft/action and aggregate-string limits. Continuity updates prune and validate a
      copy, persist it, then publish it; keyboard layout identity is unique before it can become
      durable. Files: `MobileSessionContinuityStore.swift` and
      `MobileTerminalKeyboardStore.swift`. Verified by the generic iOS Simulator build and all 8
      ThreadingMobile tests, including published-and-durable rollback regressions. Remaining risk:
      the source `UserDefaults` blob is still delivered eagerly by cfprefsd before the app can apply
      its 1 MiB decode refusal.

### Final verification — 10 August 2026

- `scripts/ci.sh`: architecture, theme, localization and test-registration boundaries passed;
  strict SwiftLint reported no violations; all three local Swift package suites passed; the
  strict-concurrency `Threading-Fast` plan executed 4,510 tests with 28 intentional skips and zero
  failures.
- `scripts/test.sh all`: the complete on-screen/WebKit `Threading-All` plan executed 4,531 tests
  with 30 intentional skips and zero failures.
- The generic iOS Simulator build and all 8 `ThreadingMobile` tests passed after the mobile
  persistence/concurrency changes. Focused regressions were run at each checkpoint before these
  repository-wide gates.
- The first final CI attempt usefully caught two invalid test assumptions introduced by this pass:
  an ARC-owned fixture window still used AppKit's release-on-close convention, causing an
  autorelease-pool segfault, and a menu test expected a change notification from a typed
  `.targetMissing` mutation. Both tests now model the production ownership/commit contracts; the
  corrected tree is what the green gates above exercised.

### Evidence-backed follow-ups

1. Virtualize the browser baseline library's image-backed rows; the measured 200-record mount and
   theme refresh remain the highest known UI scaling cost.
2. Apply the same lazy construction boundary to extension panels/preferences, whose transport caps
   still exceed a sensible eager AppKit budget.
3. Add descriptor-relative reads for the few security-relevant repository paths where a symlink can
   still be replaced after canonicalization.

## Provider-matrix review — 4 August 2026

Prompted by a fourth and fifth runtime (Grok, OpenCode) landing beside Claude and Codex. The
theme throughout: a provider difference that lived in more than one place, or that was expressed
as *which runtime is this* rather than *what can this runtime do*, could not be reviewed and
could not be extended without re-reading the whole app.

- [x] Fifteen `kind == .claude`-shaped comparisons replaced by named `AgentCapabilities`
      members. `AgentKind.capabilities` is now the only place a runtime is named to decide what
      the host may do with it, enforced by `scripts/check_architecture_boundaries.sh`.
- [x] That lint, and the theme and localization lints it sits beside, now run from the
      **Enforce Repository Boundaries** Xcode build phase. Previously only `ci.sh` ran them, and
      the push gate runs tests only — so with no git remote configured they gated nothing.
- [x] Checks were *deleted* rather than renamed wherever something better already decided: the
      effort chip is gated by the model catalog's `reasoningLevels`, and mid-conversation
      reconfiguration by `FastModeConversation` conformance. A runtime that gains either now
      gets the control with no code change.
- [x] `ConversationStreamSession.acceptsConfigurationChange` moved "when does a configuration
      change land" from a `switch kind` in the view onto the transport, where the answer is a
      property of the wire protocol carrying it.
- [x] Session construction moved into `AgentSessionConfiguration.init?`, which states the
      clamp-vs-refuse rule once: a setting the runtime *ignores* is clamped, a setting it
      *cannot honour* is refused. This closed a live bug — the composer offered Grok's
      conversation surface, the capability allowed it, a transport existed, and the store
      refused the record, so choosing it created nothing and reported nothing.
- [x] `SessionTranscript` replaced two identical per-runtime transcript-location dispatches;
      `AgentPermissionMode.launchFlags(for:)` replaced a launcher switch that had to agree with
      four value properties in another file.
- [x] `ComposerCapability.Availability` replaced `isEnabled: Bool` beside
      `unavailableReason: String?`, which admitted a refusal with no explanation and an
      available action carrying one. `isEnabled`/`unavailableReason` survive as computed
      properties, so only construction changed.
- [x] `AgentAccountDiscovery.account(for:handle:)` stopped warning for runtimes without account
      routing — the sidebar looks an account up on every row reconfigure, so a Grok session
      filled the log with the absence of a feature.
- [x] `AgentCapabilitiesTests` holds each capability to the code it governs, because both
      directions fail silently: a granted `.forking` with no `forkedConfiguration` puts Fork in
      the menu and creates nothing; a granted `.nativeUI` the store refuses is the bug above.

### Open, from the same review

Found and verified against the tree, not yet done. Ordered by value against the number of call
sites each would touch.

- [x] **`ThemedMenuItem` now has one algebraic destination:** inert, action, or submenu. Separate
      initializers preserve the call-site vocabulary while making the action-plus-submenu state
      unconstructable; consumers no longer rely on every caller honouring a comment.
- [x] **Local conversation replay has one capability and one closed adapter set.**
      `.transcriptReplay` distinguishes Claude/Codex's measured local JSONL formats from
      OpenCode's usage-only export and Grok's ACP history. `TranscriptReplayFormat` centralizes
      the format dispatch consumed by replay, subagent loading/usage, title backfill and both
      import scans; those consumers no longer keep nine runtime allow-lists. A matrix test holds
      the capability and adapters in exact agreement and requires every narrower structured
      transcript-record capability to imply the base fact.
- [x] **Attachment-reference detection settings are generated from `AgentKind.allCases`.** The
      four runtime rows, controls, persisted per-kind setting, scanner consumers, and empty-state
      guidance now share one closed set; a future runtime cannot gain detection without also
      gaining the switch the guidance sends the user to.
- [x] **Native and terminal Threading bridges are separate capabilities.**
      `.terminalThreadingBridge` is granted only to Claude and Codex and is now the terminal
      delivery/managed-workspace gate; Grok keeps `.threadingBridge` for its native ACP surface
      without receiving a half-configured terminal endpoint.
- [x] **`ConversationContinuation.destinations` now describes every acceptable runtime
      configuration.** Account-routable runtimes contribute their discovered accounts; runtimes
      without account routing contribute one explicit standard configuration instead of
      disappearing from the menu by coincidence.
- [x] **`PlaywrightAutomationOutput`** is now a two-case result. Success carries result text and
      an optional screenshot; failure carries only its diagnostic, so callers must distinguish
      the outcomes and a failed run cannot accidentally transport a screenshot.
- [x] **`HookLifecycleReport.agentSessionID` is a `TranscriptID?` at the decoding boundary.**
      Empty external strings are dropped once and consumers no longer re-wrap or revalidate the
      provider identifier.
- [x] **`SubagentSummaryItem.TranscriptAvailability`** is one three-case state: unavailable,
      openable in memory/while running, or on disk with its URL. A revealable transcript is now
      structurally openable, and the navigator and Finder action consume the same answer.
- [x] **`AccountUsageReading` names the cache state machine.** Not-fetched, current, stale with
      the last good value, and first-fetch failure are distinct cases; UI and remote catalog
      consumers take one snapshot instead of reconstructing a state from two optional reads.
- [x] **`GitDiffParser.status(fromPorcelainV2:)` is live, not dead.** `GitReviewReader` consumes
      it for both repository and staged status, and `GitStatusParserTests` covers its porcelain-v2
      parsing; the audit item had gone stale after those consumers landed.

## Follow-up review — 31 July 2026

- [x] Sidebar collapse state is published synchronously; animation completion is reserved for
      geometry work, so tests and command state no longer race AppKit animation timing.
- [x] Conversation previews opt out of autoresizing-mask constraints, and the closed drawer
      removes its required child-height conflict instead of logging runtime layout warnings.
- [x] Remote authentication publishes one locked `RemoteAuthenticatedPeer` snapshot rather
      than five independently mutable identity fields.
- [x] Global conversation discovery reports bounded per-path failures and marks partial scans
      incomplete; an unreadable account can no longer masquerade as an empty/fresh account.
- [x] GitHub request and response envelopes are typed `Codable` values, with explicit body,
      label-count and label-length budgets and strict success validation.
- [x] Workspace navigator row/grid render failures immediately fail back to Native, and the
      generation-aware container is separated from document rendering/virtualization.
- [x] Terminal history uses `TerminalInstanceIdentity`, keeping agent sessions, drawer shells,
      standalone project terminals and ephemeral terminals in distinct identity domains.
- [x] Popover lifecycle/arrow coverage and narrow session-sharing interaction/theme coverage
      protect the presentation code that had previously been exercised only incidentally.
- [x] Every concrete design component again has a live Component Gallery story; menu rows,
      workspace failback and toast presenters now have explicit frame/lifetime teardown rules.
- [x] Built-in MCP identity and capability policy are separated from the wire argument/schema
      catalog; exhaustive switches and completeness gates remain the contract.
- [x] Stale dependency/release documentation and tracked probe/cache artifacts were corrected.

Current size is recorded for orientation, not as a trend against the historical baseline: the
application has grown several major subsystems since that snapshot.

| Metric (31 July 2026) | Count |
|---|---:|
| Test methods | 2,543 |
| `@MainActor` annotations (sources + tests) | 994 |
| `[String: Any]` occurrences in sources | 282 |
| `JSONSerialization` references in sources | 71 |
| `try?` occurrences in sources | 471 |
| Conditional casts (`as?`) in sources | 705 |
| `static let shared` occurrences in sources | 53 |
| Swift files / lines in sources | 492 / 174,839 |

A prioritized working checklist from the July 2026 architectural review. Check items off as
they land; strike evidence references that a fix makes obsolete. Line numbers are as of the
review and will drift — the file and symbol names are the durable pointers.

**How to read this:** Tier 1 is damage prevention and real bugs — each item is a focused,
single-sitting change. Tier 2 moves invariants from comments into the compiler. Tier 3 is
structural and can ride along with feature work. Within a tier, order matters; across tiers,
finish 1 before starting 2.

What the review found *sound*, so nobody "fixes" it: the ProjectStore/AgentRuntime
model-runtime split; the single `quoted()` shell-quoting discipline in `AgentLauncher`;
JSONL bounded-scan/unbounded-record reading; MCP request size caps and fail-closed
permissions; atomic state writes; `AISettings`' per-key `decodeIfPresent` decoding (the
pattern the rest of the model should adopt).

---

## Tier 1 — Data safety and live bugs

### 1.1 Persistence: stop overwriting good data after a failed load
- [x] `StateManager.loadProjectsState` distinguishes **missing** (start fresh) from
      **corrupt/undecodable** (quarantine): rename to `projects.json.corrupt-<ISO date>`,
      log, and mark the store *load-failed*.
- [x] `ProjectStore` refuses to `save()` while load-failed until the user has made a
      structural change from an explicitly-acknowledged empty state (or simpler: first save
      after quarantine writes to a fresh file, never over a `.corrupt-*`).
- [x] Write a rolling `projects.json.bak` before each overwrite (cheap: rename-then-write).
- [x] Actually read `ProjectsState.version` on load: newer than
      `ProjectsStateVersion.current` → treat as corrupt-shaped (quarantine, don't touch);
      older → run a migration chain (empty today, but the seam exists).
- [x] Guard `HistoryManager.cleanupOrphanedHistoryFiles` on a *successful* store load — an
      empty-because-failed project list currently deletes **every** history file
      (`AppDelegate.cleanupOrphanedHistoryFiles` → `HistoryManager`).
- [x] Fixture tests: v1 file round-trip; corrupt file → quarantined, not overwritten.
- [x] Missing-key fixture (schema drift) decodes with explicit model defaults.

~~Evidence: `StateManager.swift:46-58` (nil on decode error), `ProjectStore.swift:319-334`
(eager save on ~every mutation; `load()` leaves `projects = []`), `Project.swift:262-276`
(`version`/`savedAt` written, never read — grep-confirmed no consumer).~~

Same decode-fails → reset → next-save-overwrites shape, lower stakes, fix with the same
pattern: `AccountPreferencesStore.swift:92-103`, `ProfileStorage` (`TerminalProfile.swift:80-93`),
`TokenUsageManager` (`TokenUsage.swift:48-61`), `AISettingsStorage` (encode side only).

- [x] The *other* stores had the same hole, and worse odds. `ShortcutOverrideStore` and
      `AccountPreferencesStore` keep their state as one encoded blob in `UserDefaults`, and a
      decode failure fell through to **defaults** — where for a settings store the next save is
      any ordinary edit, so a schema change erased every keyboard binding or account name the
      first time the user touched one. Both now tell *missing* from *unreadable*, keep the
      unreadable bytes under `<key>.unreadable` (`DefaultsQuarantine`) and permit writes only if
      that succeeded, which is `ProjectStore`'s own rule. `AccountPreferencesStore.save` also
      swallowed encode failures with `try?`, so an edit that never landed looked exactly like
      one that did.

### 1.2 MCP: fix the session-registry data race
- [x] `MCPSessionRegistry`'s `static var` dictionaries are written on main (token minting at
      launch; `retainOnly` on session deletion) and read on the `codes.threading.mcp` queue
      (`MCPServer.route`/`routePermission`) with no synchronization — UB on a Swift
      `Dictionary`. Either resolve token→session **after** the existing hop to main (keeps
      the app's single-threaded model), or guard the registry with `OSAllocatedUnfairLock`
      (macOS 13+).
- [x] `MCPServer.connectionsByID` is mutated on the MCP queue but iterated by `stop()` from
      the main thread at quit — dispatch `stop()`'s teardown onto the MCP queue.

~~Evidence: `MCPSessionRegistry.swift:17-35`, `MCPServer.swift:96-99,120,147,190`.~~

### 1.3 Permission card leak
- [x] `PermissionRequestView` retains `onDecision`; the closure captures the local `card`
      strongly → every request leaks the view *and* the pending decision continuation into
      the MCP layer. Capture the card weakly, or make `onDecision` a `var` cleared after it
      fires.

~~Evidence: `ConversationRendering.swift:176-193`, `PermissionRequestView.swift:15,178`.~~

### 1.4 Stream-session lifecycle bugs
- [x] `CodexStreamSession`: write-failure path calls `process.terminate()` without setting
      `isTerminating`, so `handleTermination` emits a **second** `.turnFinished`
      ~~(`CodexStreamSession.swift:87-99,163-171`)~~. Set the flag before terminating.
- [x] `ClaudeStreamSession`: stderr goes to a `Pipe` nobody reads — crash diagnostics are
      discarded ~~(`ClaudeStreamSession.swift:63`)~~. Capture capped, the way Codex already
      does (64 KB cap, ~~`CodexStreamSession.swift:141-145`~~).
- [x] Both sessions mutate `buffer`/`process` from the pipe's readability queue while
      `handleTermination` nils them on main. Confine all mutable state to one queue (the
      simplest: marshal raw `Data` to main and do buffering/parsing there — output volume
      is line-oriented JSON, not a PTY firehose).
- [x] `ClaudeStreamSession` spawn failure fires `onExit` synchronously; every other exit
      arrives async on main ~~(`:79-83`)~~. Make it async for a consistent caller contract.

### 1.5 Hot-path filesystem scans
- [x] `AgentAccountDiscovery` re-enumerates `~` **and re-reads six shell config files** per
      call — and it is called per sidebar row configure, per launch, per conversation turn,
      and per resume-eligibility check. Add a small TTL cache (5–10 s) or FSEvents
      invalidation; keep the API identical.
- [x] `CodexTranscript.url` walks the whole `sessions/` tree per call — memoize per
      (account, transcript id).
- [x] `GitInfo` reads are uncached on paths hit per sidebar reload
      (`SidebarTreeBuilder.rootNodes` calls `repositoryIdentity` per project) — a
      per-checkout memo invalidated at the existing stopped-working refresh point suffices.

Evidence: `AgentAccountDiscovery.swift:149-152`, `ShellAliasReader.swift:16-29`,
call sites `SessionRowView.swift:264`, `AgentLauncher.swift:220`,
`ConversationViewController.swift:76-79`, `CodexTranscript.swift:6-30`.

---

## Tier 2 — Invariants into the compiler

### 2.1 `@MainActor` on the stores, then strict concurrency
- [x] Annotate the main-thread-by-convention singletons: `ProjectStore`, `AgentRuntime`,
      `PermissionBroker`, `AccountUsageService`, `SessionActivityTracker`,
      `AccountPreferencesStore`, `ProfileStorage`, `AppSettings`, `MCPSessionRegistry`
      (after 1.2 decides its isolation). `MCPSessionRegistry` remains explicitly lock-isolated
      because token resolution runs on the MCP socket queue; its main-only cleanup is annotated.
      AppKit callers are SDK-annotated `@MainActor`
      already, so most call sites compile unchanged; the ones that don't are exactly the
      bugs this catches.
- [x] Enable strict concurrency `complete` for every app and test configuration in the Xcode
      project (there is no root `Package.swift`). Queue-owned callbacks are `@Sendable`, UI and
      state owners are actor-isolated, immutable wire/domain values are `Sendable`, and the
      remaining teardown-only cross-actor handles document their synchronization explicitly.
- Main-thread store isolation and queue crossings are now compiler-checked in the same mode CI
  and the release preflight use.

### 2.2 Typed identifiers
- [x] `SessionID` / `ProjectID` wrappers over `UUID` (single-value-container `Codable`, so
      persisted JSON is unchanged). Project and session APIs now reject the other identity
      space at compile time.
- [x] `TranscriptID` wrapper over the CLI resume id (`agentSessionID`) — transcript lookup,
      CLI resume, and MCP routing now use distinct compiler-checked identity spaces.
- [x] `AccountHandle` enum (`.standard` / `.named(String)`) replaces the nil-means-default
      `String?`, and one composite `AccountID` type owns the provider/handle key used by
      preferences, usage state, avatar caches, and visible-session account tracking.

### 2.3 One meaning per nil in the model
- [x] Hand-written `init(from:)` for `AgentSession`/`Project` uses
      `decodeIfPresent … ?? default` and explicit legacy-key encoding. The stored-`Bool?`
      and account property-wrapper workarounds are retired; missing-key and non-default
      round-trip fixtures lock in both sides of the contract.
- [x] `ResumeState` now distinguishes shells (`.unavailable`), agent conversations awaiting
      an identifier, and resumable conversations carrying a `TranscriptID`. Launch planning,
      discovery, imports, forks, replay, and migration consume the explicit state while legacy
      JSON keeps the `agentSessionID` key. `branch` remains `String?`, with nil documented as
      the single "no branch was available" state, including for older decoded records.

### 2.4 Codable at the wire boundaries
- [x] MCP JSON-RPC now has Codable request/response envelopes and a `RequestID` enum that
      preserves integer, string, explicit-null, and missing-notification semantics. Each tool
      name selects a concrete argument struct (including the integer/string tab union), while
      initialize, tool-list, tool-result, error, and schema payloads are `Encodable`; the old
      `[String: Any]` dispatch and hand-built JSON-RPC response dictionaries are gone.
- [x] Claude and Codex live-stream JSONL now decodes through tolerant Codable wire models,
      retaining tool-owned arbitrary data as `JSONValue`. Unknown provider kinds become
      `.unknown`; malformed UTF-8, JSON, or required envelope fields are skipped, counted per
      session, and logged. Focused tests cover optional-field drift, structured arguments and
      results, unknown kinds, and recovery after malformed lines. Foundation dictionary adapters
      remain only at the separate transcript-replay boundary.
- [x] Tool calls now cross the provider-neutral stream boundary as a `ToolIdentity`, with raw
      names retained by `unknown(String)` and MCP identities. Permission summaries, per-session
      approvals, `PermissionPolicy`, and tool-row glyphs consume the identity; the policy and
      glyph mappings switch exhaustively, so new known cases require an explicit decision while
      unknown tools continue to prompt and render by their original name. Focused parser,
      replay, timeline, policy, and glyph tests pass.

### 2.5 Typed notifications
- [x] All nine live app notifications are concrete `AppEvent` values sent and observed through
      generic `NotificationCenter.post`/`observe` helpers; block-observer tokens are owned by an
      `AppEventObservations` lifetime bag. Session-end now carries its `SessionID`, profile and
      usage changes carry `TerminalProfile` and `AccountID`, and signal-only events use empty
      structs instead of arbitrary sender objects. The two unused terminal notification names
      were removed. Focused payload/lifetime tests and the full suite pass.

### 2.6 `ShellCommand` builder
- [x] `ShellCommand` now quotes every executable, word, flag, value, environment assignment,
      prompt, model, identifier, title, and path as it enters the command. Composition accepts
      other builders and a closed operator enum (`&&`) rather than raw source fragments, and all
      terminal, native-stream, research, account-routing, MCP, resume/fork, and shell-profile
      launch paths use it. Hostile title/model/prompt/path fixtures and shell-executed fuzz cases
      (quotes, substitutions, operators, whitespace, newlines, empty values, and Unicode) round
      trip as single arguments. Focused tests and the full suite pass.

---

## Tier 3 — Structure and tests

### 3.1 Decompose the window-controller hub
- [x] `MainWindowController` conforms to five delegate protocols plus `MCPToolHandling`
      plus permission presentation (~800 lines + `MainWindowMCPTools.swift` 306 lines).
      Extract: `AgentToolCoordinator` (browser/display tool handling) and
      `SessionCoordinator` (create / close / import / worktree resolution). Chrome and
      layout stay. `AgentToolCoordinator` now owns MCP browser/display/storage/theme handling
      behind narrow window capabilities, while `SessionCoordinator` owns composer delegation,
      one-shot prompts, side chats, surface switches, and session lifecycle decisions. The main
      window retains navigation, toolbar, layout, and terminal-container presentation. Focused
      coordinator/MCP/UI tests pass (24 tests), and the strict-concurrency app build is clean.
- [x] "Which session is visible" is tracked in three places (`TerminalContainerViewController.currentSessionID`,
      `AgentRuntime.setVisibleSession`, toolbar's account key) — make the container
      authoritative, derive the rest. `currentSessionID` now drives runtime attention and a
      single chrome delegate event; the toolbar resolves its account from that session and its
      currently configured account instead of retaining another visibility key.
- [x] Settings pages carry an identity (`SettingsPages.page(id:)` / `id(ofTitle:)`); nothing
      indexes into `SettingsPages.all` any more, and the sidebar and container both route by id.

### 3.2 Retire the IUO init-order contracts
- [x] ~46 implicitly-unwrapped declarations whose safety hangs on `setupSplitViewController()`
      running first. Convert to `let` built in init, or a single lazy view-tree builder per
      controller. **The `AppDelegate` half is done**: the named `applicationShouldHandleReopen`
      crash is guarded, and all twenty window-scoped *menu actions* now route through
      `mainWindowController?` — two processes run this delegate and never build a window (a
      hosted test bundle, and a second instance that lost the single-instance lock), so a
      command arriving in either has nothing to act on and doing nothing is the answer.
      `AppDelegateTests` performs every one of them by selector on a window-less delegate. The
      launch path deliberately keeps its force-unwraps: there, a silent no-op would hide a real
      failure. All stored IUOs under `Sources/Threading` are now gone; required view trees are
      lazy non-optionals and genuinely optional state stays optional. The architecture boundary
      script rejects reintroduction.

### 3.3 Tests where the code is already pure
The architecture has already extracted this logic, so it is covered without a UI harness:
- [x] Persistence: round-trip, corrupt-file quarantine, old-schema fixtures (locks in 1.1).
- [x] `AgentLauncher` hostile-string tests (`AgentLaunchQuotingTests`), locking in 2.6 two ways:
      the quoter's output is tokenized by **`/bin/sh` itself** and must give back the same words
      (with a second test proving no `$(…)` ran while doing so — the round-trip alone would
      report the *result* of an expansion quite happily), and a whole plan built from hostile
      project, session, model and prompt strings must leave nothing but `&&` when its quoted
      spans are removed. The residue parser has its own test, having been wrong once: it read
      the quoter's `'\''` escape as syntax.
- [x] Stream-event golden files from real Claude/Codex transcripts (locks in 2.4): four scrubbed
      real-session fixtures cover Claude thinking/tools/edits and Codex reasoning/exec/patch
      timelines, with replay and row-shape assertions.
- [x] `SessionImporter.belongs` worktree fixtures (`SessionImportBelongingTests`), built with
      **git itself**: a main checkout, a linked worktree nested inside it, and one beside it. A
      fixture assembled by hand from what the layout is believed to be would prove the belief;
      the rule turns on where git puts a linked worktree's git directory and what it writes into
      the `.git` file pointing there. Covers the case it exists for — `<repo>/.claude-worktrees/x`
      is a *different* checkout, not a subdirectory — plus prefix-only lookalikes
      (`/tmp/repo-notes` vs `/tmp/repo`) and a project outside git entirely.
- [x] `SidebarTreeBuilder` grouping rules (`SidebarTreeBuilderTests`): a level appears only
      where it earns one, a group keeps its first session's place, an orphaned side chat stays
      visible, and a **cycle in the stored lineage** surfaces both rows rather than nesting —
      the outline view asks for children lazily, so that one is a hang rather than a wrong row.
      Writing them found a live bug: the `nonisolated static` readers on `AppSettings` went
      straight to `UserDefaults.standard`, while the seeded defaults were registered only in
      `init`, so a read before anything touched the singleton got `false` — the *opposite* of
      the documented default for every seeded setting. Registration is now idempotent and done
      by the readers themselves. (Usage-window normalizers were already covered by
      `AccountUsageSummaryTests`; fraction clamping is at all four fetcher boundaries.)
- [x] `EditDiff` LCS (`EditDiffTests`): one changed line leaves the rest as *context* — the
      alignment's whole purpose, and the same view the permission sheet is approved on — plus
      insertion, deletion, identical text, repeated lines (where an LCS walk classically drifts
      and reads a one-line insert as a rewrite), and the past-the-cap fallback. Also the
      argument reading, including that a `patch` is preferred over the tool *name*: Codex's
      `apply_patch` arrives here renamed to `Edit`, so a name-first rule would hunt for an
      `old_string` that call never carried and show no diff at all.
- [x] `Markdown` reader table (`MarkdownTests`), which is mostly about *precedence*: fenced
      code reads first and verbatim (a `*` in a shell glob is not emphasis, a `#` in a script is
      not a heading), quote reads before list so `> - item` is a quote, blank lines are not
      blocks, soft-wrapped lines flow into one paragraph, and an unterminated fence — which
      agents produce constantly by being cut off — ends at the document instead of looping.
- [x] Pin a narrowly-scoped `.swiftlint.yml` and add CI. `scripts/ci.sh` runs the architecture,
      localization and theme boundaries, strict SwiftLint, all three local Swift package suites,
      and the app's off-screen Xcode test plan under complete concurrency checking. Releases run
      the same gate before archiving, and CI invokes that one script rather than maintaining a
      second list.

- [x] `PermissionBroker`'s defaults are pinned (`PermissionBrokerTests`). The decision that
      lets an agent's tool call run unasked had no test on any of its *unsure* answers: an
      unrecognised tool prompts, a shell call whose command cannot be read prompts, a request
      with no window to ask in is denied, only this app's own MCP tools are pre-approved (and
      not a server whose name merely starts the same way), and a standing "always allow" belongs
      to one session and is forgotten when it is discarded.

### 3.4 Smaller structural notes (fold into passing work)
- [x] `ProjectStore.load()` fires `selectedSessionID.didSet` → redundant disk write during
      init; `removeSession` double-saves (`ProjectStore.swift:21-31,156-164`).
- [x] `TerminalSession.startShell` now builds the configured shell and every argument as
      `ShellCommand` words, then shares `ShellCommand.executing(_:in:)` with `AgentLauncher`
      for the fixed `cd … && exec …` wrapper. A real-shell regression test enters a directory
      containing quotes, semicolons, and command-substitution syntax without interpreting it.
- [x] Exact child identity. The local SwiftTerm fork now launches through `forkpty`, which gives
      `TerminalSession` the child PID synchronously and gives the child its controlling terminal.
      The old before/after `ProcessUtility` scan, retry window, arbitrary PID ordering and
      cross-session claim registry are gone; concurrent sessions cannot adopt one another's
      child or one of Threading's short-lived helper processes.
- [x] `ProcessUtility` silent truncation: `liveProcessIdentifiers()` sizes the buffer from the
      kernel's own count and grows when the reply comes back full, so a short list means "that is
      all of them" rather than "the buffer ran out"; three copies of the fixed-4096 walk share it.
- [x] `ProcessUtility` main-thread scans. The info panel's walk was already on
      `SessionInfoReader`'s queue, and `TerminalSession` no longer scans the process table at
      launch now that SwiftTerm exposes the exact `forkpty` child.
- [x] MCP HTTP parser. `parseRequest` answered `nil` for both "incomplete" and "impossible", so
      framing it could not read was *defaulted* to a zero-length body — which leaves the real
      body at the head of the buffer to be read as the next request's start line. It now returns
      a three-case `ParseOutcome`; an unreadable, negative, oversized or absent `Content-Length`
      on a body-bearing method, an unparseable head, and `Transfer-Encoding` (unimplemented) each
      answer 400/411/413/501 and close. The negative case additionally *trapped* on the body
      slice. Both callers — the loopback listener and the extension host channel — share it.
- [x] `HistoryManager` logs through `ThreadingLogger.session` rather than `print`.
- [x] `propose_storage_cleanup`'s "only paths the scanner already found" gate is now
      `StorageCleanupGate`, a pure function with tests — it was inline in a handler needing a
      window, a store and a modal sheet, so the security boundary of the storage feature was the
      one part of it nothing exercised. Its lookup used `Dictionary(uniqueKeysWithValues:)`,
      which **traps** on a duplicate key: two projects listing one artifact (the same folder
      added twice, or a nested checkout) took the app down from a tool call.
- [x] `TerminalTheme.decodeColor` fell back to **white**, which is the one answer that makes a
      dark terminal unusable and is indistinguishable from a theme that is genuinely white. It
      now falls back to the stock palette's colour *for the same role* and logs the loss.
- [x] The `NSImage(systemSymbolName:)!` force-unwraps are gone: both files build their chrome
      through `ThemedButton(symbol:accessibility:target:action:)`, which takes the optional.

---

## Historical baseline metrics (start of July 2026)

Track these downward as tiers land:

| Metric | Count |
|---|---|
| Unit tests | 3 |
| `@MainActor` annotations | 4 |
| `[String: Any]` occurrences | 92 |
| `JSONSerialization` uses | 27 |
| `try?` (silent-failure sites) | 61 |
| Implicitly-unwrapped declarations | ~46 |
| Conditional casts (`as?`) | 211 |
| `static let shared` singletons | 12 |
| Swift files / lines | 112 / ~22,300 |
