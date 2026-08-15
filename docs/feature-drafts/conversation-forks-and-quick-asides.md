# Conversation forks and quick asides

> Status: feature draft — researched and sequenced. Persistent-fork support for the existing
> runtimes and native quick asides for Codex and Grok are implementation-ready; Claude native
> asides still require a measured transport path. Prioritized **Next**, not scheduled.

Extends [`sessions.md`](../architecture/sessions.md) and
[`native-conversations.md`](../architecture/native-conversations.md). Those files remain the
source of truth for shipped behavior; this draft records the product split and provider research
that should replace the current Claude-only side-chat model when implementation begins.

## Summary

Threading currently uses **side chat** to mean a durable session fork. Both **New Side Chat** and
**Ask on the Side…** create a child `AgentSession`, persist it, nest it below its parent in the
sidebar, and give it the parent's copied conversation history. The second action is only the same
fork with its first prompt filled in.

That is one useful feature, but it is not the lightweight `/btw` or `/side` behavior people now
expect from Claude, Codex, and Grok. Those commands answer a temporary question from the parent
context without adding the exchange to the parent's conversation. The two operations differ in
lifetime, risk, presentation, and provider wire shape, so they must be separate product concepts:

| | **Fork Conversation** | **Ask Aside…** |
|---|---|---|
| Lifetime | Durable and resumable | One temporary question and answer |
| Threading record | Child `AgentSession` | No session or sidebar row |
| Parent context | Copied into an independent conversation | Read as context, never appended to |
| Tools | Full agent session, including writes | Read/search only; no workspace mutation |
| While parent works | Independent child may run beside it | Must remain available |
| Result path | Explicit **Send Result to Parent** | Copy or insert into the parent's composer |
| Relaunch | Survives | Does not survive |

The UI should stop using *side chat* as the category name. It is already ambiguous in the market:
[Cursor 3.11 calls its durable full child conversations side chats](https://cursor.com/changelog/side-chat),
while Codex calls an ephemeral fork `/side`. Name the behavior instead.

## Product contract

### Fork Conversation

Rename the existing actions:

- **New Side Chat** becomes **Fork Conversation**.
- **Ask on the Side…** becomes **Fork and Ask…**.
- Internal names such as `isSideChat`, `addSideChat`, and `sideChatEntries` migrate toward
  `isFork`, `addFork`, and `forkEntries`. Old persisted keys remain decodable.

A fork:

- starts from the parent's latest complete durable turn in the first release;
- inherits the parent project, runtime, account, selected model/effort where representable, and
  working directory;
- receives its own provider conversation identifier and ordinary Threading session identity;
- is a full agent session with the same terminal/native-surface choices the runtime normally has;
- appears as a durable child beneath its parent and remains resumable after either process exits;
- leaves the parent transcript unchanged;
- keeps the existing explicit **Send Result to Parent** route rather than pretending transcripts
  can merge;
- creates no orphan Threading row if the provider fork operation fails.

Fork-at-selected-turn is a later additive feature. It is supported by Codex and OpenCode, but
shipping it only for those runtimes would complicate the first product contract. The first slice
uses the latest completed turn everywhere and records the provider's returned lineage when one is
available.

A fork is allowed to use tools and mutate the shared checkout. That is the point of a full child
agent, but it also means two siblings can edit the same files. Managed workspaces are the separate
answer when isolation of file changes is required; this feature must not silently create or merge
git worktrees.

### Ask Aside…

**Ask Aside…** is a one-shot, read-only question about the selected conversation:

- it is available while the parent is idle or working;
- it receives a safe snapshot of the parent's context, including the last completed material and
  whatever partial-turn context the provider's native primitive explicitly supports;
- its question, answer, thinking, and errors never enter the parent timeline or future model
  context;
- it creates no `AgentSession`, resumable provider conversation, sidebar row, usage-title
  candidate, or report-back relationship. Provider-local auxiliary usage or diagnostic records
  stay outside Threading's session model and are never replayed into the parent;
- it may use provider-owned search or read-only tools when the provider can enforce that boundary,
  but it cannot ask for permissions, write files, run mutating commands, steer the parent, or
  spawn more asides;
- it returns one answer in a dismissible panel associated with the parent session;
- it offers **Copy** and **Insert in Composer**. Insertion does not send automatically; the user
  decides whether the answer should become parent context;
- it can be cancelled independently without stopping the parent;
- Threading retains the panel state only in memory. Returning to the parent may reveal a completed
  answer, but relaunch discards it.

One live aside per parent is the first-release bound. A second request replaces a completed aside
or is refused while one is running; it is not queued behind either the parent or another aside.

Do not emulate this contract by creating a normal child session and deleting it afterwards. A
deleted transcript does not undo a tool call, file write, shell command, or external effect. A
runtime without a provider-native isolated call stays unsupported.

### Surface behavior

The first Threading-owned aside panel belongs to native Chat. It is a separate auxiliary surface,
not a second `ConversationViewController` and not another main timeline. Terminal sessions keep
the provider TUI's own `/btw` or `/side` experience where one exists; Threading should not inject
keystrokes into a TUI or try to scrape its temporary panel.

Persistent forks remain surface-independent because they create a normal Threading session. A
fork can be requested from a parent currently shown as a terminal and the child can use either
surface supported by that runtime.

## Current Threading behavior

The implementation today has one durable Claude-only primitive:

- `AgentCapabilities.forking` is granted only to Claude in
  [`Project.swift`](../../Sources/Threading/Models/Project.swift).
- `ClaudeSessionOrigin.forked` is the only typed configuration that can carry a fork birth, and
  `AgentSession.forkedFrom` is computed from that Claude-specific configuration.
- [`ProjectSidebarSessionActions.swift`](../../Sources/Threading/UI/Views/ProjectSidebarSessionActions.swift)
  exposes **New Side Chat** and **Ask on the Side…**, but both call the same durable creation path.
- [`ClaudeStreamSession.swift`](../../Sources/Threading/Core/Agent/ClaudeStreamSession.swift)
  deliberately marks `branch`, `fork`, and `btw` unsafe in native Chat. They remain usable in
  Claude's terminal UI.
- [`CodexStreamSession.swift`](../../Sources/Threading/Core/Agent/CodexStreamSession.swift) lists
  `fork` and `side`/`btw` as terminal-only even though app-server now exposes host operations for
  both semantics.
- Grok's native catalog does not host-disable `btw`, so
  [`ACPStreamSession.swift`](../../Sources/Threading/Core/Agent/ACPStreamSession.swift) currently
  sends `/btw …` as an ordinary `session/prompt`. That path requires `canSend`, joins the main
  turn lifecycle, and cannot run while the parent works. It is command passthrough, not a
  Threading quick aside.
- The Cursor ACP path measured in [the archived provider investigation](../archive/research/CURSOR_ACP_FINDINGS.md) receives
  `-32601 Method not found` for `session/fork`; the Cursor application's separate side-chat UI is
  not available through that transport.

The comment in `sessions.md` that Codex has no fork equivalent was correct when written and is now
stale. The provider matrix below is the evidence for replacing it during implementation.

## Provider research

Here *provider* means the installed agent runtime. A Grok model selected through OpenCode still has
OpenCode session behavior; it does not acquire the standalone Grok CLI's fork or aside protocol.

Research was rechecked on 2026-08-13 against official documentation and, for Grok's native aside,
the vendor's open-source implementation.

| Runtime | Persistent fork upstream | Quick aside upstream | Threading delivery |
|---|---|---|---|
| Claude | `/branch`, `/fork`, `--fork-session` | `/btw` | Keep the existing fork. Native aside waits on a measured non-TUI wire path. |
| Codex | `codex fork`, `/fork`, app-server `thread/fork` | `/side`/`/btw`, app-server ephemeral fork | Add both through the existing app-server transport. |
| Grok | `/fork`, `--fork-session`, ACP extension | `/btw`, `x.ai/btw` | Add both; the aside must use the extension, not `session/prompt`. |
| OpenCode | `--fork`, HTTP `POST /session/:id/fork` | None found | Add persistent fork only. |
| Cursor ACP | Cursor app has durable side chats; ACP `session/fork` is unsupported | No ACP aside primitive found | Offer neither until the embedding protocol exposes one. |

### Claude

[Claude's session documentation](https://code.claude.com/docs/en/sessions) says `/branch` or
`--resume`/`--continue` with `--fork-session` creates a distinct session and leaves the original
unchanged. [Its command reference](https://code.claude.com/docs/en/commands) defines `/btw` as a
quick question that is not added to the conversation.

The persistent half is the mechanism Threading already measured and ships. The TUI owns `/btw` as
a local command, while native Chat runs a different print/stream transport and explicitly refuses
that command. Before claiming native support, measure a bounded one-shot path that:

1. reads the intended parent snapshot without appending to it;
2. runs with client tools unavailable;
3. emits a separately cancellable response;
4. leaves no durable child transcript unless Claude's own documented behavior requires one.

Do not infer that combining `--resume`, `--fork-session`, print mode, and a no-persistence flag has
those semantics. That combination is a candidate probe, not an implementation decision.

### Codex

[The Codex CLI reference](https://developers.openai.com/codex/cli/reference) documents `codex
fork`, `/fork`, and the ephemeral `/side`/`/btw` experience. The
[app-server reference](https://developers.openai.com/codex/app-server) provides the embedding
operations Threading needs:

- `thread/fork` copies a stored thread into a new provider-assigned id;
- `lastTurnId` bounds the fork at a completed turn;
- `ephemeral: true` creates an in-memory fork omitted from stored thread listings;
- the returned thread identifies `forkedFromId`;
- omitting `lastTurnId` while the source is mid-turn records an interruption marker.

Persistent fork should call `thread/fork`, create the Threading child after the response supplies
its id, and then resume that thread normally. Quick aside should create an ephemeral fork and send
its one turn without routing either thread's events into the parent's timeline. The app-server
process already multiplexes thread ids, so this is a new request/result owner rather than a second
Codex transport.

The aside turn uses app-server's documented `approvalPolicy: "never"` and a `readOnly`
`sandboxPolicy`. Read-only tool output may contribute to the temporary answer, but permission
requests, writes, and external effects do not graduate into the aside contract.

Use the latest completed turn id for the first persistent-fork release. For a quick aside requested
mid-turn, use Codex's documented ephemeral behavior and keep its interruption marker inside the
ephemeral thread.

### Grok

[Grok's CLI reference](https://docs.x.ai/build/cli/reference) documents `--fork-session` alongside
a caller-selected `--session-id`, which fits Threading's existing child-id model. The
[command reference](https://docs.x.ai/build/modes-and-commands) exposes `/fork` and `/btw`.

For native Chat, Grok has a more exact path than slash-command passthrough. Its open-source ACP
handler exposes [`x.ai/btw`](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/src/extensions/feedback.rs)
with `sessionId` and `question`; it explicitly does not interrupt the current turn. The underlying
[side-call implementation](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/src/session/acp_session_impl/recap.rs)
uses one model call over a snapshot of the parent, drops client tool calls, permits hosted search,
and stores the exchange separately in `btw_history.jsonl`.

Extend the ACP request multiplexer with a side-question purpose and response callback. It must not
set the parent's `isTurnInFlight`, feed chunks to `onEvent`, or consult `canSend`; otherwise the
feature again becomes an ordinary parent turn. Version-gate the vendor extension by handling
method-not-found as unavailable rather than by assuming every installed Grok build has it.

For persistent forks, prefer the measured ACP fork extension once its request shape is pinned in a
fixture. The documented CLI `--fork-session` path is the fallback and can keep Threading's
caller-minted child id.

### OpenCode

[OpenCode's server API](https://dev.opencode.ai/docs/server/) exposes
`POST /session/:id/fork`, optionally at a message, and returns the new `Session`. OpenCode also
accepts `--session <id> --fork` from its CLI. Because OpenCode assigns `ses_…` ids, Threading must
persist the returned child id rather than manufacture one.

The HTTP operation is the cleaner contract, but Threading currently has no long-lived OpenCode
native transport. A short-lived, bounded `opencode serve` adapter can perform the fork and exit;
if the CLI path is used instead, child-id discovery must be scoped to the parent and launch window
rather than guessing from the newest global session.

No upstream native `/btw`, `/side`, or ephemeral-fork operation was found. OpenCode therefore gets
durable forks only. A plugin that happens to implement `/btw` is account-local behavior, not a
runtime capability Threading can promise.

### Cursor

[Cursor's side chats](https://cursor.com/changelog/side-chat) are durable, full agent conversations
that can be revisited and referenced back into the parent. Semantically they are closer to
**Fork Conversation** than to this draft's **Ask Aside…** despite their command names.

Threading embeds `cursor-agent` through ACP rather than through the Cursor application's chat
panel. The [archived authenticated probe](../archive/research/CURSOR_ACP_FINDINGS.md) established durable create/load/prompt
behavior but measured `session/fork` as method-not-found. Do not copy Cursor's local session store
or automate its UI. Recheck the ACP capability when the installed CLI changes; support becomes a
normal provider-adapter addition once the wire exposes it.

## Architecture

### Split the capability

Rename the static `.forking` fact to `.persistentFork`. It governs a runtime-level operation that
may start from a dormant parent and create a durable record. `AgentCapabilitiesTests` must continue
to pair every granted runtime with a real provider adapter.

Do not add `.quickAside` to the static matrix. An aside is a fact about a live native transport and
its installed version, exactly the case optional protocols exist for. Add an optional surface such
as:

```swift
@MainActor
protocol QuickAsideConversation: AnyObject {
    var quickAsideAvailability: QuickAsideAvailability { get }
    func askAside(_ question: String, completion: @escaping (QuickAsideResult) -> Void) -> Bool
    func cancelAside()
}
```

Availability is independent of `ConversationStreamSession.canSend`: the defining behavior is that
an aside can run while the main turn is in flight. Codex and Grok transports conform when their
actual wire is available; Claude conforms only after its probe succeeds. OpenCode and Cursor do
not conform.

### Make lineage provider-neutral

`forkedFrom` is a relationship between Threading sessions, not a Claude launch setting. Move it to
provider-neutral session lineage while preserving decode of the old `forkParent` configuration.
Rename `isSideChat` to `isFork`; sidebar nesting, missing-parent tolerance, cycle refusal, and
report-back behavior remain unchanged.

Provider adapters own fork birth:

- Claude and Grok can prepare a child with a caller-minted provider id.
- Codex and OpenCode perform the fork first and return a provider-minted id.
- the store commits the child only after the adapter has enough information to resume it;
- failure leaves the parent and project unchanged;
- after first successful creation, the child is an ordinary resumable session. Fork is lineage,
  not a permanent launch mode.

The coordinator must carry the parent project, account environment, working directory, model
selection, and latest completed provider turn. It must not reach through `ProjectStore.shared` to
rediscover them after an asynchronous reply.

### Keep aside state outside the timeline

Add one transient `QuickAsideState` owner per live native conversation, with states such as idle,
asking, answered, failed, and cancelling. The owner holds bounded question/answer text and a
generation id so a late response from a cancelled or replaced request cannot repaint the panel.

The panel consumes that state directly. It does not manufacture timeline `ConversationMessage`s,
write a composer draft, enter the outbox, schedule a message, alter the session title, or emit
execution-audit rows as if the parent ran a turn. Provider usage may still be recorded as a
separately attributed auxiliary call when the provider reports it; hiding cost is not part of
ephemeral semantics.

The panel must be built lazily when an aside is requested and released on conversation teardown.
Do not instantiate a hidden panel for every project session or retain copied transcript views.

## Scaling gate

- Cardinality is at most one live aside per live native conversation, not one view per persisted
  session. The view is created on demand.
- Question and answer text use the same bounded stream/block rules as conversation text; one huge
  provider response cannot become one unbounded AppKit text object.
- Persistent forks may copy a long provider transcript and consume the full context again. The
  operation runs off the main thread, reports progress, and records the cost warning in user copy.
- Provider listing/discovery is never global per sidebar reload. A fork operation is targeted by
  the parent's known provider id and project/account environment.
- Repeated aside chunks or completion callbacks are coalesced through the existing conversation
  render cadence; no per-token layout loop is introduced.

## Tests

### Product and model

- Old persisted Claude `forkParent` data decodes into provider-neutral lineage.
- Every `.persistentFork` capability has a real adapter and every adapter grants the capability.
- A child always keeps its parent runtime, project, account, and representable model settings.
- Missing parents remain top-level; cycles and self-parenting remain refused.
- Provider failure creates no child row and changes no parent state.

### Provider fixtures

- Claude's existing `--fork-session` launch and parent-unchanged tests remain green under the new
  lineage model.
- Codex fixture traffic pins `thread/fork`, returned id, `forkedFromId`, latest-turn bounding, and
  `ephemeral: true` aside routing.
- Grok fixture traffic pins the vendor fork request and `x.ai/btw`; method-not-found disables the
  action without ending the parent stream.
- OpenCode fixture traffic pins targeted HTTP fork, returned `ses_…` id, teardown, and failure.
- Cursor remains explicitly unsupported until a fixture demonstrates a provider operation.

### Quick aside

- It can start while the parent is working and the parent continues receiving its own events.
- Its question, answer, failure, and cancellation never enter the parent timeline, replay,
  outbox, title, or future prompt context.
- No mutating tool call, permission request, write, or workspace mutation can arise from the
  aside path; any permitted read-only tool activity remains attributed to the aside rather than
  the parent timeline.
- Cancel affects only the aside; Stop affects only the parent.
- A late result from an old generation is ignored.
- Switching away and back reveals the in-memory result; process teardown and relaunch discard it.
- **Insert in Composer** copies text into the existing draft without sending.
- Render evidence covers asking, answer, error, and unavailable states in both themes, Increase
  Contrast, Reduce Motion, narrow windows, and large Dynamic Type equivalents where applicable.

## Rollout

Each slice lands reviewed and green before the next begins.

1. **Terminology and lineage.** Rename the shipped durable UI to **Fork Conversation** and **Fork
   and Ask…**; move lineage out of `ClaudeSessionOrigin`; preserve old state decoding and current
   sidebar/report-back behavior. Rename `.forking` to `.persistentFork`.
2. **Persistent provider coverage.** Add Codex through app-server, Grok through its pinned
   fork operation, and OpenCode through a bounded server adapter. Leave Cursor unavailable.
3. **Aside state and panel.** Add `QuickAsideConversation`, its transient state owner, a lazy
   design-system panel, cancel/copy/insert actions, and the lifecycle and scaling tests.
4. **Grok and Codex asides.** Wire `x.ai/btw` first, then Codex app-server ephemeral forks. Remove
   their misleading native command-passthrough/terminal-only catalog entries only when the host
   action owns the full lifecycle.
5. **Claude measurement and delivery.** Run the bounded native-transport probe. Ship Claude native
   asides only if the isolation, no-tools, cancellation, and persistence contract is demonstrated;
   otherwise retain terminal `/btw` and record the native gap as gated.
6. **Durable documentation.** Move the shipped contracts and provider matrix into `sessions.md`
   and `native-conversations.md`, update `USER_GUIDE.md`, and reduce this draft to a pointer.

## Explicit non-goals

- Merging transcripts or file changes from a fork.
- Automatically sending an aside answer into the parent.
- Making asides durable, searchable, or visible in the sidebar.
- Synthesizing asides for unsupported runtimes with a temporary ordinary session.
- Automating Cursor's application UI or reading private Cursor conversation storage.
- Adding fork-at-selected-turn before latest-turn parity exists across the supported runtimes.
- Treating model backends inside OpenCode as separate Threading runtimes.
