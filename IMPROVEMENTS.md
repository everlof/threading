# Reliability & Type-Safety Roadmap

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
      launch; `retainOnly` on session deletion) and read on the `com.skalman.mcp` queue
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
- [x] Enable strict concurrency `targeted` for the app and test targets in the Xcode project
      (there is no root `Package.swift`); move to `complete` later.
- Main-thread store isolation is now compiler-enforced; targeted checking is the baseline
  while the remaining boundaries are prepared for `complete` checking.

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
- [ ] ~46 implicitly-unwrapped declarations whose safety hangs on `setupSplitViewController()`
      running first. Convert to `let` built in init, or a single lazy view-tree builder per
      controller. **The `AppDelegate` half is done**: the named `applicationShouldHandleReopen`
      crash is guarded, and all twenty window-scoped *menu actions* now route through
      `mainWindowController?` — two processes run this delegate and never build a window (a
      hosted test bundle, and a second instance that lost the single-instance lock), so a
      command arriving in either has nothing to act on and doing nothing is the answer.
      `AppDelegateTests` performs every one of them by selector on a window-less delegate. The
      launch path deliberately keeps its force-unwraps: there, a silent no-op would hide a real
      failure.

### 3.3 Tests where the code is already pure
Currently: 3 tests (TranscriptReplay). The architecture has already extracted its logic —
these need no UI harness:
- [x] Persistence: round-trip, corrupt-file quarantine, old-schema fixtures (locks in 1.1).
- [x] `AgentLauncher` hostile-string tests (`AgentLaunchQuotingTests`), locking in 2.6 two ways:
      the quoter's output is tokenized by **`/bin/sh` itself** and must give back the same words
      (with a second test proving no `$(…)` ran while doing so — the round-trip alone would
      report the *result* of an expansion quite happily), and a whole plan built from hostile
      project, session, model and prompt strings must leave nothing but `&&` when its quoted
      spans are removed. The residue parser has its own test, having been wrong once: it read
      the quoter's `'\''` escape as syntax.
- [ ] Stream-event golden files from real Claude/Codex transcripts (locks in 2.4).
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
- [ ] Pin a `.swiftlint.yml` (unconfigured runs are noisy and crash mid-lint) and add CI:
      `swift build && swift test && swiftlint`.

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
- [x] PID capture. The "any child" fallback is gone (Skalman spawns short-lived helpers of its
      own, so it adopted strangers), pids another live session has claimed are excluded, the
      lowest new pid wins so a two-child launch resolves the same way twice, the capture retries,
      and a claim is released on teardown so pid reuse cannot lock a later session out.
- [x] `ProcessUtility` silent truncation: `liveProcessIdentifiers()` sizes the buffer from the
      kernel's own count and grows when the reply comes back full, so a short list means "that is
      all of them" rather than "the buffer ran out"; three copies of the fixed-4096 walk share it.
- [ ] `ProcessUtility` main-thread scans — **narrower than it reads**. The info panel's walk is
      already on `SessionInfoReader`'s own queue. What remains is `TerminalSession`: the two
      snapshots around a launch (`:116`, `:205`) are synchronous *by requirement* — taken before
      the child is spawned, or the child is mistaken for a pre-existing process and never adopted
      — so only `captureShellPid`'s retry walk (`:174`) can move off the main thread, and it is
      already delayed rather than blocking a launch.
- [x] MCP HTTP parser. `parseRequest` answered `nil` for both "incomplete" and "impossible", so
      framing it could not read was *defaulted* to a zero-length body — which leaves the real
      body at the head of the buffer to be read as the next request's start line. It now returns
      a three-case `ParseOutcome`; an unreadable, negative, oversized or absent `Content-Length`
      on a body-bearing method, an unparseable head, and `Transfer-Encoding` (unimplemented) each
      answer 400/411/413/501 and close. The negative case additionally *trapped* on the body
      slice. Both callers — the loopback listener and the extension host channel — share it.
- [x] `HistoryManager` logs through `SkalmanLogger.session` rather than `print`.
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

## Baseline metrics (July 2026)

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
