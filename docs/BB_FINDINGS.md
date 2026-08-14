# bb competitive findings

Researched 2026-08-14 against
[get-bb/bb](https://github.com/get-bb/bb) at commit
[`5ecdd69`](https://github.com/get-bb/bb/tree/5ecdd69ecd7445dabbf871fa829ba2b8394acee2)
(bb-app 0.37.0). File paths below are relative to that revision. bb is MIT and
in active development, so this is a source snapshot rather than a permanent
product claim.

## Short version

bb is a direct competitor and a particularly important strategic reference for
Threading's extension and self-improvement direction.

Its claim that it "builds itself" is backed by a shipped loop:

1. The user chooses **New plugin** and describes what they want.
2. bb opens an agent thread with a seeded plugin-authoring prompt.
3. The agent receives bb's built-in `bb-plugin-authoring` skill.
4. It can scaffold, build, install, test, and live-reload the plugin through the
   first-class `bb` CLI.
5. The plugin can add backend behavior, agent tools, schedules, commands, data,
   settings, and deeply integrated React surfaces.

That is more than positioning, but it is best described as **self-extending,
not autonomously self-modifying**. The user initiates an agent that writes a
plugin against stable contracts. bb does not silently rewrite or promote
changes into its core product.

The strategic opportunity for Threading is to match the low-friction authoring
loop while keeping its stronger capability, trust-tier, and semantic-rendering
boundaries.

## 1. Product and architecture

The [README](https://github.com/get-bb/bb/blob/5ecdd69ecd7445dabbf871fa829ba2b8394acee2/README.md)
describes four first-class operator surfaces: Electron desktop, web app, CLI,
and HTTP API. The packaged desktop app supports macOS; the web application runs
on macOS, Linux, and WSL2 through `npx bb-app`.

The [system overview](https://github.com/get-bb/bb/blob/5ecdd69ecd7445dabbf871fa829ba2b8394acee2/docs/system-overview.md)
splits the runtime into:

| Piece | Responsibility |
|---|---|
| Server | Central SQLite-backed state, HTTP API, WebSocket notifications, and host routing. |
| Host daemon | Workspace provisioning, provider processes, local machine operations, and event delivery. |
| Web app | Projects, structured threads, terminals, review, steering, and plugin UI. |
| CLI | A first-class user and agent interface over the same product capabilities. |

Threads produce append-only events for messages, tool calls, file changes, and
other activity. They may be standard work threads or managers with child
threads. Environments bind a workspace to an enrolled host and may be shared,
unmanaged, or bb-managed.

### Providers and conversations

The built-in provider catalog covers Claude Code, Codex, Pi, and Cursor through
ACP. The ACP path can support additional agents. Provider output becomes a
structured timeline rather than remaining raw terminal output, while terminal
panels remain available.

Notable interaction surfaces include:

- follow, steer, queue, and hand off live threads;
- split thread areas and secondary panels;
- standard and manager threads with visible child delegation;
- multiple terminal tabs attached to a thread or environment;
- durable process ownership through the server and host daemon.

### Workspaces and Git

[Managed worktrees](https://github.com/get-bb/bb/blob/5ecdd69ecd7445dabbf871fa829ba2b8394acee2/docs/worktrees.md)
are opt-in when creating a thread. bb provisions a fresh branch and working
copy, supports copied include files and a setup script, and cleans the
environment up when no unarchived thread still uses it.

The app has thread and workspace change lists, rich text/image diffs, commit
actions, pull-request state, and a squash-merge action. No first-party per-file
staging flow was found in this snapshot.

### Remote use

[Multiple-device support](https://github.com/get-bb/bb/blob/5ecdd69ecd7445dabbf871fa829ba2b8394acee2/docs/multiple-devices.md)
separates browser control from execution machines:

- `bb connect` provides account-gated browser access through getbb.app.
- Tailscale Serve is the private-network alternative.
- Additional enrolled machines run host daemons and receive work from one bb
  server.
- A wildcard-bound server API is unauthenticated and explicitly documented as
  unsafe for direct public exposure.

This is substantial remote orchestration, but it is not Threading's scoped
collaboration model. No comparable per-conversation View, Collaborate, and
Approve roles were found.

## 2. The extension and self-improvement system

### The authoring loop is real

The app's `New plugin` path seeds a new agent composer with `Create a new bb
plugin that ...` (`apps/app/src/lib/create-resource-prompts.ts` and
`apps/app/src/components/plugin/PluginsOverview.tsx`). The agent then has a
large built-in
[plugin-authoring skill](https://github.com/get-bb/bb/blob/5ecdd69ecd7445dabbf871fa829ba2b8394acee2/apps/server/src/services/skills/builtin-skills/bb-plugin-authoring/SKILL.md)
covering the host APIs and the complete development loop:

```text
bb plugin new --app
bb plugin install .
bb plugin build
bb plugin dev
bb plugin reload
```

`bb plugin dev` rebuilds and reloads on each save. Frontend changes remount in
open app pages without a refresh. The SDK also provides backend and frontend
test harnesses with lifecycle, event, RPC, storage, and UI-slot fakes.

This makes extension authoring an ordinary agent task inside the product,
rather than a separate developer workflow.

### Backend reach

A TypeScript plugin runs in-process in the bb server and can contribute:

- logging, settings, key-value storage, and a dedicated SQLite database;
- HTTP routes, typed RPC, and realtime signals;
- background services and schedules;
- lifecycle and event handlers;
- CLI subcommands and blocking user-input requests;
- native agent tools, skills, and configuration;
- cross-product operations through the bb SDK.

Plugins may be installed from a local path, npm, Git, or bb's bundled official
catalog. Compatible updates are explicit; failed activation restores the
previous snapshot. bb also provides a build toolchain, development reload, and
external plugin test helpers.

### Frontend reach

The [plugin SDK](https://github.com/get-bb/bb/blob/5ecdd69ecd7445dabbf871fa829ba2b8394acee2/packages/plugin-sdk/README.md)
can register React surfaces for:

- home and settings sections;
- navigation and thread panels;
- pending interactions, header actions, and sidebar actions;
- file openers and message directives/actions;
- composer actions, banners, rich-text behavior, and mentions;
- a complete replacement for the sidebar thread list;
- trusted same-origin content scripts;
- custom and plugin-contributed themes.

This is an unusually broad extension seam. It allows a plugin to become a
substantial product inside bb, or to replace important parts of the shell.

### The system dogfoods itself

Important bb features are plugins, including custom instructions, memory,
automations, workflows, provider retry, secrets, side chat, inline
visualizations, GitHub, docs, and task/delegation surfaces. This matters more
than the size of the SDK: first-party product work continuously exercises the
same contracts external extensions use.

The memory plugin is provider-independent and exposes versioned global and
project memories to both people and agents. Workflows and automations add
durable orchestration. Skills contributed by plugins are injected into agents.
Together these form useful pieces of a self-improvement loop, even though bb
does not autonomously turn observations into installed behavior.

## 3. Trust model

bb is explicit that plugins are **full-trust code**. Backend code runs in the
server process and can read all local bb data. Frontend content scripts are
same-origin page code, not a sandbox. React surfaces execute plugin code rather
than describing a semantic UI for the host to render.

That choice buys enormous reach and a familiar TypeScript/React authoring
experience. Its costs are equally clear:

- no declared capability or resource boundary around plugin behavior;
- compromise or mistakes inherit the user's complete bb authority;
- deep UI replacement can weaken consistency and accessibility;
- server-process faults have a larger blast radius;
- reviewing an agent-authored plugin requires source-level trust.

Install and update prompts warn about full trust, and activation rollback helps
with compatibility failures, but neither is a security sandbox.

Threading's differentiator should not be "we also execute arbitrary React more
easily." It should be: agents can create useful extensions quickly, while the
host still shows the user an understandable capability and resource diff and
renders standard UI consistently.

## 4. Focused feature matrix

| Capability | bb at `5ecdd69` | Threading |
|---|---|---|
| Product shape | Electron desktop, web app, CLI, HTTP API | Native macOS app, native iOS companion, browser collaboration |
| Agent surfaces | Structured threads plus terminals and split panes | Native conversation or provider TUI over one session model |
| Providers | Claude Code, Codex, Pi, ACP/Cursor | Claude Code, Codex, Grok, OpenCode |
| Durable execution | Server and enrolled host daemon | Mac host for remote sessions; local app owns local processes |
| Delegation | Manager/child threads and Tasks delegation | First-class delegation hierarchy and attention model |
| Git | Rich diffs, commit, PR, squash merge | Six review scopes, staging, commit, PR/MR, finish handshakes |
| Remote | bb connect, Tailscale, enrolled machines | Paired browser/iPhone clients with per-conversation roles |
| Extension authoring | User prompt opens an agent equipped to build and live-install a plugin | Extension authoring is documented and validated, but not yet a comparable in-product prompt-to-install loop |
| Backend extension | Full-trust in-process TypeScript API | Portable WASM with declared capabilities; explicit high-trust companion tier |
| UI extension | Arbitrary React slots, replacements, and same-origin scripts | Host-rendered semantic components governed by the design system |
| Agent improvement primitives | Plugin skills, memory, instructions, workflows, automations | Skills/extensions and scheduled work exist as separate primitives; no complete governed promotion loop yet |
| Themes | Custom themes and plugin contributions | Themes span native chrome, semantic extension UI, terminal, fonts, and icons |
| Interactive browser | No first-party browser-control surface found | Visible browser control, annotation, evidence, audit, and ledger |

## 5. What Threading should learn

### Copy the authoring journey, not the trust model

Add a first-class **Build an extension** action that creates a managed workspace
and launches an agent with the extension-authoring skill, examples, validation
commands, and a live preview. The product should carry the user from intent to
a reviewable install without requiring them to leave Threading.

### Make the governed promotion loop explicit

A credible self-improvement system should be a visible sequence:

```text
observation or memory
  -> proposed skill or extension
  -> generated in an isolated workspace
  -> tests and policy validation
  -> capability and resource diff
  -> user approval
  -> staged activation
  -> health check and rollback
```

Never silently rewrite the core application. Let agents propose durable new
behavior, but preserve authorship, provenance, review, bounded authority, and a
fast route back.

### Treat agents and people as peers at stable product APIs

bb's CLI is not a diagnostic sidecar. Agents can use it to operate the product
and develop extensions. Threading should ensure its agent tools, extension SDK,
and visible UI converge on the same nouns and lifecycle operations.

### Dogfood the extension boundary

bb's official plugins are strategically valuable because they force the
extension API to support real product work. Threading should keep moving
eligible first-party capabilities onto its governed extension contracts, while
retaining native host ownership for security-sensitive and performance-critical
surfaces.

### Ship author feedback loops

The most useful pieces to emulate are mundane but compounding: scaffolding,
live reload, a real test harness, compatibility declarations, failed-update
rollback, bundled examples, and an authoring skill kept in sync with the SDK.

## 6. Recommendation

Add bb to both the internal and public competitor matrices. Revisit it
frequently: its extension surface and official plugin set are moving quickly,
and it is already testing the product direction Threading is approaching.

Use bb as the benchmark for **how little friction separates a user's intent
from a working extension**. Use Threading's own capability policy, semantic UI,
native integration, scoped collaboration, and browser evidence as the standard
for how safely and coherently that extension should run.
