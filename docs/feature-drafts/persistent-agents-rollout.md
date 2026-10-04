# Persistent agents rollout handoff

> Status: **awaiting the overall orchestration review** (2026-10-03). This is an execution
> handoff for the five phases in [Persistent agents and memory](persistent-agents-and-memory.md).
> No phase is implemented by writing this document. Start implementation after the user has
> completed the wider review and recorded the approved scope and decisions below.

The implementing agent should work from the reviewed repository state, reuse the existing
portable controller, and deliver five verifiable increments. The design document owns the
behavior and Rindabox acceptance matrix; this document owns execution order, checkpoints and
the evidence needed to hand each increment back for review. Do not independently rewrite the
design or treat a sibling orchestration draft as already shipped.

## Record the overall review

The implementing agent can complete this record from the user's review notes and approved
repository state. Do not require the user to fill in the template or ask for another sign-off
when their review already authorizes implementation. Until that review is complete, the blank
record reflects the user's requested hold; it does not authorize incompatible product choices.

| Review field | Recorded decision |
| --- | --- |
| Review date and user approval of implementation scope | Pending review |
| Reviewed Threading commit and included working-tree changes | Pending review |
| Reviewed Rindabox commit and included working-tree changes | Pending review |
| Approved phases and any deferred parts | Pending review |
| Changes to the design from the review | Pending review |
| Owner of the shared controller schema and protocol changes | Pending review |

Read these together during that review: [agent identity and memory](persistent-agents-and-memory.md),
[agent mail](agent-mail.md), [portable trigger sources](portable-trigger-sources.md),
[agent usage ledger](agent-usage-ledger.md), [usage-aware accounts](usage-aware-accounts.md),
and the current [controller](../architecture/autonomous-controller.md),
[control plane](../architecture/control-plane.md) and [automations](../architecture/triggers.md).
Check Rindabox's `docs/agent-mcp-policy.md`, `docs/agent-definitions.md` and
`infra/backup-recovery.md` against the same decisions.

Resolve these interfaces once, then update the affected drafts rather than letting each
implementation pick a different answer:

| Interface | Decision the review must settle |
| --- | --- |
| Agent identity | Shared AgentRef, authority versus execution host, existing worker UUID adoption, and the single memory custodian. |
| Definition and permissions | Local host authority versus Rindabox authority; instruction snapshots; binding read/write modes; no permission inheritance from association. |
| Memory visibility | Which source-derived content may be materialized, which must remain governed references, and how legacy unclassified memory is exposed. |
| Mail routing | Logical agent destination versus concrete session/worker endpoint; one selected endpoint when several chats belong to an agent. |
| Wake behavior | One source → match → admit → run path. Agree whether `wake` remains a public grant label backed by a trigger or is replaced; do not implement two wake engines. |
| Spend | Usage receipts versus account-window readings; missing/stale readings defer protected admission; count limits remain loop protection. |
| Migration and transport | One ordered schema migration sequence and version negotiation across identity, mail, triggers and usage. No competing drafts each assume the same next version. |
| Recovery | Protected agent-state export, ordinary non-secret definition export, authority remapping, and paused/reauthorized restore behavior. |
| Native Rindabox access | Human consumer authentication and current application checks; operational agent keys and SSH owner authority are not substitutes. |

If review changes a contract, amend the design before coding its dependent phase. Routine
implementation details can be decided by the implementing agent. Once the approved scope is
recorded, continue through passed phases without requesting a new permission at every phase.

## Start from the reviewed state

Read `CLAUDE.md` and the owning architecture files before changes. In Rindabox read its
`AGENTS.md` and recovery guidance. Confirm what has actually shipped since these drafts were
written, including the database version and installed protocol contracts. Reuse current code
when it already satisfies a requirement; do not recreate features because the draft is older.

Use an isolated branch/worktree from the reviewed state for each repository. Preserve other
agents' working-tree changes; do not reset, stash or clean someone else's work to obtain a
baseline. Account for reviewed uncommitted work explicitly rather than omitting it from the
implementation checkout. Keep one owner for the controller migration/protocol files while
other orchestration changes are landing.

Create synthetic fixtures and an evidence directory outside tracked user-data files. Record
the build/runtime versions, baseline measurements and test prerequisites. Do not migrate a
live store, activate a schedule, provision a mailbox or deploy to demonstrate a local phase.
Production work remains subject to the existing repository authorization and release workflow.

For one implementing agent, the default order is **1 → 2 → 3 → 4A → 4B → 5**. Phase 4A can be
validated against phase 1's core before the UI is finished. Mail/trigger/usage work may proceed
under their own reviewed plans once shared identities and protocols are agreed; the relevant
pieces must be available before phase 5 enables behavior that depends on them.

## Phase 1 Portable identity and memory

**Own:** `Packages/ThreadingDomain`, `Packages/ThreadingController`, `Targets/Controller`,
portable tests, CLI/MCP fixtures and the controller architecture/recovery contracts.

Deliver in three reviewable increments:

1. Add the reviewed typed identities, authority records, worker mapping and binding generations.
   Write old/current synthetic store fixtures, then migrate existing workers one-to-one without
   changing UUIDs, memory keys, revision history or work/delivery IDs.
2. Extend memory metadata and admission. Implement bounded discovery, current-grant reads,
   revisioned corrections, owner-maintained entries, tombstones, purge and cache invalidation.
   Include indexes and aggregate opening-context bounds. Test the actual races between writes,
   revocation/rebinding and deletion; do not leave concurrency verification for the UI phase.
3. Add versioned protected state export/import and the scoped CLI/MCP operations. Preserve legacy
   DTOs and exact get/put semantics, negotiate additional capabilities, and reject incompatible
   schemas/clients visibly. Keep owner operations separate from model-visible tools.

**Gate:** on macOS and Linux, run `scripts/test-controller.sh` with an absolute isolated scratch
directory. Exercise the built executable and real MCP client, not just in-process store calls.
Verify legacy worker request compatibility, question → answer → continuation → result,
concurrent revision conflict, read-only rejection, stopped credentials, purge and a fresh-schema
import. Record what Linux build/profile was tested; a macOS pass is not a Linux pass.

**Handoff:** migration description, version/capability matrix, protected export fixtures,
test evidence and indexed-operation measurements. This phase may be complete without a new
app UI, but may not claim chats or Rindabox adoption are implemented.

## Phase 2 Local chats bound to agents

**Requires:** phase 1's admitted identity/memory API and recovery contract.

**Own:** Threading session/store/lifecycle integration, local agent persistence, command
operations, MCP catalog/routing and provider context adapters.

1. Add create/promote/bind/unbind/new-chat/inspect host operations and the authoritative durable
   binding. Keep the session's displayed reference a projection. Recover an association
   committed before a crash without minting a second agent or deleting its memory.
2. Resolve the calling session's existing MCP token to its current binding. Construct the
   principal inside the host; models cannot supply an identity or binding generation to assume.
   Revoke the route on deletion and recheck generation/grants at mutation commit.
3. Deliver captured instructions and the bounded retrieval manifest for fresh/resumed chats.
   Apply binding changes at a safe turn boundary. Make notices idempotent and keep mutable
   memory separate from policy and from old transcript messages.
4. Verify Claude and Codex native and terminal paths. Cover account/provider continuation,
   context reset, project eligibility and read-only side chats. A runtime without a verified
   route reports unsupported capability instead of pretending it has persistent memory.

**Gate:** two fresh chats of one synthetic agent recall the corrected fact after app restart;
another agent and an unbound chat cannot read it. Verify real token/tool routing, stale-token
denial, promotion during an active turn, cleanup and cross-store crash recovery. Tests use the
repository's hosted-store isolation rather than the developer's live database.

**Handoff:** stable host command/tool contracts, transport coverage matrix, persistence/recovery
evidence and context snapshots without private reasoning or credentials. Menus/UI can follow
in phase 3; do not label developer-only commands a finished user workflow.

## Phase 3 Profile and memory UI

**Requires:** phase 2's host operations and truthful projections.

**Own:** Design-based composer/menu/profile/picker/editor, command registry, remote/iPhone
projections, UI evidence coverage, customization audit and user guide.

1. Capture the relevant real-shell baseline and apply theme/customization/scaling gates.
2. Add **Make this chat an agent** and **New chat with agent**, the identity mark, project
   eligibility and visible memory read/write mode. Keep ordinary chats usable without an agent.
3. Add lazy metadata lists and selected-entry editing/history. Show author/source/revision,
   read-only protection, stale/unavailable authority and conflict recovery with the pending edit.
4. Add distinct remove, forget and agent archive operations with the semantics in the design.
   Chat archive must not erase the agent; forgetting must not claim to erase provider transcripts.
5. Verify supported iPhone identity/chat behavior. Report any deferred mobile editor explicitly.

**Gate:** inspect rendered evidence from the real product shell in light/dark themes, text
scales and narrow windows. An isolated journey must exercise promotion, a second chat, memory
correction/conflict, archive and forgetting with correct focus. Stress the paged profile and
one-entry update; compilation or detached-view assertions do not satisfy this gate.

**Handoff:** inspected render paths, journey results, measured main-thread/scroll/footprint
evidence and updated user/customization documentation. At this point the local user workflow
can be complete while the separate remote consumer workflow is still pending.

## Phase 4 Rindabox adoption and remote chats

### Phase 4A Existing hosted agents adopt the core

**Requires:** phase 1 and the reviewed memory/source policy. Does not require native OAuth.

**Own:** Rindabox contracts/catalog, managed recipes, controller/application adapters,
definition projections, private-memory management and backup/portable recovery.

1. In a separate Rindabox worktree, preserve its agent/worker UUIDs and authoritative PostgreSQL
   definitions. Use explicit idempotent projection/mapping operations with revision checks.
2. Add the exact read/write memory capabilities, discovery and owner/admin management through
   common API/MCP operations. Keep task grants, source grants and full-memory management distinct.
   Access planners get no target memory, and existing workers gain no unreviewed new grants.
3. Enforce the reviewed source-visibility contract, including legacy unclassified entries.
   Use governed references when body visibility cannot be enforced. Test revocation and
   cross-requester cases at the server; a prompt is not an authorization test.
4. Run the design's synthetic Signe/Vera cases. Preserve instruction snapshots, mailbox-free
   operation, questions, schedules, approval-bound decisions, feedback and delivery policy.
5. Update the recovery inventory, portable adapters and compatibility fixtures. Test encrypted
   same-release restore and fresh-schema import separately; non-secret Git definitions must
   contain neither live memory nor credentials.

**Gate:** focused regressions, actual API/MCP transport tests and `npm run gate`. Run
`make backup-test-db` for persistent schema/auth changes and `make infra-syntax` for infrastructure
changes. Missing prerequisites or skipped database cases are not passes.

**Handoff:** UUID/state continuity report, exact effective tools/scopes, source-policy tests,
complete synthetic Rindabox acceptance matrix, definition-export check and recovery evidence.
This proves managed adoption; it does not prove that Threading can sign in and chat remotely.

### Phase 4B Threading connects as a human client

**Requires:** phase 3, phase 4A and a proven supported authorization implementation.

**Own:** Rindabox human consumer authentication/transport and Threading's connection/remote
task-chat adapter. Keep human credentials in host custody and operational agent credentials
inside their managed runtime.

First deliver a synthetic transport spike: system-browser authorization code with PKCE,
bounded authorized agent listing, task submission/read/message/answer/cancel/result, and
person/client audit attribution. Verify exact redirect/issuer handling, client revocation,
current membership/grant changes and cross-agent rejection. Record any review-approved change
to the proposed OAuth route in the design before implementing it.

Then add the UI over managed tasks. An open task receives follow-ups through its message
operation; a later conversation turn submits a new task after completion. Show task progress,
questions and final results truthfully. Keep email/draft approval and uncertain sends in Rindabox.

**Gate:** an isolated Threading journey reaches the real synthetic Rindabox application and
completes a task/answer/result round trip, then demonstrates revoked access. Existing browser
CSRF checks, application admission and MCP restrictions remain covered by regression tests.

**Handoff:** tested human-client contract, Keychain/credential recovery classification,
native journey/render evidence and the complete remote-chat acceptance result. If authorization
support is unavailable, report 4A complete and 4B pending; never call phase 4 complete or
substitute cookies, operational agent keys or owner SSH commands.

## Phase 5 Scheduling and orchestration integration

**Requires:** the completed applicable local/remote paths, reviewed shared identities, and
the sibling mail/trigger/usage capabilities needed by each behavior being enabled.

**Own:** agent-aware scheduling/recipes, the mail endpoint adapter and integration tests.
Mail transport, source runner and usage parsing stay owned by their existing reviewed plans.

1. Bind schedules to AgentRef while preserving immutable work instructions, per-run current
   admission and existing host activation decisions. Remote schedules remain on their host
   and use their consumer's policy.
2. Resolve agent-directed mail to one owner-selected concrete endpoint. Preserve authenticated
   senders, durable receipts, coalescing and question/answer continuation. Multiple open chats
   must not receive an accidental broadcast or create several autonomous workers.
3. Route wake through the agreed source/match/admit/run path. Retain chain/depth/count protection
   and the usage/spend checks from the other plans. Missing protected-admission readings defer
   work; unavailable usage is not displayed as zero.
4. Keep trigger cursors, task checkpoints, delivery receipts and usage receipts outside learned
   memory. Attribute usage to the resolved AgentRef plus its work/execution identities.
5. Exercise restart/disconnect and joint failure cases before enabling the integration.

**Gate:** scheduled work recalls the same corrected fact as an interactive chat. Hosted fixture
work completes while the Mac is offline and reconnects to the same identity/revision. A mail
event admits at most one eligible task; revoked grants, stale spend state and exhausted budgets
deny/defer admission as designed. Restart/replayed delivery does not duplicate work, mail or
spend receipts.

**Handoff:** end-to-end orchestration traces and fault cases, schema/protocol compatibility,
recovery evidence and the remaining explicitly deferred features. A missing sibling dependency
keeps only its dependent activation pending; it does not prevent validating independent work.
Do not absorb every sibling draft into this rollout merely to make the phase look complete.

## Track completion and evidence

Update this table as work progresses. Use actual evidence references and the tested source
revision. Do not mark a row complete from code structure, a skipped test or a provider's claim.

| Phase | State | Tested revision and evidence | Remaining gaps |
| --- | --- | --- | --- |
| 1 Portable identity and memory | Awaiting review | None | Implementation and verification |
| 2 Local chat integration | Awaiting review | None | Implementation and verification |
| 3 Profile and memory UI | Awaiting review | None | Implementation and verification |
| 4A Rindabox managed adoption | Awaiting review | None | Implementation and verification |
| 4B Human remote-chat connection | Awaiting review | None | Authentication spike, implementation and verification |
| 5 Scheduling and orchestration | Awaiting review | None | Reviewed sibling dependencies, implementation and verification |

Each checkpoint contains the concrete behavior, changed files/owners, compatibility/migration
effects, commands and results, inspectable product evidence where relevant, and anything still
unverified. Keep test data synthetic and private payloads out of logs and tracked documents.

Run the smallest relevant checks during iteration. Run the repository's required full gates
at the checkpoint boundaries; Threading requires `scripts/test.sh all` before a commit and the
applicable `scripts/ci.sh` gates. Do not repeat broad checks without a new change or unresolved
failure. Where shared behavior changes, use the measured performance workflow and leave the
regression boundary. Update the owning architecture documents as each behavior becomes real;
the feature draft must not become a competing source of shipping truth.

Local verification does not authorize a production rollout. A requested production deployment
uses the documented release workflow, an owner-approved verified backup, tested compatible
artifacts and explicit migration/rollback evidence. Completion reports distinguish local,
fixture, live-provider and production validation.

## Prompt for the implementing agent after review

Copy the following with the completed review record or its exact reference:

> Implement the reviewed persistent-agent rollout in `docs/feature-drafts/persistent-agents-rollout.md`,
> using `docs/feature-drafts/persistent-agents-and-memory.md` as the behavior contract. Read the
> completed overall review record and applicable repository guidance first. Reconcile the
> reviewed state with current code, then execute the approved phases in order, preserving other
> agents' edits and Rindabox's identities and application permissions. Reuse the existing portable
> controller. Validate each phase through its real shipping path, update the checkpoint table
> with tested revisions/evidence, and continue without asking for routine per-phase permission.
> Report material conflicts with the reviewed contracts before making incompatible choices.
> Keep independent work moving when one external dependency is missing, and distinguish partial
> completion accurately. Do not push, deploy, activate production automation or migrate live data
> unless that action is separately within the user's authorized scope.
