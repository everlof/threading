# Skalman User Guide

A native macOS app for organizing coding-agent sessions. Projects live in a sidebar on the
left; the selected session's terminal fills the pane on the right.

## Layout

One window. The sidebar runs the full height on the left, listing projects and their sessions.
The terminal fills the rest, under a header naming the project and session currently shown.

A third pane opens on the right when an agent displays something the terminal cannot render.
See [Display Panel](#display-panel).

There is no title bar — the window controls sit over the top of the sidebar.

## Concepts

**Project** — a folder you've added. Named after its git repository when there is one, with
the current branch shown beneath.

**Session** — one Claude Code, Codex, or shell session running inside a project. A session
outlives its terminal: when the agent exits, the terminal closes but the session stays in the
sidebar so you can resume the same conversation later.

**Account** — a distinct agent login. If you have more than one, each is offered separately
when creating a session. See [Accounts](#accounts).

## Projects

### Adding
- **Add Project** button at the bottom of the sidebar
- **Project > Add Project…** (Cmd+Shift+N)
- Drag a folder onto the sidebar, or onto the app icon

Adding a project immediately creates a first session in it.

### Repositories, worktrees and monorepos
A project is a **folder**, not a repository — because a repository can have several checkouts
at once, each on its own branch.

When you add two or more folders belonging to the same repository (typically git worktrees),
they are grouped automatically under one repository heading, each labelled with its branch:

```
▾ sonda
  ▾ develop            ← main checkout
      ✦ Claude Code
  ▾ feature-auth       ← worktree
      ✦ Claude Code
```

A repository with a single checkout stays as it is — no extra nesting appears unless it earns
its place.

Other cases:
- **Monorepo package** — adding `mono/packages/api` names the project `api`.
- **Submodule** — treated as its own repository, since that is what it is. Submodules are
  usually pinned to a commit rather than a branch, so the popover shows no branch.
- **Subtree** — merged content with no marker of its own, so it behaves like any subdirectory.

**Hover a session** to see everything about it — its full title (the sidebar truncates long
ones), which agent and account it runs, the folder it runs in, the current branch (and
worktree name, for a linked worktree), and whether it is working, running, or dormant. The
branch is not shown on rows themselves: a checkout's branch changes and one repository can
have several checkouts at once, so stating it as an identity would be misleading. A grouped
checkout is the exception, named by its branch, since that is what tells the checkouts under
one repository apart.

The branch is re-read whenever a session finishes working, so an agent switching branches is
reflected the next time you hover, without you refreshing anything.

### Grouping sessions by branch
Within a project, sessions that ran on the same branch gather under a quiet branch heading —
but only when that branch has more than one session, so the extra level never appears
without earning its place:

```
▾ sonda
  ▾ feature-auth
      ✦ Claude Code
      ✦ Claude Code 2
    ✦ Codex              ← alone on its branch, stays at the project level
```

Each session remembers the branch the checkout was on when it last ran: it is recorded when
the session is created and updated each time it finishes working, then kept while the
session is dormant. So after the checkout moves on, old conversations stay filed under the
branch they actually happened on — which is also what the hover popover shows.

Branch headings collapse like projects do, showing a count of what they hide.

The grouping can be toggled from wherever you notice it, not only from Settings:

- **Hover a branch heading** — a small gear fades in at its trailing edge, opening a menu
  with **Group Sessions by Branch** (checked when on) and **All Settings…**
- **Right-click a project row or a branch heading** — the same toggle sits in the context
  menu, with a checkmark showing the current state
- **Settings > General > Group sessions by branch** — the persistent home of the setting

### Project icons
Every project row carries an icon: the project's own mark when one is known, a **generated
tile** — the project's initial on a colour hashed from its name — until then, so projects
tell apart at a glance from the moment they are added. Skalman finds the real mark itself —
no agent involved, no usage spent — by looking, in order, at:

1. **The checkout's own files** — `favicon.*`, `apple-touch-icon*`, `icon.png`, `logo.png`
   at the root or in conventional folders (`public`, `static`, `assets`, …), and an Xcode
   project's `AppIcon.appiconset`. Dependency folders such as `node_modules`, `vendor` and
   `Pods` are deliberately skipped — their favicons belong to other people's projects.
2. **The GitHub organisation avatar**, when the repository's `origin` remote points at a
   GitHub org. A **person's avatar is never used**: every repo a person owns would wear the
   same face, which distinguishes nothing — person-owned repos keep their generated tile.
3. **The homepage favicon**, when `package.json` declares a homepage.

Discovery runs in the background for projects that have no icon yet, and only ever fills an
empty slot. The network sources contact only hosts the project itself points at, and the
whole thing can be switched off with **Settings > General > Discover project icons**.

An icon whose tone would vanish against the sidebar — a dark mark in dark mode, a light one
in light mode — is drawn on a small rounded **backplate** of the opposite tone, decided from
the icon's own pixels per appearance. Icons are also clipped to a slightly rounded rect, so
square avatars sit naturally in the list.

The **Project Icon** submenu (right-click a project, or its hover buttons) offers:
- **Choose Icon…** — pick any image file; your choice is never replaced automatically
- **Use Website Favicon…** — type a domain or URL and take that site's touch icon or
  favicon; counts as your choice, like a picked file
- **Find Icon Automatically** — re-run the free discovery, replacing the current icon
- **Research Icon with Codex** — shown when a Codex login exists: asks Codex (headless,
  read-only, low reasoning effort) to identify the project's mark. **This spends your own
  Codex usage, so it never runs on its own** — each run is one explicit menu click, and a
  run in flight shows as a disabled *Researching…*
- **Open Last Research Log** — the full record of the last research run
- **Remove Icon** — back to the generated tile

**Understanding a research run.** Every run writes its complete output — the JSONL event
stream plus the CLI's own diagnostics — to
`~/Library/Application Support/Skalman/IconResearch/<project>.jsonl`, openable from the menu
above. Each stage also logs live, viewable with
`log stream --predicate 'subsystem == "com.skalman" AND category == "agent"'`. Codex itself
keeps its usual rollout under `~/.codex/sessions/`, like any other run.

Agents can also set the icon from inside a session through the `set_project_icon` MCP tool
(Settings > Tools > Project icon), e.g. "use our logo as this project's icon".

Icons are stored small (64px) under Application Support and never touch the project folder.

### Managing
**Hover a project row** — a **+** fades in at its trailing edge, opening the project's
actions. The same menu is on **right-click**. Either way it offers:
- New session (Claude Code, Codex, or Shell)
- Rename Project…
- Reveal in Finder
- Project Icon — see [Project icons](#project-icons)
- Group Sessions by Branch (checked when on)
- Remove Project — removes it from the sidebar only; saved conversations are never deleted

Click the disclosure triangle to collapse a project. Expansion state is remembered, and a
collapsed project shows how many sessions it is hiding as a count at its trailing edge.

## Sessions

### Creating
- **Cmd+N**: new session in the current project, using the default agent (Claude Code)
- **Project > New Claude Code / Codex / Shell Session**: pick the agent explicitly
- Right-click a project in the sidebar

A new session launches its agent in the project's folder.

### Status
Running and dormant are told apart by the text itself: a **dormant** session — one whose agent
has exited but which can be reopened — is greyed out. There is no permanent "running" marker,
so the sidebar stays quiet until something actually wants you.

Two things do get an indicator, at the trailing edge of the row:

| | Meaning |
|---|---|
| **Spinner** | The session is working |
| **Dot** | It finished something while you were looking elsewhere |

The dot clears as soon as you select that session.

Hovering a session row swaps the indicator for a **⋯** button holding the row's actions —
Archive, Close Session, Rename, Delete — so the list stays quiet until you reach for it.

How it works: an idle agent writes nothing to its terminal, so sustained output means it is
working, and output stopping means it has finished. A terminal bell counts as an explicit
request for attention. This is a heuristic rather than something the agents report directly —
it applies equally to Codex and to plain shells running a long command.

Redraws caused by resizing the window — or by scrolling inside a program that handles its
own scrolling, like Claude Code — are ignored, since an agent repainting itself is not the
same as an agent working.

### Scrolling
When the running program handles the mouse itself (Claude Code scrolls its own transcript),
the scroll wheel is passed to it, matching how other terminals behave. Hold **Option** while
scrolling to scroll the terminal's own scrollback instead.

### Resuming
Selecting a dormant session reopens it, resuming the prior conversation where it left off.
When a session's agent exits while you're watching, the pane shows a **Resume Session**
button rather than relaunching automatically.

Resuming works by session id:

| Agent | First launch | Resume |
|-------|--------------|--------|
| Claude Code | `claude --session-id <uuid> --name <title>` | `claude --resume <uuid>` |
| Codex | `codex` (id discovered after launch) | `codex resume <uuid>` |
| Shell | your login shell | starts a new shell |

Claude Code accepts an id chosen up front, so Skalman assigns one. Codex assigns its own,
which Skalman reads back from the rollout file Codex writes on launch. Shells have no
conversation to resume, so restarting one opens a fresh shell.

### Importing
Conversations you started outside Skalman — in a plain terminal, say — can be adopted into a
project and then resumed like any other session.

Select a project and the composer shows an **Import _n_ conversations** chip once it has
finished looking. Opening it lists what was found, newest first, searchable by title. Picking
one adds it to the project already resumable; it is not launched, so selecting it in the
sidebar is what reopens the conversation.

Skalman finds these by reading the transcripts both CLIs already keep — Claude under
`<config>/projects/`, Codex under `<codex home>/sessions/` — across every account it knows
about. Titles come from Claude's own conversation title where there is one, otherwise from the
first thing you typed.

Two kinds of transcript are deliberately left out:

- Conversations the project already tracks, so nothing is offered twice.
- Transcripts with nothing you typed in them. Codex writes a rollout for its own approval
  reviewer, in the same folder and against the same project, and a session you opened but
  never spoke in has nothing to resume either.

### Closing
- **Cmd+W**: closes the current session's terminal, leaving it dormant and resumable
- Right-click > **Delete Session**: removes it from the sidebar entirely

### Names
By default a session is named after its terminal title, which agents update as they work —
so the sidebar reflects what each session is currently doing.

Renaming a session pins your own name instead, and it stops following the terminal. Clear the
name to go back to following it. Turn the behaviour off entirely under
**Settings > General > Name sessions after the terminal title**.

Rename via right-click in the sidebar, or right-click inside the terminal and choose
**Rename Session…**.

### Moving a conversation to another account
Hover a session's **⋯** menu and, when you have more than one login for that agent, a **Move
to Account** submenu lists the others. Choosing one moves the whole conversation there — it
resumes on the new account with its full history, exactly where it left off. Useful when one
account hits its usage limit and you want to carry on under another.

It works because a conversation is just a transcript on disk that the agent replays each turn,
so moving it is copying that file into the other account and pointing the session at it —
Skalman never touches your login. The original is left untouched, so you can move back the same
way. A running session is stopped first, then moved.

Same agent only: a Claude conversation moves between Claude accounts, a Codex one between Codex
accounts. Moving *across* agents (Codex ↔ Claude) is a different thing entirely — their
histories aren't interchangeable — and isn't offered here.

One thing to keep in mind: moving to another account to keep working past a limit is fine when
the accounts are genuinely separate (your personal and your work login, say). Rotating through
accounts purely to dodge usage limits is the pattern Anthropic's terms discourage — Skalman
leaves the choice, and the timing, to you rather than doing it automatically.

## Accounts

Both CLIs support multiple logins by pointing an environment variable at an alternate config
directory. Skalman finds these automatically and offers each one when you create a session.

| Agent | Default | Alternates | Redirected by |
|-------|---------|-----------|---------------|
| Claude Code | `~/.claude` | `~/.claude-*` | `CLAUDE_CONFIG_DIR` |
| Codex | `~/.codex` | `~/.codex-*` | `CODEX_HOME` |

If an agent has only one login, nothing changes — it stays a single menu item. With more than
one, **New … Session** becomes a submenu listing the accounts.

### Naming
If you have a shell alias pointing at an account, Skalman uses your name for it. Given:

```bash
alias claudedb='CLAUDE_CONFIG_DIR="$HOME/.claude-dblock" claude'
```

the account appears as **claudedb** rather than `claude-dblock`. Accounts are found by
scanning for config directories, so they appear whether or not you have an alias; aliases only
supply the label.

Sessions on an alternate account are marked by the account's icon in the sidebar — its
emoji if you have chosen one, otherwise a lettered badge from the account's name. Hovering
the row shows the full account name.

### Icons and names
**Settings > Accounts** lists every account that was found. Click an account's icon to open
the emoji picker — choose from the grid, type any other emoji into its field, or **Remove**
the current one. The icon tells accounts apart at a glance in the sidebar.

A session's icon slot resolves in order: your chosen **emoji**, then the account's
**discovered avatar**, then a **letter badge** for alternate accounts, then the agent's own
mark — Claude's starburst, OpenAI's knot. Shells keep the terminal symbol.

The avatar is looked up from the account's login email (read from the CLI's own records):
**Gravatar** first, then GitHub for accounts whose *public* profile email matches. Most
emails resolve nowhere, and a miss just leaves the rest of the chain in place. Unlike
project icons, a face is exactly right here — an account is a person, and different logins
mean different faces. Only a hash of the email (Gravatar) or the email as a search query
(GitHub) ever leaves the machine, and **Settings > General > Discover account avatars**
turns the whole thing off. Rename an account
if the discovered name is not what you call it; clearing a name restores the one from your
shell alias, and **Reset Selected** clears both.

Accounts cannot be added or removed here — they come from your config directories. Log in to a
new one from the terminal, e.g. `CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude`.

### What counts as an account
A directory must prove it holds a real login:

- **Claude** — must contain `.claude.json` or `settings.json`
- **Codex** — must contain `auth.json`

Two things are deliberately *not* treated as accounts:

- **Claude Science data roots.** `~/.claude-science` (and custom roots carrying `install-id`,
  `runtime/`, and `orgs/`) hold Claude-shaped state but are not login slots.
- **Aliases that set no config directory.** `alias claude='~/.local/bin/claude'` is a path
  shortcut, not a separate account.

### Why the account sticks
Conversations are stored per account, so a session resumes under the account it started on.
Resuming a `claudedb` conversation under the default account would not find it.

The default account launches with `env -u CLAUDE_CONFIG_DIR` rather than a bare command, so an
override exported by your shell cannot silently route it to the wrong account.

### Usage in the toolbar
The top-right of the toolbar shows how much of the current account's rate limit is spent —
each window labelled with its value, like `5h 43% · 7d 73%`, beside a small ring gauging
whichever window is closest to its limit. It follows the selected session's account, and
hides for shells and anything else without a metered login. The pill stays monochrome while
usage is comfortable; a value turns orange past 75% and red past 92% of its window.

Click it for the full picture: every rate-limit window (the 5-hour session window and the
weekly one), each with its own bar, percentage and reset countdown, plus how fresh the
reading is. Hovering the pill shows the same summary as a tooltip.

Where the numbers come from, per agent:

- **Codex** — fetched from the account's own API login (`auth.json`), refreshed every few
  minutes and after the session finishes working.
- **Claude** — fetched with the account's `.credentials.json` when one exists. On most Macs
  Claude Code keeps its token in the Keychain instead; there Skalman reads the usage feed
  Claude Code itself publishes through its status line when [Claudex](~/repo/claudex) manages
  it. No usage source means no pill.

Skalman never stores or refreshes a login itself — it reads what the official CLI keeps, and
if a token has expired the tooltip says so and the CLI is the place to sign in again.

## Chat Sessions (experimental)

Normally a session shows the agent's own terminal. A **Chat** session instead lets Skalman
draw the conversation itself — messages, tool calls and replies as native views rather than
text painted by the CLI.

Chat is available for **Codex sessions**. Choose **Chat (experimental)** from the surface chip
when creating one. Skalman runs `codex exec --json` for each turn and resumes the same Codex
thread for the next, using the account and model selected for the session.

Claude Code always uses its terminal. Its former native transport depended on subscription
credentials in a third-party headless integration, so Skalman deliberately does not offer it.

Your messages sit in bubbles on the right; Codex's replies run down the left as formatted
text — headings, lists, code blocks and inline `code` rendered rather than shown as raw
markdown. A short instruction gets a small bubble; a long answer gets room to breathe.

Tool calls appear as a single collapsed line: a glyph, the tool, what it ran, and how much it
returned — `$ Bash · ls -la · 42 lines`. Click to expand. A directory listing is usually
longer than everything said around it, so it stays folded until you want it.

Command executions, MCP calls, searches and file-change events use the same collapsed treatment,
with their result attached when Codex finishes the item.

Reopening a chat session replays the conversation from Codex's own rollout transcript, so you
come back to what was said rather than a blank pane. Very long conversations show only the most
recent stretch, and say so.

### Permissions

Codex Chat runs with the `workspace-write` sandbox, so it may read and edit the selected project.
The non-interactive command has no terminal in which to present an approval prompt: operations
that require leaving the sandbox or gaining additional access fail instead of being silently
approved. Use the Terminal surface when a task needs Codex's full interactive approval flow.

### What is missing

It is early. Compared to the terminal you lose slash commands, plan mode, interactive approval
requests, interrupting a turn mid-flight, token-by-token text, and some of the agent's richer
rendering. Use it where you want the conversation to read like a conversation; use the terminal
when you need the complete Codex interface.

## Display Panel

A terminal can only draw text. The display panel is the way around that: a third pane on
the right that Claude or Codex can put content into while you keep working in the terminal.

Ask for something visual — "show me that screenshot", "chart the bundle sizes", "render that
as a table" — and the panel opens beside the terminal. Close it with the **✕** in its header;
it reopens the next time the agent displays something.

Two kinds of content:

- **Images** — screenshots, generated charts, design assets. Anything `NSImage` reads: PNG,
  JPEG, GIF, HEIC, PDF, SVG. Scaled to fit the panel's width.
- **HTML** — wide tables, charts, Mermaid diagrams, side-by-side diffs, rendered reports.
  It is a real browser engine, so scripts run and libraries load from a CDN; an agent can
  pull in Chart.js or Mermaid rather than hand-rolling SVG.

Clicking a link in an HTML document opens it in your real browser rather than navigating the
panel, which has no back button or address bar to get you home again.

The **⋯** button beside the caption acts on what is shown — copy the image or the HTML,
reveal the file in Finder, or open the document in your browser when the panel is too narrow
for it.

The panel belongs to a session, not to the window. Each session keeps its own content, so
switching sessions switches what the panel shows, and a session that has displayed nothing
leaves it closed. A background session that displays an image does not interrupt what you are
looking at — its image is waiting when you select it, the same way its scrollback is.

Available in Claude Code and Codex sessions. Shell sessions have no agent to call the tool.

### How it works

Skalman runs a small MCP server on a loopback port and registers it with each Claude or Codex
session it launches, giving that session a private endpoint. The agent gets two tools —
`display_image` and `display_html` — and is told the panel exists so it reaches for them
instead of printing a file path or an ASCII table.

Both are pre-approved, so displaying something does not raise a permission prompt every time.
This does not affect any other tool: your normal permission rules and your own MCP servers
are untouched.

HTML runs with network access, so CDN libraries work. That is a deliberate choice rather than
an oversight — the agent already has a shell, so a locked-down web view would stop nothing it
could not do more easily with `curl`. What is blocked is navigation, which is a usability
problem rather than a security one.

## Find

- **Cmd+F**: open find bar
- **Enter**: find next match
- **Esc**: close find bar
- Results counter shows "N of M"

## Appearance

### Sidebar
- **Cmd+Ctrl+S**, or the toggle button at the left of the header: show/hide the sidebar

### Font Size
- **Cmd++** / **Cmd+-**: increase/decrease font size

### Full Screen
- **Cmd+Ctrl+F**: toggle full screen

### Themes
Configure in **Preferences > Themes**:
- 16 ANSI colors (8 normal + 8 bright)
- Foreground, background, cursor, and selection colors
- Import themes from Terminal.app (.terminal files)
- Export themes as JSON
- Duplicate and customize built-in themes
- Live preview with sample output

### Profiles
Configure in **Preferences > Profiles**:
- Font family and size
- Cursor style: Block, Underline, or Bar
- Cursor blink toggle
- Scrollback buffer size (default: 10,000 lines)

## Settings

Open with **Cmd+,**.

### General
- **New sessions use** — the agent Cmd+N creates. Other agents stay on the Project menu
- **Name sessions after the terminal title** — see [Names](#names)
- **Group sessions by branch** — see [Grouping sessions by branch](#grouping-sessions-by-branch)
- **Discover project icons** — see [Project icons](#project-icons)
- **Discover account avatars** — see [Icons and names](#icons-and-names)
- **Reopen the last session at launch**
- **Ask before closing a running session**
- **Shell path** — used by shell sessions; agent sessions always launch via your login shell

### Accounts
Per-account icons and names. See [Accounts](#accounts).

### Profiles, Themes, AI
Terminal font and cursor, colour schemes, and AI provider configuration.

## Keyboard Shortcuts

### Projects & Sessions
| Action | Shortcut |
|--------|----------|
| New Session | Cmd+N |
| Add Project | Cmd+Shift+N |
| Close Session | Cmd+W |

### Editing
| Action | Shortcut |
|--------|----------|
| Copy | Cmd+C |
| Paste | Cmd+V |
| Cut | Cmd+X |
| Select All | Cmd+A |
| Undo | Cmd+Z |
| Redo | Cmd+Shift+Z |
| Find | Cmd+F |

### View
| Action | Shortcut |
|--------|----------|
| Toggle Sidebar | Cmd+Ctrl+S |
| Bigger Font | Cmd++ |
| Smaller Font | Cmd+- |
| Full Screen | Cmd+Ctrl+F |
| Minimize | Cmd+M |
| Preferences | Cmd+, |

## Data Storage

Stored in `~/Library/Application Support/Skalman/`:
- `projects.json` — projects, sessions, and their resumable agent session ids
- `history/` — per-session command history
- `mcp/` — one file per session pointing Claude at that session's display panel

Displayed images are held in memory only. The panel shows the file on disk; it does not copy
it, and nothing about what was displayed survives a restart.

Settings, including per-account icons and names, live in the app's user defaults.

Conversations themselves are owned by the agents, not Skalman, and live under the config
directory of the account that created them:
- Claude Code: `<config-dir>/projects/<folder>/<session-id>.jsonl`
- Codex: `<codex-home>/sessions/YYYY/MM/DD/rollout-<timestamp>-<id>.jsonl`

Removing a project or deleting a session in Skalman never deletes these files.
