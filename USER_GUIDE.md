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

**Session** — one Claude Code or Codex conversation running inside a project. A session
outlives its terminal: when the agent exits, the terminal closes but the session stays in the
sidebar so you can resume the same conversation later.

**Account** — a distinct agent login. If you have more than one, each is offered separately
when creating a session. See [Accounts](#accounts).

## Projects

### Adding
- **Add Project** button at the bottom of the sidebar — offers **Start from Scratch…**
  (name a new folder and Skalman creates it) and **Use an Existing Folder…**
- **Project > New Project…** — create the folder from scratch
- **Project > Add Existing Project…** (Cmd+Shift+N) — choose a folder that already exists
- Drag a folder onto the sidebar, or onto the app icon

Adding a project selects it, opening its composer so the first session is configured like
every other one. Starting from scratch never replaces anything: if a folder with the chosen
name already exists, it is adopted as-is.

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
**Hover a project row** — a **⋯** fades in at its trailing edge, opening the project's
actions. The same menu is on **right-click**. Either way it offers:
- Rename Project…
- Reveal in Finder
- Project Icon — see [Project icons](#project-icons)
- Group Sessions by Branch (checked when on)
- Remove Project — removes it from the sidebar only; saved conversations are never deleted

Click the disclosure triangle to collapse a project. Expansion state is remembered, and a
collapsed project shows how many sessions it is hiding as a count at its trailing edge.

## Sessions

### Creating
**Select a project in the sidebar.** Its composer fills the pane, and starting a session from
it is the only way to create one:

- Click the project row, or
- **Cmd+N** — opens the composer for the project you are currently in

There is no shortcut that starts a session for you. A session carries four decisions — agent,
account, model, and which checkout it runs in — and the menu items that used to create one
outright answered all four with defaults you never saw. The composer asks, and it is replaced
by the conversation the moment you send the first message, so it costs nothing to pass through.

The chips choose the agent, account, model and, in a git repository, **which checkout it runs
in**. Beneath them, the chosen account's rate limits are drawn in full — see
[Usage when picking an account](#usage-when-picking-an-account).

Every chip's dropdown is Skalman's own menu, and it tracks like a menu should: click to open
and browse, or **press, drag onto a row, and release** to choose in one motion. Arrow keys
move the highlight, **Return** chooses, **Escape** lets the menu go. **Typing while it is
open filters it** — what you type echoes across the menu's top, rows that match keep their
ink while the rest dim, and the highlight lands on the first match, so a long account or
theme list is a few letters and Return. Escape backs out one layer at a time: the first
press clears a half-typed filter, only the second closes the menu.

The model chip names the model the session will **actually run on** — `Fable 5 · 1M`, not
"Default" — read from whatever the selected account is configured to use. Its menu marks that
one *(account default)*, so choosing it explicitly and leaving it alone are the same thing. It
only says "Default model" when the account states no model at all.

The branch chip lists places, not branch names: this checkout (the default, always first),
any other checkout of the same repository you have added, and **New Worktree…** at the
bottom, which creates one on a new branch and adds it as its own project. A branch nothing is
checked out on is not offered — there would be nowhere to run — so making a worktree is how
you get one.

The prompt box **grows as you type**, up to about eight lines, then scrolls. **Return** starts
the session; **Shift+Return** (or Option+Return) breaks the line.

**Drop or paste a file** into it and its path is inserted, which is what the agent can act on.
An image with no file of its own — a screenshot straight from the clipboard, a picture dragged
out of a browser — is written to a temporary file first and its path inserted, so it can be
opened by the session you are about to start.

Whatever you type into the composer is kept as a **draft** for that project, saved as you
type. Switch projects, quit, or lose the app to a crash, and the text is still there when you
come back to it. Starting the session clears the draft — and writes the prompt to the
diagnostics log first, so even a launch that goes wrong leaves the message recoverable.
See [Diagnostics](#diagnostics).

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

Claude Code accepts an id chosen up front, so Skalman assigns one. Codex assigns its own,
which Skalman reads back from the rollout file Codex writes on launch.

### The shell drawer

**⌃`** (Control-backtick), or **View ▸ Shell**, opens a shell underneath the session you are
reading. Drag the strip above it to resize.

It is not a session of its own — shells used to be, and it was the wrong shape: there was no
conversation to resume, no transcript, and nothing to come back to. It belongs to the session
instead, and every session has one.

- It opens **where the agent currently is**, not where the session started — a terminal
  session reports its directory, so a shell opened while the agent is deep in a subpackage
  starts there. Sessions Skalman renders natively open in the project folder.
- It uses the **session's theme and font**, so it matches the surface above it.
- Each session keeps its own shell, and its own answer to whether the drawer is open. The
  process stays alive while you work elsewhere, so your directory and history are still there
  when you come back, and it is closed with the session.

Shell sessions from earlier versions are removed when your state is upgraded. They held
nothing — no conversation, no transcript, and no saved scrollback — and every session gains a
shell of its own in exchange.

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
A session is named after its conversation, never after its agent or account — the row's icon
and account chip already say which agent and login it runs on.

By default the sidebar follows the agent's own name for the conversation, which it updates as
the work develops: the terminal title for terminal sessions, and the title Claude records in
its transcript for natively rendered ones (including a `/rename` typed into the CLI). Until
the agent has named it, a session is named after its first prompt.

Renaming a session in Skalman pins your own name instead, and it stops following the agent.
Clear the name to go back to following it. Turn the follow behaviour off entirely under
**Settings > General > Name sessions after the agent's own title** — sessions then keep their
first-prompt names.

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

### How accounts are named

Where you *pick* an account — the composer's chip and its menu, and **Move to Account** — each
login is named after the person, derived from the address the CLI is signed in as:
`daniel.block3@example.com` shows as **Daniel Block**. Aliases are named after the agent
(`claude-dblock`, `claude-vlundborg`), which makes two logins differ by a few letters in the
middle of a word; the address is what actually tells them apart. Two logins belonging to the
same person fall back to showing the addresses, since that is the one thing guaranteed to
differ.

Your alias still names sessions started on that account, and is still what you edit in
**Settings ▸ Accounts**.

Each account in that menu also carries a **ring** showing how much of its most-pressed window
is spent — grey while there is room, orange past three quarters, red when it is nearly gone.
The percentages are still written out beside it; the ring is there so three accounts can be
compared at a glance instead of by reading six numbers.

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

A session row shows **both** the agent and the account. The icon is always the agent's own
mark — Claude's starburst, OpenAI's knot, a terminal symbol for shells — and a session on an
alternate account carries a small **chip** on its corner: your chosen emoji, else the
account's discovered avatar, else its initial on a colour of its own. Sessions on the
default login carry no chip, since the mark already says everything there is to say.

The initial comes from the account's **login email**, not its alias, because aliases are
named after the agent and collide: `claude-dblock` and `claude-vlundborg` are both `c`, while
`daniel.block3@…` and `lundborg.viktor@…` are `D` and `L`. The colour is derived from the
whole address, so two accounts sharing an initial still differ. Hover a session for the
account's full name.

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
The toolbar shows how much of the current account's rate limit is spent —
each window labelled with its value, like `5h 43% · 7d 73%`, beside a small ring gauging
whichever window is closest to its limit. It follows the selected session's account, and
hides for shells and anything else without a metered login. The pill stays monochrome while
usage is comfortable; a value turns orange past 75% and red past 92% of its window. The
pill sits at the trailing edge of the **session pane** — when the display panel opens, the
panel's own controls slide right and the pill stays over the conversation it describes.

Click it for the full picture: every rate-limit window (the 5-hour session window and the
weekly one), each with its own bar, percentage and reset countdown, plus how fresh the
reading is. Hovering the pill shows the same summary as a tooltip.

### Usage when picking an account
Choosing a login is when the number actually changes a decision — an account at 90% of its
week is a poor place to start a long task — so the composer shows it twice over:

- **In the account chip's menu**, each login carries its own `5h 43% · 7d 73%`, so the
  accounts are compared before one is picked.
- **Under the chips**, the chosen account's windows are drawn in full: a bar per window, its
  percentage, and its reset countdown.

Each bar carries a **time mark** — a thin line at the point the clock has reached in that
window. Fill short of the mark means you are spending slower than the window refills; fill
past it means faster. That comparison is the thing a bare percentage cannot tell you: 60%
spent is comfortable an hour before a reset and alarming four hours before one.

Values are the last ones fetched: the composer shows what is known and asks for a fresh
reading, so a login never read before fills in shortly after. Accounts with no usage source
show nothing at all, exactly as they show no pill.

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

Chat is available for **Codex and Claude Code sessions** — not for shells. Choose
**Chat (experimental)** from the surface chip when creating one. For Codex, Skalman runs
`codex exec --json` for each turn and resumes the same thread for the next. For Claude, it
keeps one `claude --print` process open for the whole conversation. Either way it uses the
account and model selected for the session, running the same CLI you already signed into.

Chat runs the agent headlessly, so it draws on your subscription the same way the terminal
does. Claude Chat was previously withheld while Anthropic's terms were read as excluding
third-party headless use; they no longer are, and the surface is offered again.

Your messages sit in bubbles on the right; the agent's replies run down the left as formatted
text — headings, lists, code blocks and inline `code` rendered rather than shown as raw
markdown. A short instruction gets a small bubble; a long answer gets room to breathe. The
column stops widening past a comfortable reading measure, so a wide window gives you margins
rather than very long lines, and a rule marks where each new exchange begins.

Tool calls appear as a single collapsed line: a glyph, the tool, what it ran, and how much it
returned — `$ Bash · ls -la · 42 lines`. Click to expand. A directory listing is usually
longer than everything said around it, so it stays folded until you want it. The rows sit flat
against the background until you point at one — a busy turn is mostly tool calls, and boxing
each of them buries what was actually said.

### Finding your way back

A long conversation scrolls past the point where scrolling finds anything, so a **turn rail**
runs down the left margin: one mark per exchange. Point at a mark to see what you asked and
what the agent concluded; click it to jump there. Marks for the turns currently on screen are
brighter, so the rail also shows where you are.

It needs margin to live in, so it appears only when the pane is wide enough to spare some —
in a narrow pane it stays out of the way entirely rather than crowding the text. It also needs
at least two exchanges to index before it is worth drawing.

Command executions, MCP calls, searches and file-change events use the same collapsed treatment,
with their result attached when the agent finishes the item. An edit shows the change itself as
a diff rather than raw tool output.

Claude's text arrives word by word as it is written; Codex sends each message complete.

Reopening a chat session replays the conversation from the agent's own transcript, so you
come back to what was said rather than a blank pane. Very long conversations show only the most
recent stretch, and say so.

### Side chats

Sometimes you want to ask something *about* a conversation without putting it *in* that
conversation — "why is this slow?", "what would the other approach look like?". Asking
directly costs you twice: the aside joins the transcript permanently and is replayed on every
later turn, and you cannot ask at all while the session is busy.

A **side chat** solves both. On a Claude session's `⋯` menu:

- **New Side Chat** — opens a new session that already knows everything the original does
- **Ask on the Side…** — the same thing with your question typed up front

The side chat appears nested under the session it came from, marked with a fork glyph:

```
▾ sondalabs
  ▾ main
      ✻ Refactor the parser
        ⑂ why is this slow?
        ⑂ alternative approach
      ✻ Claude Code 2
```

It runs **alongside** the original — you do not have to stop what the main session is doing,
and nothing said in the side chat ever reaches it. The original's record is untouched.

Worth knowing:

- **It is a copy, not a link.** The side chat knows what the original knew *at the moment you
  forked it*. Later turns on either side stay on their own side, and there is no way to merge
  one back into the other — if a side chat reaches a conclusion worth keeping, tell the
  original yourself.
- **It costs tokens.** The first turn carries the whole copied conversation, so forking a long
  one is not free.
- **Claude only.** Codex has no equivalent, so the items do not appear on Codex sessions.
- It inherits the original's account, model, project and surface — a side chat of a Chat
  session is a Chat, of a terminal session a terminal.
- The items appear only once a conversation has actually started. Before that there is nothing
  to fork, and a plain new session is the same thing.

### Switching surfaces mid-conversation

A session is not stuck on the surface it was created with. The `⋯` menu on a session row
offers **Show as Conversation** or **Show as Terminal**, and the conversation carries over —
the agent picks up exactly where it left off, with everything that was said before still in
its context.

It works because both surfaces drive the same conversation: they resume the CLI by the
session's own identifier and write to one transcript, so the surface is only how it is drawn.
Ask Claude something in the terminal, switch to Chat, and it can quote you back verbatim.

What the switch does cost is the running process — the agent stops and starts again on the
new surface — so a session in the middle of something asks first (unless you have turned off
**Ask before closing a running session**). Switching a session you are not looking at just
changes where it will open next time.

Two things to expect after switching **into** Chat: the terminal's scrollback is not
transferred (Chat redraws the conversation from the transcript instead, so tool output and
anything the CLI painted are summarised rather than reproduced), and Claude will start asking
for tool permissions in cards rather than in the terminal.

### Permissions

Neither agent has a terminal to ask in, and the two handle that differently.

**Claude Chat asks you, in the conversation.** A tool that would change something raises a card
in the thread — the command, or the diff for an edit — with Allow and Deny. Requests are shown
one at a time, so a turn that fires several tools does not stack up cards to be answered out of
context, and an answered card stays in place as a record of what was decided. Reading, searching
and the agent's own bookkeeping pass without interrupting you; everything else asks, including
tools added by future Claude releases. A pending request in a session you are not looking at raises that session's
attention dot in the sidebar.

**Codex Chat does not ask; it is sandboxed.** It runs with `workspace-write`, so it may read and
edit the selected project, and operations needing more than that fail rather than being silently
approved. Use the Terminal surface when a task needs Codex's full interactive approval flow.

### What is missing

It is early. Compared to the terminal you lose slash commands, plan mode, interrupting a turn
mid-flight, and some of the agent's richer rendering. Use it where you want the conversation to
read like a conversation; use the terminal when you need the complete agent interface.

## Display Panel

A terminal can only draw text. The display panel is the way around that: a third pane on
the right that Claude or Codex can put content into while you keep working in the terminal.

Ask for something visual — "show me that screenshot", "chart the bundle sizes", "render that
as a table" — and the panel opens beside the terminal. Close it with the **✕** in its header;
it reopens the next time the agent displays something. It can also be opened by hand — the
panel toggle at the toolbar's right edge, or **View ▸ Display Panel** — so its tabs (the
browser, Git Review, Session Info) are reachable without an agent putting content there first.

### Toolbar controls

Three buttons sit at the toolbar's right edge:

- **Context** (⋯) — a menu of what applies to the session on screen. So far: the **Theme**
  picker (the same one as the session row's `⋯` menu), with an *Edit Themes…* door to
  Settings.
- **Shell** — shows or hides the shell drawer under the session (same as ⌃`).
- **Panel** — shows or hides the display panel.

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

Available in every session, since every session is an agent conversation.

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

### Letting an agent change the theme

The same server gives agents `list_themes`, `set_theme` and `create_theme`, so you can ask the
session you are talking to for a different colour scheme and watch it change — no restart, no
trip to Settings.

- **"Use Ocean here"** sets it on that session alone. Ask for the project or the app default
  and it sets those instead; the same three scopes described under [Themes](#themes).
- **"Make me something warmer, like solarized but darker"** creates a new theme. Colours you
  do not mention are kept from whatever the session is using now.

Two guards, both because a terminal is where you would have to type to undo a mistake: an
existing theme is never overwritten (the agent is told to pick another name), and a palette
whose text cannot be read against its own background is refused outright.

Switch the group off in **Settings ▸ Tools ▸ Terminal theme** if you would rather agents left
your colours alone.

## Git Review

**View ▸ Git Review** (Cmd+Shift+R) opens a Review tab in the display panel: a native diff
viewer for the selected session's checkout, so you can watch what an agent is changing
without leaving the terminal. You can stage and commit from it; **discarding is deliberately
not offered** — everything the pane can do is reversible by the control beside it, and
throwing away a change an agent just made is not.

### The status card

Whenever the selected session's project is a git checkout, a small floating card sits at the
session pane's top-right corner showing the current branch and the uncommitted totals
(`+N −M`, untracked files included). It updates live as the agent writes — the same watcher
the Review tab uses — and **clicking it opens Git Review**, so the diff is one click away
without asking the agent for it. A clean checkout shows just the branch; a project that is
not a repository shows no card at all.

The chip at the top picks what is compared:

- **Uncommitted** (the default) — everything since the last commit: staged, unstaged and
  untracked files together. After an agent turn, this is "what did it do".
- **Unstaged** — working tree against the index, plus untracked files.
- **Staged** — what `git commit` would take right now.
- **Last Turn** — what changed since the agent most recently started working. The baseline
  is captured automatically each time a session goes busy; before the first turn of a launch
  the mode reports that no turn has been recorded yet.
- **Branch** — the whole branch against the repository's default branch (where it forked
  from `main`), including uncommitted work.
- **Commits** — the history: a scrolling list of commits with their `+/−` weight, drawn with
  a branch graph down the left edge (a ring marks a merge, a colour marks a lane) and the
  branch, tag and `HEAD` names that point at each commit. Click one to see its full diff, and
  **‹** returns to the list.

Each changed file is a collapsible row — its path, what happened to it (`+` added, `−`
deleted, `±` modified, `→` renamed), and its `+/−` counts. Small files open expanded; click
a row to open or close it. Untracked files appear as all-added diffs, binary files as a
`binary` note. The `+N −M` beside the chip totals the whole diff. Diffs are **syntax
highlighted** for the languages Skalman recognises by file extension; a file it does not
recognise renders plain rather than guessed at.

### Staging and committing

Two modes offer staging, because only their diffs are measured against the index:

- In **Unstaged**, each file row carries **Stage File** and each hunk a **Stage**.
- In **Staged**, the same controls read **Unstage**, and a composer at the top of the list
  commits what is staged — Return sends, Shift-Return breaks the line. Your message survives
  the pane re-reading itself, so staging more while writing one does not lose it.
- **Uncommitted** offers **Stage File** only: its diff is measured from the last commit, so
  it can speak about whole files but not about individual hunks.
- **Last Turn**, **Branch** and **Commits** stay read-only.

If the agent is running a git command at that moment, the write can lose the race for the
index; the pane says so in one line and the action can simply be repeated.

### Refreshing

The tab **watches the checkout** and re-reads a moment after the writes stop, so an agent's
edits appear without being asked for. Your place is kept: the scroll position holds, and a
file you opened or closed by hand stays that way. The ↻ button re-reads on demand, and a
session that stops working refreshes too. Paged-into history and an opened commit are left
alone — they do not change under you, and re-reading them would only lose your place.

Like every display-panel tab it belongs to its session: each session keeps its own review, in
its own mode, restored across relaunches.

Reads use git's `--no-optional-locks`, so watching a checkout never contends with the agent's
own git commands. Staging and committing do take the index lock, since a write cannot avoid
it — which is the one case that can report "the index is in use".

## Find

- **Cmd+F**: open find bar
- **Enter**: find next match
- **Esc**: close find bar
- Results counter shows "N of M"

## Inspect Mode

For pointing at the interface itself — when you want to tell an agent (or a person) *which
element* or *which spot* you mean, with a report you can paste straight into a conversation.

Two modes, both under the View menu:

- **Inspect Element** (**Cmd+Option+I**): a crosshair appears and the most specific view
  under the pointer is outlined live, with its class name and size in a badge. Click to
  capture it.
- **Inspect Geometry** (**Cmd+Option+Shift+I**): freeflow — nothing is detected. Guides
  follow the pointer across the window; a **click** records the exact spot, a **drag**
  rubber-bands and records the rectangle it drew.

**Esc** backs out of either. Invoking one command while the other is active switches mode in
place; invoking the same one again cancels. A capture ends the mode.

Every capture opens a report sheet holding a screenshot of the whole window with the capture
marked, and the report text:

- Element reports name the view's class, its frame, the view chain above it, and the view
  controllers responsible — the names a conversation about this codebase already uses.
- Point and region reports give the geometry twice: in window coordinates (bottom-left
  origin, what AppKit code speaks) and from the top-left (how anyone reading the screenshot
  counts).

The sheet also holds a **note field**: whatever you type there leads the copied text, so
"make this padding smaller" arrives above the evidence for it. Return in the field copies.

**Copy Report** puts the text on the clipboard as markdown. The screenshot is referenced by
its file path (saved under the temporary directory), because a path is the one form of an
image the agent CLIs can act on — so the pasted report lets an agent read the hierarchy *and*
open the picture.

The screenshot is taken from Skalman's own view tree, so it needs no Screen Recording
permission and can never include another app's window. The one honest gap: content another
process draws — a web page in the display panel — may appear blank in it.

## Appearance

### Sidebar
- **Cmd+Ctrl+S**, or the toggle button at the left of the header: show/hide the sidebar

### Font Size
- **Cmd++** / **Cmd+-**: increase/decrease font size

### Full Screen
- **Cmd+Ctrl+F**: toggle full screen

### Themes
Configure in **Settings > Themes**:
- 16 ANSI colors (8 normal + 8 bright)
- Foreground, background, cursor, and selection colors
- Import themes from Terminal.app (.terminal files)
- Export themes as JSON
- Duplicate and customize built-in themes (built-in themes are read-only)
- Live preview with sample output

**Use as Default** sets the theme every terminal uses unless it has been given one of its own.

#### Per-project and per-session themes

A theme can be set at three levels, and the narrowest one wins:

| Scope | Where to set it | Applies to |
|---|---|---|
| Session | The session row's `⋯` menu, or right-click ▸ **Theme** | That one terminal |
| Project | The project row's `⋯` menu ▸ **Theme** | Every session in it that has no theme of its own |
| Default | Settings ▸ Themes ▸ **Use as Default** | Everything else |

Each menu's **Inherit** item clears that level's choice and names what it falls back to, so
"Inherit (Ocean)" means removing this choice leaves the terminal on Ocean. A theme with no
choice anywhere follows the default wherever it moves — the level is remembered as *inherit*,
not as a copy of whatever was current at the time.

Deleting a theme leaves anything using it inheriting again. Renaming one keeps them.

Sessions shown as a conversation rather than a terminal are drawn in the system's own colours;
a theme sets only the backdrop behind them.

### Profiles
Configure in **Preferences > Profiles**:
- Font family and size
- Cursor style: Block, Underline, or Bar
- Cursor blink toggle
- Scrollback buffer size (default: 10,000 lines)

## Settings

Open with **Cmd+,**.

### General
- **New sessions use** — the agent the composer opens on; any other can be picked there
- **Name sessions after the agent's own title** — see [Names](#names)
- **Group sessions by branch** — see [Grouping sessions by branch](#grouping-sessions-by-branch)
- **Discover project icons** — see [Project icons](#project-icons)
- **Discover account avatars** — see [Icons and names](#icons-and-names)
- **Reopen the last session at launch**
- **Ask before closing a running session**
- **Report Codex turn boundaries** — see [Codex hooks](#codex-hooks)
- **Skip Codex hook review** — see [Codex hooks](#codex-hooks)
- **Shell path** — used by the shell drawer (⌃`); agents always launch via your login shell

### Motion

- **Working indicator** defaults to **Random**, choosing a new orb for each turn without
  immediately repeating the last one. Choose a named orb to use that animation every time.
- **Chat name transition** defaults to **Shape Morph**. Every available transition can be
  previewed on the page and used when the active chat is renamed.

Animation timing is tuned by Skalman rather than exposed as another preference, and transitions
honour macOS Reduce Motion.

#### Codex hooks

Skalman knows when a Claude session starts and finishes a turn because Claude reports it, which
is how a session's status dot stays accurate without guessing from terminal output. Codex can
report the same thing, but only from entries in `~/.codex/hooks.json` — a file you own, and one
another tool may already be using.

Both settings are **off by default** and do different jobs:

- **Report Codex turn boundaries** adds Skalman's entries to each Codex account's `hooks.json`.
  Anything already in that file is kept, and switching the setting off removes only what Skalman
  put there.
- **Skip Codex hook review** decides how those entries get permission to run. Codex refuses to
  run any hook until its exact text has been approved once, and that approval happens in the
  Codex terminal app — which a session Skalman launches never shows.

Leaving the second setting **off** is recommended. Open `codex` in a terminal once, approve the
hooks when it asks, and they work from then on: Skalman's entries are written so their text never
changes between launches, so one approval holds.

Switching it **on** means Skalman passes `--dangerously-bypass-hook-trust`, which runs *every*
hook in that config folder without review — not only Skalman's. Since an agent can write to
`hooks.json` itself, that would let an agent arrange for its own code to run unreviewed on the
next launch.

### Accounts
Per-account icons and names. See [Accounts](#accounts).

### Will it last?
The usage panel above the composer, and the toolbar's pill popover, say how much of each
window is spent. When Skalman has watched a window long enough to see a *rate*, it also says
where that rate leads:

```
5h  ████████████░░░░░░  62%
7d  ████████████████░░  85%
    7d spent by 19:40 · 8h early · Updated just now
```

The line appears only when the projection matters — when the window will run out **before** it
resets. A window that will comfortably outlast its own reset says nothing, because being told
you are fine is noise.

For Codex this works immediately: it records rate limits into its own transcripts, so Skalman
recovers the past week from disk the first time it looks. Claude records none, so its
projection appears after Skalman has watched the window for a while.

### Usage
Where your tokens went, read from the agents' own transcripts — the question the toolbar's
usage pill provokes and cannot answer. It says the week is 85% spent; this says what spent it.

It opens with the windows you are actually metered on — the join neither source can make
alone, since the rate-limit API reports no tokens and the transcripts know nothing about
windows:

```
RATE LIMITS · EVERLOF
  5 hours · 62%        4.0M      513 turns · resets in 1h 48m
  7 days · 85%        62.0M   10,865 turns · resets in 17h
```

Then by **checkout**, since a repository's worktrees are separate places doing separate work,
and by account, day and model:

```
300.0M                                    [Rebuild]
56,594 turns · measured 20 min ago

BY CHECKOUT
  sonda                            113.8M   ████████████
  inristo                           28.9M   ███
  AnotherTerminal                   24.6M   ██▌
```

Counts input, output and cache writes — the tokens a plan is charged for. **Cache reads are
excluded**, because they are the cheap path and would drown everything else.

Two things it gets right that are easy to get wrong, and both were measured here rather than
assumed. A turn copied forward by a resume, a compaction or a side chat is **counted once** —
on this machine 52.9% of all turns were copies, and counting them made the total look 157%
too big. And **subagent threads are counted**: a Task keeps its own transcript nested a level
deeper, its turns appear in no other file, and missing them understated the total by 56%.

The report is built in the background and remembered between launches, so the page opens on
what is already known. **Rebuild** re-reads every transcript now, which takes about a minute.

Claude only — Codex records its usage differently, and is not in these totals yet.

### Storage
Build output your projects can make again, and a button that removes it. Also reachable from a
project's own menu (**Reclaim Disk Space…**), though the page always reports every project —
what is worth finding is usually somewhere you were not thinking about.

Findings are grouped **by checkout**, because that is where the surprise is. A project with six
worktrees has six `target/` directories and six copies of `node_modules`, and only one of them
belongs to the folder you actually open:

```
sonda · SONDA-401-issued-artifact-publisher · 36.8 GB
    target                35.62 GB   Rust build output · cargo build · last written 2 wk ago
    web/node_modules       1.18 GB   Node packages · npm install · last written 2 days ago

sonda · main · 14.6 GB
    target                13.38 GB   Rust build output · cargo build · last written 1 day ago
    web/node_modules       1.18 GB   Node packages · npm install · last written 3 days ago
```

Under each heading is the checkout's full path, so a worktree name resolves to a place on disk
before you remove gigabytes from it. Directories a gigabyte or larger get their own row;
everything smaller folds into a single **"N smaller directories"** line — a codebase collects
dozens of tiny caches, and they used to bury the two directories holding the space. Click the
fold to show them, and **Show fewer** to close it again.

Every row says what it costs to bring back — the command that rebuilds it — and when anything
inside it was last written. A directory written in the last few minutes is marked **in use**,
which almost always means a build is running in it right now.

Remove one row, everything in one checkout, or everything found. Removals ask first, and say so
if a session is running in the project or if anything about to go was written moments ago.

**The page never makes you wait.** Skalman surveys the disk quietly in the background — at low
priority, and never while a session in that project is working — and remembers what it found
between launches. Opening Storage shows what is already known, with a line saying when it was
measured, and refreshes anything stale behind you. **Rescan** re-reads everything now.

**Agents can help, but cannot delete.** With **Settings > Tools > Disk space** on, an agent that
notices the disk is filling can read this same listing and *propose* a cleanup — "these three
worktree build directories are 60 GB and rebuild with `cargo build`". You get a sheet with
exactly what it proposes and why, and nothing happens until you approve. An agent can only
propose paths that already appear in the listing, so it cannot use this to delete anything else,
and it is told to propose rather than reach for `rm` itself.

**What is never offered.** Only directories that git ignores *and* that a known tool can rebuild
— `target` beside a `Cargo.toml`, `node_modules` beside a `package.json`, and so on. Ignored
files that are not build output are never touched, which matters more than it sounds: your
`.env.local` and your secrets files are ignored too. Anything a repository tracks is left alone
whatever it is called, even if `.gitignore` also matches it.

Removal is immediate rather than to the Trash, since space in the Trash has not been reclaimed.
Sizes are measured the way `du` measures them, counting a hard-linked file once however many
names it has — build directories are full of them, and counting each name would promise space
that deleting does not return.

### Profiles, Themes, AI
Terminal font and cursor, colour schemes, and AI provider configuration.

## Diagnostics

**Help > Reveal Diagnostics Log** opens the folder holding Skalman's own journal, one file per
day, kept for two weeks:

```
~/Library/Application Support/Skalman/Logs/skalman-<date>.jsonl
```

Each line is one event — the app launching and quitting, a session being started from the
composer (including the prompt), the command line each agent was launched with, and the exit
code it came back with. It is written as things happen rather than buffered, so the last line
before an unexpected quit is on disk.

A launch that never reaches its quit leaves its marker behind, and the next launch records
`Previous launch did not quit cleanly`, pointing at the macOS crash report from that run in
`~/Library/Logs/DiagnosticReports/`. That pair — what Skalman was doing, and what macOS
recorded about it dying — is what a crash needs explaining.

## Keyboard Shortcuts

### Projects & Sessions
| Action | Shortcut |
|--------|----------|
| New Session (opens the composer) | Cmd+N |
| Add Existing Project | Cmd+Shift+N |
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
| Terminal (display panel tab) | Cmd+T |
| Browser | Cmd+Shift+B |
| Files (display panel tab) | Cmd+P |
| Git Review | Cmd+Shift+R |
| Session Info | Cmd+Shift+I |
| Shell drawer | Ctrl+` |
| Inspect Element | Cmd+Option+I |
| Inspect Geometry (freeflow) | Cmd+Option+Shift+I |
| Bigger Font | Cmd++ |
| Smaller Font | Cmd+- |
| Full Screen | Cmd+Ctrl+F |
| Minimize | Cmd+M |
| Preferences | Cmd+, |

### Changing shortcuts

**Settings ▸ Keyboard** lists every command and the keys it answers to. Click a shortcut and
press the combination you want; Escape cancels and Delete removes the shortcut entirely. A
change takes effect immediately — the menu bar is updated in place rather than at next launch.

Skalman's own commands can be rebound. The system ones (Quit, Cut, Copy, Paste, Full Screen and
the like) are listed but fixed, so the page can answer "what already owns this key" without
letting a rebinding leave you unable to quit or paste. A combination already in use is refused
rather than taken from its current owner, and **Reset All** puts everything back.

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
