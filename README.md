<p align="center">
  <img src="Brand/ThreadingMark-1024.png" width="112" alt="Threading">
</p>

<h1 align="center">Threading</h1>

<p align="center">
  <strong>Keep every coding session in one place.</strong><br>
  A native Mac app for running Claude Code, Codex, Grok, OpenCode and Cursor side by side.
</p>

<p align="center">
  <a href="https://github.com/everlof/threading/releases/latest">Download for Mac</a> ·
  <a href="https://threading.codes">threading.codes</a> ·
  <a href="USER_GUIDE.md">User guide</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

<p align="center">
  Apple silicon · macOS 13 or later · Free and open source under GPLv3
</p>

---

Threading is not a coding agent. The agents you already use do the coding; Threading runs their
command-line tools in your project folders, keeps their sessions together, shows you which one
needs you, and puts the diff next to the agent that wrote it. It uses your existing provider
accounts and sells no model access.

It is a native AppKit app built on [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), so
each provider's own terminal interface — its keys, slash commands and plan mode — behaves exactly
as it does anywhere else.

## What it does

### Sessions and attention

- **One sidebar for every project and chat.** Each row carries one mark — working, needs you,
  finished, dormant — so a glance tells you where to go next. Notifications for blocked and
  finished turns are taken back once they stop being true.
- **Sessions outlive their terminals.** When an agent exits, the conversation stays and resumes
  by the provider's own session id. Continue a conversation with another provider, move it to
  another account with its full history, or follow it into another checkout.
- **Side chats, a shell drawer per session, standalone terminals, pinned and snoozed chats**, and
  one search field over projects, chats, transcripts and files — on the Mac and on the iPhone.
- **Sessions can talk to each other.** A manager session can list the project's other chats and
  send them work.
- **Chat (experimental)** draws the conversation natively for Claude Code, Codex, Grok and Cursor:
  tool calls, diffs and permission requests as real UI rather than terminal text.

### Review beside the agent

- **Git Review** (<kbd>⌘</kbd><kbd>⇧</kbd><kbd>R</kbd>) on uncommitted changes, the last turn,
  the branch or the commit graph. Stage a file or a hunk, comment on a line for the agent, and
  commit.
- **Pull and merge requests** — open or create the branch's PR on GitHub or MR on GitLab.
- **Managed workspaces** — give a session its own Git worktree, then merge it, keep it for
  review, or open a pull request.
- **Execution Audit** — a local, hash-linked record of every tool call and permission answer.

### Tools for agents

Threading registers its own MCP server with each session; you choose which tool groups an agent
sees.

- **A live browser** per session with per-site grants, responsive presets, Web Inspector, visual
  baselines, page annotations, stored test accounts and, if you allow it, your signed-in Chrome.
- **iOS Simulators and Android devices** adopted into the side panel, which agents can tap, swipe
  and type into — and which you can record with the touches drawn on screen.
- **Your paired iPhone's screen** in the panel, controllable only by you, plus **live device
  logs** from a Simulator or iPhone, including formats Threading has never seen.
- **HTTP and HTTPS traffic capture** through a session-owned proxy.
- **A display panel** where agents put images, charts, web pages and file comparisons beside the
  chat, grouped by the turn that made them.

### Long-running work

- **Scheduled messages** — write the next prompt now and send it at a set time, when a usage
  limit resets, or when another session finishes its turn.
- **Limit recovery** — when an agent is refused over a limit, the row shows the reset time and
  can continue on its own when it arrives.
- **Curfews** — end a session at a time, at a usage-window reset, during quiet hours, or when an
  account reaches a usage percentage you choose.
- **Automations** — saved tasks that run on a schedule or an event. They are created paused, run
  only the exact revision you approved, and cannot push, deploy or write back to their source.

### Accounts and usage

Add several Claude Code or Codex logins and pick one per session. Usage readings sit in the
session header and the account picker, and the **Usage** page shows cost and tokens over 7, 30
or 90 days by provider, project, account and model — computed locally from your transcripts.

### iPhone (TestFlight beta)

The iPhone app pairs with your Mac by QR code. Read a chat, type into the provider's terminal,
approve a permission request, look through the changed files and start a new chat — while every
session keeps running on the Mac. Connect over your own network or VPN, your Tailscale tailnet,
or Threading Direct from anywhere (new Macs currently need a pilot invitation). Remote Access is
off until you turn it on, and Direct verifies your Mac's paired certificate before sending
anything, so the hosted service never sees a transcript, prompt or terminal byte. The app is not
on the App Store yet; it can also be built from this repository.

### Beyond the Mac (in development)

Threading's window stays a Mac app, but more of the work underneath it is moving to other
machines. This is not switched on in public releases yet; builds from source have it.

- **Chats on a Linux host.** Choose an SSH host for a project and its Claude Code terminal chats
  run there, with hooks, Threading's tools, transcripts, usage and Git Review carried back to the
  Mac. The host installs verified, version-matched components from GitHub Releases, so it needs
  no build of its own. Claude and Codex native chats on a host are next.
- **Windows through WSL.** A Windows PC joins as a Linux host running under WSL, with a startup
  task that keeps it reachable after a reboot. This is landing now.
- **A portable core.** The daemon that keeps a session's terminal alive (`threading-ptyd`) ships
  as a single static Linux binary. The experimental `threading-controller` runs queued agent work
  on a macOS or Linux machine, such as a VPS, and agents on different hosts can mail each other.
  The traffic-capture proxy is a portable C program built for macOS, Linux and Windows.
- **A native Linux app** is at the research stage:
  [`docs/feature-drafts/linux-host-runtime.md`](docs/feature-drafts/linux-host-runtime.md).

### Make it yours

- **More than two dozen built-in themes**, from Swiss Minimalist to Windows 98, applied to the
  app, one project or one session — and agents can design new ones for you.
- **Extensions** are WebAssembly modules that declare their permissions up front; Threading draws
  their interface with its own controls and your theme. **Signed native plugins** can go further,
  like the Device Logs pane that ships with the app.
- **Command palette and editable shortcuts** for every action, and a standalone **Markdown
  editor** with Finder Quick Look.

The [user guide](USER_GUIDE.md) covers every feature and shortcut in detail.

## Install

Download the latest `Threading-x.y.z.zip` from
[Releases](https://github.com/everlof/threading/releases/latest). The app is Developer ID signed
and notarized, and updates itself through Sparkle. To get betas as well, choose **Betas and
stable releases** under **Settings ▸ General ▸ Software Updates**.

Bring the agent command-line tools you already use. The first-launch walkthrough checks which
ones your login shell can find and offers the official install command for any that are missing.

## Build from source

The project is Xcode-only — one `Threading.xcodeproj`, no root SwiftPM manifest. Clone with
submodules:

```bash
git clone --recurse-submodules https://github.com/everlof/threading.git
cd threading
```

For the complete cloud-free development environment, run:

```bash
./dev
```

That builds and opens an isolated Debug Mac app, starts the loopback control plane, and builds
and opens the iOS app in an available iPhone Simulator. `./dev --no-ios` is Mac-only,
`./dev --fresh --no-ios` launches as a first-time user in an empty home, and `./dev --help`
lists the rest.

Or build directly:

```bash
# The Mac app
xcodebuild -project Threading.xcodeproj -scheme Threading -configuration Debug build
open "$(ls -dt ~/Library/Developer/Xcode/DerivedData/Threading-*/Build/Products/Debug/Threading.app | head -1)"

# The iPhone app (Simulator; a device needs your own signing team)
xcodebuild -project Threading.xcodeproj -scheme ThreadingMobile \
  -destination 'generic/platform=iOS Simulator' build

# Tests
scripts/test.sh          # fast: everything that keeps windows off screen
scripts/test.sh all      # the whole suite
```

### Repository layout

| Path | What lives there |
|---|---|
| `Sources/Threading/` | The Mac app (Swift, AppKit) |
| `Sources/ThreadingMobile/` | The iPhone app |
| `Packages/` | First-party Swift packages — remote wire protocol, PTY host, extension and plugin kits, simulator and Android support, usage, Markdown |
| `Packages/Vendor/` | SwiftTerm (vendored) and the ThinkingOrbs, LabelMorph and BorderBeamKit submodules |
| `Targets/` | Helper executables — the PTY host, controller, MCP bridge, proxy, trigger daemon, Simulator helper, Quick Look preview |
| `Plugins/` | Native plugins that ship with the app, such as Device Logs |
| `Service/` | The hosted rendezvous control plane and supporting services |
| `docs/` | Architecture notes, extension authoring, feature drafts and decisions |

## Documentation

- [`USER_GUIDE.md`](USER_GUIDE.md) — every user-facing feature and shortcut.
- [`docs/architecture/`](docs/architecture/) — one file per subsystem, recording the decisions
  and measurements behind it. Read the relevant one before changing a subsystem; the index is
  [`CLAUDE.md`](CLAUDE.md).
- [`docs/extensions/AGENT_AUTHORING.md`](docs/extensions/AGENT_AUTHORING.md) — writing an
  extension.
- [`docs/feature-drafts/`](docs/feature-drafts/) and [`docs/decisions/`](docs/decisions/) —
  researched proposals, and ideas investigated to a recommendation.

## Licensing

The repository is licensed under the **GNU GPLv3** (see [`LICENSE`](LICENSE)), with these
carve-outs, each under its own terms:

- `Service/ThreadingControlPlane/` — the hosted rendezvous service, under the
  [Functional Source License](https://fsl.software) (FSL-1.1-ALv2, its own `LICENSE`). Read it,
  modify it, run it for your own Macs; you may not offer it as a competing service. Each version
  becomes Apache-2.0 two years after it is made available. It stays readable on purpose: the
  claim that no transcript, prompt or terminal byte reaches the server is only worth something
  if you can check it.
- `Packages/Vendor/SwiftTerm/` — a vendored fork of
  [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), MIT.
- `Packages/Vendor/ThinkingOrbs/`, `Packages/Vendor/LabelMorph/` and
  `Packages/Vendor/BorderBeamKit/` — submodule forks, each MIT under its own `LICENSE`.
- `Sources/Threading/Resources/Fonts/` — open-licensed fallback fonts; provenance and license
  per family in its `*-SOURCE.md`.

Other bundled third-party components are listed in
[`Legal/THIRD_PARTY_NOTICES.md`](Legal/THIRD_PARTY_NOTICES.md).

An App Store build of the iPhone app would be distributed by the copyright holder under the App
Store's terms rather than the GPL, which is why contributions require the lightweight agreement
described in [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) — the build gates (architecture, theme and localization
boundaries are enforced at build time), the test levels, and the contributor license agreement.
Bugs and ideas go to [Issues](https://github.com/everlof/threading/issues).
