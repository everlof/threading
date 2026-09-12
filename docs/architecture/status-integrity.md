# Status integrity

Badges, activity marks and loaders are claims about work outside the view displaying them. A
yellow dot claims a completed result is unread; a spinner claims work is still progressing; an
idle row claims no stronger state is known. Those claims must survive persistence failures,
socket loss, reconnect races, app suspension and host restarts without silently turning missing
evidence into a reassuring answer.

This file is the change gate for those claims. Read it before changing a receipt, session status,
catalogue event, dashboard row copy, loading phase or raw `ProgressView` in the iPhone target.

## The contract

Status moves through one directed pipeline:

`authoritative fact -> durable proof -> typed projection -> scoped transport -> presentation`

Every arrow has one owner. Presentation may simplify a known state, but it may not invent truth
that an earlier layer could not prove. In particular:

- Failure or absence is not `false`, `idle`, `read`, `finished` or an empty collection.
- A mutation acknowledgement means durable commit, not merely an in-memory assignment.
- A cached dashboard is labelled cached and is not treated as live catalogue authority.
- A transport delta is applied only when its stream and order connect it to the snapshot held.
- Indeterminate progress has a named owner, a bounded operation or deadline, and a settled failure
  path. A spinner is presentation, never the state machine itself.

Fail-closed does not mean freezing all interaction. It means retaining the last safe claim or an
explicit unknown state while recovery proceeds. For read receipts, unknown conservatively keeps
attention visible; it never clears a result the ledger could not prove was read.

## Read receipts

`SessionReadReceiptStore` is the authority for participant-scoped completion and seen generations.
Owner devices share the stable owner participant id; collaborators use their stable member id.
Socket ids never enter the ledger.

The store has three projections:

- `read(completionGeneration, seenGeneration)` is proven only from loaded, committed state.
- `unread(completionGeneration, seenGeneration)` is proven from the same ledger.
- `unknown` represents a failed load or a session record whose latest write failed.

Loads must not use an empty/default fallback. Writes must be checked. A failed mutation remains in
memory so a later visit can retry the complete session-sized record, but that session projects
`unknown` until the retry commits. `SessionReadReceiptMutationResult` deliberately separates
`didChangeProjection` from `persistence`; callers must not infer one from the other.

`AgentRuntime` is the sole publisher of `SessionAttentionDidChange`, the narrow receipt-ledger
edge. `SessionRuntimeDidChange` owns runtime changes. `SessionActivityDidChange` remains a broad
local presentation invalidation and is not a remote catalogue input. This prevents one semantic
change from being broadcast twice and prevents a receipt-only change from waiting for an unrelated
project mutation.

## Snapshot and event continuity

The host projects `RemoteSessionAttentionDTO` into every authorization-specific session row. The
row retains both the display activity and the receipt knowledge, so a client never needs to derive
reader-specific truth from a transient event.

Each authenticated dashboard event connection receives:

1. `catalogueHello(streamID, revision)` after registration;
2. scoped `sessionsChanged` frames numbered from one for that stream;
3. only frames visible to that connection's authorization.

Registration and hello revision capture are one main-actor transaction. Hidden rows consume no
sequence number, avoiding both false gaps and a side channel about unauthorized activity. The
iPhone accepts only the next frame for its current stream. A missing sequence, wrong stream,
missing revision, host-epoch change, malformed control frame or framed delta without a hello makes
the catalogue non-authoritative and schedules a full scoped refresh. It stays non-authoritative
until the REST snapshot meets the newest revision observed.

Opening a live session has a second settlement path. After the host attempts the durable receipt,
the session socket sends `sessionVisited` with the canonical post-visit row, catalogue revision and
commit result. The originating phone applies that row directly; other devices still learn through
their catalogue streams. A pooled socket replays its last visit frame when the detail view installs
the callback, closing the callback-order race that used to strand a badge. An uncommitted visit
cannot clear the phone's row. A committed canonical visit may repair a divergent row at the same
catalogue revision; ordinary equal-revision stream deltas remain stale and are ignored.

The wire additions are backward compatible. New fields are optional on existing messages; an old
host continues through the unframed compatibility lane, and an old client ignores the new hello
and visit message types. Compatibility is not permission to omit the fence in current code.

## Loader settlement

The iPhone dashboard's working mark projects only an available, unarchived `.working` session
from a live catalogue. The existing typed session/catalogue states own completion, refusal and
loss of authority; the cell owns no work timer or speculative state. Presentation stays host-only.

Content and identity changes must land in the same publication. A recency change can move a chat
while its activity changes, but a diffable move alone retains the old cell contents. Structural
snapshots therefore reconfigure retained visible identities as well as moving them. UIKit can
also prepare an offscreen cell before a publication; `willDisplay` resolves its current row again.
This costs O(visible) per publication and O(1) per displayed row, without polling or constructing
views for the catalogue. The dashboard regression covers starting, settling, cached/live
transitions and prepare/update/display ordering at 20 and 1,000 rows.

Before adding or changing a loader, write down all of these in the owning type or test:

1. the typed phase that makes progress true;
2. the operation, generation or transaction that owns it;
3. the cancellation and replacement rule;
4. the deadline or other bounded completion condition for external work;
5. the success, empty, refusal and failure states that replace it;
6. whether restored data is live, cached or unknown.

Do not add a Boolean such as `isLoading` when the operation already has multiple terminal outcomes.
Do not leave `ProgressView` behind after the task, socket or route walk has settled. Recovery may
start another named attempt, but a completed failure must remain a failure surface with a recovery
action rather than reverting to indefinite progress.

`scripts/config/status-integrity.json` records the current raw `ProgressView` ceiling by iPhone
source file. The ceiling is a ratchet, not approval of every existing site: counts may fall without
editing policy; a new site or increase requires an explicit policy change and review against the
six questions above.

## Required change review

For any nearby change, answer these before implementation:

- What is the authoritative fact, and which type represents unknown?
- What durable write or bounded operation must complete before success is claimed?
- Which single event owns the transition, and can it be emitted twice or not at all?
- How is the snapshot joined to subsequent events across registration, reconnect and host restart?
- What happens if the final response is delivered but the broadcast is lost?
- Which participant and authorization scope does the status belong to?
- Is steady-state work proportional to the changed row, not the whole catalogue?
- Which test proves failure, reordering, callback timing and compatibility behavior?

Status meaning and receipt ownership are host-owned safety semantics. Extensions may use supported
design-system presentation seams, but they do not redefine when a receipt is committed or when a
catalogue is authoritative.

## Mechanical enforcement

`scripts/check_status_integrity.py` is part of the repository boundary build phase. It enforces the
document index, the loader-site ratchet, checked receipt persistence, the single receipt-event
publisher, the stream fence/direct-settlement seams, and preservation of attention proof when
mobile session rows are copied. Its regression tests live in
`scripts/tests/test_status_integrity.py`.

The structural checker is intentionally backed by behavior tests:

- `SessionReadReceiptTests` refuses failed loads and writes as unknown and proves a later retry.
- `RemoteCatalogueScalingTests` pins the narrow, single-row publication edges.
- `RemoteProtocolTests` pins additive wire compatibility and round trips.
- `MobileRefreshPolicyTests` pins stream gaps, epoch changes, ordering and refresh settlement.
- `StatusIntegrityTests` pins direct post-visit delivery and late callback replay.

For presentation changes, the ordinary design-system and real-shell UI-evidence gates still apply.
This contract does not replace them.

### Work recency and catalogue publication

`lastWorkAt` is conversation use, separate from process lifecycle and the preserved `lastTurnAt`.
Work boundaries update the model before the renderer publishes `SessionRuntimeDidChange`, so the
remote catalogue projects timestamp and operational state together on its existing single row edge.
Accepted steering has no new turn edge and publishes through `SessionWorkDidChange.inputAccepted`.
Local sidebar ordering and search consume the narrow work event; they do not depend on an unrelated
project edit or a future catalogue rebuild. Receipt changes and visiting a row never stamp work.
