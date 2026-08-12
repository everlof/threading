# Automatic settling

> Status: **decision record** (2026-08-12). **No-go** on a settled/snoozed lifecycle state.
> **Experiment** with a presentation-only *Needs Attention* filter over facts the app already
> derives, and let that experiment decide whether anything durable is owed.
> Not implementation work.

Part of the [decisions index](README.md). Read alongside
[`session-activity.md`](../architecture/session-activity.md) (the state vocabulary and the rule
that nothing is lowered by guessing), [`sessions.md`](../architecture/sessions.md) (Close and
Archive), [`git.md`](../architecture/git.md) (sidebar grouping and pinning),
[`limit-recovery.md`](../architecture/limit-recovery.md) (the parked state),
[`scheduled-messages.md`](../architecture/scheduled-messages.md) (the durable clock a snooze would
reuse) and [`source-control.md`](../architecture/source-control.md).

**The one-sentence version.** t3code's inbox exists because their sidebar is a flat list with no
structure to lean on; Threading's sidebar is a tree that already groups by repository, checkout and
branch and already draws four distinct attention marks. The question "which of my thirty chats
wants me?" is a **query over facts that exist**, and answering it with a query costs one view,
while answering it with a lifecycle state costs two persisted fields, a wake timer, a clock-skew
policy, a sync contract for two devices, and a second meaning for Archive.

---

## 1. User problem and concrete use cases

With thirty sessions across six projects, the sidebar stops answering the only question that
matters at a glance.

1. **The morning scan.** Twelve rows have marks of some kind. Two are genuinely blocked on an
   approval; three finished overnight and nobody has read them; the rest are working or idle. The
   user reads all thirty rows to find the two.
2. **The finished-and-filed chat.** A conversation is done. Archiving it is correct but feels
   heavy — it stops the agent, leaves the sidebar, and lands in Settings ▸ Archived. So the user
   leaves it in the list, and the list grows.
3. **Not now.** A chat wants an approval the user cannot give until after a meeting. There is no
   way to say "hide this until 14:00"; the choices are to leave the mark up (and stop trusting
   marks) or to archive it (and stop the agent).
4. **The merged branch.** A session whose pull request merged three days ago still sits in the
   sidebar looking like live work.
5. **The long-running fleet.** Eight sessions are working. None of them is the user's problem yet,
   and all eight draw a spinner.

Case 1 and case 5 are the real pain and they are the *same* pain: prominence is spent evenly across
rows that cost the user very different amounts. Cases 2 and 4 are housekeeping. Case 3 is the one
genuinely absent primitive.

---

## 2. Existing Threading behaviour and overlap

The overlap here is unusually large, which is most of the argument.

**The facts are already derived, exactly and separately.** `SessionActivityTracker` keeps
`turnInFlight`, `awaitsUser`, `openAsks`, `pausedOnOwnWork`, `limitPark` and `isDormant`, and
`settle()` is the single place they become a `SessionActivity`. The vocabulary already distinguishes
the two kinds of attention that matter: `awaitingUser` is a turn stopped dead (filled dot, warning
role) and `needsAttention` is a turn nobody has read (hollow accent ring), and
[`session-activity.md`](../architecture/session-activity.md) records that the marks are *ranked by
what they cost, not by novelty* — the exact judgement t3code's recede rule is reaching for.
`limitReached` has its own mark. So Threading already knows, per row, which of `dormant`, `idle`,
`working`, `awaitingUser`, `needsAttention` and `limitReached` is true — and draws a distinct mark
for the four that are not "nothing to see".

**The structure is already there.** The sidebar groups repository → checkout → branch → session →
side chat, each level earned rather than always drawn, with three sort orders (order added, recent
activity, name) and pinned rows always first. t3code's Sidebar V2 *removes* project grouping and
makes project a filter dropdown, because a flat list is what they have.
[`T3CODE_FINDINGS.md`](../T3CODE_FINDINGS.md) §7 item 6 already says this out loud: "Threading's
grouping carries information their flat inbox discards".

**Archive is the filing action, and it is properly built.** It stops the agent, moves the row to
Settings ▸ Archived, is provider-backed where the runtime has a reversible archive (Codex), is
reconciled three ways against external changes, acts-then-offers-Undo rather than confirming, and
can be requested by the agent itself through `archive_session` with a settle delay and an expiry.
Archive/Restore is reversible and keeps checkpoints. Cases 2 and 4 are Archive's job.

**Pin exists** (`AgentSession.isPinned`, a filled mark after the title, pinned rows first on Mac and
iPhone).

**Notifications are already the "tell me when it matters" channel**, on four levels: a master
switch, a toggle per `AttentionAlert` kind stored as the disabled set, a separate sound, and
`notificationsMuted` as a tri-state on session and project so *inherit* is a state. Every alert is
withdrawn the moment it stops being true.

**Managed workspaces already have proof-based completion.** A session that finishes its handshake
archives itself; a refused proof lands `needsAttention` and stays visible. That is a *real*
settling signal — the agent proved it was done — and it does not need a heuristic.

**The parked state is the precedent for how a new fact gets added here.** `limitPark` was added as a
genuinely fifth fact rather than as a longer turn, and the record states why two obvious lowering
rules (being looked at, an output burst) were tried and removed: *"a limit is not a question the
user can answer by arriving."* Any settling design has to survive the same scrutiny about what
lowers it.

**What is genuinely absent:** a way to say *not now, come back at a time* (case 3), and a way to
ask the sidebar a question (cases 1 and 5).

---

## 3. Lessons from t3code

Read from the local clone at `edc503a7a`, which is newer than the `5719e8a` the findings document
was written against — and it has moved, which is itself a finding.

`packages/client-runtime/src/state/threadSettled.ts` is 274 lines of pure derivation:

- **`effectiveSettled`** checks blockers first — pending approvals, pending user input, a starting
  or running session, an unadopted queued turn — and those hold a thread active **even against an
  explicit user settle**. Past the blockers, the explicit override wins in both directions
  (`"settled"` files it, `"active"` pins it open), and without one a thread auto-settles on a
  merged/closed change request or on inactivity past a configurable window.
- **`canSettle` is deliberately the same blocker list**, on the stated rule that anything the
  partition refuses to *classify* as settled must also be refused as a settle *target*.
- **`hasQueuedTurnStart`** is a two-minute grace window with a two-sided `Math.abs` clock-skew
  check, because message timestamps originate on whichever device sent the message.
- **Snooze is an overlay, never touching the agent.** `threadRaisedHandWhileSnoozed` wakes early on
  a pending approval, a *fresh* failure (`session.updatedAt > snoozedAt` — a thread snoozed while
  already failed stays snoozed), or a turn completing after the snooze. `threadWokeAt` keeps an
  early hand-raise authoritative even after the scheduled time passes, so a visit does not suppress
  an indicator the user has not seen.
- **Timer wakes are derived**: no server event fires when `snoozedUntil` passes; the stale fields
  simply stop classifying.

**The drift is worth recording.** The findings document says PR merged/closed auto-settles "only
after 1 h idle (otherwise the permanent merge signal snaps a revived thread straight back)". The
current code has no such window: merged or closed returns `true` immediately, and the *server*
un-settles on real activity instead. So they moved the correction from a client-side idle timer to a
server-side un-settle command — which is a real architectural cost (a server that must observe
activity and issue un-settle commands) that Threading's local, single-process model would have to
pay for differently.

**Three things they got right that any Threading design must keep:**

1. Blockers outrank the user's own explicit settle. Hiding a pending approval defeats the approval.
2. Settled ≠ archived. Their settled shelf is still in the list.
3. The recede rule: working rows recede *with* read-ready ones. "Inbox-zero: working threads aren't
   your problem yet."

**Two things that are theirs, not ours.** The static sort ("activity NEVER reorders the list") is a
correction for a flat inbox where a moving row loses your place; Threading's tree has stable
positions already and offers recent-activity sorting as an explicit choice. And the settled shelf is
a third list on top of Active and Snoozed — the findings document's own warning applies: the sidebar
has since gained Archive, and "a design pass must reconcile settle-vs-archive semantics explicitly
rather than adding a third shelf."

---

## 4. Proposed domain and host contract

### 4.1 What "settled" would have to mean here, if it existed

Writing this down is what makes the no-go arguable rather than a shrug.

A settled session would be one that is **finished for now and needs no prominence**, derived — never
stored as a state the app decides on its own — as:

- **Blockers, first and absolute:** `awaitingUser`, `needsAttention`, `limitReached`, `openAsks`
  non-empty, a turn in flight, `pausedOnOwnWork`, a managed workspace in `needsAttention`, or a
  scheduled message pending against the session. Any of these and the session is not settled,
  whatever anybody asked for.
- **An explicit override**, both directions: the user filed it, or the user pinned it open.
- **Otherwise, a signal**: the managed-workspace finish handshake completed; or the session's change
  request merged or closed; or the session has been idle past a window.

**What wakes it** must be evidence, not a guess, on `limitPark`'s rule:

- a turn starting, `UserPromptSubmit`, or a structured stream turn boundary;
- any blocker rising;
- a scheduled message becoming due for it;
- the user sending into it from any surface, including the remote client and `send_to_session`.

Deliberately **not** waking it: being looked at, terminal output, a branch change, a `ProjectsDidChange`
for a title. Those are the same guesses the tracker already refuses.

**Presentation state, never a record edit.** The load-bearing rule: settling must not touch
`isArchived`, must not stop a process, must not reach `ProviderArchiveSync`, and must not remove
anything from the store. Archive already means *the record leaves the sidebar and the agent stops*,
it is provider-backed, it is reconciled against Codex's own archive across clients, and it is
reversible through a named Undo. A second concept that also removes rows from view but means
something different is how one of them starts getting used for the other. If a row can leave the
list without the user filing it, the user stops trusting the list — which is the exact failure the
feature is meant to fix.

### 4.2 What is actually proposed: a Needs Attention view

One presentation-only filter over the tree, no persisted state, no new derived lifecycle:

- A sidebar scope control with three positions: **All** (today's behaviour, the default),
  **Needs Attention**, **Recent**.
- **Needs Attention** shows sessions whose current `SessionActivity` is `awaitingUser`,
  `needsAttention` or `limitReached`, plus managed workspaces sitting in `needsAttention`, plus
  sessions with a scheduled message that failed. Pinned rows always show. Headings collapse away
  when they have no matching children — the earns-its-level rule, applied to a filter.
- **Recent** shows sessions with turn activity inside a window, ordered by `lastTurnAt`, which
  `sessionRestorePolicy` already established as the honest recency field (`lastActiveAt` is stamped
  by relaunch and feeds itself).
- The scope is **window state, not a preference and not per-session state**: it resets to All on
  launch. A filter the user forgot they left on is a sidebar that lies about how many sessions
  exist, which is worse than no filter.
- The currently selected session is **always rendered**, even when the filter excludes it — t3code's
  rule for the routed thread, and the same reason: a filter must not empty the pane.
- Counts sit on the control so All says how much is hidden.

That is the whole contract. No `settledAt`, no `snoozedUntil`, no wake timer, no clock skew, no
sync.

### 4.3 If snooze is ever built, what it costs

Recorded here so a later reader does not have to rediscover it.

Snooze is the one primitive with no overlap, and its natural home is not a new subsystem: it is
`ScheduledMessageStore`'s neighbour. That store already solves the hard parts — a
`RecoverableFileStore` at `.userAuthored` criticality, disk-commits-before-memory, refuses rather
than evicts, an absolute `dueAt` **plus** `intendedTimeZone` and `intendedWallClock` re-derived on
`NSSystemTimeZoneDidChange` so "tomorrow at 09:00" survives a flight. Snooze needs exactly that and
one boolean less.

It would still need, all of which are why it is not proposed now:

- one persisted field per session (`snoozedUntil`), which means a `threading.db` payload field, a
  RemoteKit wire field, an iPhone presentation, and a decision about what a *second* device does
  when it wakes;
- the raised-hand rule, including the *fresh*-failure clause;
- a derived timer wake with the signed-32-bit `setTimeout` clamp t3code hit (an overflowing timer
  fires immediately → tight loop) — on AppKit that is a `Timer` with a far-future date, which has
  its own version of the same trap;
- preset arithmetic worth taking verbatim from
  [`T3CODE_FINDINGS.md`](../T3CODE_FINDINGS.md) §7 item 16: evening-suppression when the evening is
  less than an hour away, DST-safe day arithmetic, minutes ceiled so a snooze never reads "0m";
- and an answer to "what does the notification do while snoozed", which is a fifth thing on top of
  the four-level notification settings that already exist.

---

## 5. Security, privacy, destructive-action and scaling analysis

**Destructive-action.** A filter destroys nothing, which is most of why it is the recommendation.
The destructive risk in the *rejected* design is specific and worth naming: an automatic settle on
an inactivity window silently reduces the prominence of a session the user never filed. If the
derivation is wrong once — a blocker Threading does not model, a runtime that reports no turn
boundaries, an inferred terminal whose quiet timer expired — the user loses a chat they were waiting
on and has no way to know it happened. Grok and OpenCode terminal sessions run on provider-neutral
output inference precisely because Threading does not rewrite their configuration to install hooks;
an inactivity settle would be least reliable exactly where the state is least reliable.

**Privacy.** Nothing here leaves the machine, and nothing here may be measured by telemetry.
[`T3CODE_FINDINGS.md`](../T3CODE_FINDINGS.md) §6 lesson 1 is that t3code's largest trust wound was
default-on PostHog; the "measurable success criteria" in §11 are therefore **local and
user-readable** by construction — see below.

**Scaling.** Apply the [scaling gate](../../CLAUDE.md#scaling-gate). Session count is externally
sized. The filter must be O(visible), not O(store):

- Filtering happens in `SidebarTreeBuilder` against facts already held in memory
  (`SessionActivity`, `isPinned`, `lastTurnAt`); no filesystem read, no process, no transcript
  parse.
- It must not clear and rebuild the outline. The existing structure-signature comparison
  (identities and nesting, deliberately not names) is what keeps a rename from destroying the
  morph; a scope change *is* a structure change, so it reloads once — but a session changing
  activity while the filter is on must reconcile only the affected identities, or every attention
  edge rebuilds the whole tree.
- `SessionActivityDidChange` is high-frequency; the filter must not recompute a whole tree per
  event. `AgentWorkloadMonitor` already establishes the pattern — recompute one aggregate, post only
  on a real change.
- Stress fixture: 200 sessions across 20 projects, half working, activity churning at the rate an
  inferred terminal produces, with the filter on. Measure tree rebuild count, main-thread mount, and
  that a row entering the filtered set does not scroll the list.

---

## 6. Dependencies on earlier roadmap goals

Shipped and sufficient for the recommended slice: the activity vocabulary and its `settle()`
derivation, the attention marks, `SidebarTreeBuilder`'s structure-signature reload and `refreshRow`,
`SidebarSessionOrder`, pinning, `lastTurnAt`, `SessionRestorationLedger`.

Owed only if snooze is later built: a durable per-session field and its RemoteKit wire shape, the
iPhone presentation, and the wake timer. `ScheduledMessageStore` supplies the clock semantics.

Owed for the measurement in §12, and cheap: **archive and restore are not journalled to `EventLog`
today**. One line each in the `session` category — the archive-to-restore round trip — is the
prerequisite for knowing whether people are using Archive as a snooze.

---

## 7. Smallest shippable slice

The **Needs Attention scope control**, alone:

- three positions, window state, resets to All on launch;
- the selected session always rendered;
- counts on the control;
- reachable from the sidebar header's existing arrangement control, which already owns grouping and
  sorting, and from the View menu beside the two grouping toggles.

No new persisted field, no new activity state, no wake timer, no change to Archive, no change to
notifications, no remote change.

---

## 8. Explicit non-goals

- A `settled` state, a settled shelf, or any third list beside the sidebar and Settings ▸ Archived.
- Automatic archiving of any kind. Nothing may reach `ProviderArchiveSync` without a person or the
  finishing agent's own handshake.
- Automatic reduction of a row's prominence on an inactivity timer.
- Snooze, in this slice.
- Flattening the tree, or turning project into a dropdown. The grouping is the information t3code's
  inbox discards.
- A static-sort rule. Threading offers recent-activity sorting as a choice and the tree gives rows
  stable homes; importing "activity never reorders" would remove a working option to solve a
  problem the tree does not have.
- Any telemetry, of any kind, to evaluate this.
- Changing what a mark means. The four marks and their ranking are settled and are the input to
  this feature, not its subject.

---

## 9. Acceptance and failure tests

Acceptance:

1. With the filter on Needs Attention, a session in `awaitingUser`, one in `needsAttention` and one
   in `limitReached` are shown; `working`, `idle` and `dormant` sessions are not.
2. A pinned session shows in every scope.
3. The selected session shows in every scope, even when it does not match, and switching scope never
   empties the pane.
4. A heading with no matching children is absent; a repository heading whose only matching session
   is two levels down is present, with the intervening levels.
5. A session entering `needsAttention` while the filter is on appears without a full tree rebuild
   and without moving the scroll position of the row the pointer is on.
6. Relaunching resets the scope to All.
7. Recent orders by `lastTurnAt`, and a session brought back by the startup relaunch does **not**
   appear recent on that basis alone.
8. The 200-session fixture holds the filter change and subsequent activity churn inside the frame
   budget, with reconciliation proportional to changed identities.

Failure:

9. A session whose activity is unknown (no hooks, inferred, currently silent) is shown in
   Needs Attention **only** if it holds one of the three marks — an unknown state never
   silently disappears from a filtered view.
10. With every session filtered out, the sidebar shows an explicit empty state naming the scope and
    offering the way back to All. A blank sidebar that looks like data loss is the failure mode.
11. Switching scope while a rename is morphing does not animate a transition between two unrelated
    conversations — the same rule `MorphingTitleLabel` already enforces on reuse.

---

## 10. Estimated complexity and maintenance burden

**Filter: small.** One control, one predicate, one tree-builder parameter, and the reconciliation
care in §5. Maintenance is **near zero** — it derives from facts that are maintained anyway, and a
new activity state costs one line in the predicate.

**Settled/snoozed lifecycle: large, with permanent maintenance.** Two persisted fields, a derivation
with blocker precedence, a wake timer, clock-skew handling, DST-safe presets, a wire shape, an
iPhone surface, a second device's opinion about a wake, an interaction with all four notification
levels, an interaction with scheduled messages, an interaction with limit recovery's park, and a
reconciliation with Archive. Every subsequent activity fact — and the tracker has gained three in
the last year — must decide whether it is a blocker. That is the cost the recommendation is
avoiding.

---

## 11. Recommendation

**No-go on settling as a lifecycle state.** The problem it solves is real; the mechanism is
disproportionate here because Threading has the structure and the facts that t3code's inbox is
compensating for the lack of.

**Go on the Needs Attention view, as an experiment with a stated exit.**

The success criteria have to be honest about the no-telemetry posture, so they are observations the
user and the developer can both make locally:

- **Primary, qualitative:** after the filter has been available for a month, does the request for
  settle/snooze recur? A feature request that stops being asked for has been answered.
- **Secondary, local and user-readable:** with the `EventLog` line from §6 in place,
  `Archive → Restore` round trips completed inside seven days. That pattern *is* somebody using
  Archive as a snooze, and it is the one behaviour that would prove snooze is a missing primitive
  rather than a nice idea. Zero round trips in a month is a no.
- **Tertiary, and a failure signal rather than a success one:** if the user leaves the scope on
  Needs Attention permanently and complains that sessions are missing, the filter is being used as
  the list and the honest response is to reconsider the tree, not to add state.

**Reject automatic archiving permanently**, separately from the rest. Archive stops a process and
touches provider state; nothing derived may do that on a timer.

---

## 12. What should reopen this

**Reopen snooze** (build it, reusing `ScheduledMessageStore`'s clock semantics) when the
Archive→Restore round-trip count is non-trivial, or when a user describes leaving a mark up because
archiving was too heavy. That is case 3 asking for itself.

**Reopen settling** when — and only when — one of these is true:

- the Needs Attention filter ships and the morning scan is still the reported pain, which would mean
  the problem is prominence *ranking* rather than *finding*, and the recede rule is the answer;
- session counts routinely exceed what the tree can hold on one screen even filtered, in which case
  the right move may be collapsing settled *groups* rather than settling rows; or
- a second device makes the question different: the iPhone dashboard is closer to t3code's flat list
  than the Mac's tree is, and if the pain is reported there first, the answer may belong to the
  companion rather than to the sidebar.

**Reopen the merged-PR signal separately and earlier.** Case 4 does not need settling: a session
whose change request merged could carry a quiet badge and sort last within its group, using the PR
state the sidebar already knows. If that alone removes the housekeeping complaint, the rest of this
record stays closed.

**Watch, but do not chase:** Codex 0.147.0 has grown a `threadSection/*` family — server-owned
named sections with explicit ordering (`thread/section/move`, `beforeThreadId`). If providers start
owning thread organisation, the question changes from "should Threading settle rows" to "whose
grouping wins", and that is a different record.
