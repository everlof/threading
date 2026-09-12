# Session work-time audit — 12 September 2026

The iPhone ordering defect is part of a wider inconsistency: some consumers read process
lifecycle time, others read conversation use, and several cached consumers never hear when
conversation use changes. Recording a turn only on one send path also misses real work.

This audit follows timestamp producers through persistence, catalogue publication, native
ordering, restoration, search and usage caching. It does not claim a full audit of every timer,
provider protocol or distributed event in the application.

## Baseline before the repair

| Value | Actual producer / meaning |
|---|---|
| `AgentSession.lastActiveAt` | Initialized at creation, then stamped by terminal process launch and exit. Imported sessions initially receive the provider transcript's last activity instead. It therefore has mixed provenance. |
| `AgentSession.lastTurnAt` | Latest observed terminal turn start, or accepted direct native send. Completion does not update it. |
| `AgentSession.lastUsedAt` | `lastTurnAt ?? lastActiveAt`. This resolves the legacy fallback, but is still a turn-start time when known. |
| `archivedAt` | Separate durable archive chronology. |
| Remote `lastActiveAt` | After the preceding fix, projects `AgentSession.lastUsedAt`; its wire name no longer means the internal process timestamp. |

The reported Fras conversation demonstrated the difference in the live SQLite store: process
activity was 10 September at 15:28 UTC; the latest recorded turn was 12 September at 04:02 UTC.
The previous task corrected the remote projection and verified it with 23 passing focused tests
(one opt-in stress test skipped). The findings below record the defects identified before the wider repair. Implementation and
verification status are recorded at the end of this document.

## Findings

### 1. Native queued turns do not record their start — high priority

The direct send path calls `ProjectStore.noteTurnStarted` in
[`ConversationViewController.sendPreparedTurn`](../../Sources/Threading/UI/Views/ConversationViewController.swift).
The queue path in
[`ConversationOutboxCoordination.flushOutboxIfReady`](../../Sources/Threading/UI/Views/ConversationOutboxCoordination.swift)
admits the turn, sends it and calls `recordSentTurn`, but never records the timestamp.
`recordSentTurn` updates the timeline and working presentation only.

A follow-up queued hours earlier can therefore begin real work while its persisted last-used
time still names the preceding direct send. The remote catalogue fix cannot recover a timestamp
that was never recorded. Restoration, account-default selection and search also inherit it.

The repair belongs at the shared accepted-turn boundary. Queueing a message must not count as
execution; accepting it for execution must. Rejected sends and transcript replay must remain
excluded. Steering needs a separate decision because it joins an existing turn.

### 2. Search indexes do not observe work changes — high priority

[`NavigationSearchProjection`](../../Sources/Threading/Core/Search/NavigationSearchProjection.swift)
and [`TranscriptSearchProjection`](../../Sources/Threading/Core/Search/TranscriptSearchIndex.swift)
read `lastUsedAt`, but their owning
[`NavigationSearchIndexStore`](../../Sources/Threading/Core/Search/NavigationSearchIndexStore.swift)
and [`TranscriptSearchIndexStore`](../../Sources/Threading/Core/Search/TranscriptSearchProvider.swift)
only observe `ProjectsDidChange`. `noteTurnStarted` schedules an exact-record save without that
notification; its eventual persistence flush does not publish a project mutation either.

An already-warm navigation index keeps the previous recency after new work begins. Conversation
history can also remain missing new transcript content: opening Search queries the standing
index rather than scheduling ingestion. A subsequent title/project mutation can conceal the bug
by triggering the missing refresh.

The repair needs explicit work-change invalidation. Navigation metadata should update one
session; transcript ingestion should schedule only the affected source on its worker. A global
`ProjectsDidChange` broadcast on every token would create expensive unrelated work.

### 3. OpenCode usage exports are cached by process time — high priority

[`TranscriptUsageService`](../../Sources/Threading/Core/Agent/TranscriptUsageService.swift)
copies `session.lastActiveAt` into `ExportSource`, then uses it as the revision of both
`UsageLedgerIndex.update` and `UsageScanCache.records`.

After the first export is cached, more turns in the same live process leave that revision
unchanged. Subsequent scans can reuse old usage until the process exits or relaunches.
`refresh(force: true)` bypasses the report-age throttle, not these per-source revision checks.

Replacing this with turn-start time alone is insufficient: an export taken early in one turn
can remain cached after that same turn produces more usage. A reliable source revision must
reflect execution progress/settlement or a supported provider revision. Idle exports should stay
cached; active exports need bounded freshness. The export subprocess and parsing remain off-main.

### 4. The Mac sidebar sorts by process activity — medium priority

[`SidebarTreeBuilder.orderedActiveSessions`](../../Sources/Threading/UI/Views/SidebarOutlineNodes.swift)
uses `.sessionLastActive` and `session.lastActiveAt` for `.recentActivity`.
An old conversation relaunched today therefore outranks an old process used moments ago.
This is the same field mismatch as the original phone bug.

Use the canonical conversation-recency value, including its legacy fallback. The native-sidebar
parity declaration must identify the existing public `sessionLastUsedAt` fact, keeping native and
customized ordering consistent. Preserve pin precedence, reverse direction and stable ties.

### 5. Live sidebar activity repaints but does not reorder — medium priority

[`MainWindowController.terminalContainer(sessionStateDidChange:)`](../../Sources/Threading/UI/Windows/MainWindowController.swift)
calls `sidebarViewController.refreshRow`. That method reconfigures the visible row and updates
its height; it does not apply a session-order change.

Correcting the sort key alone fixes the next rebuild, but not the standing list when work starts.
The existing row-motion regression explicitly calls `reload()` after manually changing a process
timestamp, so it cannot detect this missing production event path.

Use the existing affected-project ordering update at a genuine recency change, while keeping
ordinary activity repaint and receipt updates cheap. Verify selection, row identity and ordering
through the real outline controller without a test-only reload.

### 6. Restore-running-at-quit uses a different clock from restore-recent — medium priority

[`StartupSessionRelaunch.policyPlan`](../../Sources/Threading/UI/Windows/StartupSessionRelaunch.swift)
sorts `.runningAtLastQuit` candidates by `lastActiveAt`. Its `.recentlyUsed` branch correctly
sorts by `lastUsedAt`.

The default policy can resume a recently restarted but long-unused process ahead of the
conversation just worked in. This matters because launches are staggered. The recorded set
should still determine eligibility; conversation recency should determine its launch order.

### 7. Managed chats also sort by process activity — medium priority

[`SupervisionListViewController.refresh`](../../Sources/Threading/UI/Views/SupervisionListViewController.swift)
sorts its production rows by `session.lastActiveAt`. Its activity observer refreshes the list,
but another turn leaves that sort field unchanged.

Use conversation recency for a list intended to put recently worked chats first. If the intended
order is instead supervision events, use the explicit event time rather than process lifetime.

## Policy gap: latest start is not latest work

Neither a native completion nor a terminal completion advances a dedicated durable work-end
timestamp. A turn that started yesterday and finishes now still has yesterday's `lastUsedAt`.
Native steering also does not record a new use timestamp, correctly avoiding a fictitious new
turn but losing evidence of the new interaction.

This propagates beyond sorting: `SessionProcessRetentionPolicy` computes warm-process expiration
from `lastUsedAt`. Once a sufficiently long turn settles and becomes eligible for retirement, it
can expire immediately even though work just finished. Protected in-flight work is retained;
this is a question about the settled process's warm lifetime, not killing active work.

The user-facing choice is whether recency means latest turn start or latest actual work including
completion. If completion should count, preserve start and end separately and define the derived
recency once. Do not silently redefine process timestamps, archive times or provider usage dates.

## Boundaries that already use the appropriate source

- Direct native send records a turn only after transport acceptance, before its local working
  presentation is applied. The suspected direct-send publication race was not confirmed.
- The terminal runtime observer records a turn before publishing its state change.
- `.recentlyUsed` restoration, inherited launch configuration, enabled-account selection and the
  native plugin navigator already consume `lastUsedAt`; their remaining exposure is missing or
  incomplete upstream work records.
- Archive ordering uses the explicit archive timestamp, with a documented migration fallback.
- Transcript import searches a bounded tail for provider timestamps before falling back to mtime.
  It does not normally mistake a metadata-only transcript rewrite for new work.
- Usage adapters attribute records to provider event times; the OpenCode issue is stale source
  caching, not moving all historical spend to the scan time.

## Original reproduction and repair requirements

Two audit-only regression probes exercise the shipping `SidebarTreeBuilder` and
`StartupSessionRelaunch.plan` with opposing process and work dates. They are run in
`/tmp/threading-recency-validation`, keeping intentional failures out of the main test target.
Both probes reproduced the defects: the build succeeded, then each assertion failed because
the recently relaunched process was ordered first. The run completed at 06:34 CEST with two
tests and two expected failures. Their run log is `/tmp/threading-recency-audit-tests.log`.

The other findings are traced through production call sites and observer ownership. Live
OpenCode export refresh, queued provider execution, and the physical iPhone were not exercised
in this audit. The main checkout still has an unrelated attachment-gallery status-boundary
failure; the isolated checkout includes the existing floating-button theme correction needed to
pass the baseline build boundary.

The coherent repair is a single definition of conversation work recency, a complete set of
accepted execution boundaries, and one narrow publication contract for changed sessions.
Cache freshness needs its own revision contract rather than overloading display dates. Keep
work proportional to changed sessions/sources, not transcript size or catalogue size; use the
existing 1,000-session ordinary and 5,000-session stress fixtures for any new publication path.

Regression scenarios should include direct and queued sends, rejected sends, steering, long
turn completion, idle process restart, transcript replay, active reattach, warm search results,
active/settled export refresh, pinning and reverse order. Existing manual-reload assertions are
insufficient for the live path.

## Repair implementation

All seven findings have source fixes. `AgentSession.lastWorkAt` records observed work while
`lastTurnAt` retains the latest start. `lastUsedAt` resolves those once for the sidebar, remote
catalogue, extension facts, search, restoration, supervision and process retention. Legacy records
keep their prior fallback; no completion history is invented for work observed by older builds.

Native admission now records start after successful transport, before presentation, for direct
sends, provider commands and queue drains. Accepted steering advances work without opening a turn.
Terminal operational endings and native non-replay endings record completion. The narrow
`SessionWorkDidChange` updates local projections; runtime catalogue edges remain singular.

Search has serial background workers: navigation coalesces immutable index builds, and transcript
work events ingest only changed sources. Supervision coalesces work/runtime/receipt refreshes.
Export freshness uses settled work revisions and explicitly bypasses both caches for active or
forced reads. Provisional and settled keys remain separate even when timestamps coincide; versioned
export keys retire old process-clock entries without invalidating other parsers. Account discovery
also retains work queued for another account while one discovery is already in flight.

The regression suites include model migration and persistence, actual native queued execution,
rejected opening sends, replay, terminal lifecycle, warm search, an unchanged transcript that must
not be reread, both export cache layers, remote steering publication, and standing sidebar movement.
### Verification results

- 141 non-stress tests passed across focused runs. The broad run covered native admission, live
  outline movement, remote rows, restoration, retention, Git turn checkpoints and host facts.
  The final rerun passed all 42 affected search/cache/model/fact tests, including account discovery
  during another account's work and forced export reads with identical timestamps.
- The opt-in catalogue test also passed at both 1,000 and 5,000 sessions with 32 owner clients.
  Each size built the catalogue once. Measured fan-out was 1,016.352 ms / 1,933.610 ms; encoding was
  64.357 ms / 326.225 ms; cached-body lookup was 0.004 ms at both sizes. These are cold Debug
  measurements, not network or physical-device latency measurements.
- The isolated app build passed theme, architecture, main-actor latency, native fact parity,
  module, dependency and status-integrity gates. `git diff --check` passes in the working checkout.

Validation uses `/tmp/threading-recency-validation`, with only the recency patch and the previously
identified floating-button theme prerequisite. The main checkout remains blocked by an unrelated
`RemoteAttachmentGallery.swift` ProgressView ratchet violation. The running installed app was not
replaced. The physical iPhone and a live OpenCode export subprocess were not exercised; remote DTO
publication and both real usage-cache layers were tested.

Logs: `/tmp/threading-work-isolated-tests.log`, `/tmp/threading-work-final-tests.log`,
`/tmp/threading-work-stress-1000.log`, `/tmp/threading-work-stress-5000.log`.

