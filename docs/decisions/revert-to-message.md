# Revert to this message

> Status: **decision record** (2026-08-12). **Prototype** the workspace-only half —
> *Restore files to the start of this turn*. **Reject** any presentation that claims the
> conversation itself was reverted, until the provider evidence in §3 changes.
> Not implementation work.

Part of the [decisions index](README.md). Read alongside [`git.md`](../architecture/git.md)
(turn checkpoints, Git Review, the deliberate absence of a discard),
[`managed-workspaces.md`](../architecture/managed-workspaces.md),
[`sessions.md`](../architecture/sessions.md) (side chats, archive/undo),
[`native-conversations.md`](../architecture/native-conversations.md) (turn admission and the
disabled rewind commands), [`persistence.md`](../architecture/persistence.md) and
[`crash-recovery.md`](../architecture/crash-recovery.md).

**The one-sentence version.** Threading already stores, per turn, two immutable Git trees of the
whole worktree — so restoring the files is a small, buildable feature over machinery that shipped.
Rewinding the *conversation* is a different feature with a different owner, and the two providers
that can do it at all disagree about what it means, one of them has deprecated its own primitive,
and neither of the other two runtimes has anything. Shipping them behind one verb would be the
product lying about which half happened.

---

## 1. User problem and concrete use cases

"The last turn made it worse. Put it back."

1. **The broken refactor.** An agent rewrites 40 files in one turn and the build stops. The user's
   own half-finished edits are in the same checkout. `git checkout -- .` throws away both, and
   nothing in the app distinguishes them.
2. **The codemod with untracked output.** A turn runs a generator that writes new files and edits
   old ones. `git stash` and `git checkout` both miss the new files; the user is left deleting them
   by hand from a `git status` listing.
3. **The wrong question.** The user realises three turns in that they asked for the wrong thing.
   They want to go back to before they asked and ask differently, without the failed attempt
   spending context on every subsequent turn.
4. **The managed workspace.** A session running in its own detached worktree
   ([`managed-workspaces.md`](../architecture/managed-workspaces.md)) *is* its change set. A bad
   turn there has no "the rest of my work" to protect, and the appetite for restoring is highest.
5. **The bisect.** Turn 4 was good, turn 7 is bad, and the user wants to see turn 4's tree without
   losing turn 7's. This one is already served — Git Review's Turn N chip reads any retained
   checkpoint — and it is worth naming because it is the case people *think* they want a revert
   for.

Cases 1, 2 and 4 are about **files**. Case 3 is about the **conversation**. They co-occur but they
are not one operation, and §3 is why.

---

## 2. Existing Threading behaviour and overlap

Most of this feature exists. What is missing is one write.

**The storage half is done.** `GitTurnBaselineStore` publishes, per turn, a `before` and an `after`
tree at `refs/threading/turn-checkpoints/v1/<session UUID>/<checkpoint UUID>/{before,after}`, with
`git-turn-checkpoints.json` recording project, logical and execution checkouts, repository and
worktree identities, session, ordinal, stable native/provider turn ids, both refs and hashes,
capture status, failure and timestamps. Reading proves the current checkout's repository identity,
that each exact ref still exists, and that it still resolves to the recorded tree; a replaced ref
is an explicit unavailable checkpoint rather than a loose-object fallback. Retention is 50 per
session and 1,000 total, and startup reconciles the private namespace against the metadata.

Three properties of that capture matter here more than they did when it was built for diffs:

- **It includes non-ignored untracked files.** The alternate index (`GIT_INDEX_FILE=<temporary>`
  plus `git add -A -- .`) admits them. This is exactly the gap that makes `git stash create` and
  `git checkout` useless for case 2.
- **It excludes ignored files.** `.env`, `node_modules`, build output and every other
  ignored path are absent from the tree — which is what makes a restore *safe* rather than a
  workspace wipe. It is also a limit: an agent that edited an ignored file is not covered.
- **It is a tree pair, not a start-tree compared against today.** The comparison is
  recorded-to-recorded, so the checkpoint is a real point in time.

**The reading half is done.** Git Review's mode chip has Last Turn and a second chip selecting any
retained **Turn N**, newest first; the per-turn changed-files card in the conversation opens *that*
checkpoint rather than redirecting to the newest.

**The refusal is deliberate and is the most important thing on this page.**
[`git.md`](../architecture/git.md) records that Git Review has stage, unstage and commit and
**no discard**, "because every other action here is undone by the control beside it while throwing
away a change an agent just made is undone by nothing." A restore is a discard with a wider blast
radius. Adding one is a reversal of that rule, and the only honest way to reverse it is to make the
restore itself undoable — which §4 does, and which is most of the work.

**The pattern for a reversible destructive act exists too.** Archive stopped asking and started
acting-then-offering: `SessionCoordinator.archiveToast` names what happened and carries Undo, and
`ConfirmationPrompt.archiveRunningSession` was removed on the stated rule that *a prompt is right
where the way back is a different action the user has to know to take, and wrong where the way back
can be handed to them.* A restore that captures a recovery checkpoint first has a way back that can
be handed over.

**The conversation half has a non-destructive answer already.** A side chat is
`--fork-session`: the parent transcript is copied, the parent is untouched, and the child runs
beside it. `AgentSession.forkedFrom` is Threading's own bookkeeping. Case 3's user wants the
conversation to *continue differently*, and a fork does that without deleting anything.

**And Threading already refuses the destructive version.** `native-conversations.md` records that
Claude's slash catalog is dispatch authority but not UI authority: "`/clear` and its aliases,
resume/fork/rewind/background families … remain visible but disabled with a Terminal explanation
until an atomic native mapping exists." This record is the argument about whether that mapping
should exist.

**Adjacent machinery this would reuse rather than invent:** `GitProcess` (pipe handling, timeout,
oversized-output guard, `GitFailure.indexLocked`), `GitCheckoutWatcher` for the refresh afterwards,
`RecoverableFileStore`'s write-the-transition-before-the-operation rule, and `ToastPresenter`'s
queue for the receipt.

---

## 3. Lessons from t3code, and what the providers actually offer

**t3code.** A hidden Git ref per turn (`apps/server/src/checkpointing/`), powering revert to any
user message plus per-turn diff ranges, with the provider history rewound too via `rollbackThread`.
[the archived t3code findings](../archive/research/T3CODE_FINDINGS.md) §7 item 7 already records the storage idea as the
thing worth taking, and Threading took it. What t3code adds beyond that is the *write*, and they
present it as one action across both halves.

The interesting part is not their design; it is what the providers underneath will actually do.
Measured on 2026-08-12 against the installed runtimes.

### Claude Code 2.1.228

Two separate control requests, both present in the dispatch table and both reachable over
`--input-format stream-json`:

`rewind_conversation { target_message_uuid, interrupt_if_running }` →
`{ rewound, targetMessageUuid, prefillText, precedingAssistantUuid }`.

- It truncates the in-memory message array at the target user message and persists a **rewind
  anchor**; `prefillText` hands back the user's original text so a client can refill its composer.
- Refusals, verbatim: `commands queued`, `turn running`, `target not found`, `stale target`,
  `no preceding assistant`, `failed to persist rewind anchor`, `state changed`. The last is a
  re-validation after the persist — the array is re-checked and the operation abandoned if the
  targeted message moved underneath it.
- `interrupt_if_running` will abort a live turn and then spin for up to ten seconds waiting for the
  session to reach `idle`, failing with `turn running` if it does not.
- A `stackedExpansion` user message walks backwards to the real preceding user message, so the
  target is not always the uuid asked for.

`rewind_files { user_message_id, dry_run }` →
`{ canRewind, filesChanged, insertions, deletions, skippedLinks, error }`.

- Backed by Claude's **own** file-history subsystem (`fileHistoryEnabled`, `fileHistoryCanRestore`,
  `fileHistoryGetDiffStats`, `fileHistoryRewind`), which keeps per-file backups keyed by message id
  and populated by `fileHistoryTrackEdit` — i.e. **only for files Claude's own file tools wrote**.
  Anything a `Bash` step changed is not in it.
- Errors, verbatim: `File rewinding is not enabled.`, `No file checkpoint found for this message.`,
  `rewindFiles: no turn received yet`, and `Failed to rewind: …`.
- `skippedLinks` is returned on success: symlinks it declined to restore.

So Claude's file rewind is **narrower than Threading's tree pair** and its conversation rewind is
**genuinely destructive** to the transcript. The two are independently addressable, which is the
one piece of good news: a client can rewind files without rewinding the conversation, or the
reverse.

### Codex 0.147.0

`thread/rollback { threadId, numTurns }`, and its own schema is the argument:

> **DEPRECATED: `thread/rollback` will be removed soon.**
>
> `numTurns` — The number of turns to drop from the end of the thread. Must be >= 1. **This only
> modifies the thread's history and does not revert local file changes that have been made by the
> agent. Clients are responsible for reverting these changes.**

It is addressed by a *count from the end*, not by a target — so mapping "revert to this message"
onto it requires the client to compute a distance and be right about it while the thread may still
be moving. There is a dedicated error code, `threadRollbackFailed`.

The non-deprecated neighbour is `thread/fork { threadId, lastTurnId, … }`:

> `lastTurnId` — Optional last turn id to fork through, inclusive. When specified, turns after
> `last_turn_id` are omitted from the fork. The referenced turn cannot be in progress.

That is the same shape as Claude's `--fork-session` with a truncation point, it is
non-destructive, and it lands in a vocabulary Threading already has: a side chat.

### Grok and OpenCode

Nothing. ACP has cancel; there is no rewind, rollback or truncate in the schema Threading consumes,
and OpenCode's public CLI offers list/delete. `AgentCapabilities` would carry a capability that two
of four runtimes never claim.

### What that adds up to

| | Claude 2.1.228 | Codex 0.147.0 | Grok | OpenCode |
|---|---|---|---|---|
| Conversation rewind | `rewind_conversation`, by target uuid, destructive | `thread/rollback`, by count, **deprecated** | — | — |
| Non-destructive truncated branch | `--fork-session` (no truncation point) | `thread/fork lastTurnId` | — | — |
| Provider-side file restore | `rewind_files`, own-edits only | explicitly none | — | — |

A cross-provider "revert" built on this would be one runtime doing the real thing, one doing a
lesser thing through a primitive its vendor has announced the removal of, and two doing nothing.
That is not a capability; it is a per-runtime footnote wearing one button.

---

## 4. Proposed domain and host contract

**Two operations, two verbs, never one control.**

### 4.1 `Restore files to this checkpoint` — workspace-only

The only one recommended for implementation. It touches no provider and makes no claim about the
conversation.

**Wording is part of the contract.** The control says *Restore files to the start of this turn* and
its receipt says what moved and what did not. It must never read "revert", "undo this message" or
anything that implies the agent has forgotten.

**Preconditions**, all checked immediately before the write and all producing a typed refusal:

1. The checkpoint resolves under the existing rule: current checkout's `repositoryIdentity` matches
   the recorded one, both refs exist, and each still resolves to its recorded tree.
2. **No turn is in flight in any session standing in this checkout.** Not just the asking session:
   `worktreeIdentity` is the key, and `CheckoutBranchFollower` already proves several sessions can
   share one checkout. A restore under a working agent races its next write.
3. No other agent process is *running* in the checkout, turn or no turn. A dormant session is fine;
   a live one is refused with the session named, because the way out is to close it.
4. The repository is not mid-`rebase`/`merge`/`cherry-pick`/`bisect`, and `index.lock` is absent —
   the latter reusing `GitFailure.indexLocked`, whose stated answer is "try again", not "fix
   something".
5. The checkout is the one the checkpoint was captured from, or another checkout of the same
   repository that is on the same commit. Restoring a tree onto a different base is a merge, and
   there is no conflict resolver here for the same reason `integrateAndClean` has none.

**The recovery checkpoint is not optional and comes first.** Before a byte moves, capture the
current worktree through the *same* alternate-index path the turn checkpoints use, record it with
an explicit non-turn kind, and persist the metadata transition **before** the Git operation — the
rule `git-turn-checkpoints.json` already follows so that a crash leaves evidence that reads
`incomplete` on the next launch rather than a plausible older result. A restore whose recovery
capture failed does not proceed. This is the whole answer to `git.md`'s no-discard rule: the
control beside it undoes it.

**The apply**, and each clause is a thing that goes wrong otherwise:

- Compute the path set as a **tree-to-worktree difference**, not a checkout of everything: work is
  O(changed paths), not O(repository).
- Write through a private index (`GIT_INDEX_FILE=<temporary>`), never the checkout's real one. The
  index is the user's staging decision and this operation is not about it. `--no-optional-locks`
  does **not** apply — this is a write, and the same rule Git Review's writes follow holds.
- Restore modified and deleted paths from the tree.
- Delete paths that exist now, are absent from the tree, and are **not ignored**. The tree admits
  non-ignored untracked files, so this set is exactly "files that appeared since the checkpoint and
  are not ignored".
- **Never run `git clean`, and never touch an ignored path.** `.env`, `node_modules` and build
  output are not the agent's and were never in the checkpoint.
- Skip symlinks rather than replacing them, and report the count — the same answer Claude's
  `skippedLinks` gives, reached independently: a symlink restore is a decision about the link
  target, and this operation has no basis for making it.
- Leave the index alone; report the resulting `git status` in the receipt so the user can see what
  the restore left staged.

**Afterwards**: the checkout watcher already refreshes Git Review; the receipt is a
`ToastPresenter` band naming the checkpoint, the counts, the skipped symlinks, and **Undo**, which
restores the recovery checkpoint through the identical path. A restore that partially applied still
writes its receipt and names the recovery checkpoint, because a half-applied tree with no route
back is the failure this design exists to prevent.

**Managed workspaces** are in scope and are the best case: the recovery checkpoint scopes its ref
to `repositoryIdentity`, so it survives worktree disposal exactly as turn checkpoints do. Refused
while the finish handshake is running, after `integrateAndClean` has succeeded, or once a
publication receipt exists — at that point the change set is somebody else's.

### 4.2 `Start again from this message` — conversation, and not now

If it is ever built, it is built as a **fork, not a rewind**:

- Claude: `--fork-session` (already Threading's side-chat primitive) plus, if and when the
  truncation point becomes available on the launch line rather than only through an excavated
  control request, a truncation at the target message.
- Codex: `thread/fork { threadId, lastTurnId }`.
- Grok, OpenCode: absent from the menu, per the capability matrix, not silently degraded.

`AgentCapabilities` gains at most one fact — whether a runtime can fork a conversation *through* a
stated turn — and `AgentSession.forkedFrom` already carries the lineage. A destructive
`rewind_conversation` / `thread/rollback` mapping is refused; see §11 and §12.

**The product may claim the conversation was reverted only when all four hold:**

1. A **non-deprecated**, **target-addressable** truncation exists on at least two shipping
   runtimes, so the capability is a behaviour rather than a Claude footnote.
2. Its file-side contract is stated by the vendor, so Threading is not silently responsible for a
   half the user assumes happened.
3. There is a way back: either the operation is non-destructive (a fork) or the pre-rewind
   transcript is retained somewhere the user can reach.
4. The failure is legible: the refusal vocabulary maps onto something a person can act on, rather
   than `stale target` reaching a sheet.

Until then the two controls stay separate and honestly named, and a user who wants both presses
both.

---

## 5. Security, privacy, destructive-action and scaling analysis

**Destructive.** This is the most destructive operation the app would own, and the rules follow
from that rather than from convenience:

- **No agent-callable tool. Ever.** An MCP `restore_checkpoint` is one prompt injection away from
  an agent discarding the user's uncommitted work, and page text, file contents and tool output are
  all untrusted input reaching the same model. The [control plane](../architecture/control-plane.md)
  boundary holds: session lifecycle tools file a conversation away; none of them rewrite a
  checkout.
- **No scheduled, unattended or startup-relaunch route.** A scheduled message freezes launch
  choices and re-validates them; a restore has no equivalent re-validation that would be worth
  anything, because the thing it validates against is a worktree that moved.
- **Not exposed to the remote client in the first slice.** [Remote access](../REMOTE_ACCESS.md)
  already draws this line for approvals: a diff too large to send as one bounded snapshot leaves
  the card visible and requires the decision on the Mac, because Threading never offers an approval
  against a partial diff. A restore is that rule with more at stake — the phone cannot show the
  working tree it would discard.
- **Confirmation vs. receipt.** Archive's rule says a prompt is wrong where the way back can be
  handed over. A restore *has* a way back (the recovery checkpoint), so a receipt with Undo is the
  right surface — but only once the recovery capture has been proven to work. Until the Undo path
  has tests behind it, the first implementation confirms as well, and drops the confirmation when
  the receipt is trustworthy rather than shipping both forever.

**Privacy.** A recovery checkpoint writes worktree bytes into the user's own repository as loose
objects, exactly as turn checkpoints already do. Nothing leaves the machine. The one thing worth
saying out loud: an operation the user reaches for *because* something went wrong is also the one
most likely to snapshot a half-written secret into an object that retention will keep for up to 50
turns. That is already true today; the restore makes it happen more often, and the existing
retention and collection rules are the answer.

**Scaling.** Apply the [scaling gate](../../CLAUDE.md#scaling-gate):

- Cardinality comes from the repository, so treat it as unbounded. The apply must be O(changed
  paths); a `git checkout-index -a` over a 10,000-file monorepo to restore three files is the
  obvious wrong implementation.
- The write runs off the main actor on `GitProcess`'s queue, like every other Git operation here.
- The refresh afterwards goes through the existing watcher path, which already preserves the
  reader's place by file path plus within-row offset.
- Stress fixture: a 10,000-file repository, a checkpoint differing in 1,000 paths including 200
  additions and 50 deletions, restored while Git Review is open on Uncommitted. Measure the apply,
  the main-thread mount of the refreshed table, and that the reader's position survives.
- Retention is unchanged; a recovery checkpoint counts against the same 50-per-session and
  1,000-total bounds, which means a user restoring repeatedly evicts their own oldest turns. That
  is acceptable and must be *stated* in the record's retention note rather than discovered.

---

## 6. Dependencies on earlier roadmap goals

Shipped and depended on:

- Turn checkpoints as refs plus `git-turn-checkpoints.json` — the whole storage half.
- The turn-admission fence (`NativeGitTurnAdmission`, the terminal hook's held HTTP response), which
  is what makes "the start of this turn" a real boundary rather than an activity edge.
- Git Review's Turn N chip and the changed-files card's per-checkpoint opening — the surfaces the
  control hangs off.
- `GitProcess`, `GitFailure.indexLocked`, `GitCheckoutWatcher`, `RecoverableFileStore`.
- `ToastPresenter`'s queue and Undo pattern.
- Managed workspaces' repository-vs-worktree identity split.

New and owed:

- A non-turn checkpoint kind in `GitTurnBaselineStore` (`manual` / `recovery`), which the archive's
  schema validation and retention must both learn.
- A restore primitive beside `GitIndexWriter` — the first Git write in this app that changes the
  working tree rather than the index.
- One typed refusal enum, and one receipt.

Not depended on: anything in the composer-queue work, the control plane, or remote access.

---

## 7. Smallest shippable slice

**Restore files to the start of this turn**, for one checkpoint, on the Mac, by hand.

- Entry points: the Turn N header in Git Review, and the changed-files card's overflow menu — both
  already know exactly which checkpoint they are showing.
- Preconditions and apply per §4.1.
- Recovery checkpoint, receipt, Undo.
- No conversation change, no provider call, no MCP tool, no remote route, no scheduled route, no
  multi-checkpoint "restore to N turns ago" browser.

That slice is worth shipping alone: cases 1, 2 and 4 are answered, and the user who also wants
case 3 forks a side chat, which they can do today.

---

## 8. Explicit non-goals

- Conversation rollback of any kind, and in particular any mapping onto `thread/rollback` or
  `rewind_conversation`.
- Deleting or rewriting records in a provider's own transcript file. Those files are the provider's
  and are also Threading's grounding for replay, import and title recovery.
- A "revert" verb, or any wording implying the agent forgot something it did not forget.
- Restoring ignored files, or any use of `git clean`.
- Touching the index, staged state, `HEAD`, branches, tags, remotes, stashes or reflog.
- Restoring across repositories, or onto a checkout at a different base commit.
- An agent-callable tool; a scheduled restore; an unattended restore; a restore initiated from the
  iPhone or a shared browser session.
- A general checkpoint-browser or time-machine UI. Turn N already browses.
- Restoring a managed workspace after delivery or publication.

---

## 9. Acceptance and failure tests

Acceptance:

1. A turn that edits three tracked files and adds one untracked file is restored: all four paths
   return to their checkpoint state, and the added file is deleted.
2. An ignored file written during the turn is **untouched** by the restore.
3. A file the user edited by hand *after* the turn is restored to the checkpoint too, and the
   receipt says how many paths changed — the operation is about the tree, not about attribution,
   and the receipt must not imply otherwise.
4. Undo returns the worktree to exactly its pre-restore bytes, including the file from (3).
5. Staged content is unchanged by the restore, and the receipt reports the resulting status.
6. A symlink present in both states is skipped and counted.
7. Restore inside a managed worktree works, and its recovery checkpoint is still readable through
   the logical checkout after the worktree is disposed.
8. The apply is O(changed paths): the 10,000-file fixture with 1,000 changed paths does not read or
   write the other 9,000.

Failure, each producing a *typed* refusal with the worktree untouched:

9. A turn is in flight in another session standing in the same checkout.
10. Another agent process is running in the checkout with no turn in flight.
11. `index.lock` is held.
12. The repository is mid-rebase.
13. The checkpoint's ref has been deleted or moved (`git gc`, a manual `update-ref`) — refused as
    unavailable, never falling back to a loose object hash.
14. The recovery capture fails — the restore does not start.
15. The process is killed between the recovery capture and the apply — the next launch reads the
    transition as `incomplete`, the recovery checkpoint is intact and reachable, and nothing claims
    a completed restore.
16. The apply fails halfway — the receipt still names the recovery checkpoint and Undo works.
17. The checkout is a different checkout of the same repository at a different commit.

Belt-and-braces, in the spirit of `check_architecture_boundaries.sh`: a test asserting no MCP tool
registration and no remote route reaches the restore entry point, because "we decided not to expose
this" is exactly the kind of decision that erodes silently.

---

## 10. Estimated complexity and maintenance burden

**Workspace slice: medium.** Roughly one Git primitive, one checkpoint kind, one confirmation, one
receipt, and a test matrix that is larger than the feature. Most of the effort is in §9's failure
half. Maintenance is **low**: the primitives are `read-tree` / `checkout-index` / `diff --name-status`,
which have been stable for two decades, and the retention and reconciliation rules already exist.

**Conversation half: high, with high ongoing maintenance.** Two incompatible provider contracts, one
already announced for removal, one reachable only through a control request read out of a compiled
binary rather than from a published schema. Every CLI release is a re-measurement. This is precisely
the shape [the archived t3code findings](../archive/research/T3CODE_FINDINGS.md) §6 warns about — session durability is the
product, and their top bug class is context going missing.

---

## 11. Recommendation

**Prototype the workspace-only slice.** The storage exists, the surfaces exist, the reversibility
story is clean, and it closes three real cases. Build it behind the confirmation, keep the
confirmation until the Undo path has the failure tests above behind it, then drop it.

**Reject the conversation revert**, as a feature and as a claim. Point case 3 at side chats, which
already answer it non-destructively and which the fork-with-`lastTurnId` work would improve without
deleting anything. Keep Claude's `/rewind` family disabled in the slash catalog with its existing
Terminal explanation.

**Reject a combined verb permanently**, not just for now. Even if both halves ship, one button that
moves the files *and* the transcript hides which of the two failed, and the two fail independently
and often — a turn running, an index lock, a deprecated RPC, a missing capability. Two controls with
two receipts is the design, not a staging step towards one.

---

## 12. What should reopen this

**Reopen the workspace slice** (build it) when:

- a user reports reaching for `git checkout -- .` after a bad turn and losing their own edits; or
- managed-workspace sessions accumulate `needsAttention` refusals whose cause is a turn that dirtied
  the checkout past `integrateAndClean`'s cleanliness requirement — the restore is the repair.

**Reopen the conversation half** only on evidence, and specifically:

- Codex ships the replacement for `thread/rollback` and it is target-addressable, or `thread/fork`'s
  `lastTurnId` gains a documented mapping in the Threading adapter; **and**
- `rewind_conversation` appears in Claude's published control surface rather than only in the
  dispatch table, with a documented relationship between the anchor it persists and the transcript
  file `TranscriptReplay`, `SessionImporter` and `SessionNaming` all read; **and**
- either the operation becomes non-destructive or the pre-rewind transcript is retained.

**Reopen the whole decision** if a provider ships a rewind that also restores the worktree, because
then Threading would have two competing sources of truth about the same bytes — and the right answer
would be to let the provider own it and delete this feature, not to run both.

**Actively watch:** Claude's `seed_read_state` control request and the file-history subsystem behind
`rewind_files`. If Claude's file history grows to cover shell-written files, the argument that
Threading's tree pair is strictly better weakens, and the cheaper integration may become the right
one.
