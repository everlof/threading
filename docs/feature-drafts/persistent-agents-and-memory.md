# Persistent agents and memory in Threading

> Status: **researched implementation plan** (2026-10-03). The user approved the product
> direction and requested planning. The behavior below is proposed; this document does not
> claim it is implemented or deployed. Extends [sessions](../architecture/sessions.md), the
> [autonomous controller](../architecture/autonomous-controller.md),
> [control plane](../architecture/control-plane.md) and [agent mail](agent-mail.md). Coordinates
> with [portable trigger sources](portable-trigger-sources.md) and the
> [agent usage ledger](agent-usage-ledger.md).

Threading should let a person turn a useful chat into a named, persistent agent, then open new
conversations and run scheduled work with that same agent. Its purpose and memory survive a
conversation being archived, a provider account changing, and a worker execution ending.
Rindabox's hosted agents must use the same underlying identity and memory contracts without
moving their business permissions or private data into a coding chat.

The recommendation is to introduce **Agent** as the durable identity, attach **Chats** and
controller **Workers** to it, and extend the portable memory implementation already in
Threading. Keep one authoritative memory store per agent. Preserve Rindabox's existing UUIDs,
memory revisions, task admission, instruction snapshots and application permission checks.

The [rollout handoff](persistent-agents-rollout.md) gives the implementation sequence,
cross-orchestration review decisions, phase gates and a prompt for the next agent. The user
requested the wider review before implementation; record its outcome there before starting.

## What already exists

These observations come from the local working trees on 2026-10-03, based on Threading
`127498fd9` and Rindabox `5dc6da3`, including uncommitted changes. They are implementation
evidence, not a live production audit. Rindabox paths below are relative to `~/repo/rindabox`.

| Existing behavior | Evidence | Consequence for this work |
| --- | --- | --- |
| A Threading session has its own typed identity, project, transcript/resume state and lifecycle. | [AgentSession.swift](../../Sources/Threading/Models/AgentSession.swift), [Identifiers.swift](../../Packages/ThreadingDomain/Sources/ThreadingDomain/Identifiers.swift) | Add an optional agent association; keep conversation identity and provider identifiers distinct. |
| The portable controller owns stable workers and memory independent of provider transcripts. | [Records.swift](../../Packages/ThreadingController/Sources/ThreadingController/Records.swift), [ControllerStore+Memory.swift](../../Packages/ThreadingController/Sources/ThreadingController/ControllerStore+Memory.swift) | Reuse this store and its revision checks. Memory does not need to be moved out of Rindabox: it is already implemented here. |
| Private memory reads and writes derive the worker from an authenticated, current execution. | [ControllerAgentTools.swift](../../Packages/ThreadingController/Sources/ThreadingController/ControllerAgentTools.swift) | Generalize authenticated access for chats without letting a model choose another agent's identity. |
| Shared knowledge has explicit per-worker space grants and revisioned content. | [ControllerKnowledge.swift](../../Packages/ThreadingController/Sources/ThreadingController/ControllerKnowledge.swift) | Preserve separate shared knowledge; selecting a tool must not grant a space. |
| The current controller database supports schema versions through 6. | [Database.swift](../../Packages/ThreadingController/Sources/ThreadingController/Database.swift) | Introduce a versioned migration and capability negotiation; old binaries must refuse a future schema. |
| Rindabox uses its agent UUID for the controller worker UUID. | `src/server/autonomous-service.ts`, `src/server/agent-schedules.ts` | Adopt that UUID unchanged; do not replace existing identities or rekey their memory. |
| Rindabox instructions and schedules are owner-authored, and each task captures an instruction snapshot. | `src/server/agent-schedules.ts`, `src/server/agent-task-store.ts` | Definition changes affect new work, not the immutable instructions of an admitted task. |
| Rindabox exact tools, projects, mailbox grants and current membership are checked by the application. | `docs/agent-mcp-policy.md`, `src/server/agent-access-planning.ts`, `src/server/mcp-registry.ts` | A Threading association adds no application permission. |
| Definitions can be exported as reviewed, non-secret configuration; live memory is separate. | `docs/agent-definitions.md`, `packages/contracts/src/agent-definition.ts` | Keep definitions suitable for Git and private state in protected storage/export. |
| Controller state is included in encrypted recovery captures; fresh-schema portable import of the agent domains is not yet supported. | `infra/backup-recovery.md` | Same-release recovery and portable migration are separate deliverables, with separate tests. |

Important gaps today: there is no persistent agent association for ordinary Threading chats;
private memory has get/put/history core operations but no complete discovery, correction and
forgetting product; owner RPC currently exposes memory reads/history, not the complete mutation
surface; private memory lacks the richer provenance proposed below. Existing shared knowledge
is implemented even though an earlier paragraph of the controller architecture still describes
it as a future slice. Update that stale paragraph when the owning architecture is next changed.

## Rindabox requirements

The shared design must pass these concrete cases. Implementing a local-only agent picker does
not satisfy the whole feature.

| Case | Required behavior | Acceptance evidence |
| --- | --- | --- |
| Signe learns Vic's or David's preferred signature. | Save a small named preference after an authorized answer; a fresh task can find it without the old provider transcript. | Synthetic question, answer, memory write, provider restart and a second task that recalls the corrected preference. Source: `docs/cvo-agent.md`. |
| Vera's Chief of Staff instructions change. | Keep owner-authored definition revisions separate from learned memory; an already admitted task retains its instruction snapshot. | Definition edit between admission and execution does not rewrite that task; a later task uses the new revision. Source: `docs/agent-definitions.md`. |
| Signe and a Chief of Staff share approved venture guidance. | Read a separately granted knowledge space, with write access only where explicitly granted. | A read-only agent reads; its write is denied; another agent without a grant cannot discover or read the space. |
| A deal decision is needed. | Memory may point to a decision item; only the existing application review/decision path can authorize the decision. | A memory entry saying "approved" cannot satisfy `deal_decision` or bypass the database guard. Source: `docs/cvo-agent.md`. |
| A hosted agent has no mailbox. | Identity, instructions and memory still work; mailbox provisioning remains optional. | Create/use a synthetic mailbox-free identity without starting provisioning. |
| A task waits for a person or the provider exits. | Preserve worker memory, work checkpoint, question and task identity as distinct state; resume under a fresh execution credential. | Existing question/answer/continuation lifecycle plus a memory recall after restart. |
| A founder chats with an existing hosted agent from Threading. | Submit and follow work through Rindabox's authenticated application operations; use its managed recipe and exact access. | Real application routing with synthetic data, showing that a native chat cannot bypass task, source or email policy. |
| A teammate can submit/read tasks but cannot manage the agent. | Task visibility does not imply access to all private memory, definition editing or grant management. | The task operation succeeds while private memory management is denied. |
| An owner changes access or revokes a mailbox source. | Recheck current permissions; memory is never an alternative route around a revoked source. | New memory/reference reads are denied or filtered when the applicable permission is revoked; existing provider context is acknowledged as already disclosed. |
| Definitions are reviewed in Git and the host is rebuilt. | Definitions exclude memory and credentials; protected export/recovery preserves identity, memory history and deletion state. | Non-secret export fixture, current-schema import rehearsal and an isolated restore drill. |
| Scheduled work runs while the Mac is offline. | The VPS retains memory and executes independently; Threading reconnects to current state. | Disconnect the Mac, complete fixture work on the host, reconnect and read the same identity and revision. |

## Public guidance and design choices

Primary sources were opened and inspected on 2026-10-03. Their documented patterns support the
choices below; they do not establish a benchmark or prove this implementation correct.

| Source observation | Proposed Threading choice |
| --- | --- |
| LangChain separates conversation-scoped checkpoints from cross-conversation memory in explicit namespaces. It discusses both profile documents and smaller collections, and the tradeoffs of foreground versus background writes. [Memory overview](https://docs.langchain.com/oss/python/concepts/memory) | Separate chat state from agent memory. Start with named entries and explicit writes, then evaluate automatic extraction separately. |
| Letta's current SDK describes an agent as the persistent entity, a conversation as a thread on it, and a session as an active connection. [Sessions and durability](https://docs.letta.com/agent-sdk/sessions) | A chat belongs to an agent; a provider process or active connection does not define its identity. |
| Letta's current memory design distinguishes a small in-context area from memory read on demand. Its shared repositories can be attached for a session or persistently for an agent. [Memory](https://docs.letta.com/agent-sdk/memory), [Shared memory](https://docs.letta.com/agent-sdk/repositories) | Supply bounded opening context and explicit retrieval. Distinguish temporary task inputs from durable grants to shared knowledge. Adopt the pattern, not Letta's Git/cloud storage dependency. |
| Google ADK separates the current session, session state and cross-session memory services. [Conversational context](https://adk.dev/sessions/) | Use portable storage contracts behind host adapters rather than making a provider's transcript format the memory store. |
| Anthropic recommends using lightweight references to retrieve context when needed and describes structured notes for work spanning context windows. [Context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents), [Long-running harnesses](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) | Retrieve relevant entries instead of replaying every chat. Keep task progress/checkpoints separate from persistent facts. |
| OWASP documents indirect prompt injection through retrieved documents and recommends enforcing privilege boundaries outside the model. [Prompt injection](https://genai.owasp.org/llmrisk/llm01-prompt-injection/) | Treat memory bodies as untrusted data. Admission, provenance, grant checks and mutation policy stay in the host. |

There is no reason to add a hosted memory vendor, an agent framework, embeddings or a vector
database for the first release. The existing SQLite store can support the required identities,
named records, revisions and grants. Reconsider semantic retrieval only after representative
Rindabox evaluations show that indexed key/title discovery is inadequate.

## Identity and ownership

| Concept | Owns | Does not imply |
| --- | --- | --- |
| Agent | Stable ID, name, purpose, definition revisions and private memory namespace | A running process, a provider login, a mailbox or autonomous permission |
| Chat | Conversation ID, transcript, project and optional agent binding | Ownership of all the agent's memory or deletion of the agent on archive |
| Worker | An agent's configured autonomous execution policy on one host | Another agent identity merely because a new task starts |
| Work | Request, immutable admission context, checkpoints, questions and result | A conversation transcript or a source of grants |
| Execution | One attempt with a current credential and observed runtime lifecycle | Permanent memory access after completion or stop |
| Knowledge space | Shared, explicitly granted context | Automatic access from a project name or agent association |

Introduce typed `AgentID` and `AgentAuthorityID` in `ThreadingDomain`, and an
`AgentRef(authorityID, agentID)`. An authority is the durable instance that issues agent
identities and decides access. Its UUID survives a hostname, IP or executable change. Storage
host/transport references remain separate, so reconnecting does not mint another identity.
Identical names never merge identities. An authority namespace also prevents an imported UUID
from accidentally referring to an unrelated local agent.

For local agents, Threading owns the definition. For Rindabox agents, Rindabox remains the
definition and permission authority; its controller owns durable memory and work. Threading
displays an authorized projection and sends operations through the correct authority. Do not
keep two independently editable copies of the same purpose or instructions. Projections carry
the authority's revision and an explicit freshness/unavailable state.

Preserve existing `WorkerID` values and their wire representation. Add an explicit mapping to
`AgentID`; existing workers initially map one-to-one using the same UUID. Avoid a source-wide
rename of worker/work/execution types: those remain useful execution concepts. Multiple worker
policies for one agent are future work; v1 uses one memory custodian and one worker mapping.

An agent has an explicit project eligibility policy. Promoting a local chat initially makes it
eligible only in that project; using it elsewhere requires an owner action. Remote agents use
their consumer's scopes. Eligibility to open a chat is separate from project tool authority.
Renaming or moving a checkout does not change memory identity.

## User workflows

### Make a chat an agent

The chat menu offers **Make this chat an agent**. The person sets a name, purpose and initial
owner-authored instructions. They may select factual text to save as initial memory; defaults
do not copy the transcript or run an extraction model. The preview states the initial project
eligibility and memory access. Completing the action creates the identity and attaches the chat.

A running turn must settle before attachment takes effect. Capture the expected session and
definition revisions, then apply at that boundary; refuse if the chat was deleted or rebound.
This avoids giving a tool invocation one identity at admission and another at commit. Promotion
does not relaunch a provider, enable schedules or add business tools.

### Start another conversation

The composer offers **New chat with agent** and shows the selected identity beside the usual
runtime/account choices. The new chat has a fresh transcript and the same authorized memory
namespace. Provider/account changes use existing session admission and continuation behavior.
Agent association does not promise transcript portability that a runtime cannot support.

Keep ordinary chats valid without an agent. Initially use the existing chat/composer and a
bounded agent picker/profile; a new top-level Agents sidebar is not a dependency of useful
memory. The profile shows purpose, instructions, memory, shared knowledge access, associated
chats, worker availability and schedules with separate loading and failure states.

### Chat with a hosted Rindabox agent

The person selects a connected consumer and an agent they may use. A Threading remote-agent
chat is an application conversation over managed tasks: submission, task messages, questions,
answers and results. It is not a local provider shell holding the hosted agent's credentials.
Its UI distinguishes durable task progress from a provider transcript; do not invent streamed
assistant tokens when the application only exposes checkpoints and a final result.

The first task binds the conversation to an application-issued task ID. A follow-up while that
task is open uses its existing message operation; after completion it submits a new task under
the same AgentRef. Cancellation, answer and read operations use their existing independent
permissions. Email/draft delivery continues through Rindabox, including uncertain-send handling.

### Inspect, correct and forget memory

The profile lists named entries with revision, source, author and last update. Open an entry
before constructing its full text/history UI. Saving a correction requires the displayed
revision; a conflict shows the current entry and the pending edit without silently merging.
Owner-maintained entries can be read-only to agents. An agent may propose a correction to an
owner-maintained entry but cannot change its protection through a memory write.

**Remove entry** hides an entry through a revisioned tombstone while retaining reviewable
history. **Forget stored contents** additionally removes its body from current/history/search
storage, clears content-bearing titles/tags and invalidates pending context projections and
local body caches. Keep only opaque identity and content-free audit metadata. The interface
explains that provider
transcripts and existing backups may still contain it. Preserve a content-free tombstone and
revision so a delayed write cannot recreate a forgotten entry using revision zero. Future
relearning is possible only through a new authorized write; forgetting is not a promise to
rewrite past provider context. Specify SQLite WAL/checkpoint and cache cleanup before enabling
purge; the API promises removal from retrievable live stores, not forensic erasure of backups
or provider-owned files.

Archiving a chat preserves the agent. Archiving an agent prevents new chats/work admission and
memory mutations and revokes bindings at their next tool call; it does not erase history or
implicitly kill running processes. Stop and erase remain separate host actions. Forking a chat
does not clone an identity or grants: an eligible side chat defaults to a clearly shown read-only
binding; an independent agent clone requires an explicit owner action and selected initial
content. Existing transcript-copy behavior still copies whatever the provider had already seen.

## Memory contract

Extend named text entries rather than adding one ever-growing autobiographical document.
Keep the existing key/content/revision compatibility shape. New metadata is versioned and
includes the following concepts:

| Field | Meaning |
| --- | --- |
| Namespace and key | Agent-private or a granted knowledge space; stable key within that namespace |
| Revision and state | Compare-and-swap revision; active or removed |
| Title | Small discoverable description independent of the body |
| Author | Host-authenticated owner, chat or execution attribution; never a claimed actor in model input |
| Source reference | Opaque, validated chat/turn, work/question, consumer record or owner-edit reference |
| Observation/update times | Source time where known, and host commit time; do not invent dates for legacy content |
| Protection | Agent-editable or owner-maintained; separate from permission to read |
| Applicability | Optional validated project/task scope and consumer visibility policy reference |
| Retrieval selection | Owner-selected opening entry, or retrieve on demand; bounded in either case |

Source metadata records why a fact was saved; it does not prove the fact correct. For example,
Signe's signature entry can reference the authorized answer that supplied it. A correction
records a new revision and its source. Factual memory, task state, owner instructions and
application decisions remain distinct even if their bodies all use text.

Keep shared knowledge grants outside memory content, checked in the same transaction as reads
and writes. Add bounded discovery of granted spaces and entry keys so a new execution can find
information without guessing keys. No agent can promote a private entry to a shared space or
change the audience through `memory_put`; sharing is a distinct host-authorized operation.

### Permissions and source restrictions

Model-visible private-memory tools act only on the caller's authenticated AgentRef. A read-only
binding has get/list/history/context access but no put/delete permission. Host owner operations
have their own admission. For Rindabox v1, inspecting/editing the complete private memory store
is owner/admin-only; ordinary task read/submit/answer grants do not confer it. External MCP
clients require exact selected read/write tools and current backing grants.

Memory must not turn previously permitted mailbox, CRM or person-specific data into an
unrestricted cache. Rindabox owns the visibility policy for source-derived entries. A validated
reference is resolved using current application/source permission checks. A materialized body
may be released only where the consumer can enforce its applicable audience and source policy.
When it cannot, retain a reference and retrieve the source through its governed tool rather
than retaining a free-form private-data copy. Client-declared provenance is insufficient.

This requires an explicit consumer contract, not a claim that prompts or provenance labels
perform automatic information-flow tracking. Legacy entries have unknown provenance and
remain in the existing managed-worker scope; new human/remote memory endpoints must not broaden
their audience without owner classification. The Rindabox acceptance gate includes source
revocation and cross-requester disclosure cases. If those cannot be enforced for a class of
content, that class cannot ship as materialized reusable memory.

Tool allowlists and MCP read-only annotations describe capabilities; server admission enforces
them. Account switching never widens grants. Memory cannot alter instructions, spend limits,
tool selection, recipients, schedules, mailbox modes, decision approvals or authority bindings.
Agent-authored tool input cannot choose an AgentID or create its own authenticated principal.

## Opening context and retrieval

A new bound conversation/execution receives a small host-authored manifest: identity, captured
definition revision, purpose/instructions, memory capability and how to discover entries/spaces.
Owner-selected opening memory is delivered as visibly labeled data, separately from trusted
instructions. Do not concatenate agent-editable text into a system-policy file or `AGENTS.md`.

Use `agent_context` at the start and after a provider context reset, then list/get the entries
needed for the task. Reads return current revisions. Instruction revisions are captured at
admission; memory is current when explicitly read. Record which opening memory revisions were
supplied so inspection and a replay test can explain the context. Do not persist model reasoning.

For resumed chats, use an idempotent host notice for a changed definition/binding generation at
a safe turn boundary. Do not rewrite old messages or repeatedly insert the same instruction
block. A changed grant applies to the next tool call even while an execution retains its older
instruction snapshot. Refresh/context assembly runs on a bounded worker, not during layout,
scroll, a pointer event or a synchronous session-activity callback.

Foreground explicit saving is v1. Background extraction, consolidation and automatic promotion
of transcript text require a later opt-in policy, a separate cost/latency budget and evaluations
for false memories, secrets, duplication and correction. They are not enabled by promotion.

## Portable core and host adapters

Use `ThreadingDomain` for shared identity/value contracts. Extend `ThreadingController` with
agent records, memory metadata, discovery, protection and authenticated bindings; use the same
store for memory in the app and the Linux executable. A local app-owned controller database
can serve agent state without a supervisor running. Do not create fake work items or executions
just so an interactive chat can access memory.

This is the smallest dependency change: the package is already Foundation/SQLite-only and the
app already consumes its portable models. Give the memory/identity operations a focused API so
the module can later be extracted if a real independent consumer needs it. A new package or a
second database/migration framework is not a prerequisite and must not duplicate the store.

| Adapter | Authenticated caller | Operation path |
| --- | --- | --- |
| Local Threading chat | Existing session MCP token plus a current host-owned binding/generation | Host admission constructs an internal principal; portable store checks binding/grant and revision atomically. |
| Hosted worker | Current execution credential, work and worker mapping | Preserve current running-execution fence and worker-derived identity. |
| Host owner UI/CLI | Local owner authority, or the existing trusted SSH owner transport | Fixed bounded operations; not an unrestricted owner command offered to models. |
| Rindabox application | Current authenticated member/API principal and application locks | Validate application policy, then call fixed controller operations; preserve RLS and exact tool admission. |
| Threading remote-agent chat | An authorized consumer connection | Consumer task API/MCP adapter; no direct SSH owner RPC substituted for application admission. |

Bindings are host-authored durable records with monotonically increasing generations. The
agent/control store owns agent-to-chat binding truth; a reference displayed on `AgentSession`
is a projection, not an authorization record. Rebinding/revocation and a memory mutation use
the current binding in the same store transaction. A stale token cannot change identity by
supplying another session ID. Live session existence and token revocation remain host-owned.

Create the agent and binding atomically in the control store with a caller-minted operation ID.
Project/session presentation updates occur after commit. Because project state and agent state
are separate stores, define crash recovery explicitly: replay the committed association from
the control store, never infer another identity from a title. Session deletion revokes its MCP
route before cleanup; reconcile orphaned associations without deleting the agent or memory.

Host operations use one command path shared by menus, command palette and MCP admission. Scope
interactive memory to agent bindings, independently of the existing project-wide session
messaging grants. Agents sharing a Unix account retain that account's file authority; scoped
tools are not an OS sandbox. In particular, Rindabox operational identities must not be attached
to a broad local coding process that can read/export their protected store.

## MCP and consumer transport

Proposed model-visible tools share semantic schemas across Threading's session server and the
controller's `work` server. Preserve existing `memory_get`, `memory_put`, `knowledge_get` and
`knowledge_put` inputs and results for compatible clients; negotiate the additional features.

| Tools | Mode and scope |
| --- | --- |
| `agent_context` | Read captured definition, binding and bounded retrieval manifest for this agent. |
| `memory_list`, `memory_get`, `memory_history` | Read this binding's permitted private entries; lists return metadata, not every body. |
| `memory_put`, `memory_delete` | Separate write access, expected revision, valid protection and current binding. Delete is a tombstone, not privileged history erasure. |
| `knowledge_spaces`, `knowledge_list`, `knowledge_get`, `knowledge_history` | Read only currently granted spaces and permitted entries. |
| `knowledge_put` | Existing separately granted write access with expected revision. |

Human profile configuration, binding, grant changes, restore, purge and schedule activation are
host operations, not self-management tools granted to the modeled agent. For automation/tool
clients that need management, expose separately scoped host commands under the existing control
plane rather than adding owner authority to `work`.

Rindabox must register the added useful read/write capabilities in its shared contracts and
catalog, generate exact provider allowlists from accepted assignments, and enforce the same
policy in API and MCP paths. Read-only discovery cannot require write access. Existing managed
workers retain their current private get/put capability on upgrade; new capabilities/grants
need explicit accepted configuration. Access-planning workers continue to have no target-agent
memory. Version/capability mismatch is visible and fails closed, not an empty memory response.

For Threading's consumer connection, define a versioned adapter contract for bounded authorized
agent listing/definition reads and task submit/read/message/answer/cancel/history/results. Use
Rindabox's existing `AgentWorkOperations` and `tasks` MCP behavior as the implementation owner.
Its browser API currently uses authenticated sessions and same-origin write checks. Its external
MCP keys identify an agent and act under that agent's owner; hosted `rm1` credentials have still
narrower operation restrictions. Neither is a human native-client login. Do not give Threading
a target agent's operational key or bypass the browser protections.

The proposed native route is a separate human consumer principal, authorized through the
system browser using authorization code with PKCE. Native OAuth guidance calls for an external
browser and PKCE. [RFC 8252](https://www.rfc-editor.org/rfc/rfc8252) Rindabox must provide or adopt
the authorization-server support; its existing Google browser sign-in alone does not establish
that this client flow exists. Use a supported authorization implementation, with exact redirect
and issuer validation, rather than adding a homemade token protocol.

The owner selects permitted agent IDs and client operations. Effective authority is always the
intersection of that selection and the person's current Rindabox permissions. Default to task
read/submit where the member already has them; answer/cancel and private-memory management are
separate scopes. Store native secrets in Keychain. Keep access short-lived, rotate/revoke refresh
credentials and recheck membership and grants through operation commit. The modeled agent never
receives these human credentials. Human-client API/MCP admission constructs its own principal
and calls the shared application operations; do not disguise it as `withMcpAgent`.

Before the connection UI, a synthetic transport spike must demonstrate sign-in, bounded agent
discovery, a task round trip, token/permission revocation, cross-agent rejection, cancellation
and audit attribution to the person/client. If the supported authorization server cannot supply
this contract yet, remote consumer chat remains visibly unavailable while Rindabox's existing
managed workers still adopt the portable identity/memory core. Cookie copying, weaker CSRF or
SSH owner authority are not fallback transports.

## Storage migration and recovery

1. Add the authority/agent/binding records and required indexes through the next controller
   migration. Backfill an agent mapping for each existing worker with the same UUID. Preserve
   `memory`, `memoryRevision`, knowledge, work and delivery record IDs and revisions.
2. Existing memory keys remain valid up to their current 256 UTF-8 byte limit and bodies up to
   their existing 32 KiB limit. Backfill optional metadata as legacy/unknown; never fabricate
   authors, sources or observation dates. Migration does not silently truncate or merge entries.
3. Keep legacy wire DTOs separate from new versioned metadata DTOs. A schema upgrade must prevent
   an old binary from writing records that would discard new protection/deletion metadata.
4. Leave ordinary chats unbound. Add/read optional associations without rewriting provider
   transcripts, converting every chat into an agent or touching other sessions' permissions.
5. Adopt Rindabox's UUIDs and authority explicitly. Its PostgreSQL definition and controller
   projection revisions have separate owners; synchronize through idempotent operations and
   read back the result. They cannot be assumed to share a database transaction.

Capture a verified owner-approved backup before a production migration. Before deployment,
use synthetic copies/fixtures to verify restart, interrupted migration, idempotent backfill,
future-schema refusal, corrupt-store quarantine and existing question/delivery reconciliation.
Rollback after a schema upgrade restores a verified compatible capture; do not point an old
binary at the upgraded file or reverse live DDL by guesswork.

Keep two export contracts:

- **Definition export**: reviewed name/purpose/instructions and non-secret desired configuration.
  Rindabox keeps its existing v1 document and adapters; memory never appears in that Git export.
- **Protected agent-state export**: versioned identity, authority mapping, entries/history,
  protection, tombstones, source policy references and knowledge/grant references. Explicit
  import validation is required on a fresh current schema. Import restores no credentials,
  active processes, runnable schedules or permissions without destination-owner reauthorization.

Same-authority recovery preserves identities. Importing into another authority creates an
explicit mapping/clone; it cannot masquerade as the original authority or carry its grants.
Source references unavailable after import render unresolved rather than broadening access.
An archive/backup is not proof of a portable restore. Record which source content and deletion
history are carried, and retain compatibility fixtures for supported versions.

Update Threading's [persistence inventory](../architecture/persistence.md) and Rindabox's
`infra/backup-recovery.md`, `src/server/portable-data.ts` and contracts when implementation adds
durable records. Include binding intents/projections, authority IDs and purge state, not only
memory bodies. Protected storage stays outside repositories and checked-in definitions; logs
and performance fixtures contain no private memory text. Recovered services remain paused
until the existing owner workflow validates them.

## Scaling contract

These are proposed design targets, not measured results. Measure the real shipping path before
claiming latency or footprint compliance. Reuse the controller's bounded pagination vocabulary.

| Dimension | Typical fixture | Stress fixture | Required behavior |
| --- | --- | --- | --- |
| Agents | 5–20 | 1,000 registered | Indexed authority/project listing; UI constructs only viewport rows. |
| Associated chats and completed work | 10–100 per agent | 100,000 retained per agent | Indexed cursor pages; profile opening never loads all transcripts or work. |
| Current memory entries | 20–200 per agent | 10,000 per agent | Metadata pages; no eager body decoding for list/filter. |
| Revision history | A few revisions per key | 100,000 retained revisions | Indexed selected-key history and bounded page/scan work. |
| Mutations | Explicit writes at task milestones | 32 concurrent writers across hosts/chats | Atomic revision checks, bounded contention and cancellation; no lost update. |
| Opening context | A few selected facts | Maximum selection and maximum-size legacy entries | Independent aggregate budget; do not load everything then truncate it. |

Initial hard limits: retain existing 256-byte keys/32-KiB bodies; metadata/title lengths have
named constants. New listing pages return at most 50 metadata items and 64 KiB, and examine at
most one bounded candidate window before returning a continuation, including when permission
filtering is sparse. A get returns one bounded body. Opening memory returns at most 8 entries
and 8 KiB total; oversized selected entries are skipped with an explicit retrieval reference,
never silently truncated. Keep definition text under its separate existing/validated budget.
These byte limits are safety bounds, not claims about a model's exact token count.

Start with indexed key/prefix/title discovery and active-state filtering. Do not expose an
unindexed arbitrary substring scan as "search". Add full-text retrieval only with a measured
index, bounded candidate work and freshness/forgetting tests. Limits on new writes must not
prevent reading/exporting an oversized legacy working set; provide a visible capacity error
and a migration path if measured storage growth later justifies an aggregate quota.

Measure background query/context preparation separately from main-thread mount and scrolling.
Capture matched before/after median and tail/max timings and visible-view/footprint counts.
History growth should leave key lookup, first-page opening and one-entry edits independent of
unrelated retained history. No file, SQLite, codec, SSH or subprocess wait runs on the main actor.

## UI and customization boundary

Apply [theme boundaries](../THEME_BOUNDARY.md), the
[design system](../architecture/design-system.md),
[iOS themed dialogs](../IOS_THEMED_DIALOGS.md) and the
[customization gate](../extensions/CUSTOMIZATION_SURFACE_AUDIT.md#gate-for-every-new-surface)
before implementation.

The initial durable surfaces are the agent profile/memory editor and binding/access decisions.
Their entities are AgentRef, memory namespace/key/revision and binding generation. They are
deliberately host-only: Threading retains identity, authorization, revisions, archive/purge,
source disclosure, command routing, keyboard/focus and exact mutation results. Use existing
Design form/table/editor parts and register stable host popover IDs where used. The native
fallback works with extensions disabled, invalid or reloaded.

The chat's agent identity mark can be a display-only value in an existing protected component
after the public data-exposure review. A sidebar replacement may customize presentation and
invoke admitted host commands; it cannot replace access decisions or receive memory content
merely because it renders the row. No memory-body extension API is part of v1. Document this
boundary and generated catalog changes with the implementation.

Use existing lazy, virtualized list owners. Verify the actual app shell in light/dark themes,
app text scales, narrow windows, focus/error/conflict states and empty/unavailable profiles.
iPhone v1 needs truthful bound-chat identity and ordinary chat behavior; remote memory editing
can follow after a separately verified host mutation route. Do not claim phone editing ships
because the Mac profile exists.

## Dependencies on other agent work

Identity/memory can ship before cross-host mail, new trigger probes or the usage ledger. Share
AgentRef and host/authority distinctions with those drafts before adding their wire contracts.
Mail routes to one selected endpoint; deterministic trigger probes keep their cursor/event
state outside learned memory; usage receipts retain worker/work/execution attribution and add
the resolved AgentRef for aggregation without guessing it from names or transcript text.

Enabling schedules, mail wake or background memory processing keeps the existing host approval,
source-revision and spend-admission boundaries. Creating an agent grants none of them. The
usage-ledger draft owns token/cost accounting and trigger admission owns spend checks; memory
does not introduce another budget engine. If a ledger is not yet available, do not display a
zero cost for memory/model work whose usage is unknown.

## Implementation slices

### Slice 1 Portable identity and memory

Owner: `Packages/ThreadingDomain`, `Packages/ThreadingController`, `Targets/Controller` and their
tests/scripts. Add typed identities/mapping, current binding admission, memory metadata,
protection, list/history/tombstone/purge operations and capability negotiation. Preserve existing
worker wire contracts and execution fences. Add the protected portable-state contract and
synthetic old/current fixtures before enabling a schema upgrade in the app or consumer.

Exit: macOS and Linux portable tests prove concurrent revisions, revoked/stale bindings,
legacy memory continuity, deletion behavior and export/import on a fresh schema. A fixture worker
still completes the existing ask/answer/finish lifecycle through real CLI/MCP transport.

### Slice 2 Local chats with persistent agents

Owner: Threading's session/store/lifecycle, MCP catalog/admission and context delivery paths.
Add host commands for create/promote/bind/unbind/new-chat/inspect. Open an app-owned agent store
using the existing persistence isolation rules. Add scoped read and write tools for capable
runtimes, profile snapshots and bounded opening context. Verify native and terminal adapters;
initial provider coverage is Claude and Codex because their shipping transports are already
known. Other runtimes show unsupported persistent-memory capability until their real tool and
context paths pass the same checks.

Exit: two fresh conversations of a synthetic agent recall the same corrected fact across app
restart/provider change; an unbound or unrelated chat cannot read it. A crash between association
commit and UI update recovers one identity. A resumed chat receives each context revision once.

### Slice 3 Agent profile and memory UI

Owner: Design-based profile/picker/editor, command registry, local/iPhone projections, evidence
coverage and user guide. Ship promotion/new-chat flows, identity marks, read-only indication,
memory inspection/correction, conflict handling and separate remove/forget/archive actions.
Surface capacity, unavailable authority and revoked access without an empty-success state.

Exit: inspected renders from the real app shell and an isolated UI journey prove creation,
second-chat recall, correction/conflict, archive and forgetting. The scaling fixture validates
first page, scrolling and one-entry mutation without eager history construction.

### Slice 4 Rindabox adoption and remote chats

Owner: a separate Rindabox branch/worktree for shared contracts, catalog, controller adapters,
agent work operations, consumer transport, tests and recovery documentation; Threading owns the
native connection/chat adapter. Preserve agent/worker UUIDs, accepted access, instruction
snapshots, schedules, feedback and delivery policy. Keep PostgreSQL definitions authoritative.
Add owner-authorized memory inspection/correction and separately grantable client read/write
operations. Implement the source-visibility contract before exposing additional audiences.

Exit: the complete Rindabox matrix above passes through the application, actual MCP clients and
a Threading remote chat against synthetic data. Definition Git export contains no live memory.
Old compatible consumers still work or receive an explicit version refusal. Backup and fresh
import rehearsals pass; deployment and a live production trial are separate owner-authorized
operations, not inferred from passing local tests.

### Slice 5 Scheduling and agent mail alignment

Owner: existing automation commands/controller recipes and the agent-mail implementation.
Local schedules can select a persistent local agent; remote schedules remain consumer-owned.
Memory identity is the agent, while schedule/work identity and per-run grant checks stay intact.

Align the mail draft before implementing new addresses: keep existing session/worker addresses
as concrete endpoints and add an owner-resolved logical AgentRef destination. One owner-selected
endpoint receives agent-directed mail; never broadcast to every open chat. Moving custody must
not silently duplicate mailboxes or memory. Durable delivery receipts remain separate from
saved facts. This alignment does not require cross-host mail to ship before local memory.

Exit: a scheduled fixture run recalls the same fact as its interactive chat, the Mac can be
offline for hosted work, and mail routing has no ambiguity with several chats of one agent.
Cross-host migration/replication remains deferred beyond explicit protected export/import.

## Verification and completion criteria

| Level | Required cases |
| --- | --- |
| Portable core | Old/current/future/corrupt stores; idempotent UUID adoption; two writers with one revision winner; owner-maintained entry rejection; binding revoke/rebind racing a write; tombstone revision continuity; purge removes current/history/index bodies; protected import and unresolved source references. |
| Scoped transport | Real CLI and stdio MCP discovery/invocation; wrong/stopped execution credentials; wrong chat token; read-only write rejection; no model-selected identity; capability mismatch; bounded sparse pages; same semantic results across worker and chat adapters. |
| App integration | Promotion at a settled turn; association recovery; unrelated/unbound isolation; project eligibility; two chats and restart; profile/instruction change on fresh/resumed work; provider/account continuation; deleted chat cleanup; side-chat read-only behavior. |
| Rindabox integration | Existing managed recipe regression; target-memory denial for access planners; current membership/source revocation; task-only members cannot inspect full memory; approval remains application-bound; same UUID after adoption; schedules/questions/delivery unaffected; API/MCP parity and native consumer transport. |
| Product evidence | Real-shell renders and isolated journeys for profile, promotion, memory list/editor, conflict, unavailable/revoked access, archive and forget. Verify focus in the real host, not only a detached control. |
| Performance | Deterministic typical/stress sets; history-independent indexed operations; bounded scanned candidates/context bytes; background versus main-thread timings; visible views, scroll behavior and footprint. |
| Recovery | Synthetic migration interruption; compatible rollback rehearsal; encrypted same-release capture/restore; versioned fresh-schema import; revoked grants/services do not become active merely through restore. |

Use the repository's smallest relevant regression first. Portable implementation runs
`scripts/test-controller.sh` on macOS and Linux. Threading changes require the applicable
`scripts/test.sh` lanes and architectural/theme/main-actor gates; run `all` before a commit.
Rindabox changes run its focused regressions then `npm run gate`, plus `make backup-test-db` for
schema/auth changes and `make infra-syntax` for infrastructure changes. Missing prerequisites
or skipped suites are reported as unverified. No test uses production data or the developer's
real session/agent store.

Add behavior evaluations after deterministic contracts pass. With synthetic Signe/Vera cases,
evaluate cross-chat recall, corrections replacing stale facts, no recall for another agent,
use of references after source revocation, memory containing hostile instructions, and absence
of invented approval. Record provider/runtime versions, context bytes, tool calls and latency;
repeat model trials and inspect failures rather than relying on one successful response.

This plan has not executed runtime, migration, production, UI or model evaluations. Its own
validation is limited to source inspection, opened public guidance, document links and review
against the user's requests. Shipping claims require the evidence listed above.

## Decisions and deferred work

Decisions for implementation: durable agent identity; optional chat association; preserve
Rindabox UUIDs; reuse the portable store; explicit memory writes and bounded retrieval; current
server-side admission; separate definition/private-state exports; one memory custodian; and
consumer-managed remote chats that retain application policy.

Deferred: automatic transcript extraction, embeddings, background reflection, multi-writer
offline replication, several independent workers for one agent, implicit permission inheritance,
automatic mailbox provisioning, and a provider-independent transcript merge. Each needs its own
observed requirement and verification. A later richer Agents navigation surface can build on
the same identity contracts without delaying the first useful local and Rindabox paths.

Before starting slice 1, recheck the working trees and current schema version. Before slice 4,
verify the proposed native OAuth route against an actual supported authorization implementation
and enforce the source-derived memory policy in Rindabox contract tests. These are bounded
implementation spikes, not permission to bypass existing authorization or postpone the Rindabox
acceptance matrix.
