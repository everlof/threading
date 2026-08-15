# Archived Herdr competitive findings

Researched 2026-07-28 against https://herdr.dev, its public documentation and stats,
the public repository at commit `e16d7d8c07a20f5ee0b4111808680bbcfd7df9ac`, the
v0.7.5 source and changelog, GitHub issues, and Hacker News discussion.

Herdr is Apache-2.0 and implemented as a Rust terminal multiplexer. Its code does not port
literally to Threading's Swift/AppKit architecture. The useful material here is product shape,
protocol design, failure handling, and evidence of what developers value.

The short version: **this is a real competitor for the "many agents, one place" promise, but
not for the whole product.** Herdr is strongest *under* the agents: PTYs, persistence, SSH,
processes, panes, and agent-to-agent automation. Threading is strongest *around and after* the
agents: readable conversations, governed permissions, subagent inspection, Git review,
accounts and limits, visual/browser work, and native remote collaboration.

That distinction should shape both the roadmap and the positioning. "A native macOS app for
organizing coding-agent sessions" undersells Threading into Herdr's strongest category. "The
native place to supervise, understand, review, and continue agent work" describes the part
Herdr deliberately does not build.

---

## 1. What it is

**"Agent multiplexer that lives in your terminal."** Herdr is a background session server
plus one or more terminal clients. The server owns PTYs and processes. The client draws a
mouse-capable TUI in the terminal the user already chose.

Its hierarchy is:

```
named session
└── workspace ("space" in the UI; normally a project)
    └── tab
        └── pane (a real PTY)
            └── recognized agent, ordinary shell, server, test, editor, …
```

This is deliberately not an agent wrapper and not a reconstructed conversation. Claude Code,
Codex, OpenCode and the rest draw their own interfaces in real terminal panes. Herdr adds:

- workspace/tab/pane organization;
- semantic `blocked` / `working` / `done` / `idle` / `unknown` state;
- detach and reattach while the original processes keep running;
- local and SSH clients;
- a CLI and newline-delimited JSON socket API;
- process/session detection and native agent conversation restore;
- worktree creation and grouping;
- executable plugins and a GitHub-indexed marketplace.

The binary uses Ratatui for the outer UI, a forked `portable-pty` for process hosting, and
vendored `libghostty-vt` for terminal state. `src/` is approximately 200,000 lines of Rust,
excluding the vendored terminal engines and website.

### Traction

The growth is unusually fast and is itself competitive evidence:

- first commit 2026-03-23; first release 2026-03-27;
- 21,889 GitHub stars and 1,474 forks on the research date;
- 117 open issues and 11 open pull requests;
- 76 stable + preview releases in 127 days according to Herdr's public stats page;
- latest stable release v0.7.5, 2026-07-21;
- Herdr reports 257,637 total installs, defined as release-asset downloads plus Homebrew
  installs, not unique active users;
- 150+ automatically indexed community plugin repositories;
- two successful Hacker News submissions: 166 points / 110 comments and
  404 points / 178 comments.

Most core commits still come from one maintainer. The velocity is a strength; the release
count, issue history and terminal-compatibility surface are also a warning about pre-1.0
stability and maintenance load.

---

## 2. Feature inventory

### Terminal workspace

- Persistent workspaces, tabs and binary-split pane layouts.
- Mouse click, drag-resize, text selection and right-click menus.
- tmux-style prefix bindings plus configurable direct shortcuts.
- Split, move, swap, resize, zoom, close and rename panes.
- Temporary overlay panes and session-modal popups.
- Copy mode with search and vi-like motion.
- OSC 8 and visible-URL clicking.
- Host-terminal theme following, built-in themes and custom colors.
- Narrow-screen mobile UI over an ordinary SSH terminal.
- Experimental Kitty graphics overlays for plugin panes.
- Native Windows/ConPTY beta; Linux and macOS stable.

### Agent awareness

- Automatic foreground-process detection.
- Bundled screen manifests for 19 agent families; 21 kinds accepted by `agent start`.
- Official integrations for lifecycle state, native session identity, or both.
- State rolls from agent → pane/tab/workspace and into a global Agents panel.
- `done` means settled but not yet seen; focusing it turns it into `idle`.
- Custom stable agent names such as `reviewer`.
- Custom state labels and arbitrary presentation tokens, without changing semantic state.
- User-facing `herdr agent explain` diagnostics for why a state was selected.
- Remote manifest updates for known agents, plus local overrides.

The supported list is materially broader than Threading's: Pi, OMP, Copilot CLI, Devin,
Kimi, Hermes, Qoder, Droid, OpenCode, Kilo, MastraCode, Claude Code, Codex, Cursor Agent,
Amp, Grok, Antigravity, Kiro and Maki, with Gemini and Cline detected but described as less
thoroughly tested.

### Persistence and remote use

- Closing or detaching the client leaves the background server and every pane process alive.
- Named sessions create independent runtime namespaces and sockets.
- A cold server restart reconstructs workspace/tab/pane shape and working directories.
- Optional pane-history persistence replays recent screen contents after a restart.
- Native agent session restore resumes 14 documented agent conversation formats.
- Experimental live handoff transfers live Unix PTY masters to a replacement Herdr server.
- Direct attach opens one agent or terminal rather than the whole Herdr UI.
- `herdr --remote host` makes the local binary a thin client to a Herdr server over SSH.
- Ordinary `ssh host; herdr` works from any terminal, including phone terminal apps.
- The local thin-client path bridges a local clipboard image to a remote temporary file.

### Agent and script automation

Three distinct primitives keep the API understandable:

| Primitive | Owns |
|---|---|
| Layout | Workspaces, tabs and pane topology |
| Pane | Raw terminal input, output, processes and output waits |
| Agent | A recognized live occupant and its semantic lifecycle |

The CLI/API can create and rearrange layouts, start a named agent in an existing shell pane,
submit prompts, send logical keys, read recent output, wait for lifecycle state, subscribe to
events, and export or apply declarative layouts.

The installed binary prints the exact JSON Schema for its protocol. `session.snapshot`
provides one bootstrap snapshot and clients then follow resource events. This is a credible
third-party client surface, not a collection of undocumented commands.

### Git and worktrees

- Git branch and ahead/behind status in workspace rows.
- Create a worktree on a new or existing branch.
- Open an existing checkout as a grouped child workspace.
- Remove a checkout safely, then offer force only when Git rejects dirty removal.
- Branches are never silently deleted.
- Worktree operations are also available through the socket API and emit lifecycle events.

There is **no first-party diff review, staging, commit graph, checkpoint or PR flow.** Community
plugins add file browsing and review, but those are separately installed executable programs,
not Herdr's product boundary.

### Plugins

Plugin v1 is intentionally language-agnostic. A package is a directory with
`herdr-plugin.toml` and arbitrary commands. A plugin can declare:

- install-time build commands;
- one-shot startup hooks;
- user-invoked actions;
- event hooks such as `worktree.created`;
- terminal panes in overlay, popup, split, tab or zoomed placement;
- keybindings;
- URL link handlers;
- platform requirements and a minimum Herdr version.

The full CLI is the plugin API. Runtime context arrives through environment variables and a
JSON context blob. Installation from GitHub shows source and command previews, can pin a ref,
and records the resolved commit.

The marketplace is operationally clever: any public GitHub repository tagged
`herdr-plugin` appears in the index on its next 30-minute refresh. It is cheap to publish and
cheap for Herdr to operate.

The security model is the opposite of Threading's. A Herdr plugin is unsandboxed code running
as the user, with the user's environment and full Herdr CLI. The marketplace is explicitly
unreviewed. Herdr validates provenance and the manifest, not behavior.

### Notifications and customization

- In-app, host-terminal or system notification delivery.
- Separate done/request sounds and per-agent sound policy.
- Active-tab notification suppression.
- A `notification.show` API for plugins and scripts.
- Declarative multi-row Agent and Space sidebar layouts.
- Built-in, custom and metadata-backed sidebar tokens.
- A plugin can install a transient filtered/sorted Agent view without rewriting config.
- Shell completion, generated config reference, reloadable TOML and extensive diagnostics.

### What it deliberately does not do

Herdr has no first-party:

- native conversation renderer;
- structured message/tool/permission history;
- transcript import, turn folding, turn rail or side-chat tree;
- subagent transcript navigator;
- built-in diff review, staging or commit composer;
- account identity, rate-limit or token-usage model;
- browser automation or visual display panel;
- per-chat remote membership, collaboration or approval rights;
- process sandbox for agents or plugins.

Those omissions are not backlog accidents. "Real terminal views, not a wrapped
interpretation" is central to its position.

---

## 3. Implementation deep-dive — the mechanics worth studying

### 3.1 One status authority, with explainable fallback

Herdr first identifies the pane's foreground process. It then assigns one authority for the
agent's lifecycle:

- a complete integration owns state when installed and actively reporting;
- otherwise a screen manifest reads the live bottom of the terminal buffer;
- session-only hooks may report the native conversation identifier without becoming state
  authority.

Herdr explicitly keeps Claude Code and Codex on screen-manifest state. Their hooks report a
session identifier for restore, but Herdr considers their hook coverage incomplete for
approval outcomes, interrupts and other transitions.

The bundled Claude and Codex manifests are priority-ordered rules over named regions:
OSC title, OSC progress, the prompt body, the part after the latest horizontal rule, the last
few non-empty lines, or the whole recent buffer. Rules declare evidence such as `contains`,
`regex`, `line_regex`, `all`, `any` and `not`.

Important rules:

- the detector reads the live bottom buffer, not the user's scrolled viewport;
- transcript viewers can match `skip_state_update`, preserving the previous real state;
- `blocked` requires known visible blocker evidence;
- an unmatched known agent falls back to `idle`, not a scary false blocker;
- remote manifests can update known-agent screen rules without a binary restart;
- local overrides win over cached remote and bundled definitions.

`herdr agent explain` returns the effective manifest source/version, every evaluated rule,
matched rule, region preview, evidence counts, visible-state flags, skipped-update reason and
fallback reason. That is excellent operational design: a heuristic is acceptable when the
product can show exactly what it believed and why.

**Take for Threading:** the single-authority rule already exists in
`SessionActivityTracker.reportsOwnActivity`; keep it. Add a user-visible **Why this status?**
diagnostic that names process state, hook authority, last accepted lifecycle event, fallback
activity evidence, notification state and rejection reason. Do not adopt a remotely updated
screen-regex system for two deeply integrated agents unless the direct signals prove
insufficient.

### 3.2 Five distinct persistence promises

Herdr documents persistence as five different mechanisms rather than one vague claim:

| Mechanism | Preserves |
|---|---|
| Detach/reattach | Original processes, PTYs, layout, terminal and agent conversation |
| Snapshot restore | Layout, cwd and focus; processes become new shells |
| Pane-history replay | Recent pixels-as-ANSI, not the old process |
| Native agent restore | The provider conversation, restarted through its official resume command |
| Live handoff | Original processes and PTYs across a same-machine server replacement |

This honesty is a product strength. "Session persistence" usually hides which of process,
screen, layout and conversation is actually durable.

Live handoff is the most technically distinctive part. On Unix:

1. The old server rejects new mutations and pauses every PTY reader.
2. It snapshots serializable app state.
3. It duplicates the PTY master file descriptors.
4. It spawns the replacement in import mode.
5. It sends the manifest and FDs over a private Unix socket with `SCM_RIGHTS`.
6. The new server rebuilds runtimes, binds public sockets and reports ready.
7. Only then does the old server commit and exit without signaling pane process groups.

Before commit, failure rolls back to the old server. Exactly one process may read each PTY.
No failure path may close the final master FD. Alternate-screen programs stay alive but get
best-effort visual continuity until they redraw.

**Take for Threading:** first adopt the vocabulary. Be precise about live process, layout,
screen and conversation durability in product copy and diagnostics. A background
`SessionKeeper` that owns PTYs separately from the AppKit process is a valuable foundational
bet, but it is not a feature-sized borrow. It would change lifecycle, remote access, updates,
permissions and crash recovery together and deserves its own architecture plan.

### 3.3 Race-aware agent automation

The control plane has several details worth copying:

- Creation commands return generated stable IDs; callers never predict them.
- `agent start` targets an existing shell pane and returns only after the expected agent is
  observed in that same terminal.
- Agent names attach to the current live occupant and clear when it exits or is replaced.
- `agent prompt --wait` submits and begins its wait in one server request, eliminating the
  race between two commands.
- A wait pins the resolved occupant, so a later process in the same pane cannot satisfy it.
- A prompt sent from a non-working state must produce a lifecycle transition within five
  seconds or returns `agent_prompt_stalled`.
- Moving a live pane returns its new ID and retains the old ID as an alias for the process'
  inherited `HERDR_PANE_ID`.
- Snapshot-plus-event clients resnapshot after reconnect instead of replaying an assumed gap.

There is also an honest limit: full-screen agent TUIs use the alternate screen, whose old rows
do not enter host scrollback. `agent read --lines 500` cannot recover content the terminal
never retained. The documented fallback is the agent's own transcript or asking it to write a
result file.

**Take for Threading:** expose a small, capability-scoped session control plane:
`list_sessions`, `get_session`, `focus_session`, `start_session`, `send_prompt` and
`wait_for_session`. Keep read/focus separate from start/prompt authority. Pin waits to a
`SessionID` plus process generation, and make submit+wait atomic. This would let extensions,
automations and—only when explicitly allowed—one agent coordinate another without raw UI
driving.

### 3.4 SSH is the remote protocol

Herdr's remote story has two paths and almost no product infrastructure:

- SSH into the machine and run Herdr there.
- Run `herdr --remote host`; a local thin client bootstraps or finds the matching remote
  binary, starts/attaches the server and streams the interface over SSH.

The second path keeps local keybindings and can bridge a local image clipboard. Both use the
user's existing OpenSSH authentication and work on a headless server.

This is much less capable than Threading's remote product: no native conversations, scoped
sharing, permission evidence, APNs, attachments, themes or guest roles. It is also dramatically
simpler, cloud-independent, cross-platform and available from almost any device.

**Take for Threading:** remote *host execution* is the opening, not another phone UI. A future
Mac client that owns the rich native interface while a small SSH-side helper owns PTYs and
agent files would combine the strongest part of each product. It is a separate problem from
the current iPhone/browser mirror, which assumes the Mac owns the work.

### 3.5 An ecosystem optimized for contribution speed

Herdr made four choices that explain 150+ marketplace entries:

1. Any executable language works.
2. The existing CLI is the SDK.
3. GitHub is the package registry.
4. One GitHub topic is the marketplace publication step.

Source/command preview, exact-ref pinning, resolved-commit provenance and manifest hashing make
the unsafe model inspectable. They do not make it safe.

Threading's Foundation-only Wasm SDK, capability declarations, brokered services, host-rendered
UI, preview validation and package inspection are far stronger boundaries. They also impose
more authoring friction.

**Take for Threading:** borrow discovery, provenance and installation ergonomics without
borrowing arbitrary execution. An automatic marketplace index for
`.threadingextension` repositories, a one-command install/link workflow, visible source commit,
and a public cookbook would make the safe platform feel like an ecosystem rather than only
an SDK.

### 3.6 Mouse-first TUI and the interactive landing-page demo

Herdr does not assume that choosing a terminal means choosing keyboard-only software. Every
first-use action is clickable, right-click menus expose the model, and shortcuts are learned
incrementally. HN users repeatedly praised exactly that: it does not punish someone for
forgetting bindings.

The landing page goes further. Its hero contains an interactive facsimile of the real sidebar
and terminal layout. A visitor understands the product before installing it. The install
command sits beside the demo, and live public adoption numbers are one click away.

**Take for Threading:** the product itself is already mouse-native. The borrow is distribution:
an interactive or recorded product surface that shows session attention, native conversation,
Git Review and remote review in one minute. Herdr's growth is not only feature evidence; it is
evidence that immediate category explanation matters.

### 3.7 The changelog exposes the terminal compatibility tax

Herdr's release history is a dense map of terminal edge cases:

- Kitty keyboard protocol, CSI-u, bracketed paste and modifier ambiguity;
- SGR mouse leakage, focus events, cursor flicker and host color queries;
- Unicode grapheme crashes, wide cells and CJK labels;
- alternate-screen repaint stalls and scrollback CPU;
- Windows ConPTY behavior, clipboard boundaries and shell differences;
- SSH version skew, authentication prompts and connection reuse;
- agent UI changes invalidating state recognition.

The team resolves these quickly, which is a strength. The breadth is also the cost of "runs in
your existing terminal, on every platform." Threading's single native host and forked SwiftTerm
still carry a terminal tax, but the matrix is much smaller and visual/native surfaces can
escape terminal limitations entirely.

---

## 4. Public feedback

### Praise

The consistent positive themes across HN, reviews and the project's own issue history:

- **Agent attention is the killer feature.** A user running 10+ agents said Herdr was the best
  tool they had tried for seeing what needed attention.
- **Real detach/reattach changes behavior.** Users attach to the same live work from a desktop,
  another laptop and a phone.
- **Mouse-first makes a multiplexer accessible.** Several users who found tmux cumbersome
  praised being able to click first and learn bindings later.
- **It preserves first-party CLI fidelity.** No wrapper delay, lost slash command or missing
  provider UI.
- **The control API is genuinely differentiated.** Agents and scripts can create, address,
  read and wait on other agents through semantic operations.
- **The local posture is easy to trust.** One binary, no account, no telemetry and plain SSH.
- **Breadth matters.** Users do not have to choose a supervisor based on which agent CLI they
  happen to be testing this month.
- **Execution and onboarding are unusually strong for a new TUI.** One HN user described the
  first experience as working exactly as expected; another said they could not go back.

### Complaints and risks

1. **"Why not tmux?" is a persistent comprehension problem.** Multiple HN comments reduced
   Herdr to mouse support plus agent status. The API, state model and restore path are real
   differences, but the product must keep proving that they are enough to switch.
2. **Performance has been visible to users.** Reports include delayed typed text, scrollback
   stutter/100% CPU (#512), high CPU regressions (#560), and 40–500 ms alternate-screen repaint
   stalls (#1295). Several have been fixed; the category remains sensitive because users
   compare it to their direct terminal.
3. **Agent detection drifts with CLI releases.** Historical failures include stuck-working
   (#198), working↔blocked flicker (#409), subagent work appearing idle (#509), and wrappers
   hiding Claude (#803). Remote manifests reduce time-to-fix but do not remove the dependency
   on another product's pixels.
4. **Terminal input is a very long tail.** Paste, selection, mouse leakage, modifier keys,
   IMEs, host themes, SSH and ConPTY occupy a large share of the changelog.
5. **The first-party review layer is thin.** HN users asked for built-in diffs and described
   keeping an editor/lazygit beside Herdr. File and diff plugins prove demand, but the core
   product delegates the review contract to unsandboxed third parties.
6. **Cold restart is not process resurrection.** Arbitrary shells, servers and tests become
   fresh shells. Screen replay and agent conversation restore are separate mechanisms; live
   handoff is Unix-only, experimental and opt-in.
7. **Plugins and agents run with the user's authority.** Herdr is not a safety boundary.
8. **Pre-1.0 velocity cuts both ways.** 76 releases in 127 days means fast fixes and frequent
   protocol/behavior movement. Core development is still highly concentrated in one maintainer.
9. **The terminal-only ceiling is real.** Users wanting a readable conversation, structured
   tool history, evidence-bounded approvals, native diffs or visual/browser output need
   companion plugins and apps—or a different product.

### What the demand says

The strongest signal is not that developers want four panes. tmux already proved that. They
want an **attention allocator**:

- show every live agent;
- distinguish working from waiting;
- remember unseen completions;
- keep work alive when the supervising surface disappears;
- make the state scriptable so orchestration does not require polling.

Threading's sidebar indicators and notifications solve the human half. Herdr's traction validates
adding the machine-addressable half and making the durability promise sharper.

---

## 5. Direct comparison

| Capability | Herdr | Threading | Edge |
|---|---|---|---|
| Primary surface | TUI inside the user's terminal | Native macOS app, native/terminal conversation surfaces | Different |
| Agent breadth | 21 recognized kinds, 14 documented native resume paths | Claude Code and Codex, deeply integrated | Herdr breadth; Threading depth |
| Original process survives UI detach | Yes; server owns PTYs | Conversations resume by provider ID; no detached PTY server | **Herdr** |
| Cold restart | Layout + optional screen replay + supported agent resume | Stored sessions + provider transcript/session resume | Comparable for conversations; Herdr broader |
| Arbitrary shell/server persistence | Yes while server lives; experimental live upgrade handoff | Shell drawer lives with the app/session | **Herdr** |
| SSH/headless host | First-class, no GUI or cloud | Mac-hosted remote mirror via browser/iOS | **Herdr** |
| Native mobile/collaboration | Any SSH terminal; ecosystem clients | Native iOS, browser, sharing roles, scoped approvals, APNs | **Threading** |
| Attention state | Process + one authority + manifests + explain | Hooks/provider events + guarded PTY inference + notifications | Herdr explainability; Threading direct depth |
| Agent-driven orchestration | Full layout/pane/agent CLI and socket API | Session-private task tools; no cross-session control plane | **Herdr** |
| Readable native conversation | No | Markdown, tool rows, turn folds, minimap, permissions | **Threading** |
| Subagent understanding | Agents are sibling pane occupants | Structured nested subagents and child transcripts | **Threading** |
| Conversation import/fork | Provider restore only | Import, side chats, account migration, surface switching | **Threading** |
| Git worktrees | Create/open/remove and group | Checkout-aware creation, repository/branch grouping | Comparable |
| Git review | Branch/ahead/behind; community plugins | Live native diffs, images, scopes, staging, commit graph/commit | **Threading** |
| Accounts and quota | Inherits whatever shell launches; no product model | Multiple logins, effective model, rate-limit windows and usage | **Threading** |
| Browser and visual work | Terminal links and experimental graphics/plugins | Governed shared browser, screenshots, diagnostics, display/compare | **Threading** |
| Notifications | In-app, terminal, system and sound | macOS actionable routing + scoped mobile/APNs path | Different |
| Extensions | Arbitrary executable, full CLI, 150+ index | Capability-scoped safe Wasm + governed host UI | Herdr reach; Threading safety |
| Platform reach | Linux/macOS; Windows beta; any SSH client | macOS host + iOS client | **Herdr** |
| Local trust posture | No account, telemetry or hosted control plane | Local sessions/no default telemetry; remote relay opt-in | Comparable locally |

---

## 6. Where Herdr is strong

### 6.1 It owns process durability, not just conversation durability

This is the biggest substantive advantage. An agent, dev server, test watcher, REPL and shell
remain the exact same processes after the user closes the client. Threading can faithfully resume
the provider conversation, but that is not the same promise.

### 6.2 It runs where the code lives

A Linux server, Mac Mini, sandbox VM or SSH host is a normal installation target. The user's
laptop is only a client. Herdr wins users whose development machine has no GUI or whose security
model keeps agency off the personal laptop.

### 6.3 It supports the changing agent market

Recognizing 21 agent kinds lowers adoption friction and makes Herdr the neutral layer. A user
can try a new CLI without waiting for Herdr to build a native chat renderer.

### 6.4 The control plane is a product, not an implementation detail

The agent skill, CLI, JSON Schema, stable IDs, snapshot/events, atomic waits and occupant
identity make Herdr composable. This enables visible multi-agent workflows that are awkward in
Threading today.

### 6.5 Its category and install story are exceptionally clear

One line says what it is, one command installs it, and an interactive hero demonstrates it.
The public stats and open repository reinforce momentum.

### 6.6 The extension loop is fast

Any language, GitHub as registry, full CLI as API, one topic to publish. It traded safety for
ecosystem velocity and received the velocity.

### 6.7 It treats fallbacks as things that need explanations

Status manifests, `agent explain`, protocol mismatch errors, config checks and explicit
persistence tables make an inference-heavy runtime diagnosable.

---

## 7. Where Threading is strong

### 7.1 It understands the work, not only the terminal containing it

Threading's Native surface has typed user messages, assistant replies, reasoning/tool lifecycle,
edit diffs, permissions, turn boundaries, turn folds, scrolling rules and a navigation rail.
Herdr can show the provider's TUI but cannot build product behavior from the conversation.

### 7.2 Review is first-party and connected to the session

Live file watching, Last Turn/Branch/Staged/Unstaged/Commit scopes, syntax-highlighted diffs,
image comparison, staging, hunk staging, commit history and committing are already one click
from the session. Herdr's core stops at branch status and worktree operations.

### 7.3 Accounts and limits are modeled where decisions happen

Threading understands multiple Claude/Codex logins, effective models, scoped limits, reset times,
usage pace, transcript token accounting and conversation migration. Herdr inherits shell
environment and has no concept of who pays for a pane or whether the chosen model is nearly
unavailable.

### 7.4 Remote access is a collaboration product

Threading has device-bound membership, one-chat invitations, view/collaborate/approve roles,
bounded permission evidence, owner-only checkout data, native iOS rendering, APNs, attachment
containment, typing presence and immediate revocation. Herdr's SSH path is better for personal
operator access to a host; it does not address sharing a reviewed agent session with another
person.

### 7.5 Visual and browser work escapes the terminal

The display panel, governed shared browser, HTML, screenshots, image/PDF attachments, visual
comparison, console/network diagnostics and private-input boundary support work Herdr must
delegate to other terminal programs or plugins.

### 7.6 Conversation continuity is richer

Importing outside sessions, Claude side chats, surface switching, moving a conversation between
accounts, transcript-grounded replay and structured nested subagent inspection all treat the
conversation as the durable object. Herdr's durable object is primarily the PTY and layout.

### 7.7 Extensions have a real safety boundary

Threading's safe extensions cannot import AppKit/SwiftUI or draw arbitrary chrome. They declare
capabilities, receive sanitized host snapshots and render through host components. Herdr tells
the user to inspect code and then runs it with full user authority. Herdr is more open; Threading
is far more governable.

### 7.8 Native macOS depth is an asset

Accessibility, menus, notifications, Quick Look, Finder, Keychain restraint, image drag/drop,
system permission sheets, themed controls and rendered-state testing create a level of desktop
integration a cross-platform TUI should not try to match.

---

## 8. Strategic reading

### Herdr is a competitor

For a developer whose need is "I have six agent terminals and keep losing them," Herdr is
free, popular, cross-platform, fast to install, remotely attachable and broader than Threading.
If Threading is described as a terminal organizer with status dots, Herdr wins the comparison.

### Herdr is not the same product

For "What did the agent do? Is this diff safe? Which child found this? Can I approve it from my
phone? Which account has capacity? Can it test the page and show me the result?", Herdr's
terminal-first boundary leaves most of the question unanswered.

### It can also be infrastructure beneath us

Herdr's own comparison says worktree/review apps own a different layer. Conceptually, a future
Threading remote-host adapter could use Herdr or a Herdr-shaped helper for durable PTYs while
keeping the Mac/iOS supervision surface. That does not mean adding a hard dependency; it means
the architecture proves the layers can be separated.

### The positioning implication

Do not lead with:

> Organize coding-agent sessions in one native app.

That invites a checklist against multiplexers.

Lead with the outcome Herdr does not offer:

> Supervise agent work as work: readable conversations, live changes, permissions, subagents,
> accounts and review—on Mac and iPhone.

Terminal fidelity remains a feature, not the category.

---

## 9. Borrowables — ranked

Ranked for Threading's current shape, not for abstract impressiveness.

1. **A scoped session control plane.** Start read-only with list/get/status/focus, then gated
   start/prompt/wait. Preserve `SessionID` and process-generation identity; make prompt+wait
   atomic. This unlocks automations, extensions and deliberate agent coordination.
2. **Supported-agent capability tiers.** Publish three honest levels:
   Native conversation / Managed terminal / Runs as a terminal. Add declarative terminal-agent
   descriptors for launch, process identity, resume and icon so breadth does not require a
   native renderer. Herdr proves the market values breadth; our depth remains explicit.
3. **"Why this status?" diagnostics.** Show authority, process generation, last hook report,
   last meaningful output, suppression reason, attention reason and notification disposition.
   Herdr's `agent explain` is the right standard for heuristic product state.
4. **Remote host execution.** Keep the native Mac UI but let a small SSH-side runtime own the
   agent, transcript and checkout where the code lives. This is the largest market-expanding
   move and the hardest implementation.
5. **Extension marketplace mechanics.** GitHub discovery, source commit provenance,
   install/link command, manifest preview and a cookbook—implemented on top of Threading's safe
   extension model.
6. **Worktree lifecycle events and recipes.** Let a project define or an extension respond to
   `worktree.created` with bounded setup steps. Herdr's events and T3's setup scripts validate
   the same demand from two different architectures.
7. **A detached session keeper.** Separate PTY ownership from the AppKit process so closing or
   updating the UI need not interrupt work. Treat this as a foundational program, not a quick
   feature.
8. **Snapshot + event semantics for extension clients.** Threading's extension host already has
   snapshots and cursor events; preserve and advertise the pattern as the route to future
   live external clients. Herdr demonstrates why resnapshot-on-gap and stable IDs matter.
9. **Agent-view projections.** Allow saved attention filters such as "blocked everywhere +
   this project's working sessions" without flattening the repository/checkout/branch tree.
   This is a safer version of a fully customizable sidebar.
10. **Declarative layouts/project recipes.** Named shell/server/test panels that can be
    recreated without pretending those terminals are conversations. The session shell drawer
    remains per conversation; project tools belong beside it.
11. **Direct session attach/link.** A CLI command that focuses a Threading session, prints its
    status, or opens its remote URL would improve scripts and notification integrations without
    exposing raw UI automation.
12. **Persistence vocabulary.** Document process, terminal screen, layout and conversation
    durability separately everywhere. This is almost free and prevents an important promise
    from being misunderstood.
13. **Interactive product demo.** Show a real supervision loop—blocked session → permission
    evidence → changed files → Git Review → iPhone handoff—before asking someone to install.
14. **Public capability and compatibility matrix.** Per provider, say exactly which surface,
    lifecycle, permissions, resume, subagents, accounts and usage features are verified.
15. **Install/update simplicity.** Herdr's one-command path and transparent release channel are
    a distribution benchmark even though Threading is a signed native app rather than a CLI.

### Near-term shortlist

1. Status explanation
2. Read/focus/wait session API, designed for later gated prompting
3. Provider capability tiers + declarative managed-terminal agents
4. Extension marketplace/provenance
5. Worktree-created events and setup recipes

### Foundational bets

1. Remote host runtime over SSH
2. Detached PTY/session keeper

The two foundational bets should be designed together. A helper that can own a PTY after the
Mac UI disconnects is already close to the helper needed on a remote host; building two
unrelated lifecycle protocols would waste the architectural opportunity.

---

## 10. Lessons — what not to copy

1. **Do not trade the safe extension boundary for plugin count.** Marketplace reach is worth
   copying; arbitrary code with full user authority is not.
2. **Do not screen-scrape when a direct typed signal exists.** Herdr needs manifests because it
   supports many opaque terminal UIs. Threading's two deep integrations can demand stronger
   evidence.
3. **Do not flatten conversation semantics into pane semantics.** A pane is not a turn, a
   process is not a conversation, and recent screen output is not a transcript.
4. **Do not chase platform breadth inside the current app target.** Windows/Linux support is a
   different product architecture. A portable remote helper is a better seam.
5. **Do not make cross-session agent control ambient.** Herdr's processes already share one
   user's terminal authority. Threading's permission and sharing model promises finer boundaries;
   orchestration must be explicitly scoped and observable.
6. **Do not call screen replay process persistence.** Herdr's own table is the model for honest
   language.
7. **Do not let release velocity substitute for stability.** Herdr's changelog shows how much
   regression surface a terminal/runtime product can accumulate.
8. **Do not position against tmux.** Herdr has chosen and is winning that argument. Threading's
   valuable comparison is against manually reading, reviewing and coordinating agent work.

---

## 11. Sources

Primary product and source:

- https://herdr.dev/
- https://herdr.dev/compare/
- https://herdr.dev/stats/
- https://herdr.dev/docs/
- https://herdr.dev/docs/agents/
- https://herdr.dev/docs/session-state/
- https://herdr.dev/docs/persistence-remote/
- https://herdr.dev/docs/agent-automation/
- https://herdr.dev/docs/socket-api/
- https://herdr.dev/docs/plugins/
- https://github.com/ogulcancelik/herdr
- Repository snapshot `e16d7d8c07a20f5ee0b4111808680bbcfd7df9ac`
- `src/detect/manifests/{claude,codex}.toml`
- `src/detect/manifest.rs`
- `src/persist/{snapshot,restore}.rs`
- `src/app/api/`
- `src/api/schema/`
- `src/server/handoff.rs`
- `src/handoff_runtime.rs`
- `src/app/worktrees.rs`
- `src/app/api/plugins/`
- `website/src/content/blog/live-updates-without-killing-your-terminal-processes.md`
- `CHANGELOG.md`

Public feedback and issue evidence:

- https://news.ycombinator.com/item?id=48714802
- https://news.ycombinator.com/item?id=48756578
- https://www.bitdoze.com/herdr-agent-multiplexer/
- GitHub issues: #198 (stuck working), #261 (worktree layouts), #409 (status flicker),
  #509 (subagent state), #512 (scrollback CPU), #560 (high CPU), #714 (host theme),
  #803 (wrapped-agent detection), #893 (handoff/plugin persistence), #1116 (keyboard
  protocol), #1158 (per-pane idle CPU), #1295 (alternate-screen repaint stalls), #1340
  (Apache-2.0 relicensing), #1382/#939 (mouse escape leakage), #1468 (Windows updater),
  #1471 (selection), #1528/#1533 (Windows input)

Threading comparison:

- `USER_GUIDE.md`
- `docs/REMOTE_ACCESS.md`
- `docs/architecture/native-conversations.md`
- `docs/architecture/session-activity.md`
- `docs/architecture/git.md`
- `docs/architecture/accounts.md`
- `docs/architecture/agent-browser.md`
- `docs/extensions/API_V1.md`
- `docs/extensions/AGENT_AUTHORING.md`
