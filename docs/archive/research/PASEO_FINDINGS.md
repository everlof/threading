# Archived Paseo competitive findings

Researched: 2026-08-22

Source snapshot: [`getpaseo/paseo@7c43077`](https://github.com/getpaseo/paseo/tree/7c430777bfb3117eb1d359eddb69235ea308930e)

Snapshot version: `0.5.0-beta.5`

## Short version

Paseo is an AGPL-3.0 daemon-plus-clients control plane for coding-agent CLIs. A
Node daemon runs the agents on a machine you own; an Electron desktop app, an
Expo iOS/Android app, a browser app, and a CLI all connect to it over the same
WebSocket protocol. It is the closest competitor we have researched: it ships
worktree isolation, structured provider conversations, diff review with pull
requests, browser automation, cross-provider subagents, cron schedules, voice,
plugins, and usage readings, on macOS, Windows, Linux, iOS, Android, web, and
terminal.

It is also the largest by adoption. The repository was created 2025-10-13 and by
the research date had 14,651 stars, 1,557 forks, 968 open issues, and roughly
5,088 commits, of which one person wrote the overwhelming majority. Five beta
releases shipped between 2026-08-18 and 2026-08-22.

Where Threading stays ahead is the trust boundary and the native surface, and both
are narrower leads than the feature list suggests. Paseo's access control is a
single optional daemon password with no roles, its browser automation is one global
switch that includes arbitrary JavaScript evaluation with no per-origin grant, its
plugins are documented as unsandboxed in-process code on the daemon machine, and its
push notifications route through Expo's hosted service and can fall back to putting a
pending tool's arguments on a lock screen. Where Paseo is ahead is reach: platforms, providers, remote execution hosts, voice, an SDK, and
a real contributor community.

## 1. Product and architecture

```text
Electron desktop  ┐
Expo iOS/Android  ├── WebSocket ──> Node daemon ──> agent CLI subprocesses
React web app     │   (direct, or   (per machine)   (Claude Code, Codex, ...)
paseo CLI / SDK   ┘    E2E relay)         │
                                          ├─ PTY terminals (xterm.js client)
                                          ├─ workspace services + port proxy
                                          ├─ MCP server for agent orchestration
                                          └─ optional Hub registration
```

Package layout at the snapshot, with TypeScript/TSX line counts including tests:

| Package | Lines | Role |
|---|---|---|
| `packages/app` | ~410k | Expo client shared by iOS, Android, web, and the Electron renderer |
| `packages/server` | ~380k | The daemon: agents, workspaces, git, terminals, browser broker, MCP |
| `packages/cli` | ~29k | `paseo` command line |
| `packages/protocol` | ~23k | Wire schemas shared by daemon and clients |
| `packages/desktop` | ~24k | Electron shell and the browser-automation host |
| `packages/relay` | ~3.3k | Client half of the end-to-end encrypted relay |
| `packages/plugin` | ~731 | Plugin SDK surface |

One client codebase serves every screen. The desktop app is Electron rendering the
same React Native Web tree as the phone. The claim on the site is that "macOS,
Windows, and Linux are all primary targets. None of them are a port," which is
accurate in the sense that no platform gets a hand-built native surface.

Daemon state is atomic JSON files under `$PASEO_HOME`, zod-validated on read, not a
database. Agent timelines were moved out of full-transcript rewrites in beta.5.

Product vocabulary differs from ours in a way worth noting. Paseo's unit is the
**workspace**, not the chat: a project contains workspaces, and a workspace holds
agent sessions, terminals, browsers, and diffs as tabs. The documentation states the
position directly: "Paseo is organized around workspaces, not chats." Threading's
sidebar makes the conversation the unit and hangs the working directory off it.

## 2. Feature inventory

### 2.1 Providers and conversations

Paseo ships no agent of its own. It launches CLIs the user already installed and
authenticated, in two tiers:

- **Bundled adapters** for Claude Code, Codex (via its app-server protocol),
  OpenCode, Pi, OMP, and Copilot, with mode, model, thinking-level and feature
  metadata per provider.
- **A one-click ACP catalog** of 37 entries in `packages/app/src/data/acp-provider-catalog.ts`:
  Cursor, Gemini, Grok, Hermes, Kimi, Qwen Code, Amp, Cline, goose, Junie, Devin,
  Factory Droid, Mistral Vibe, GLM, MiniMax, Poolside and the rest. Any other agent
  speaking the Agent Client Protocol can be added by configuration.

Conversations render as structured timelines with tool-call rows, not terminal
scrollback, and the terminal is a separate session type rather than a fallback.
Sessions started outside Paseo can be imported (`agent/import-sessions.ts`).

**Steering** shipped in 0.5.0-beta.1 for Codex and Claude, with OpenCode following
in beta.4: text typed during a running turn is delivered into the turn instead of
interrupting it. Threading has no equivalent seam today.

### 2.2 Workspaces, worktrees, scripts, and services

Every workspace declares an isolation mode, `local` or `worktree`. Managed worktrees
live under `$PASEO_HOME/worktrees/` keyed by a hash of the source checkout, get a
generated branch name, and are removed after the last workspace referencing them is
archived. Setup and teardown hooks run around that lifecycle, and the agent sees
`$PASEO_SOURCE_CHECKOUT_PATH` and `$PASEO_WORKTREE_PATH`.

A committed `paseo.json` at the repository root declares setup and teardown
commands, scripts, long-running services, and terminals. It is read from the
committed version of the base branch, so an uncommitted edit on another branch
cannot change what a new workspace runs. This is the same idea as Threading's
`.threading.json`, with two additions we do not have: services get an allocated port
from a per-workspace registry, and `service-proxy.ts` publishes each one under a
routed hostname with local and public proxy URLs. A dev server started in a
workspace is therefore openable from the phone through the daemon connection.

`auto-archive-on-merge` closes a workspace when its pull request merges.

### 2.3 Review, forges, and pull requests

The explorer is a persistent pane with its own tabs, so files, changes, and the pull
request stay open beside the chat. Diff rendering has a folder tree, ordered file
list, an explicit too-large state, and inline comments; beta.1 notes large diffs
staying responsive while expanding and commenting.

Forge support is broader than ours: GitHub, GitLab, Gitea, Forgejo, and Codeberg
each have an adapter and a view. Pull-request panels show a checks summary grouped
by status with failures first.

The git action set is commit, pull, push, pull-and-push, create PR, merge PR by
squash/merge/rebase, the three auto-merge toggles, merge branch, merge from base,
and discard changes. There is **no staging surface**: no index, no per-hunk stage.
Commit is whole-worktree.

### 2.4 Remote, mobile, and notifications

Two transports. The **relay** is the default path for phones: the daemon connects
outbound to an open-source Elixir relay, pairing happens by QR code or link, and the
two ends derive a shared key by Curve25519 ECDH and encrypt with XSalsa20-Poly1305.
The daemon refuses commands before the handshake completes, and the relay is
designed to be untrusted. Relay is off until the user enables it. The alternative is
a **direct** connection over LAN, Tailscale, a Unix socket for CLI-only use, or a
reverse proxy in front of the bundled web UI.

Native apps ship on the App Store and Google Play, and the daemon can serve the web
app itself from the same origin as its API (`paseo daemon start --web-ui`).

Push notifications are the one place where content leaves the machine.
`push-service.ts` posts to `https://exp.host/--/api/v2/push/send`, Expo's hosted
service. The payload built by `agent-attention-notification.ts` carries a title, the
agent id, the workspace id, and a body of up to 220 characters: for a finished turn,
the markdown-stripped tail of the assistant's last message; for a permission
request, the request title and description, falling back to a JSON dump of the
tool's `input` when those are absent. Threading signs its own APNs provider request
with a `.p8` key and talks to Apple directly.

### 2.5 Orchestration, subagents, and schedules

`Enable Paseo tools` injects an MCP catalog into every launched agent, delivered
through the provider's native tool interface where one exists. Tools cover agents
(`create_agent`, `send_agent_prompt`, `get_agent_status`, `cancel_agent`,
`archive_agent`, `kill_agent`, `update_agent`, `get_agent_activity`,
`set_agent_mode`), workspaces (`create_workspace`, `list_workspaces`,
`rename_workspace`, `archive_workspace`), plus scripts, terminals, and schedules.

The distinctive claim is that Paseo subagents cross provider boundaries: a Claude
orchestrator can spawn a Codex worker in a worktree-isolated workspace and read its
diff back. Spawned work appears in a **Subagents track**; Paseo subagents open as
full editable sessions while provider-native subagents stay read-only timelines.

Three orchestration skills ship as slash commands and install through
`npx skills add getpaseo/paseo`: `/paseo-handoff` writes a self-contained briefing
and hands the task to another provider, `/paseo-advisor` spawns a single second
opinion, `/paseo-committee` forms two contrasting high-reasoning agents that analyse
only and never edit.

Scheduling has two shapes, both cron-backed. A **schedule** starts a fresh agent on
a cadence with a prompt, repo, and agent settings. A **heartbeat** sends a prompt
back into an existing agent so it reassesses the same conversation, which is how
they express "watch CI until it passes."

### 2.6 Browser automation

`packages/server/src/server/browser-tools/tools.ts` defines 22 tools:
`browser_list_tabs`, `browser_new_tab`, `browser_snapshot`, `browser_click`,
`browser_fill`, `browser_wait`, `browser_type`, `browser_keypress`,
`browser_navigate`, `browser_back`, `browser_forward`, `browser_reload`,
`browser_screenshot`, `browser_upload`, `browser_hover`, `browser_select`,
`browser_drag`, `browser_logs`, `browser_evaluate`, `browser_scroll`,
`browser_resize`, `browser_close_tab`.

The model is ours in shape: an accessibility-tree snapshot with `@e3`-style refs
that expire when the page changes, real dispatched input events, waits for
visibility and stability. Tabs are scoped to a workspace and open in the background.
Execution is desktop-only; the daemon brokers to a connected Electron app and fails
with `browser_no_host` when none is attached.

The gate is `browserTools.enabled` in the daemon config: one global boolean.
`policy.ts` reads nothing else. There is no origin allowlist, no per-site grant, and
no record of what was visited. `browser_evaluate` runs arbitrary JavaScript in the
page, and browser-profile sharing for authenticated testing is opt-in per host.

### 2.7 Voice

First-class and local-first. Speech runs ONNX models on CPU by default, downloading
`parakeet-tdt-0.6b-v2-int8` for STT and `kokoro-en-v0_19` for TTS into
`$PASEO_HOME/models/local-speech` on first start, with a v3 STT model covering 25
European languages by auto-detection. OpenAI is an alternative provider per feature.
Voice reasoning reuses an already-authenticated agent provider in a hidden session
rather than adding a cloud voice stack, and reaches tools through an MCP stdio
bridge. There is a dedicated `voice-permission-policy.ts`.

### 2.8 Usage and accounts

`services/quota-fetcher/providers/` reads plan usage for Claude (including a
keychain path that had to learn about multiple credential items), Codex, Copilot,
Cursor, Grok, Kimi, MiniMax, and Z.ai. The client renders these as balance bars and
a settings section.

This is a usage **reading**, not a recovery system. There is no parked-session
state, no reset-time continuation policy, and no send-later queue in the source.

### 2.9 Plugins

Experimental, added in 0.5.0-beta.1. Plugins are TypeScript with React Native
components; they contribute workspace panels, Command Center items, global
surfaces, application themes, daemon behaviour, and composer attachment sources, and
they reach every connected client including phones. Installation is
`paseo plugin install /path`, enablement is explicit in Settings.

The security model is stated plainly in the documentation: plugins are "trusted
local code," "backend code runs unsandboxed with access to the daemon machine, and
client contributions run inside the Paseo app," with no sandboxing, intended for
personal use rather than distribution.

A `@getpaseo/client` TypeScript SDK connects to the daemon WebSocket for external
integrations, and the CLI is documented as reaching everything the app can.

### 2.10 Hub

A separate layer above daemons, self-hostable with an embedded database or run as a
hosted service whose registration is currently closed. Daemons register with it; it
starts agents from GitHub, Slack, and Discord activity, deploys `.paseo/hub.yml` and
`.paseo/workflows/*.yml` from a repository on push, and keeps an activity record of
what arrived, what matched, and what ran. Guided setup landed in beta.5.

### 2.11 Features not found

Searched the snapshot and found no equivalent of: a hash-linked execution audit
ledger, per-conversation roles or any authorization beyond one password, an iOS
Simulator surface, a host-owned media/document player, curfew or wind-down
deadlines, rate-limit recovery policies with scheduled continuation, a
capability-governed out-of-process extension boundary, or a crash-recovery ledger
with held-back restoration.

## 3. Direct feature matrix

| Capability | Threading | Paseo |
|---|---|---|
| Primary surface | Native macOS AppKit; native iOS companion; browser | Electron desktop, Expo iOS/Android, web app, CLI, all from one React tree |
| Platforms for the host | macOS on Apple silicon | macOS, Windows, Linux, Docker, any Node host |
| Interactive agents | Claude Code, Codex, Grok, OpenCode | 6 bundled adapters plus a 37-entry one-click ACP catalog and arbitrary ACP agents |
| Native structured conversation | Yes, with terminal fallback | Yes; terminal is a separate session type |
| Steering into a running turn | No | Yes, for Claude, Codex, OpenCode |
| Durable process after client disconnect | Local agents end when the Mac app quits | Daemon owns lifecycle; clients are detachable |
| Isolated git worktrees | Opt-in managed workspaces with a finish/merge/disposal handshake | First-class isolation mode with setup/teardown hooks and refcounted removal |
| Repository-declared scripts | `.threading.json`, visible-terminal execution | `paseo.json` read from the committed base branch, plus services with allocated ports |
| Dev-server access from the phone | No | Yes, per-workspace service proxy with routed hostnames |
| Read-only diff review | Six scopes, structured and image diffs | Folder tree, ordered files, inline comments, too-large state |
| Stage, commit, PR/MR | Yes, including staging | Commit, push, PR, three merge modes, auto-merge; no staging surface |
| Forges | GitHub, GitLab | GitHub, GitLab, Gitea, Forgejo, Codeberg |
| Mobile and remote | Paired devices, native iOS and browser, direct APNs | Store apps on iOS and Android, E2E relay or Tailscale, self-served web UI, push via Expo's hosted service |
| Scoped collaboration and roles | Per-conversation View, Collaborate, Approve | None; one optional bcrypt daemon password |
| Visible delegation hierarchy | Yes | Yes, and cross-provider; Subagents track |
| Recurring autonomous watchers | No; scheduled messages are narrower | Yes; cron schedules plus heartbeats into a live agent |
| Usage and limit visibility | Account limits, history, recovery estimates, tokens, cost | Plan usage for eight providers; no recovery or continuation policy |
| Rich artifacts/results | Display panel, attachments, media, charts, scenes | Attachments, images, file explorer; no host-owned media player found |
| First-party browser automation | Visible browser, origin grants, annotation, evidence, audits, execution ledger | 22 tools including `browser_evaluate`; single global switch, no origin grants, no ledger |
| Voice | No | Local ONNX STT/TTS by default, OpenAI optional, provider-backed voice reasoning |
| Extension boundary | Capability policy plus semantic native rendering, out of process | In-process TypeScript/React Native, documented as unsandboxed on both halves |
| External automation API | MCP tools | MCP tools, a TypeScript SDK, and full CLI parity |
| Team triggers | No | Hub: GitHub, Slack, Discord, repo-deployed workflows |
| UI languages | Catalogued strings | 9 |
| Licence | Proprietary | AGPL-3.0 |

## 4. Mechanics worth studying

### 4.1 The workspace, not the chat, as the container

A workspace holds several agent sessions, terminals, browsers, and a diff at once,
and survives any of them ending. It makes "implement in one session, review in
another, keep the dev server and the browser next to both" the default arrangement
rather than something the user assembles. Our session-first model handles the single
conversation better and the multi-session task worse. This is the deepest structural
difference between the two products and the one most likely to matter.

### 4.2 Steering instead of interrupting

Delivering composer text into a running turn, rather than queuing it or stopping the
agent, removes the most common reason to interrupt. Note the bug they had to fix
alongside it: steers sitting unread while Claude or Codex waited on a permission.

### 4.3 Services with allocated ports and a proxy

Declaring long-running services in the committed repository config, allocating each
a port per workspace, and publishing routed local and public URLs turns "check the
dev server" into a link that works from the phone. Threading has the script registry
already; the port registry and proxy are the missing half.

### 4.4 Reading the committed config from the base branch

`paseo.json` is read from the committed base branch, so an uncommitted or malicious
edit on a feature branch cannot change what setup commands a new workspace runs.
That is a cheap, real hardening of a seam we also have.

### 4.5 Heartbeats as a distinct primitive

Separating "start a fresh agent on a cadence" from "send a prompt back into this
agent on a cadence" is a better decomposition than one scheduler. The second is what
"watch CI until it passes" actually needs, and it reuses a live context.

### 4.6 Cross-provider handoff as a packaged skill

`/paseo-handoff` ships the briefing format, not just the mechanism: task, context,
relevant files, current state, what was tried, decisions, acceptance criteria,
constraints. The value is in having written the template once.

## 5. Risks and constraints

### Authorization is one password

`auth.ts` compares a bearer token against one optional bcrypt-hashed daemon
password. There are no roles, no per-workspace scoping, and no per-conversation
grants. Anyone holding the password or a pairing link controls every agent, every
terminal, and every file on that machine. The pairing QR code is the trust anchor
and the documentation says to treat it like a password.

### Browser automation is a single global switch

One boolean enables 22 tools, including arbitrary JavaScript evaluation in whatever
page the agent opens, with browser-profile sharing available for authenticated
sessions. No origin allowlist, no per-site consent, no visit record. An agent that
can be prompt-injected by a page it reads can act on any other site the profile is
logged into.

### Plugins are unsandboxed by design

Documented, not incidental: backend plugin code runs with the daemon's full access
to the machine. The system is described as for personal use rather than
distribution, which is honest, but application themes are already a plugin
contribution type and the distribution pressure will follow.

### Push previews: one questionable hop, one questionable fallback

Two separable choices here, and only one of them is a mistake.

**Previewing the assistant's last message is reasonable and we do a version of it.**
A push that says only "Agent finished" is close to useless, and 220 markdown-stripped
characters of what the agent just said is the same trade every messaging app makes.
This is not the criticism.

**The transport is inconsistent with their own positioning.** The payload is posted
in cleartext to `exp.host`, Expo's hosted push service, which then forwards to APNs
and FCM. Note that APNs is not end to end either, so an alert body is readable by the
platform vendor for any sender; the issue is that Paseo adds a second operator that
is neither the user nor Apple, in a product whose headline is "no telemetry" and
whose relay was carefully built so the relay operator could read nothing. The
encrypted-relay design and the push design answer the same question differently.

**The permission fallback is the actual defect, and it is independent of transport.**
When a pending permission request carries no title or description,
`buildPermissionDetails` falls back to `JSON.stringify(request.input)`: the tool's
arguments. A shell command's argv, or a path plus a snippet, truncated at 220
characters and put on a lock screen. That is not a message anyone composed for a
human. Threading's equivalent path names the tool and stops, with the reason written
at the call site: "Tool arguments, paths and diffs belong behind authentication, not
on a lock screen."

### Concentration risk

One person wrote roughly 4,532 of the top-ten contributors' commits, against a
14.6k-star, 1.5k-fork, 968-open-issue project releasing multiple betas a week. The
velocity is real and so is the bus factor.

### The cost of one tree everywhere

React Native Web through Electron on the desktop is why five platforms exist at all.
It is also why the changelog carries entries like composer typing lag on web and
desktop, Android workspace-switch stalls after several long chats, CJK IME
composition being cancelled in text fields, and reading-position jumps when tool
calls expand. Those are the failures a shared abstraction produces, and they land on
the surface a developer stares at all day.

## 6. Recommendation for Threading

Treat Paseo as the reference competitor, replacing omg.dev in that role. It is
larger, faster-moving, and overlaps more of our roadmap than anything else in this
directory.

Do not respond by chasing platform count. Windows, Linux, Android, a web app, an
SDK, a hosted Hub, and 43 providers are a different product's spine, and matching
them means giving up the AppKit surface that is our reason to exist.

Three things are worth taking:

1. **A container above the conversation.** Their workspace model is better for how
   people actually run several agents on one task. We do not have to adopt their
   vocabulary, but a task-level container that holds sessions, a terminal, a browser
   and a diff would close the gap that matters most.
2. **Steering into a running turn**, with the permission-wait case handled from the
   start.
3. **Ports and a proxy for project scripts**, so a workspace's dev server is a link
   the paired phone can open.

Two things are worth saying out loud in positioning, because they are true and
verifiable in their source rather than marketing contrast: their access control is
one password with no roles, and their browser automation is one switch that includes
arbitrary page evaluation with no origin grant. Threading's per-conversation roles,
origin grants, permission broker, browser audit ledger, and out-of-process
capability-governed extensions are the substantive difference, and they are
differences a self-hosting audience can check for themselves.

Recheck this dossier before any decision that depends on it. Five releases shipped in
the five days before the research date.

## Primary sources

- [README at the researched revision](https://github.com/getpaseo/paseo/blob/7c430777bfb3117eb1d359eddb69235ea308930e/README.md)
- [CHANGELOG](https://github.com/getpaseo/paseo/blob/7c430777bfb3117eb1d359eddb69235ea308930e/CHANGELOG.md)
- [LICENSE (AGPL-3.0)](https://github.com/getpaseo/paseo/blob/7c430777bfb3117eb1d359eddb69235ea308930e/LICENSE)
- [Security model](https://github.com/getpaseo/paseo/blob/7c430777bfb3117eb1d359eddb69235ea308930e/public-docs/security.md)
- [Workspaces](https://github.com/getpaseo/paseo/blob/7c430777bfb3117eb1d359eddb69235ea308930e/public-docs/workspaces.md)
- [Git worktrees](https://github.com/getpaseo/paseo/blob/7c430777bfb3117eb1d359eddb69235ea308930e/public-docs/worktrees.md)
- [Providers](https://github.com/getpaseo/paseo/blob/7c430777bfb3117eb1d359eddb69235ea308930e/public-docs/providers.md)
- [Orchestration](https://github.com/getpaseo/paseo/blob/7c430777bfb3117eb1d359eddb69235ea308930e/public-docs/orchestration.md)
- [MCP reference](https://github.com/getpaseo/paseo/blob/7c430777bfb3117eb1d359eddb69235ea308930e/public-docs/mcp.md)
- [Plugins](https://github.com/getpaseo/paseo/tree/7c430777bfb3117eb1d359eddb69235ea308930e/public-docs/plugins)
- [Voice](https://github.com/getpaseo/paseo/blob/7c430777bfb3117eb1d359eddb69235ea308930e/public-docs/voice.md)
- [Hub](https://github.com/getpaseo/paseo/tree/7c430777bfb3117eb1d359eddb69235ea308930e/public-docs/hub)
- [Daemon auth](https://github.com/getpaseo/paseo/blob/7c430777bfb3117eb1d359eddb69235ea308930e/packages/server/src/server/auth.ts)
- [Browser tool definitions](https://github.com/getpaseo/paseo/blob/7c430777bfb3117eb1d359eddb69235ea308930e/packages/server/src/server/browser-tools/tools.ts)
- [Browser tools policy](https://github.com/getpaseo/paseo/blob/7c430777bfb3117eb1d359eddb69235ea308930e/packages/server/src/server/browser-tools/policy.ts)
- [Push service](https://github.com/getpaseo/paseo/blob/7c430777bfb3117eb1d359eddb69235ea308930e/packages/server/src/server/push/push-service.ts)
- [Attention notification payload](https://github.com/getpaseo/paseo/blob/7c430777bfb3117eb1d359eddb69235ea308930e/packages/protocol/src/agent-attention-notification.ts)
- [Service proxy](https://github.com/getpaseo/paseo/blob/7c430777bfb3117eb1d359eddb69235ea308930e/packages/server/src/server/service-proxy.ts)
- [ACP provider catalog](https://github.com/getpaseo/paseo/blob/7c430777bfb3117eb1d359eddb69235ea308930e/packages/app/src/data/acp-provider-catalog.ts)
- [Provider quota fetchers](https://github.com/getpaseo/paseo/tree/7c430777bfb3117eb1d359eddb69235ea308930e/packages/server/src/services/quota-fetcher/providers)
- [Agent storage](https://github.com/getpaseo/paseo/blob/7c430777bfb3117eb1d359eddb69235ea308930e/packages/server/src/server/agent/agent-storage.ts)
