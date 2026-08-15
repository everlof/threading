# Archived omg.dev competitive findings

Researched: 2026-08-13

Source snapshot: [`BennyKok/omg.dev@301e29f`](https://github.com/BennyKok/omg.dev/tree/301e29f79af42226967b8d7df1f1586ed8d305a0)

Snapshot version: `0.1.362`

## Short version

omg.dev is an MIT-licensed, self-hostable control plane for running coding-agent
CLIs on a computer and controlling them through a desktop or phone browser. It is
not merely a remote terminal. It normalizes transcripts from several agents,
creates isolated worktrees, exposes diff and file views, delegates child sessions,
runs recurring watcher agents, tracks usage, and gives completed work a
cross-session **Shipped** feed.

Its strongest ideas for Threading are reliable delivery into terminal UIs, explicit
agent-produced completion evidence, and low-noise recurring findings. Its main
tradeoff is the security boundary: the local server intentionally has no
application authentication, and several adapters start agents in permission-bypass
modes. Tailscale or an equivalent trusted network is therefore part of the product's
security model rather than a transport convenience.

## 1. Product and architecture

The public product consists of:

```text
React/Vite installable PWA
          │ HTTP, WebSocket, Web Push
          ▼
Bun/TypeScript local server ── SQLite transcript and product state
          │
          ├── tmux-backed agent CLIs
          ├── SDK/command-file agent harnesses
          ├── git worktrees
          └── optional outbound hosted relay
```

The documented installation creates a user service listening on loopback by
default. The PWA can be exposed through Tailscale, or connected through an
experimental outbound relay. A hosted omg.dev service is optional; users can run
the local system without an application account and bring their existing provider
accounts or API tokens.

At the snapshot, the repository was less than two months old, had versioned through
`0.1.362`, and showed unusually high release velocity. That makes it a meaningful
product signal but also a moving target. The code is concentrated: the primary web
application component alone is roughly 23,000 lines, and most repository commits
come from the author and release automation.

## 2. Feature inventory

### 2.1 Agents, sessions, and conversations

The session catalog exposes eight branded interactive agent families:

- Claude Code
- Codex
- OpenCode
- Jcode
- Cursor
- Grok
- Pi
- GitHub Copilot

Claude and Codex each have terminal and SDK-style adapter variants, so the source
contains ten adapter keys rather than ten distinct agent brands. Hermes appears as
an automation backend, not as a normal interactive-session adapter.

Claude, Codex, Grok, Cursor, and the SDK harnesses are normalized into a web-native
transcript of messages, thinking, and tool activity. A SQLite index makes older
history searchable without replaying every transcript. The product can create,
resume, archive, search, filter, and pin sessions, and it surfaces live states such
as busy, idle, blocked, and finished.

Wide screens can pin up to four conversations side by side. Narrow screens become a
mobile card list. A full terminal and a per-session terminal overlay remain
available when the normalized conversation is insufficient.

Most adapters support durable recovery. Copilot and Jcode are explicitly
process-bound exceptions. tmux also lets a running session outlive a browser or
local-server disconnect, though sleeping or shutting down the host still stops
useful computation.

### 2.2 Input delivery, queueing, and steering

The terminal adapter does more than paste text and hope. Its send queue serializes
input per session, captures the TUI before and after delivery, detects whether text
landed in the input box or transcript, and retries or reports failure. This is a
substantive reliability feature for CLI wrappers.

The UI offers **queue** and **steer** actions. Queue waits behind the active turn.
In omg.dev, steer interrupts the current turn and then sends the replacement; it is
not the same as Threading's provider-aware mid-turn steering behavior.

### 2.3 Worktrees, files, and review

For git repositories, managed sessions use a separate worktree by default. Branches
are named for the session and the worktrees live under a user-level directory. The
cleanup path writes an ownership marker and prefers leaking a directory over
deleting an ambiguous target, which is a sound safety property.

The session diff compares the worktree with its merge base or fork point and
includes committed, uncommitted, and untracked changes. It supports unified and
split presentation, lazy per-file loading, and explicit size/file-count limits.
Binary content is not rendered.

This is a review surface, not a source-control workflow. There is no first-party
staging interface, commit composer, commit graph, pull-request flow, or inline
review commenting. An agent can perform those tasks in the terminal, but the
product does not model them.

The Files panel is likewise intentionally agent-mediated. It can browse and read
files. A user may compose an edit in a diff editor, but saving turns that draft into
a patch request sent to the agent; the browser does not write the source file
directly. That keeps the agent as the single writer.

### 2.4 Remote, mobile, notifications, and voice

The PWA is the mobile client. The recommended private remote path is Tailscale,
which exposes the entire local server to peers on that network. The alternative
relay is an outbound WebSocket protocol; the repository defines the client and
protocol but does not ship a general relay implementation. omg.dev operates the
hosted counterpart.

Web Push notifications cover questions, completion, shipped results, automation
findings, and some error states. They use VAPID and encrypted push payloads rather
than a native iOS application or APNs.

There are no per-conversation shares, View/Collaborate/Approve roles, device-scoped
credentials, or an equivalent revocation boundary. The UI has user assignment and
filtering concepts, but they are coordination metadata rather than authorization.

The PWA includes realtime/batch dictation and push-to-talk. Self-hosted speech
recognition uses ElevenLabs Scribe, while the hosted system can relay
transcription. No text-to-speech surface was found. Threading deliberately requests
no microphone permission today, so this is a genuine product difference rather
than an implementation gap hidden behind an OS capability.

### 2.5 Delegation and autonomous agents

An MCP server lets an agent list, find, create, message, reparent, and close other
sessions. Child sessions can use a different harness, inherit context, and appear in
a visible parent/child hierarchy. The implementation caps nesting depth and defines
progress and terminal-status messages so the parent can tell whether delegated work
actually finished.

Separately, an **auto agent** combines a prompt, schedule, selected backend, and
usually read-only tools. Each run emits at most one finding and otherwise stays
silent. Dismissed findings feed back into later runs, while repeated unresolved
findings accumulate an occurrence count and notify on a restrained cadence. This is
closer to a recurring repository watcher than Threading's scheduled message.

The repository also contains an older markdown-defined collector/report system for
repository, git, GitHub, security, and model context. The two mechanisms show the
same direction: persistent observation is treated as a first-class workload.

### 2.6 Artifacts and the Shipped feed

Agents can publish images, video, and sandboxed HTML artifacts. Script-backed HTML
artifacts can refresh through a bounded server-side command, while iframe sandbox
and content-security-policy restrictions prevent the resulting page from gaining
general network access.

The more distinctive feature is **Shipped**. An agent calls a dedicated tool only
for a verified final result, supplying a headline, short summary, and evidence, and
explicitly deciding whether the session should close. Results then appear in a
cross-session feed separate from the artifact gallery.

Threading already has richer in-conversation display primitives and a managed
workspace finish handshake, but it has no comparable inbox of completed outcomes.
The Shipped feed solves a different navigation problem: “what became ready while I
was looking elsewhere?”

### 2.7 Accounts, models, usage, and resources

The UI helps install agents, authenticate through browser/device or terminal flows,
inspect account status, and select models and reasoning effort. It supports multiple
Claude accounts and provider-specific model discovery.

Usage reporting combines several unlike sources: live Claude subscription windows,
the last Codex rate-limit snapshot and plan, Grok billing endpoints, and estimated
OpenCode spend from its local database. Per-session views include token/context
breakdowns and process resource usage. Global controls include a concurrency limit,
pause, and idle-session archival. Some caps are hosted-plan concerns rather than
local technical limits.

### 2.8 Extension and embedding seams

The full web application is distributed as reusable React packages, making it
possible for another React host to mount the client or use its protocol/client
layers. This is a practical embedding seam.

The operator extension mechanism is much thinner. An environment variable can
inject arbitrary external ESM after the application bundle and extensions can add
navigation tabs; an optional backend proxy can inject a bearer token. These modules
are trusted, unsandboxed code without a manifest, capability review, semantic
rendering protocol, or marketplace boundary. It should not be treated as equivalent
to Threading's extension SDK.

### 2.9 Features not found

No first-party implementation was found for:

- browser automation, DOM annotation, visual comparison, or a browser execution
  ledger;
- staging, commit graph, structured commit creation, or pull-request review;
- application-level authentication and per-conversation authorization;
- a tamper-evident execution or approval audit ledger;
- native desktop or iOS clients; or
- a sandboxed, capability-declared application extension system.

Playwright appears in dependency and test-related paths, but not as a user-facing
agent browser-control surface.

## 3. Direct feature matrix

| Area | omg.dev | Threading | Competitive reading |
|---|---|---|---|
| Product shape | Self-hosted web/PWA control plane | Native Mac workspace with native iOS and browser companions | Different center of gravity: ubiquitous browser access versus native host depth |
| Agent breadth | Eight interactive agent families; terminal and SDK adapters | Claude Code, Codex, Grok, OpenCode | omg.dev leads on breadth; Threading can keep a smaller, deeper compatibility contract |
| Conversation UI | Normalized web transcript plus terminal | Provider-native structured UI plus Original UI/terminal fallback | Broadly comparable philosophy |
| Attention model | Status cards, filters, pins, four-column stage | Five attention states and a focused conversation | omg.dev favors simultaneous monitoring; Threading favors prioritization |
| Process persistence | tmux sessions survive client/server disconnects | Conversation persists, but local agents terminate when the Mac app quits | omg.dev has a real unattended-operation advantage |
| Input while busy | Confirmed terminal delivery; queue; interrupt-then-send steer | Editable/reorderable queue plus provider-aware steer | Each leads in a different layer; omg.dev's delivery verification is worth studying |
| Workspace isolation | Automatic worktree by default | Opt-in managed workspace with explicit finish/merge/disposal | omg.dev is lower-friction; Threading has a more complete lifecycle contract |
| Git review | Read-only session diff | Six review scopes, staging, graph, structured/image diffs, PR/MR providers | Threading is substantially deeper |
| Files | Read-only browser; draft edits become agent patch requests | Read-only Activity/Files views and external-editor handoff | Similar single-writer instinct; omg.dev makes patch delegation explicit |
| Remote security | Network perimeter; local server has no app auth | Paired device identities and scoped per-conversation roles | Threading is materially stronger for collaboration and least privilege |
| Mobile | PWA and Web Push | Native iPhone companion, browser, APNs | omg.dev is easier to deploy; Threading has deeper platform integration |
| Voice | Dictation and push-to-talk | No microphone access | omg.dev leads if voice input is desired |
| Delegation | MCP-created cross-harness child sessions and visible lineage | Visible subagent trees and scoped controls | omg.dev's agent-spawns-agent API is a notable differentiator |
| Recurring automation | Scheduled watcher agents with deduplicated findings | Scheduled messages | omg.dev models autonomous observation explicitly |
| Results and artifacts | Sandboxed artifacts plus cross-session Shipped feed | Rich display surfaces inside conversations | Threading's rendering is richer; omg.dev's outcome inbox is stronger |
| Usage | Provider limits, context, token/cost estimates, resources | Limits/history/recovery plus local tokens and cost | Both are serious; data sources and certainty differ by provider |
| Browser work | No first-party browser agent surface found | Visible automation, evidence, audits, and exact execution ledger | Threading has a major differentiated subsystem |
| Extensibility | Trusted ESM injection and embeddable React modules | Capability-governed extensions with semantic native UI | Threading's boundary is safer and more productized |

## 4. Mechanics worth studying

### 4.1 Confirm delivery into agent TUIs

Terminal wrappers fail at the seam between “bytes written” and “prompt accepted.”
omg.dev treats that as a state machine: serialize sends, inspect the terminal,
classify delivery, retry safely, and show failure. Threading's Original UI and any
future terminal-only integration should have similarly explicit confirmation rather
than equating a PTY write with acceptance.

### 4.2 Make completed outcomes navigable across sessions

Shipped combines a deliberate agent action, verification evidence, and a lifecycle
decision. Threading could connect the same idea to its stronger managed-workspace
finish handshake: a “Ready” inbox could link the final message, evidence, diff,
workspace disposition, and pending approval without weakening any existing safety
gate.

### 4.3 Treat recurring findings as a noise-control product

The most useful automation detail is not cron. It is the contract of zero or one
finding, feedback from dismissal, recurrence tracking, and restrained notifications.
If Threading grows scheduled messages into watchers, these anti-noise semantics and
explicit read-only defaults matter more than the scheduling UI.

### 4.4 Default isolation, conservative cleanup

Automatic worktrees make parallel work the normal path. Ownership sidecars make the
cleanup boundary inspectable and deliberately conservative. Threading's opt-in
managed workspace has the stronger completion lifecycle, but the amount of setup
required before isolation begins should continue to be challenged.

### 4.5 Separate the protocol from the app package

Publishing protocol, client, React bindings, and the complete application as
separate packages lowers the cost of embedding the control plane elsewhere. The
exact React approach does not transfer to AppKit, but maintaining clean seams
between transport, product state, and presentation does.

## 5. Risks and constraints

### Network reachability grants control

The project's security document is explicit: anyone who can reach the server can
list, start, and control agents. A deployment mistake, permissive LAN, or overly
broad tailnet is therefore an authorization mistake. The experimental relay adds a
second trust dependency even though its connection is outbound.

### Several agents run with elevated trust

Claude terminal and SDK variants bypass permissions; Cursor disables its sandbox
and uses its permissive mode; Grok is also configured for bypass. Codex is the
notable adapter using workspace-write with on-request approval. The UI can surface
questions and some permission selectors, but that should not be mistaken for a
central permission-policy broker.

### Normalization depends on unstable terminal behavior

Some providers have structured SDK streams; others require transcript parsing and
terminal-screen recognition. The latter also powers trust prompts, plan selectors,
and input confirmation. Supporting eight agent brands is valuable, but it creates a
large compatibility matrix whose failures may be silent or version-specific.

### Fast growth raises maintenance questions

The snapshot is very young and release-heavy, with large central source files and a
small human contributor base. That does not negate the feature set, but architectural
choices and public contracts should be treated as provisional until they survive
more provider releases and multi-user deployments.

## 6. Recommendation for Threading

Keep omg.dev on the direct-competitor list and re-snapshot it before any roadmap
decision involving unattended operation, mobile control, or multi-agent delegation.

The most promising ideas to prototype are:

1. a cross-session **Ready/Shipped** inbox backed by Threading's existing finish
   handshake and evidence surfaces;
2. explicit acceptance confirmation for text sent through terminal-only adapters;
3. recurring read-only watchers with zero-or-one findings, dismissal feedback, and
   recurrence-aware notification thresholds; and
4. an optional wide monitoring surface for several active conversations, especially
   on iPad or the browser companion.

Do not copy the network-perimeter authorization model, blanket permission bypasses,
or unsandboxed extension injection. Threading's paired-device roles, permission
broker, browser audit ledger, managed-workspace lifecycle, and semantic extension
boundary remain substantive differentiators rather than incidental complexity.

## Primary sources

- [Repository README at the researched revision](https://github.com/BennyKok/omg.dev/blob/301e29f79af42226967b8d7df1f1586ed8d305a0/README.md)
- [Security model](https://github.com/BennyKok/omg.dev/blob/301e29f79af42226967b8d7df1f1586ed8d305a0/SECURITY.md)
- [Coding-agent adapters](https://github.com/BennyKok/omg.dev/blob/301e29f79af42226967b8d7df1f1586ed8d305a0/src/coding-agent-adapters.ts)
- [Confirmed send queue](https://github.com/BennyKok/omg.dev/blob/301e29f79af42226967b8d7df1f1586ed8d305a0/src/sendq.ts)
- [Worktree lifecycle](https://github.com/BennyKok/omg.dev/blob/301e29f79af42226967b8d7df1f1586ed8d305a0/src/worktree.ts)
- [Session diff service](https://github.com/BennyKok/omg.dev/blob/301e29f79af42226967b8d7df1f1586ed8d305a0/src/session-diff.ts)
- [Remote-access design](https://github.com/BennyKok/omg.dev/blob/301e29f79af42226967b8d7df1f1586ed8d305a0/docs/remote-access.md)
- [Agent-facing capabilities](https://github.com/BennyKok/omg.dev/blob/301e29f79af42226967b8d7df1f1586ed8d305a0/src/omg-capabilities.ts)
- [Script-backed HTML artifacts](https://github.com/BennyKok/omg.dev/blob/301e29f79af42226967b8d7df1f1586ed8d305a0/docs/script-backed-html-artifacts.md)
