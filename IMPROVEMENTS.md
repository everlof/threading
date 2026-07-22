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
- [ ] `StateManager.loadProjectsState` distinguishes **missing** (start fresh) from
      **corrupt/undecodable** (quarantine): rename to `projects.json.corrupt-<ISO date>`,
      log, and mark the store *load-failed*.
- [ ] `ProjectStore` refuses to `save()` while load-failed until the user has made a
      structural change from an explicitly-acknowledged empty state (or simpler: first save
      after quarantine writes to a fresh file, never over a `.corrupt-*`).
- [ ] Write a rolling `projects.json.bak` before each overwrite (cheap: rename-then-write).
- [ ] Actually read `ProjectsState.version` on load: newer than
      `ProjectsStateVersion.current` → treat as corrupt-shaped (quarantine, don't touch);
      older → run a migration chain (empty today, but the seam exists).
- [ ] Guard `HistoryManager.cleanupOrphanedHistoryFiles` on a *successful* store load — an
      empty-because-failed project list currently deletes **every** history file
      (`AppDelegate.cleanupOrphanedHistoryFiles` → `HistoryManager`).
- [ ] Fixture tests: v1 file round-trip; corrupt file → quarantined, not overwritten;
      missing-key file (schema drift) → decodes with defaults once 2.3 lands.

Evidence: `StateManager.swift:46-58` (nil on decode error), `ProjectStore.swift:319-334`
(eager save on ~every mutation; `load()` leaves `projects = []`), `Project.swift:262-276`
(`version`/`savedAt` written, never read — grep-confirmed no consumer).

Same decode-fails → reset → next-save-overwrites shape, lower stakes, fix with the same
pattern: `AccountPreferencesStore.swift:92-103`, `ProfileStorage` (`TerminalProfile.swift:80-93`),
`TokenUsageManager` (`TokenUsage.swift:48-61`), `AISettingsStorage` (encode side only).

### 1.2 MCP: fix the session-registry data race
- [ ] `MCPSessionRegistry`'s `static var` dictionaries are written on main (token minting at
      launch; `retainOnly` on session deletion) and read on the `com.skalman.mcp` queue
      (`MCPServer.route`/`routePermission`) with no synchronization — UB on a Swift
      `Dictionary`. Either resolve token→session **after** the existing hop to main (keeps
      the app's single-threaded model), or guard the registry with `OSAllocatedUnfairLock`
      (macOS 13+).
- [ ] `MCPServer.connectionsByID` is mutated on the MCP queue but iterated by `stop()` from
      the main thread at quit — dispatch `stop()`'s teardown onto the MCP queue.

Evidence: `MCPSessionRegistry.swift:17-35`, `MCPServer.swift:96-99,120,147,190`.

### 1.3 Permission card leak
- [ ] `PermissionRequestView` retains `onDecision`; the closure captures the local `card`
      strongly → every request leaks the view *and* the pending decision continuation into
      the MCP layer. Capture the card weakly, or make `onDecision` a `var` cleared after it
      fires.

Evidence: `ConversationRendering.swift:176-193`, `PermissionRequestView.swift:15,178`.

### 1.4 Stream-session lifecycle bugs
- [ ] `CodexStreamSession`: write-failure path calls `process.terminate()` without setting
      `isTerminating`, so `handleTermination` emits a **second** `.turnFinished`
      (`CodexStreamSession.swift:87-99,163-171`). Set the flag before terminating.
- [ ] `ClaudeStreamSession`: stderr goes to a `Pipe` nobody reads — crash diagnostics are
      discarded (`ClaudeStreamSession.swift:63`). Capture capped, the way Codex already
      does (64 KB cap, `CodexStreamSession.swift:141-145`).
- [ ] Both sessions mutate `buffer`/`process` from the pipe's readability queue while
      `handleTermination` nils them on main. Confine all mutable state to one queue (the
      simplest: marshal raw `Data` to main and do buffering/parsing there — output volume
      is line-oriented JSON, not a PTY firehose).
- [ ] `ClaudeStreamSession` spawn failure fires `onExit` synchronously; every other exit
      arrives async on main (`:79-83`). Make it async for a consistent caller contract.

### 1.5 Hot-path filesystem scans
- [ ] `AgentAccountDiscovery` re-enumerates `~` **and re-reads six shell config files** per
      call — and it is called per sidebar row configure, per launch, per conversation turn,
      and per resume-eligibility check. Add a small TTL cache (5–10 s) or FSEvents
      invalidation; keep the API identical.
- [ ] `CodexTranscript.url` walks the whole `sessions/` tree per call — memoize per
      (account, transcript id).
- [ ] `GitInfo` reads are uncached on paths hit per sidebar reload
      (`SidebarTreeBuilder.rootNodes` calls `repositoryIdentity` per project) — a
      per-checkout memo invalidated at the existing stopped-working refresh point suffices.

Evidence: `AgentAccountDiscovery.swift:149-152`, `ShellAliasReader.swift:16-29`,
call sites `SessionRowView.swift:264`, `AgentLauncher.swift:220`,
`ConversationViewController.swift:76-79`, `CodexTranscript.swift:6-30`.

---

## Tier 2 — Invariants into the compiler

### 2.1 `@MainActor` on the stores, then strict concurrency
- [ ] Annotate the main-thread-by-convention singletons: `ProjectStore`, `AgentRuntime`,
      `PermissionBroker`, `AccountUsageService`, `SessionActivityTracker`,
      `AccountPreferencesStore`, `ProfileStorage`, `AppSettings`, `MCPSessionRegistry`
      (after 1.2 decides its isolation). AppKit callers are SDK-annotated `@MainActor`
      already, so most call sites compile unchanged; the ones that don't are exactly the
      bugs this catches.
- [ ] `Package.swift`: enable strict concurrency `targeted`, later `complete`
      (`.enableUpcomingFeature("StrictConcurrency")` / `-strict-concurrency=`).
- Today: 4 `@MainActor` annotations in 22k lines; enforcement lives in doc comments.

### 2.2 Typed identifiers
- [ ] `SessionID` / `ProjectID` wrappers over `UUID` (single-value-container `Codable`, so
      persisted JSON is unchanged). Today both identities share `UUID`; a project id passed
      to `session(withID:)` compiles and silently returns nil.
- [ ] `TranscriptID` wrapper over the CLI resume id (`agentSessionID: String?`) — the
      id-space confusion CLAUDE.md itself warns about (MCP routing keys on `AgentSession.id`,
      *not* `agentSessionID`).
- [ ] `AccountHandle` enum (`.standard` / `.named(String)`) replacing the nil-means-default
      `String?`, and one composite `AccountID` type replacing the two hand-built
      `"provider:handle"` string formats (`AgentAccount.swift:26,49-51`,
      `AccountPreferencesStore` keys, usage-service keys, `usageAccountKey` in
      `MainWindowController`).

### 2.3 One meaning per nil in the model
- [ ] Hand-written `init(from:)` for `AgentSession`/`Project` using
      `decodeIfPresent … ?? default` (the `AISettings.swift:62-69` pattern). This retires
      the stored-`Bool?` workaround (`archived`, `nativeUI`) and makes future field
      additions decode-safe by default — the constraint is currently enforced by a comment
      (`Project.swift:141`).
- [ ] Replace overloaded optionals with enums where nil has two meanings today:
      `agentSessionID` (shell vs not-yet-discovered vs resumable) → `ResumeState`;
      `branch` (non-git vs pre-feature record) can stay `String?` once recorded-at is
      implied by decode defaults, but document the single remaining meaning.

### 2.4 Codable at the wire boundaries
- [ ] MCP: `JSONRPCRequest`/`JSONRPCResponse` envelopes; `RequestID` enum (int / string /
      null) instead of `Any` threaded through `result(id:_:)`; per-tool argument structs
      decoded by tool name instead of `MCPToolCall.arguments: [String: Any]` with a
      string-only accessor. Hand-built response dictionaries become `Encodable`.
      (`MCPServer.swift:152-155,223-234,303-318`, `MCPTools.swift`)
- [ ] Stream events: `StreamEvent.parse` / `CodexStreamEvent.parse` from
      `JSONSerialization` + `as?`-with-defaults to tolerant `Codable` (unknown kind →
      `.unknown` case; malformed line → skipped *and counted*, surfacing drift in logs
      instead of silence). This removes the bulk of the 92 `[String: Any]` sites.
- [ ] Tool identity enum with `unknown(String)` case so `PermissionPolicy` and the tool-row
      glyph mapping switch exhaustively (`PermissionBroker.swift:141-143`,
      `CodexStreamEvent.swift:61-93`).

### 2.5 Typed notifications
- [ ] Replace `object:`-cast payloads with a ~20-line typed event helper
      (`protocol AppEvent { static var name: Notification.Name }` + generic post/observe).
      Worst offenders: `.accountUsageDidChange` matching on a raw id string;
      `.terminalSessionDidEnd` carrying no session at all; `.profileDidChange` downcast at
      each receiver. Nine names total (`TerminalConstants.swift:350-357` + per-file
      extensions).

### 2.6 `ShellCommand` builder
- [ ] A small type whose `append(word:)`/`append(flag:value:)` quote by construction, so
      unquoted interpolation into the `sh -c` string becomes unrepresentable. One unquoted
      interpolation exists today (`AgentLauncher.swift:225-227`, safe only because the
      env-var name is a constant). Fuzz-test with hostile titles/branches/paths
      (`'; rm -rf ~'`).

---

## Tier 3 — Structure and tests

### 3.1 Decompose the window-controller hub
- [ ] `MainWindowController` conforms to five delegate protocols plus `MCPToolHandling`
      plus permission presentation (~800 lines + `MainWindowMCPTools.swift` 306 lines).
      Extract: `AgentToolCoordinator` (browser/display tool handling) and
      `SessionCoordinator` (create / close / import / worktree resolution). Chrome and
      layout stay.
- [ ] "Which session is visible" is tracked in three places (`TerminalContainerViewController.currentSessionID`,
      `AgentRuntime.setVisibleSession`, toolbar's account key) — make the container
      authoritative, derive the rest.
- [ ] Settings pages are index-coupled (sidebar index → `SettingsPages.all[index]`) — give
      `Page` an identity enum.

### 3.2 Retire the IUO init-order contracts
- [ ] ~46 implicitly-unwrapped declarations whose safety hangs on `setupSplitViewController()`
      running first. Known crash shape: `AppDelegate.mainWindowController!` if
      `applicationShouldHandleReopen` beats `didFinishLaunching`
      (`AppDelegate.swift:13,53-58`). Convert to `let` built in init, or a single lazy
      view-tree builder per controller.

### 3.3 Tests where the code is already pure
Currently: 3 tests (TranscriptReplay). The architecture has already extracted its logic —
these need no UI harness:
- [ ] Persistence: round-trip, corrupt-file quarantine, old-schema fixtures (locks in 1.1).
- [ ] `AgentLauncher` plan snapshots, including hostile strings (locks in 2.6).
- [ ] Stream-event golden files from real Claude/Codex transcripts (locks in 2.4).
- [ ] `SessionImporter.belongs` worktree fixtures — CLAUDE.md says the rules were "proven
      against a built layout"; make that proof executable.
- [ ] `SidebarTreeBuilder` grouping rules; `EditDiff` LCS; `Markdown` reader table;
      usage-window normalizers (fraction clamping, expiry, window identity).
- [ ] Pin a `.swiftlint.yml` (unconfigured runs are noisy and crash mid-lint) and add CI:
      `swift build && swift test && swiftlint`.

### 3.4 Smaller structural notes (fold into passing work)
- [ ] `ProjectStore.load()` fires `selectedSessionID.didSet` → redundant disk write during
      init; `removeSession` double-saves (`ProjectStore.swift:21-31,156-164`).
- [ ] `TerminalSession.startShell` interpolates the directory into `sh -c` with hand-rolled
      quoting (`TerminalSession.swift:133`) — route through 2.6's builder.
- [ ] PID capture is a timed guess with a "first child" fallback
      (`TerminalSession.swift:157-167`); wrong-PID risk under concurrent launches. At
      minimum, drop the fallback when the diff is empty.
- [ ] `ProcessUtility` fixed 4096-PID buffer silently truncates on busy systems
      (`ProcessUtility.swift:26,104`); full-system scans run on the main thread.
- [ ] MCP HTTP parser: no chunked-encoding support, missing `Content-Length` treated as
      empty body rather than 400 (`MCPConnection.swift:184-222`). Both clients send
      well-formed requests today; fix opportunistically, not urgently.
- [ ] `HistoryManager` logs errors with `print` instead of `SkalmanLogger`.
- [ ] `TerminalTheme.decodeColor` silently turns unparseable stored colors white
      (`TerminalTheme.swift:100-103`).
- [ ] `NSImage(systemSymbolName:)!` force-unwraps in `BrowserViewController` /
      `DisplayPaneController` chrome (`BrowserViewController.swift:248-251`,
      `DisplayPaneController.swift:90,145`).

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
