# Threading User Guide

A native macOS app for organizing coding-agent sessions. Projects live in a sidebar on the
left; the selected session's terminal fills the pane on the right.

## First Launch

A fresh install opens a short walkthrough instead of the main window — four pages, all
optional beyond the first click:

1. **Appearance** — pick the app's look from every built-in theme. The walkthrough itself
   restyles the moment you click a tile, and everything is changeable later under
   **Settings ▸ Themes**.
2. **Accounts** — the Claude Code and Codex logins found on this Mac, each with a switch that
   takes it out of use on the spot (the same switch as **Settings ▸ Accounts**), and whether
   the `claude`/`codex`/`grok`/`opencode` commands are actually reachable from your shell; a missing one shows
   the install command instead of failing later inside a terminal.
3. **Conversations** — chats you already have on disk, one list newest first, with the last
   two days pre-checked. Importing creates a project for each checked conversation's folder
   implicitly and adopts the conversations so they resume in place; **Skip for now** leaves
   everything where it is — each project's composer offers the same import later.
4. **Notifications** — what Threading would notify about, disabled until you press **Enable
   notifications** and macOS asks its own question. Skipping is fine: Threading will ask the
   first time there is genuinely something to say.

Closing the walkthrough quits the app and it returns on the next launch; finishing it opens
the main window. **Settings ▸ Advanced ▸ Welcome Tour** offers it again in two ways: **Show
Again…** opens it immediately over the running app, and **Clear Flag** makes the *next launch*
open with it — the true first-launch experience, main window held back and all.

## Layout

One window. The sidebar runs the full height on the left, listing projects and their sessions.
The terminal fills the rest, under a header naming the project and session currently shown.

A third pane opens on the right when an agent displays something the terminal cannot render.
See [Display Panel](#display-panel).

There is no title bar — the window controls sit over the top of the sidebar. That is also as
narrow as the sidebar goes: drag its divider and it stops where those controls end, and pushing
on past that stop closes the sidebar altogether. **⌃⌘S** brings it back, as does the sidebar
button beside the traffic lights.

Widening has no fixed limit — the sidebar takes whatever the terminal beside it can spare — and
the width you leave it at is the width it opens at next launch.

## Concepts

**Project** — a folder you've added. Named after its git repository when there is one, with
the current branch shown beneath.

**Session** — one Claude Code, Codex, Grok, or OpenCode conversation running inside a project. A session
outlives its terminal: when the agent exits, the terminal closes but the session stays in the
sidebar so you can resume the same conversation later.

**Terminal** — a standalone shell in the sidebar, for work that does not belong to a chat. Its
row, name, directory, branch and theme survive relaunch; its process and scrollback do not.

**Account** — a distinct agent login. If you have more than one, each is offered separately
when creating a session. See [Accounts](#accounts).

## Projects

### Adding
- The **+** at the top of the sidebar, beside the arrangement control — offers **Start from
  Scratch…** (name a new folder and Threading creates it) and **Use an Existing Folder…**
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
Within a project, chats and standalone terminals on the same branch gather under a quiet branch
heading. A heading first appears when some branch has more than one row — and from that moment
every row with a recorded branch gets one, so the tree is either fully flat or fully
labelled, never a heading beside a bare row whose branch you cannot see:

```
▾ sonda
  ▾ feature-auth
      ✦ Claude Code
      ✦ Claude Code 2
  ▾ fix-hover-state
      ✦ Codex            ← alone on its branch, labelled once any branch groups
```

A project where every session sits on its own branch stays flat — the extra level never
appears without earning its place. **Headings for Lone Branches** turns the second half of
this rule off, returning lone branches to the project level; sessions with no recorded
branch always stay there.

Each session remembers the branch of the checkout it runs in: recorded when the session is
created, updated each time it finishes working, and — by default — **kept in step while the
session sits idle**. Switch the checkout's branch anywhere — in another session, in the
shell drawer, in a terminal outside Threading — and every session standing in that checkout
follows, because that is the branch any of them would resume onto. **Settings > General >
Follow the checkout's branch** turns this off; sessions then keep the branch they last ran
on until they next run, filing old conversations under the branch they actually happened
on. Either way, the hover popover shows the session's recorded branch.

Branch headings collapse like projects do, showing a count of what they hide.

The grouping can be toggled from wherever you notice it, not only from Settings:

- **The arrangement control at the sidebar's top** — see
  [Arranging the sidebar](#arranging-the-sidebar)
- **The View menu** — **Group Sessions by Branch** (Cmd+Ctrl+B) and **Headings for Lone
  Branches** (Cmd+Option+B), both rebindable in Settings ▸ Keyboard
- **Hover a branch heading** — a small gear fades in at its trailing edge, opening a menu
  with both grouping toggles (checked when on) and **All Settings…**
- **Right-click a project row or a branch heading** — the same toggles sit in the context
  menu, with checkmarks showing the current state
- **Settings > General > Group sessions by branch** — the persistent home of the setting

### The sidebar's top and bottom
The band at the top of the sidebar carries the app's brand at its left — the Threading mark,
which stitches itself in when the app launches (skipped under Reduce Motion), beside the
app's name — and two quiet controls at its right: **+** to add a project, and the
arrangement control described below. Both the brand and **Settings**, at the sidebar's
bottom-left, sit on the same left margin as the rows between them, icon and word.

A build that is not a release names itself beside Settings: a quiet **NIGHTLY**, **BETA**
or **DEV** mark, so a screenshot or a bug report always says which kind of build produced
it. Hovering it spells the name out; a release build shows nothing there. The exact version
stays out of the chrome — it lives in the About box.

The mark answers the pointer: it lifts while the pointer is anywhere over the brand row, and
a click turns it one sixth of a turn — the mark has six strands, so it lands back on itself.
Nothing is opened by the click; the brand names the window rather than pointing anywhere.
Both are skipped under Reduce Motion. A theme can restyle the whole row — its own logo, its
own wordmark, even a gradient or image behind the list — see [Themes](#themes).

### Arranging the sidebar
The arrangement control at the sidebar's top opens the sidebar's view
options in one menu: how sessions group (**Group Sessions by Branch**, **Headings for Lone
Branches** — disabled while grouping is off), then how they sort:

- **Sort by Order Added** — the order sessions were created in; the default
- **Sort by Recent Activity** — the most recently active session first
- **Sort by Name** — alphabetical, case-insensitive

A pinned session leads the list under every order — pinning is a stronger statement than
any sort. Sorting rearranges branch groups too: a group sits where its first session would.

Rows move rather than blink. A session that starts fades in while the rows below it slide down,
one that is archived or deleted takes the gap with it, and a row that changes place — a session
hoisted to the top under Recent Activity, or gathered under a branch heading — travels there.
Under Reduce Motion every row simply arrives in place.

### Choosing a navigator

An enabled extension can replace the complete list area with another navigator: a project
outline, activity inbox, lifecycle view, grid, or a composition with its own host-rendered search
and filters. Choose it under **View ▸ Navigator**. The choice is remembered, while **Native**
always returns to Threading's built-in project and session list.

The extension changes only the column's interior. Threading still owns the divider, collapse
behavior, theme, accessibility, keyboard focus, and project/session navigation. If the selected
extension stops, reloads, or returns an invalid view, the visible column immediately returns to
Native; the extension can be selected again after a valid process generation registers.

### Project icons
Every project row carries an icon: the project's own mark when one is known, a **generated
tile** — the project's initial on a colour hashed from its name — until then, so projects
tell apart at a glance from the moment they are added. Threading finds the real mark itself —
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
`~/Library/Application Support/Threading/IconResearch/<project>.jsonl`, openable from the menu
above. Each stage also logs live, viewable with
`log stream --predicate 'subsystem == "codes.threading" AND category == "agent"'`. Codex itself
keeps its usual rollout under `~/.codex/sessions/`, like any other run.

Agents can also set the icon from inside a session through the `set_project_icon` MCP tool
(Settings > Tools > Project icon), e.g. "use our logo as this project's icon".

Icons are stored small (64px) under Application Support and never touch the project folder.

### Code statistics
**Rest the pointer on a project row** and a popover opens with what the project's code is
made of: total lines of code and files, a **language-composition bar**, and a legend naming
each language with its share and line count. Languages past the top five fold into a muted
*Other* — unless only one would fold, which keeps its own name. The last line says when the
count was taken.

The counting is done by [`scc`](https://github.com/boyter/scc), which answers a whole
repository in tens of milliseconds. **Without scc installed the popover says so instead** —
it names the one command that gets it, `brew install scc`, and counting starts on its own
within a minute of installing; no relaunch, no button. Counts refresh on their own: shortly
after launch, when a session stops working (the moment the code most likely changed),
periodically while the app runs, and on the hover itself when the reading is more than a
minute old. A count honours `.gitignore`, skips minified and generated files, and never runs
while a session in the project is working.

### Managing
**Hover a project row** — a **+** and **⋯** fade in at its trailing edge. The **+** opens the
chat composer straight away; **right-click it** for **New Chat…** or **New Terminal**. Clicking
the project row itself also opens the chat composer. The **⋯** opens the project's actions, also
available on **right-click**:
- Rename Project…
- Reveal in Finder
- Project Icon — see [Project icons](#project-icons)
- Group Sessions by Branch (checked when on)
- Headings for Lone Branches (shown while grouping is on)
- Remove Project — removes it from the sidebar only; saved conversations are never deleted

Click the disclosure triangle to collapse a project. Expansion state is remembered, and a
collapsed project shows how many chats and terminals it is hiding as a count at its trailing edge.

## Sessions

### Creating
**Select a project in the sidebar.** Its composer fills the pane, and starting a session from
it is the only way to create one:

- Click the project row, or
- **Cmd+N** — opens the composer for the project you are currently in, or
- **New Session** on the empty pane — when no session is selected, the pane offers the same
  route Cmd+N takes

The composer sits at the **bottom of the pane**, the way a chat input does, and the room above
it holds the Threading mark over a greeting that changes as you move between projects — it
knows the time of day and the calendar, and only sometimes says so.

**Two chips sit above the box: where the session runs, and who it runs as.** The first reads
**AnotherTerminal ▸ master** — the project, then the checkout inside it — or just the project
name for a folder that is not a git repository. The second reads **Claude Code · work** — the
agent, then the login it will run as, where that agent has more than one to choose between.
Point at either for the detail: the location chip's tooltip names the folder the session will
actually run in.

**The location chip's menu answers two different questions, and keeps them apart.** At the top
are the places this session can run: this checkout, any other checkout of the same repository
you have added, then **New Worktree…**. Picking one of those routes the session and leaves
everything else exactly as you left it, half-written prompt included. Under the line,
**Switch Project** opens every project (with its folder), plus **Add Existing Folder…** and
**Create New Folder…** — the same actions the sidebar's + offers. That one *moves* the
composer, which starts its choices over, so it lives one layer in rather than in the same list
as the checkouts.

With no projects at all, the empty pane shows this composer directly with the chip reading
**Choose a project…** and its menu skipping straight to the projects, since choosing one is the
only question there is. Type your task first if you like and pick the folder second — the words
follow the composer into the project you choose. The send stays disabled until there is somewhere
to run, and says so when you point at it.

**The identity chip's menu is the same shape.** Your logins for the current agent come first,
each with what is left of it (see
[Usage when picking an account](#usage-when-picking-an-account)); under the line are the other
agents. Picking a login keeps the agent; picking an agent moves to that agent's preferred
login. The agent you are already on has no row of its own — the chip is showing it.

**The prompt is focused the moment the composer appears**, however you got there, so the
first message can be typed straight away without clicking the field. If a draft is waiting,
the caret lands at the end of it — typing continues the sentence rather than cutting in front
of it.

There is no shortcut that starts a session for you. A session carries up to four decisions —
agent, account, model, and which checkout it runs in — and the menu items that used to create one
outright answered them with defaults you never saw. The composer asks, and it is replaced
by the conversation the moment you send the first message, so it costs nothing to pass through.
Where the session is drawn by Threading rather than shown as a terminal, the box you typed in
travels to where the conversation replies from instead of being swapped out, so the thread you
land in is visibly the one you were writing in. Reduce Motion lands it there at once.

Everything the session *runs with* sits on the row along the bottom of the prompt box, rather
than above it with the two chips: the model, how much it may do before it asks, the surface it
is shown on, and the account's usage reading beside the send — see
[Usage when picking an account](#usage-when-picking-an-account). Above the box is who and
where; inside it is what with.

Every chip's dropdown is Threading's own menu, and it tracks like a menu should: click to open
and browse, or **press, drag onto a row, and release** to choose in one motion. Arrow keys
move the highlight, **Return** chooses, **Escape** lets the menu go. **Typing while it is
open filters it** — what you type echoes across the menu's top, rows that match keep their
ink while the rest dim, and the highlight lands on the first match, so a long account or
theme list is a few letters and Return. Escape backs out one layer at a time: the first
press clears a half-typed filter, only the second closes the menu.

The same menu serves **every right-click in the window** — sidebar rows, the file tree, Git
Review's files, the terminal, the composer's attachments — so filtering, drag-to-choose and
the keyboard work identically everywhere, and the menu opens at the pointer rather than at
some corner of what was clicked. Rows with more behind them carry a chevron: they open beside
the menu on hover or **→**, **←** steps back out with the parent still highlighted, and a
choice anywhere in the chain answers the whole menu. Only the menu bar at the top of the
screen remains the system's own.

The model chip names the model the session will **actually run on** — `Fable 5 · 1M`, not
"Default". Its menu's first row means "leave the choice to the agent", and names what that
resolves to, marked with where the name came from:

- *(account default)* — the model your account is configured to use, in its `settings.json`
  (Claude) or `config.toml` (Codex), or the default set by your organisation. A setting you can
  go and change; choosing this row explicitly and leaving it alone are the same thing.
- *(in use)* — what the agent picked for **this** conversation, reported when it started. Shown
  when your account configures no model, so the running session can still name what it is on.
- *(last used)* — what this account ran the last time nothing was chosen, either watched by
  Threading or read back from the account's own transcripts. This covers sessions you ran in a
  plain terminal too, so an account that has never been used in Threading still names its model.

It falls back to "Agent's choice" only when none of those can answer — a login that has never run
this agent anywhere at all. That wording is literal: nothing has chosen yet, and the agent will
decide at launch. Threading does not guess what it would pick, because that is negotiated with
the service and is not recorded on your machine.

The menu also offers any model your login has beyond the standard ones (`Opus`, `Sonnet`,
`Fable`), read from the agent's own cache — `Fable 5 · 1M`, for instance, which no plain alias
names. Those three aliases always mean *the latest* of each family, so they stay current on their
own as new versions ship.

For **OpenCode**, provider login and model selection stay in its own TUI. Run `/connect`, choose
**OpenRouter**, and enter the key there; use `/models` to choose any OpenRouter model, including
xAI/Grok. Threading neither reads nor stores the OpenRouter key. OpenCode's account, model,
permission, and Chat-surface chips are hidden because those choices are not equivalent to the
Claude/Codex host controls.

For the standalone **Grok** runtime, the first launch uses xAI's own login. Model selection remains
in Grok's live/custom catalog (`/model` in Terminal), while Threading can set the opening Terminal
permission posture because Grok exposes the same six modes. Threading does not read Grok's login.

The location chip lists places, not branch names: this checkout (the default, always first),
any other checkout of the same repository you have added, and **New Worktree…** under them,
which creates one on a new branch and adds it as its own project. A branch nothing is
checked out on is not offered — there would be nowhere to run — so making a worktree is how
you get one.

The prompt box **grows as you type**, up to about eight lines, then scrolls. **Return sends
it**, and so does **⌘Return**; **Shift+Return** or **Option+Return** breaks the line. This is
the same box, and the same key, as a reply inside a running conversation — see the Keyboard
setting below if you would rather Return always broke the line. Under the box sits
**Import _n_ conversations** when this project has conversations it could adopt.

To give every new chat the same standing instruction, enter an **Opening Message** under
**Settings ▸ General**. Threading appends it after the task you write and sends both as the
chat's first turn. For example:

> Rename this chat to a ONE-WORD, ALL-CAPS name that represents it.

It is sent once to Terminal and Native chats, including side chats and cross-provider
continuations. Reopening or resuming an existing chat does not send it again, and imported
conversations receive nothing. The sidebar's initial name still comes from the task you typed,
not from this reusable message.

**If you write long briefs, say so** under **Settings ▸ Keyboard ▸ Composer**, at *When writing
a prompt, press Return to*. The default — **Do What the Composer Expects** — sends from any box
with a send control in it, which is every prompt you write to an agent. **Start a New Line**
gives Return back to the text everywhere, leaving ⌘Return as the send; **Send** makes Return
send in the report fields too. Whichever you pick, three keys never change: **⌘Return** always
sends, **Shift+Return** and **Option+Return** always break the line, and Return while an input
method is still converting a word belongs to the input method rather than to the send.

**Drop or paste a file** into it. An ordinary file has its path inserted, which is what the
agent can act on. An image instead appears as a thumbnail above the text; use the **×** on its
corner to remove it before sending, or click the image to open Threading's media inspector. With
keyboard focus, Space or Return opens the same view, and arrows move through all the images in
the prompt. Right-click for Inspect, the default app, Reveal in Finder, image/name/path copying,
System Quick Look, or removal. The image's path stays out of what
you type and is added only when the prompt is submitted. An image with no file of its own — a
screenshot straight from the clipboard, a picture dragged out of a browser — is written to a
temporary file first, so the session can still open it.

**The terminal takes a drop too**, and answers it the same way: dropping a file on a running
session puts its path where the cursor is, escaped so a name with spaces stays one path, with
a space after it so a second file lands beside the first rather than glued to it. An image with
no file of its own is written out first, exactly as in the composer. This is what every terminal
does with a dropped file, and it is the only way to hand an agent a picture — neither CLI can be
given pixels, only a path to them.

**A dropped image becomes an image, not a path.** The drop arrives as a paste rather than as
typing, and that is the difference an agent reads: drop a PNG, JPEG, GIF or WebP on a running
Claude Code and it becomes `[Image #1]` in the prompt instead of a line of path. Codex does the
same for a single PNG or JPEG.

**A format the agent cannot open is converted for it.** A photo out of Finder is a HEIC and a
scan is often a TIFF, and neither CLI takes either — so one is written out as a PNG first,
keeping its name, and that is what the paste names. It happens per session and per agent: a GIF
goes to Claude Code untouched and is converted for Codex, because only one of them reads GIFs.
The file you dropped is never altered or moved. Turn it off under
[Profiles](#profiles) when you want the agent handed the original.

**The shell drawer converts nothing.** A path handed to a shell has to be the path you pointed
at — you may be dropping that HEIC onto a half-typed `sips` command — so drops there are the
plain path they always were.

Whatever you type into the composer is kept as a **draft** for that project, saved as you
type. Switch projects, quit, or lose the app to a crash, and the text is still there when you
come back to it. Starting the session clears the draft — and writes the prompt to the
diagnostics log first, so even a launch that goes wrong leaves the message recoverable.
See [Diagnostics](#diagnostics).

### Status
Running and dormant are told apart by the text itself: a **dormant** session — one whose agent
has exited but which can be reopened — is greyed out. There is no permanent "running" marker,
so the sidebar stays quiet until something actually wants you.

Three things do get an indicator, at the trailing edge of the row:

| | Meaning |
|---|---|
| **Spinner** | The session is working |
| **Filled dot** | It has stopped to ask you something and cannot go on until you answer |
| **Hollow ring** | It finished something while you were looking elsewhere |

The filled dot is the one worth interrupting yourself for: that session is doing nothing until
you reply. The ring only means there is something to read.

Either mark clears as soon as you select that session. Answering a question mid-turn puts the
row back to the spinner rather than leaving it blank — the session is still working, and it says
so.

Hovering a session row swaps the indicator for two buttons, so the list stays quiet until you
reach for it: a **⋯** holding the row's actions — Archive, Close Session, Rename, Delete — and,
outboard of it at the row's trailing edge, an **archive** button that files the session away in
one press without opening the menu first. The archive button is the menu item's shortcut, not a
second behaviour.

Close and Archive sound alike and answer different questions. **Close Session** ends the
agent but keeps the row — greyed out, ready to be resumed. (It ships without a keyboard
shortcut — **Cmd+W** closes tabs and pages, never an agent — but can be given one in
**Settings ▸ Keyboard**.) **Archive** files the whole session away: the row leaves the sidebar for
**Settings ▸ Archived**, where it can be restored or deleted for good, and a running agent
is stopped first rather than left running with nothing listing it. Neither touches the
conversation itself. Closing a running session asks first, and that question can be switched
off — see [Confirmations](#confirmations).

**Archiving asks nothing, and hands you the way back instead.** The row leaves the sidebar
immediately, and a small band appears at the bottom of the sidebar naming the session, saying
whether its agent was stopped, and where it went — with **Undo** on it. The band stays for about
six seconds, and a thin line along its lower edge shows how much of that is left. Rest the
pointer on the band and both stop, so it will not disappear while you are reaching for it; move
away and the band starts over with its full time again. Undo puts the row back where it was and
reopens the session if it was the one on screen; the agent is not restarted, so the session comes
back dormant with **Resume** on it, exactly as it would after Close. Miss the band and nothing is
lost — the session is in **Settings ▸ Archived**, which is what the band's second line says.

**Archive several in a row and the bands wait their turn.** Each one carries its own Undo, so
none of them is thrown away to make room for the next: the second band appears when the first
leaves, and so on. You can see that one is waiting — the band gains a card edge above it, one per
receipt still to come, so a band with more behind it never looks like the last thing that
happened. Only the last few are kept if you archive faster than you can read — the sessions
themselves are all in **Settings ▸ Archived** either way.

**A session can also file itself away when you ask it to.** "Commit this and then close the
session" is one instruction, and the agent can now carry out both halves: it finishes the work,
answers you as usual, and the session is archived a moment after that answer lands — never
before, since archiving stops the agent and would otherwise cut its reply off mid-sentence. The
band that appears says which agent did it and, if it gave one, what it had just finished, and it
stays on screen for about fourteen seconds rather than six, because nobody clicked anything and
you may well be reading elsewhere. **Undo** works exactly as it does for an archive you performed
yourself. Agents archive only when asked to; if you change your mind before the turn ends, saying
so is enough — the agent takes the request back. The capability is **Settings ▸ Tools ▸ Session
lifecycle**, and switching that group off removes it.

How it works: an idle agent writes nothing to its terminal, so sustained output means it is
working, and output stopping means it has finished. A terminal bell counts as an explicit
request for attention. This is a heuristic rather than something the agents report directly —
it applies equally to Codex and to plain shells running a long command.

Redraws caused by resizing the window — or by scrolling inside a program that handles its
own scrolling, like Claude Code — are ignored, since an agent repainting itself is not the
same as an agent working.

A session that has just queued something in the background — a test run or a build the agent
left running while it answered you — keeps its working mark and stays out of the finished
states until that work lands. Claude ends its turn straight away in that case and picks the
conversation back up on its own once the command exits, so a session waiting on its own shell
has not finished anything and does not notify as though it had.

Only the turn that *started* the work waits on it. Something long-lived that the agent parked
earlier — a dev server it started three answers ago — does not hold later turns open, so those
finish and notify as usual while it keeps running.

### Notifications

The same states can reach you outside the app. When a session stops to ask for an approval,
finishes off screen, or finishes its turn while Threading is behind another app, a macOS
notification is posted — with sound only for the blocked case, matching the filled dot's
urgency. Clicking it brings Threading forward and opens that session. When the project has an
icon, the banner carries it as a thumbnail, so a glance says which project wants you.

Banners only appear while Threading is in the background; in the app, the sidebar marks above
are the cue. A notification is withdrawn on its own the moment it stops being true — the
question is answered, the session is opened, or the agent starts working again — so
Notification Center holds only things still waiting for you.

Turn it off with **Notify when a session needs you** in General settings. macOS's own
notification permission also applies; it is requested the first time there is something to
say. Sessions that report their own turn boundaries (Claude, and Codex with hooks enabled)
notify on finished turns; plain shells never do.

**Choosing which ones arrive.** Under that switch, each of the three has its own row, and each
row shows the sentence its notification would say:

| Setting | What it covers |
|---|---|
| **Blocked on an approval** | A turn has stopped on a permission request and is waiting. |
| **Finished while you were elsewhere** | A session away from the pane finished or asked something. |
| **Finished a turn in the background** | A turn ended while Threading was behind another app — the chattiest of the three. |
| **Play a sound** | Only the blocked alert ever sounds; the other two are silent either way. Off keeps the banner without the ping. |

**Silencing one chat or one project.** **Session Options ▸ Mute Notifications** in a session's `⋯` menu quiets
that conversation; the same item on a project row quiets the whole checkout, including sessions
started in it later. A session follows its project unless you answer for it — so you can mute a
busy project and leave one conversation audible, or the reverse. The item reads **Unmute
Notifications** whenever the chat is currently silent, whichever level silenced it. Anything
already showing in Notification Center is withdrawn as you mute.

### Scrolling
When the running program handles the mouse itself (Claude Code scrolls its own transcript),
the scroll wheel is passed to it, matching how other terminals behave. Hold **Option** while
scrolling to scroll the terminal's own scrollback instead.

### Selecting text
Drag to select, double-click for a word or a bracketed expression, triple-click for a line, and
shift-click to extend what is already selected. **Cmd+C** copies, as does **Copy** in the
terminal's right-click menu; neither touches the clipboard when nothing is selected.

**Settings ▸ Profiles ▸ Selection ▸ Copy selected text to the clipboard** makes selecting enough
on its own, the way it works in a Linux terminal. It is off until you turn it on, because macOS
keeps a single clipboard rather than a separate selection — with this on, a stray drag replaces
whatever you last copied. Selecting nothing still leaves the clipboard alone, and a program that
handles the mouse itself takes the drag before a selection can start, exactly as it does for
scrolling above.

### Resuming
Selecting a dormant session reopens it, resuming the prior conversation where it left off.
When a session's agent exits while you're watching, the pane shows a **Resume Session**
button rather than relaunching automatically.

Resuming works by session id:

| Agent | First launch | Resume |
|-------|--------------|--------|
| Claude Code | `claude --session-id <uuid> --name <title>` | `claude --resume <uuid>` |
| Codex | `codex` (id discovered after launch) | `codex resume <uuid>` |
| Grok | `grok --session-id <uuid> -- <opening>` | `grok --resume <uuid>` |
| OpenCode | `opencode` (id discovered after the first prompt) | `opencode --session <ses_…>` |

Claude Code and Grok accept ids chosen up front, so Threading assigns them. Grok is marked
resumable only after its supported session listing confirms the conversation exists; quitting
the first browser-login screen therefore leaves it safe to launch fresh again. Codex assigns its
own id, which Threading reads back from the rollout file Codex writes on launch. OpenCode also
assigns its own id; Threading reads the supported JSON session listing for the newest conversation
in that checkout.

**Sessions that were running when you quit come back on their own.** With **Relaunch sessions
that were running at quit** on (Settings ▸ General ▸ Startup, the default), the next launch
resumes them in the background: the last session you had selected opens on screen as before,
and the rest come up behind it, one per second, most recently used first. Their sidebar rows
show them idle and ready, and opening one attaches a session that is already running instead
of resuming it on the click. Only what was live at quit comes back — closed and archived
sessions stay dormant — and after a crash nothing relaunches automatically.

### Continuing with another provider

Right-click a recorded chat and choose **Continue with…** to start a new session with any other
runtime: Claude Code, Codex, Grok, or OpenCode. The source stays resumable. Threading freezes its
visible conversation into a provider-neutral snapshot, creates a new provider-native conversation,
and sends that snapshot through the safest launch path the destination supports. Private reasoning
is not copied; bounded tool calls and results are copied as untrusted context.

The new chat remembers the whole provider/model path across repeated continuations. Native Chat
shows it in a **Context handoff** divider above the conversation; every session, including
terminal-only OpenCode, shows the retained path in its sidebar hover card. Click the divider's
source endpoint to return to the previous chat. If an older row was deleted, its frozen provider
and model label remains but it is no longer navigable.

Claude/Codex Terminal and native Chat use Threading's private paginated history tool. OpenCode
receives the snapshot with its `--file` launch option. Grok Terminal receives a bounded inline
copy because Grok's TUI has no per-launch MCP or file-attachment flag; Grok Chat uses the private
history tool through ACP. Very long snapshots keep the newest context and say when earlier
content was omitted.

### Standalone terminals

Choose **New Terminal** from a project's hover **+** to add a terminal row and start its shell.
The process stays alive while you visit other chats or terminals, preserving cwd, history and
scrollback for the app launch. Exit leaves a dormant row; select it and choose **Start Again**
to open a fresh shell in its last directory. Closing the row ends the process and removes its
saved terminal record.

As the shell changes directory, its row follows the most specific already-added project folder
that contains that cwd in the same git worktree. It moves beneath that project's current branch
heading too. Moving somewhere unrelated leaves it under the project where it was created. A
terminal-specific theme wins first; otherwise it inherits from the project it is currently
shown under, then from the app default.

### The shell drawer

**⌃`** (Control-backtick), or **View ▸ Shell**, opens a tabbed drawer underneath the session
you are reading. The first time it opens it holds the session's shell; the **+** at the end of
its strip adds more — another shell, or a browser (private too). Drag the strip above it to
resize; push it on past the drawer's floor and the drawer closes, the same gesture that closes
the sidebar and the display panel at their dividers. Tabs reorder by drag or their
secondary-click menu, exactly as the display panel's do, and **⌘⇧[ / ⌘⇧]** and **⌘1–⌘9** work
here when the drawer has focus.

It is not a session of its own — shells used to be, and it was the wrong shape: there was no
conversation to resume, no transcript, and nothing to come back to. It belongs to the session
instead, and every session has one.

- A shell opens **where the agent currently is**, not where the session started — a terminal
  session reports its directory, so a shell opened while the agent is deep in a subpackage
  starts there. Sessions Threading renders natively open in the project folder.
- It uses the **session's theme and font**, so it matches the surface above it.
- Each session keeps its own drawer tabs, and its own answer to whether the drawer is open —
  both survive a relaunch (a shell's *process* does not; it restarts on first reveal). The
  processes stay alive while you work elsewhere, so your directory and history are still there
  when you come back; closing a tab ends that tab's shell, and closing the session ends them
  all. The drawer's height is remembered for the window.
- It is hidden while Settings or the new-session composer is on screen — neither is a session,
  so neither has a shell — and comes back with the session when you return to it.

Shell sessions from earlier versions are removed when your state is upgraded. They held
nothing — no conversation, no transcript, and no saved scrollback — and every session gains a
shell of its own in exchange.

### Importing
Conversations you started outside Threading — in a plain terminal, say — can be adopted into a
project and then resumed like any other session.

Select a project and the composer shows an **Import _n_ conversations** offer under its prompt
box once it has finished looking. Opening it lists what was found, newest first. Picking one adds it to the
project already resumable; it is not launched, so selecting it in the sidebar is what reopens
the conversation.

Search it by title, by agent, or **by session ID** — paste a whole one, or type any fragment of
one. Each row carries the first eight characters of its ID down the right-hand edge, which is
usually enough to tell two conversations with near-identical titles apart; when your query
matches further into an ID than that, the row slides its window along to show you the part that
matched. Whatever matched is marked in the row, ID included.

Threading finds these by reading the transcripts both CLIs already keep — Claude under
`<config>/projects/`, Codex under `<codex home>/sessions/` — across every account it knows
about. Titles come from Claude's own conversation title where there is one, otherwise from the
first thing you typed.

Two kinds of transcript are deliberately left out:

- Conversations the project already tracks, so nothing is offered twice.
- Transcripts with nothing you typed in them. Codex writes a rollout for its own approval
  reviewer, in the same folder and against the same project, and a session you opened but
  never spoke in has nothing to resume either.

### Closing
- **Cmd+W**: closes the focused drawer/panel tab, or the page on screen — never the agent
- Right-click > **Close Session**: ends the agent, leaving the session dormant and resumable
- Right-click > **Delete Session**: removes it from the sidebar entirely, after asking — the
  agent's own transcript stays on disk and can be imported again, which is what the sheet says

### Confirmations
Some actions stop and ask first. The ones you can safely undo carry a **Don't ask again**
checkbox, and it is remembered **for that one prompt only** — ticking it on the close sheet
does not stop the account-move sheet asking. It is also only remembered **when you go ahead**:
tick the box and then press Cancel and nothing is stored, because the next attempt would
otherwise sail past an action you had just declined.

A few actions ask nothing at all and put the way back on screen afterwards instead — archiving
a session is the one to know about. A question stops you every time you meant it in order to
catch the once you did not; an **Undo** sitting in the corner for six seconds costs only the
mistake.

Statements get the same courtesy as questions. When an extension command finishes, it may
confirm with a short message — "Checks refreshed." — and that alert carries a **Don't show
this message again** checkbox, remembered for that one command only. Failures always show,
whatever you hid: a command whose errors stopped appearing would look like it was working.
Hidden messages come back all at once with **Show All** on the same Settings card.

Everything you switch off this way has a row in **Settings ▸ General ▸ Confirmations**, so
there is always a way back:

- Closing a running session
- Moving a running chat to another account
- Continuing a running chat with another provider
- Switching a running chat's interface
- Quitting with agents running
- Removing an extension
- Revoking all website access

Quitting only asks when an agent is actually running, and never when the Mac is logging out,
restarting or shutting down — a dialog there would stall the system rather than help. The
conversations are kept either way and resume on the next launch; only the turn in flight is
lost. The alert says which of the two you are about to do: it counts the **turns in flight**
when any agent is mid-answer or stopped on a question, and otherwise counts the **sessions
open**, because closing a row of idle agents costs you nothing but their processes. Closing the
window is quitting and asks the same question: decline it, and the window stays open with
everything still running.

Nothing else offers the checkbox. Anything that deletes for good — removing a project,
**deleting a session**, deleting an archived session or a theme, reclaiming build directories,
clearing website data, running an extension command marked destructive — asks every time, and
puts **Return** on Cancel rather than on the action. So does anything that grants access outside Threading: a
website for the browser, a tool call, an unreviewed extension, or a shared chat link. Those
prompts have their own narrower memory instead — "Always Allow This Host" is one host,
"Allow for This Session" is one tool in one chat, and both are revocable in Settings.

### Names
A session is named after its conversation, never after its agent or account — the row's icon
and account mark already say which agent and login it runs on.

By default the sidebar follows the agent's own name for the conversation, which it updates as
the work develops: the terminal title for terminal sessions, and the title Claude records in
its transcript for natively rendered ones (including a `/rename` typed into the CLI). Until
the agent has named it, a session is named after its first prompt.

Renaming a session in Threading pins your own name instead, and it stops following the agent.
The rename sheet's **Use Agent's Name** button hands it back — it appears only when you have
given the session a name of your own, since that is the only time there is anything to undo.
Turn the follow behaviour off entirely under
**Settings > General > Name sessions after the agent's own title** — sessions then keep their
first-prompt names.

Rename via right-click in the sidebar, or right-click inside the terminal and choose
**Rename Session…**.

**Terminals name themselves after where they are and what they are doing.** A standalone
terminal's row, and each shell tab in the drawer, shows the command currently running in it —
`npm`, `ssh`, `vim` — and falls back to the directory when you are at a prompt: the path within
the project (`Sources/Threading`), or your shell's name (`zsh`) at the project's own folder,
where the project row above already says the folder name. A program that sets its own window
title, like `ssh` or `tmux`, gets to keep it until it exits. Renaming a terminal pins your name
over all of that, exactly as it does for a session.

**Rename with Agent** sits just below it and hands the job to the agent running in the chat.
Threading sends it one line asking it to name the conversation in a few words, and the name
appears in the sidebar when it answers. This is worth reaching for because a chat is named
after its *first* message and keeps that name however far the work moves on — the agent's own
title, in practice, is chosen early and then rarely revisited.

Two things to know. It costs one short turn of your usage, which is why it never happens on its
own. And it appears only when there is an agent running, it is between turns, and **Settings ▸
Tools ▸ This session** is switched on — the agent renames the chat by calling a tool, so with
that group off there is nothing to ask. A name you typed yourself still wins: the agent's name
is stored underneath it and shows through if you ever clear your own.

### Copying identifiers and paths
Everything about a chat that is needed *elsewhere* sits in the right-click menu's **Copy ▸**
submenu:

- **Agent Session ID** — the agent's own id for the conversation: what a `--resume` takes in
  a terminal and what the transcript file on disk is named after. It appears once the agent
  has named the conversation, so a chat that has never launched does not offer it.
- **Threading ID** — Threading's own id for the chat. It never changes: not when the
  conversation moves to another account, not when it continues with another provider, not
  across resumes. It is what extensions, support files and the diagnostics journal key by,
  so it is the one to quote when the question is about the app. For Claude and Grok the two
  ids are the same string, because Threading mints the id and hands it to the agent; Codex
  and OpenCode name themselves, so there the two differ.
- **Worktree Path** — the checkout the session runs in: its project's folder.
- **Transcript Path** — where the agent's transcript lives on disk, for grepping or quoting.
  Shown when Threading knows how to find it (Claude and Codex).

A standalone terminal carries the same **Copy ▸** submenu with its own **Threading ID** and
the **Worktree Path** of the checkout it is currently standing in.

### Permission mode
How much a chat may do before it stops to ask. Claude Code and Codex support it, in one set of names:

| Mode | What it does |
|---|---|
| **Manual** | Asks before making any change. |
| **Plan** | Reads and proposes. Changes nothing. |
| **Accept Edits** | Edits files without asking. Commands still ask. |
| **Auto** | Decides for itself when to ask. |
| **Don't Ask** | Never interrupts — *refuses* anything that would need approval. |
| **Bypass Permissions** | No permission checks at all. |

Don't Ask and Bypass Permissions sound alike and are opposites: Don't Ask keeps quiet by saying
no, Bypass keeps quiet by saying yes.

Set it in three places:

- The **mode chip** in the composer, on the row inside the prompt box beside the model, when
  starting a chat.
- A single chat's **⋯** menu has a **Permission Mode** submenu, including an inherit item that
  follows the setting below.
- **Settings > General > Permission Mode** sets what new chats use. *Agent's Setting* is the
  default and changes nothing — Claude's own `permissions.defaultMode` and Codex's `config.toml`
  still decide.

Codex has no plan mode of its own, so Plan there stops it writing but does not ask it to plan;
the menu says so. Changing a running chat's mode applies the next time it launches — Claude's
own Shift+Tab moves it in the meantime, and Threading cannot see that.

OpenCode keeps its richer per-tool policy in `opencode.json`; its `--auto` option is not one of
these six postures. OpenCode sessions therefore show no Threading Permission Mode control.
Grok accepts all six postures directly; Manual is sent using Grok's spelling, `default`.

### Claude's Remote Control
Claude Code can hand a session to claude.ai and the Claude mobile app so you can check on it
or reply from your phone. That is Claude's own feature, not Threading's Remote Access below —
the two are separate, and a session can use either, both, or neither.

Claude normally decides this account-wide, in its own `/config`. Threading lets you set it per
chat instead:

- **Settings > General > Claude Remote Control** sets what new Claude sessions do. *Follow
  Claude's setting* is the default and changes nothing — the account's `/config` still
  decides. *Always on* and *Always off* override it.
- A single chat's **⋯** menu has a **Session Options ▸ Claude Remote Control** submenu:
  *Always On*, *Always Off*, or the inherit item, which follows the setting above. This is the one to reach for
  when you want everything reachable from your phone except one conversation.

Both take effect the next time the session launches or resumes. A chat that is already
connected stays connected until then — to disconnect one immediately, run `/remote-control`
inside it.

### Moving a conversation to another account
Hover a session's **⋯** menu and, when you have more than one login for that agent, a **Move
to Account** submenu lists the others. Choosing one moves the whole conversation there — it
resumes on the new account with its full history, exactly where it left off. Useful when one
account hits its usage limit and you want to carry on under another.

It works because a conversation is just a transcript on disk that the agent replays each turn,
so moving it is copying that file into the other account and pointing the session at it —
Threading never touches your login. The original is left untouched, so you can move back the same
way. A running session is stopped first, then moved.

Same agent only: a Claude conversation moves between Claude accounts, a Codex one between Codex
accounts. Moving *across* agents (Codex ↔ Claude) is a different thing entirely — their
histories aren't interchangeable — and isn't offered here.

One thing to keep in mind: moving to another account to keep working past a limit is fine when
the accounts are genuinely separate (your personal and your work login, say). Rotating through
accounts purely to dodge usage limits is the pattern Anthropic's terms discourage — Threading
leaves the choice, and the timing, to you rather than doing it automatically.

## Accounts

Both CLIs support multiple logins by pointing an environment variable at an alternate config
directory. Threading finds these automatically and offers each one when you create a session.

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
If you have a shell alias pointing at an account, Threading uses your name for it. Given:

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

### Switching an account off
Each row carries a **switch**. Turning it off withdraws that login from everywhere an account
is offered — the composer's identity chip, the new-session menus, the usage readings and the
import list — without deleting anything. The config directory, its conversations and the
sessions already running on that account are untouched, and those sessions still resume on it.
A switched-off account stays listed here, dimmed, so you can switch it back on; **Reset**
restores its icon and name and leaves the switch alone.

If the account you switch off is the CLI's default one, new sessions start on the first login
that is still on. Switch off every account for an agent and it stops being offered for new
sessions altogether.

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

### Usage in the session header
The header above the session shows how much of the current account's rate limit is spent —
each window labelled with its value, like `5h 43% · 7d 73%`, beside a small ring gauging
whichever window is closest to its limit. It follows the selected session's account, and
hides for shells and anything else without a metered login. The pill stays monochrome while
usage is comfortable; a value turns orange past 75% and red past 92% of its window. The
pill sits at the trailing edge of the **session pane** — when the display panel opens, the
panel's own controls slide right and the pill stays over the conversation it describes.

Hover it for the full picture: every rate-limit window (the 5-hour session window and the
weekly one), each with its own bar, percentage and reset countdown, plus how fresh the
reading is. The detail opens the moment the pointer settles on the pill and closes the
moment it leaves.

For Claude accounts the freshest numbers come from **Settings ▸ Privacy ▸ Live usage from
your Claude login**; without it the pill reads the CLI's local caches, which can lag by
hours. Refreshes are polite by design: they run when a turn finishes — the only moment the
number moves — and back off whenever the usage service asks for a pause, so watching the
pill never eats into the limits it reports.

### Usage when picking an account
Choosing a login is when the number actually changes a decision — an account at 90% of its
week is a poor place to start a long task — so the composer shows it twice over:

- **In the identity chip's menu**, each login carries its own `5h 43% · 7d 73%`, so the
  accounts are compared before one is picked. Within the line the values carry the ink:
  window names and separators sit back, and a value turns amber as its window nears the
  limit and red when it is nearly spent — the same colours the toolbar pill uses.
- **In the model chip's menu**, every model carries what a session on it would be measured
  against — the account's windows, plus that model's own where the plan meters one separately.
  This is the menu where a spent limit is escaped, since switching model is the way out of it.
  The same menu on a **running session's header** carries the same readings.
- **Inside the prompt box**, beside the send: the same short reading the toolbar's pill carries
  once the session is running, so the number you start on is the number you keep watching.
  Point at it for the detail — which account it belongs to, when each window comes back, and
  how old the reading is. It stays out of the way when the account has nothing to report.

A window is named by its length, and one that meters a single model adds that model: `5h`, `7d`,
`7d Fable` in a line; `5-hour`, `Weekly`, `Weekly · Fable` on a bar. So the same window is
recognisable wherever it is quoted.

Wherever a window is drawn as a bar — the pill's popover, **Settings ▸ Usage** — the bar carries
a **time mark**: a thin line at the point the clock has reached in that window. Fill short of the
mark means you are spending slower than the window refills; fill past it means faster. That comparison is the thing a bare percentage cannot tell you: 60%
spent is comfortable an hour before a reset and alarming four hours before one.

Values are the last ones fetched: the composer shows what is known and asks for a fresh
reading, so a login never read before fills in shortly after. Accounts with no usage source
show nothing at all, exactly as they show no pill.

Where the numbers come from, per agent:

- **Codex** — fetched from the account's own API login (`auth.json`), refreshed every few
  minutes and after the session finishes working.
- **Claude** — fetched with the account's `.credentials.json` when one exists. On most Macs
  Claude Code keeps its token in the Keychain instead; there Threading reads the usage feed
  Claude Code itself publishes through its status line when [Claudex](~/repo/claudex) manages
  it. No usage source means no pill.

Threading never stores or refreshes a login itself — it reads what the official CLI keeps, and
if a token has expired the tooltip says so and the CLI is the place to sign in again.

## Chat Sessions (experimental)

Normally a session shows the agent's own terminal. A **Chat** session instead lets Threading
draw the conversation itself — messages, tool calls and replies as native views rather than
text painted by the CLI.

Chat is available for **Codex, Claude Code, and Grok sessions** — not yet for OpenCode. Choose
**Chat (experimental)** from the surface chip when creating one. Codex keeps its app-server open,
Claude keeps one `claude --print` process open, and Grok uses its supported ACP stdio transport.
Each uses the same official CLI and login as its Terminal surface; Threading never reads a Grok
credential.

Chat runs the agent headlessly, so it draws on your subscription the same way the terminal
does. Claude Chat was previously withheld while Anthropic's terms were read as excluding
third-party headless use; they no longer are, and the surface is offered again.

Your messages sit in bubbles on the right; the agent's replies run down the left as formatted
text — headings, lists, code blocks and inline `code` rendered rather than shown as raw
markdown. A short instruction gets a small bubble; a long answer gets room to breathe. The
column stops widening past a comfortable reading measure, so a wide window gives you margins
rather than very long lines, and a rule marks where each new exchange begins.

The reply box accepts images the same way as the new-session prompt: drop or paste one to see a
removable thumbnail above your text. Click the thumbnail to open the media inspector; its
right-click menu has the same file and clipboard actions, with System Quick Look as a fallback.
This follow-up composer belongs to Chat sessions; a
terminal session continues to use the agent CLI's own image input.

**What the next message will be sent with lives inside the reply box**, on a row along its
bottom: the **model**, the **permission mode**, the **reasoning effort** where the provider
offers one, and **Fast** or **Standard**. The context meter and the send sit at the other end of
that same row. Changing the model, the effort or the speed applies from your next message onward:
Claude takes it without restarting, Codex takes it with the next turn.

The **permission mode** chip is the same choice as Permission Mode in a session's **…** menu, and
it shows the mode that will actually apply: the one this chat has chosen, or the app-wide default
from Settings, or **Agent's Setting** when neither has. A running Claude chat changes mode there
and then. Everywhere else the choice is recorded and the menu says so, with **Applies the next
time this chat starts.** under the modes. If a mode is one the agent will not accept, such as
Bypass Permissions on a chat that was not started with permissions skipped, the chat says why
instead of pretending the change landed.

The line **above** the box is the session talking rather than something you set: the working orb
and a word for the turn in flight while the agent runs, and after it what the last turn cost —
`Ready · last turn 47s · ↓ 1.2k tokens`.

### Referencing and commenting

Use the **…** beside one of your messages or an agent response to **Add … to chat** or
**Comment…** on it. The reference lands above the reply box as a small receipt instead of pasting
a long quote into your text. You can type an accompanying message, send the receipt by itself, or
open its menu to add a comment or remove it. After sending, the same receipt stays with your message
so it is clear what the agent was answering.

The same pattern reaches beyond messages:

- secondary-click a code line in Git Review or an edit tool's diff to add or comment on that line;
- secondary-click a changed-file row to reference/comment on the whole file, including an image;
- in **Attachments**, select an item and use **Chat…** to add it or comment on it;
- secondary-click an image already waiting in the reply box and choose **Comment…**.

Several references and comments can be staged together. The reply box keeps them as compact count
receipts; opening a receipt lists the individual messages, lines, and files. This works the same in
Claude, Codex, and Grok Chat. OpenCode currently uses its terminal surface, so it has no Threading
Chat reply box to receive these receipts.

Tool calls appear as a single collapsed line: a glyph, the tool, what it ran, and how much it
returned — `$ Bash · ls -la · 42 lines`. Click to expand. A directory listing is usually
longer than everything said around it, so it stays folded until you want it. The rows sit flat
against the background until you point at one — a busy turn is mostly tool calls, and boxing
each of them buries what was actually said.

A call that went wrong says so: its glyph becomes a red **✗** and the row reads `Edit ·
failed`. That covers failures the provider admits to and ones it does not — shell output that
plainly reports `command not found` or a non-zero exit code marks the row even when the CLI
called it a success. A call still unanswered when its turn ends reads **stopped** rather than
`running…` forever.

Once a turn finishes, the work itself folds away: what remains is your message, a one-line
**"Worked for 42s"**, and the agent's final reply. Click the line to unfold the tool calls and
intermediate steps beneath it. A turn you stopped mid-way stays open so you keep your place —
it folds when you send the next message, labelled "Stopped after" rather than "Worked for".
Reopened sessions fold their past turns the same way, timed from the transcript's own clock.

While the agent works, the view no longer chases the newest line. Sending a message lifts it
toward the top and holds it there while the reply streams in below; scrolling up releases the
view to you and nothing moves it until you scroll back near the bottom, which resumes
following. The scrollbar and mouse wheel always win over the stream.

A long message of your own — a pasted log, a briefing past a screenful — collapses to its
first eight lines behind a fade. **Show full message** opens it in place, and **Copy**
always copies the whole thing, collapsed or not.

At the trailing end of the reply box's control row, beside the send, a quiet **context meter**
says how full the conversation's context window is: a percentage for Codex, which states its
window, and a token count for Claude, which does not. It turns amber past 90% — the point where
compaction or a fresh session is worth considering. This is the conversation's own weight,
distinct from the account usage pill's rate limits.

When a turn changed files, a **changed-files card** closes it out: the files as an indented
tree, `+/−` counts beside every file and rolled up per directory, with single-child folders
compressed into one `src/lib` row. Small turns (up to 5 files and 200 lines) open expanded;
bigger ones start with the folders closed so a wide sweep stays one line per area. Click a
folder to open just it, **Collapse all**/**Expand all** for the whole tree, and **View
diff** to open Git Review on the Last Turn scope — offered on the latest turn's card, since
that is the turn the scope describes. The card appears for turns run live in this window;
reopened conversations don't reconstruct old turn diffs.

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

A session is not stuck on the surface it was created with. Use the interface button in the
session header to switch directly to the other one: it shows a chat symbol in the agent's
terminal UI and a terminal symbol in Threading's native UI. For an explicit choice, open
**Session Options ▸ Interface** from either the session row's `⋯` or the header's **Context**
menu. The two menus are the same menu, including their current-surface checkmark.

The conversation carries over — the agent picks up exactly where it left off, with everything
that was said before still in its context.

It works because both surfaces drive the same conversation: they resume the CLI by the
session's own identifier and write to one transcript, so the surface is only how it is drawn.
Ask Claude something in the terminal, switch to Chat, and it can quote you back verbatim.

What the switch does cost is the running process — the agent stops and starts again on the
new surface — so a session in the middle of something asks first (unless you have turned off
**Ask before switching a running chat's interface** — see [Confirmations](#confirmations)).
Switching a session you are not looking at just changes where it will open next time.

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
tools added by future Claude releases. A pending request in a session you are not looking at
raises that session's filled attention dot in the sidebar — the turn is stopped until you answer.

**Codex Chat does not ask; it is sandboxed.** It runs with `workspace-write`, so it may read and
edit the selected project, and operations needing more than that fail rather than being silently
approved. Use the Terminal surface when a task needs Codex's full interactive approval flow.

When Claude or Codex delegates work, both Chat and Terminal show a **Subagents** summary with live working/done
counts and, when the provider reports them, the child's current tool, elapsed time, tool count,
and token count. Select a child to open its conversation in the display panel; child output
stays out of the parent's transcript. Both providers show structured child text, thinking, tool
calls, and results, including nested delegated agents.

Switching between Chat and Terminal keeps the same child list and transcript links. A compact
copy of that navigator is also restored after relaunch; any child that was still running when
the app stopped returns as **Stopped**, not as a spinner for a process that no longer exists.
Claude can additionally rebuild its hierarchy from its own saved child index. A child's full
saved transcript is loaded only when you open it. The compact row shows a provider name or short
agent id, never the transcript's filesystem path; use its folder button to reveal that source in
Finder. Provider response envelopes such as Claude's `<analysis>` are presented as **Reasoning**
rather than exposed as protocol markup.

### Commands and skills

Type **/** at the start of the Chat composer to see the commands available in that live
session. Type **$** for Codex skills; Claude skills use Claude's own slash syntax and therefore
appear with the other `/` entries. Continue typing to filter by name, alias, or description.
Use Up/Down to move, Tab or Return to insert the selected entry, and Escape to close the list.
Insertion does not run it: add any arguments you want, then submit normally. **/skills** opens
the same list filtered to skills.

Claude supplies and updates its own catalog, including project/plugin skills and command
metadata. Commands that would replace or detach the underlying Claude conversation, plus
internal or sensitive interactive workflows, remain visible but disabled in Chat until
Threading can keep its transcript and process state synchronized; use Terminal for those rows.

Codex Chat enables the operations it can execute through app-server — **/compact** and
**/review [instructions]** — plus the skills available in the current checkout. Familiar Codex
TUI commands are still identified: unsupported ones are shown disabled with a Terminal
explanation instead of being sent accidentally as prompts. **/status** is handled locally for a
provider/model/run-state/context summary, and **/skills** is the shared skill browser. Running a
skill keeps its instructions and local path inside Codex on the Mac.

The iPhone conversation composer receives the same live catalog. Its plus button browses all
entries, and typing `/`, `$`, or `/skills` works as on the Mac. The phone receives presentation
metadata only; the Mac resolves and executes the selected action against the still-current
session. An unknown leading Claude slash command remains at the start of the provider message —
shared-chat attribution never moves it out of command position.

### What is missing

It is early. Compared to the terminal you still lose plan-mode controls, interrupting a turn
mid-flight, shell shortcuts, and some of the agent's richer rendering. Use it where you want the
conversation to read like a conversation; use the terminal when you need the complete agent
interface.

## Remote Access (beta)

Open **Settings > Remote Access**, choose **Relay**, **Tailscale**, or **Private + Sharing**, and turn on
**Remote Access** to mirror Threading from a browser or the Threading iPhone app. Relay supports
ordinary public share links; Tailscale keeps the connection inside your tailnet; Private +
Sharing uses Tailscale for owner pairing and starts the relay when you create a one-chat link.
**Owner Relay Fallback** separately lets your own devices use that relay if Tailscale is
unreachable; **Keep Sharing Relay Ready** starts it immediately. Both are off by default. The
Tailscale readiness card tells you whether installation, sign-in/running, or private HTTPS Serve
needs attention. **Open in Browser** tests the
client on the Mac, and the page shows an owner-device QR code for the native app. Pairing is for
your own
trusted devices: a paired owner can see your unarchived chats, manage them, and approve bounded
Native permission requests. To involve somebody else, use a session's **… > Share Chat…** and
choose an invitation for that chat alone. The sheet names each grant and what it withholds:
**View only** follows the chat but cannot type, prompt, or answer a permission request;
**Collaborator** adds typing and prompts while permission requests still come to you; and
**Collaborator + approval** adds answering those requests, which lets the agent run commands and
change files without asking you. View only needs the chat to be running — watching alone never
starts an agent — so its button waits, and says why. The invitation works once and expires after
24 hours only if unused. Acceptance creates a device-bound membership that lasts until
**Stop Sharing** or explicit member revocation. Unused invitations and accepted memberships are
kept in the Mac login Keychain, so disabling Remote Access or restarting the app suspends them
without silently making collaborators rejoin. Permission approval is an explicit right for that
member and chat; it never grants another chat, Mac settings, or the ability to create shares.

You can pair several phones and tablets with the same Mac. Each receives a separate Keychain
credential and can control sessions concurrently; Settings lists and revokes them independently.
The iPhone still shows that Mac once even when it knows both a Tailscale and relay address. It
follows the connection policy chosen on the Mac, shows the active route beside its connection
status, and can fail over or adopt an advertised stable relay address without being paired again.

You can also pair one iPhone with several Macs. **Devices** shows the current Mac and compact
switch targets for the others; choosing one swaps the session list without re-pairing. The app
remembers the selected Mac and the last open session. Because continuity uses the paired host
identity rather than its current URL, switching between Tailscale and relay keeps the same saved
state, while two different Macs that happen to expose the same provider session id remain
separate.

For a shared session, choose its live input mode in the Mac's **Sharing** pane (or from the
control menu on iPhone/browser):

- **Collaborative** — everyone with reply access can send; completed terminal lines and Native
  prompts are still submitted atomically.
- **Focused** — one person controls the Claude Code/Codex terminal or Native composer while the
  others watch and keep their private drafts. The controller or owner can hand off at any time,
  and the owner can always reclaim control or switch back to Collaborative.

This can be changed while the session is running; it is not decided permanently at startup.
Set the starting choice for newly shared chats under **Settings > Remote Access > New shared
chats**. Control belongs to a person across their connected devices, not to the most recent tab.
If a guest controller drops offline, a 30-second grace period preserves the turn across a normal
Tailscale/relay reconnect before it returns to the owner. Revoking the controller returns it
immediately. A watcher can use **Request control**, which reaches the current controller through
the existing human-only **@** attention path. It never sends anything to Claude/Codex, and push
delivery follows that recipient's separate **Requests for my input** notification setting.

Each open device or browser tab has its own live presence row. In Native chats, every device keeps
its own draft; sending waits for the Mac's acknowledgement before clearing the exact submitted
text. If another composer wins the current turn, the session changes, or reconnect cannot safely
retry, your draft stays in place with an explanation.

Unsent Native drafts are saved as you type on macOS, iPhone, and the browser. Independent iPhone
terminal drafts are saved the same way. iPhone and browser also reopen the last session and restore
the reading position for Native conversations and agent-UI terminals; the Mac restores each Native
conversation's draft and reading position. This state is device-local rather than collaborative:
another person or one of your other devices does not inherit half-written text or pull your view
away from where you left it. Drafts are retained until sent or cleared; older position-only records
may be pruned.

Agent-UI terminals use **Independent terminal drafts** on iPhone by default. Type in the composer
below the terminal and send when the line is ready; the entire line and Return reach Claude Code
or Codex as one PTY write, so another phone cannot mix its keystrokes into yours. Escape, Ctrl-C,
Tab, and arrow controls remain immediate. In the iPhone notification settings, **In-app
collaboration** lets you independently hide people presence, hide typing indicators, or turn off
independent drafts to restore raw direct terminal typing. These in-app indicators never create a
push notification.

Focused control is enforced on the Mac, not merely by disabling a button. A watcher may edit a
draft, select and scroll terminal output, and follow the session, but raw keys, paste/drop, mouse
reporting, atomic terminal sends and Native prompt sends are refused. Only the controller's
devices influence the shared terminal grid. Switching between Tailscale and relay does not
change who holds control; a reconnect receives the current host-authoritative state.

Use the separate **@** button beside a Native composer—or above an agent-UI terminal—to ask a
specific chat member for input. The sheet includes accepted members who are away and allows a
short optional note. This is a human-only attention request: it sends no prompt to Claude or
Codex and no bytes to the terminal. A successful request appears as a quiet collaboration event
in open views and can notify the selected person's phone. **Requests for my input** is its own
notification setting. Repeated pokes to the same person are briefly collapsed.

### Who is watching

The session status card at the pane's top-right grows a row whenever a chat can be reached from
outside this Mac: **2 following** while somebody has it open, **Shared** while a link exists and
nobody is on it. Click the row — or use the **Sharing** tab in the side pane — to see the whole
picture:

- **Watching now** — every live view, including multiple devices or tabs belonging to the same
  person and your own paired devices, which are marked as
  yours. Each row says what they may do, which surface they are on, and the terminal grid they
  are holding it at. Somebody composing a reply shows as typing.
- **With access** — people who accepted an invitation and are not looking right now, with when
  they joined and when they were last seen. **Revoke** ends their access immediately and closes
  anything they have open; because the invitation was single-use, letting them back in means
  sharing the chat again, so this asks first.
- **Invited** — links nobody has used yet, with when each was created and when it expires.
  **Copy** puts it back on the clipboard; **Revoke** withdraws it without touching anybody who
  already accepted a different one.

Your own paired devices carry no Revoke here: they are paired to the Mac rather than to one
chat, so unpairing them belongs in Settings, and the section links there.

A shared chat sizes itself to the window it is opened in. A collaborator's browser asks the Mac
to reflow the terminal to the width it can actually show — the same lease the iPhone takes, given
back when the page closes — while a view-only page, which is never allowed to resize your
session, shrinks its own type until the whole grid fits its frame instead. Two clients watching
one chat settle on the grid both can display, which is why the Sharing pane prints each one's:
the chat is held at the smallest.

A dormant session can be resumed remotely; a running agent UI mirrors its terminal scrollback
and accepts keyboard input, while Native sessions show the conversation, composer, and
permission cards. Long Native conversations initially open at their newest messages. Pull near
the top or choose **Load earlier messages** to fetch older pages without losing your reading
position. A permission whose edit diff is too large for a bounded remote snapshot must be
reviewed on the Mac, so a remote device can never approve from a partial preview.

On iPhone, use the toolbar's **Workspace** button for **Browser**, **Review**, **Files**, and
**Attachments**. If an agent opens a page, Threading does not pull you away from the chat. The
Workspace icon gives one subtle pulse and keeps a small dot until you open Browser. Browser is a
read-only follow view of the Mac tab: the Mac still owns navigation and interaction, and private
tabs never send a preview. The Workspace is available only to a paired owner device, not one-chat
guest links. Attachment files are still fetched only when you choose one, and only if the file
remains inside that session's checkout.

The iPhone explains notifications in the dashboard before asking iOS for permission. They cover
accepted shared chats, Native permission cards, a session that changes into waiting for your
response, explicit human input requests, and updates you explicitly ask an agent to send when it
finishes. Every category can be disabled independently, with a master sound switch and separate
sound switches for each category. Opening one goes directly to its chat;
permission details and Allow/Deny stay behind the authenticated chat rather than appearing on the
lock screen. Terminal UI prompts are not parsed, so use the app's **@** control when a person
needs attention. With APNs provider credentials the notification reaches a suspended phone;
otherwise the settings page marks the connection **Live only**. For `notify_user`, “me” follows
whoever wrote the current turn; an explicit request can instead target the owner, everyone in
this chat, or a named member. Open sessions show the device-aware live roster and **Name is
typing…** without locking anyone out of a composer; the iPhone exposes separate switches for
both indicators.

The iPhone and browser keep their own bounded, content-free connection history; it is not sent to
the Mac by default. From **Diagnostics** on iPhone, or beside the Mac on the browser dashboard, a
paired owner can choose **Share diagnostics for 30 minutes**. Existing and new connection events
then join the Mac's share-safe support timeline until the timer expires, you stop sharing, or the
client closes. Raw logs, messages, prompts, terminal output, paths, URLs, notification text and
credentials are never sent, and one-chat guest links do not get this control.

Every link is a password, but an owner pairing code is much more powerful than a one-chat guest
link. It is a one-time bootstrap exchanged for a unique device credential kept in Keychain on
both Mac and iPhone. Turning Remote Access off or quitting closes every connection and suspends
both paired-owner and one-chat guest credentials. They are restored from the Mac login Keychain
when Remote Access starts again; use **Stop Sharing** or revoke a named member/device to remove one
permanently. A Tailscale pairing has a stable private origin and reconnects after restart.
Threading refuses to replace an unrelated Tailscale Serve handler already using its HTTPS 8443
endpoint. The current Cloudflare Quick Tunnel changes origin at restart. A phone that can still
reach the Mac through Tailscale can learn the new route; a relay-only pairing still needs a new
scan. The client now prefers a stable relay endpoint whenever the Mac advertises one, but this
phase does not provision the planned named Cloudflare Tunnel. Without `cloudflared`, Relay is unavailable;
without a signed-in Tailscale installation, Tailscale is unavailable. **Open in Browser** still
works locally. See [Remote access](docs/REMOTE_ACCESS.md) for
pairing, notifications, the complete security model, and beta limitations.

## Display Panel

A terminal can only draw text. The display panel is the way around that: a third pane on
the right that Claude or Codex can put content into while you keep working in the terminal.

Ask for something visual — "show me that screenshot", "chart the bundle sizes", "render that
as a table" — and the panel opens beside the terminal, taking about a third of the window the
first time and the width you last dragged it to after that. Drag its divider to resize it; drag
it all the way to the edge and the panel closes. Close it with the **✕** in its header;
it reopens the next time the agent displays something. It can also be opened by hand — the
panel toggle at the session header's right edge, or **View ▸ Display Panel** — so its tabs (the
browser, Git Review, Session Info) are reachable without an agent putting content there first.

The tabs are yours to arrange: drag one along the strip to reorder it, middle-click one to
close it, or use its secondary-click menu — **Close Tab**, **Close Other Tabs**,
**Close Tabs to the Right**, **Close All Tabs**, then **Move Left** / **Move Right**. The
order is the same one the agent sees, and it survives a relaunch. **⌘⇧[** and **⌘⇧]** step through the strip, and
**⌘1**–**⌘9** jump to a tab by its place in it. The same gestures and menu, with the same
commands, work on the shell drawer's tabs.

**Opening a picture properly.** Click an image in the panel, or focus it and press **Space**, to
open Threading's media inspector inside the same window. It starts fitted; pinch or press
**⌘+**/**⌘−** to zoom, drag to pan, and double-click or press **Z** to switch between Fit and
100%. Arrow keys or a horizontal swipe move through a collection and the thumbnail rail jumps
directly to an item. **Space** or **Escape** closes and returns focus to the image you came from.
The inspector's **⋯** offers copying, Finder, the default app, and **Open in System Quick Look**
as the last-resort system viewer. The panel's own **⋯** advertises the same routes.

**The panel gives way to the window.** Showing an image opens the panel, and an open panel used
to put a floor under how narrow the window could be made. It no longer does: drag the window's
edge in and the panel is squeezed with everything else. Its own width is still yours — drag the
divider to set it, and it opens there next time.

Shell and browser tabs can also change *pane*: drag the tab off its row and the other pane
opens on its own to take it — a closed drawer or panel springs open the moment the drag
leaves its home row, the receiving tab row shows a quiet wash while the drop would land, and
the tab dims to say it is on its way out. Drop it at the spot you want; it lands in exactly
that slot. Let go anywhere else and everything springs back. The same move is in the tab's
secondary-click menu — **Move to Shell Drawer** on a panel tab, **Move to Display Panel** on
a drawer tab. Either way the tab moves live — a shell keeps its process and scrollback, a
browser keeps its page — and the new home survives a relaunch. The panel-only surfaces
(Review, Info, Files, comparisons) stay where they are one of a kind.

### The session header

Every session sits under a header of its own, at the top of the pane: the **page tab** naming
what is on screen and a **+** for a new session on the left, then what the session's account
has left to spend, then what can be done to it. It belongs to the pane rather than to the
window, so it moves when the sidebar is dragged or collapsed instead of drifting over the
project list.

There is deliberately **one** page tab, not a row of them: switching a session swaps the whole
workspace — its drawer, its panel, its sidebar selection — so the sidebar is the session
switcher, and this chip names where you are (a session, the new-session composer, or a
Settings page). Click it to reveal the current page's row in the sidebar; its × (or **⌘W**)
closes the page back to the empty pane — which never stops the agent; the session stays in
the sidebar. For hopping between recent sessions, use the **‹ ›** history pair or ⌃⌘←/→.

The window's toolbar keeps only the controls that act on the window rather than on a pane,
beside the traffic lights: the **sidebar toggle**, and the **‹ ›** history pair — Go Back and
Go Forward through your selection history (**⌃⌘←** / **⌃⌘→**), the way Xcode retraces
editors. Sessions, composers and settings pages all count as places; deleted sessions fall
out of the history.

**Open in** sits just before those, as one split control: the icon of the app you last opened
something in — VS Code, Xcode, Zed, a terminal, Finder — and a chevron welded to it, sharing a
single surface. Press the icon (or **⌘O**) and this session's checkout opens there; take the
chevron to pick a different app, which then becomes what the press does. Hovering lights only
the half under the pointer, so the two presses stay tellable apart. Only apps you actually have
installed are listed, and a terminal is only ever offered a folder. The control hides on a
Settings page, which has no checkout.

The same **Open in ▸** submenu appears wherever a folder or a file is named: on a project row
and a session row in the sidebar, on a row of the **Files** tab, and — the useful one — on a
right-click in **Git Review**, where it opens the file *at the first line the diff changes*.

Four buttons sit at the header's right edge:

- **Context** (⋯) — the same full menu as the session row's `⋯`: pinning, archiving, side
  chats, **Theme**, **Permission Mode**, **Session Options** (Interface, Claude Remote
  Control, Mute Notifications, Attachments), rename, the **Copy ▸** submenu, account moves,
  sharing, deletion, and any installed extension actions that apply.
- **Interface** — switches directly to the other renderer. Its icon points at the destination:
  chat for Threading's native UI, terminal for Claude Code's or Codex's own UI.
- **Shell** — shows or hides the shell drawer under the session (same as ⌃`).
- **Panel** — shows or hides the display panel.

Five kinds of content:

- **Images** — screenshots, generated charts, design assets. Anything `NSImage` reads: PNG,
  JPEG, GIF, HEIC, PDF, SVG. A picture the agent shows lands as a row in **Attachments**, selected
  and previewed, rather than as a tab of its own: the pictures a session shows are a history, and
  a strip of near-identical tabs was a poor one. Showing the same file again refreshes that row
  instead of adding a second. (A session that has no project folder — nothing to keep a list
  against — still gets a tab per image.)
- **HTML** — wide tables, charts, Mermaid diagrams, side-by-side diffs, rendered reports.
  It is a real browser engine, so scripts run and libraries load from a CDN; an agent can
  pull in Chart.js or Mermaid rather than hand-rolling SVG.
- **Comparisons** — two files against each other in a Compare tab. Two images open an
  interactive comparison: drag the seam across the picture (or arrow-key it; Space recentres),
  and pick the mode from the chip — **Wipe** in either direction, **Fade** (hold it in the
  middle for an onion skin), **Difference** (identical pixels go black, so any change leaps
  out), or **Side by Side**. Each side is named in the margin beside the picture rather than
  on top of it — old where the wipe starts, new where it ends, above and below for the vertical
  wipe — so no title ever sits on the pixels you are comparing. Mismatched pixel sizes are
  flagged rather than silently normalised. The button beside the mode chip **opens the same
  comparison at the window's size**, where the seam has room to be dragged and the modes are
  the same chip; Escape or the × closes it, and the mode and the position you left it at are
  the ones the panel comes back to. Two text files render as a native diff instead.
  Agents open comparisons with a before and an after; you can open your own with the panel's
  **+ ▸ Compare Files…**, which asks for exactly two files (first chosen is the old side).
  The mode chip and both buttons sit in a row at the top of the tab, so they stay put while a
  tall screenshot scrolls under them.
- **Sending a comparison to someone** — the ⇧ button in that row (or **Export Comparison…** on
  the tab's right-click menu) writes the comparison as a web page the recipient opens in any
  browser, with no copy of Threading and nothing to install. The exported page carries the same
  five modes: they can drag the seam, hold the fade, and ask difference the same questions you
  did, and it opens on whichever mode you left the tab in. A text comparison exports as the
  same diff. The save panel offers two formats: **Single Page (.html)** is one file with the
  images inside it — the fastest thing to drag into a chat window — and **Folder in a Zip
  (.zip)** keeps the images as files beside the page, so the recipient also receives the
  originals, and it survives mail that strips `.html` attachments. Nothing in the page loads
  from the network, and it names the two files without saying where they live on your Mac.
- **Native scenes** — bounded semantic maps supplied by an agent or another MCP server. Treemaps,
  heatmaps, timelines, dependency maps, scatter plots, and similar views use Threading's active
  theme and native AppKit accessibility rather than HTML. The scene is stored with its tab.
- **Extension panels** — safe extensions can provide persistent native tabs made from Threading's
  own AppKit controls: text and status, actions, search fields, pickers, and interactive semantic
  maps. Treemaps, heatmaps, charts, timelines, and similar views follow the active theme and
  remain keyboard and accessibility navigable. They are declarative host UI, not extension HTML
  or code loaded into the app.

### Attachments

The **Attachments** tab is the session's visual history — the images and PDFs that went in either
direction, newest first. Two things land there:

- **What the agent surfaces.** A path it prints to an existing PNG, JPEG, GIF, WebP, HEIC, TIFF,
  BMP or PDF, in the terminal or in a native Chat reply, and any image it shows deliberately
  through the display tool. Code files are ignored because Git Review already covers them.
- **What you send.** An image you paste or drop into a composer, or drop onto a terminal —
  including the ones attached to the prompt that *starts* a session. These are marked **You** so
  the picture you just sent is findable next to whatever the agent made of it, rather than
  disappearing into the conversation.

Every row shows the picture itself and when it arrived — the time for today, the date before
that — and is marked **Agent** or **You**; when a session has both, a small **All / Agent / You**
filter appears beside the count. It stays hidden while everything came from one side. A picture the
agent shows opens this tab and selects its row, and resets that filter if it would have hidden it:
being asked to show something outranks a filter you left set.

Open **Attachments** from the session `⋯` menu's **Session Options** or the panel's **+** menu. The list
sits above an inline image/PDF preview; click an image to enter the same collection-aware media
inspector. **Open**, **Finder**, and **Copy Path** act on the selected file.

Images shown by earlier versions came back as one panel tab each. On the first launch after
updating, those tabs become rows in this list — same pictures, same order, one place.

When the session uses native Chat, **Chat…** adds the selected attachment to the reply box or opens
a comment prompt for it. The attachment becomes a compact context receipt; the original file stays
in this list and is not copied into the message text.

A file already inside the checkout is *referenced*: a new mention of the same path moves it to the
top and refreshes the preview, so the project file stays the source of truth. A file from anywhere
else — a screenshot in a temporary directory, something dropped from the Desktop — is **copied**
into Threading, because nothing else is keeping it: temporary files are cleaned up by macOS, and a
list pointing at one would empty itself. Those copies are removed when the row falls off the end
of the list or the session is deleted, and **Copy Path** gives you Threading's copy.

Paths merely *printed* are restricted to the session's checkout by default: any text can name any
file, and the list is what a paired phone can fetch, so one `find ~ -name '*.png'` in a terminal
would otherwise enumerate your pictures into it. Missing paths, unsupported file types, directories,
and symlinks escaping the checkout are ignored. Terminal discovery happens after an output burst
settles, so it does not need native rendering or an explicit MCP tool call.

You can change that answer. When a session has named files outside its project, a quiet band
appears at the bottom of the Attachments tab — the count, and **Show**. It is there only when the
setting would change *this* list, so a session that never names one never mentions it. Showing
them lists them and copies each into Threading, so a paired phone still only fetches files
Threading itself holds; **Hide** puts the list back to the project's own files without deleting
the copies, so the choice is reversible. The same switch is
**Settings ▸ General ▸ Attachments ▸ Include files outside the project**, and it applies to every
session. Images you attach and ones the agent shows are unaffected either way — those were handed
over on purpose.

Automatic detection is an opt-out feature and is enabled separately for both agents by default.
Use **Settings > General > Attachments** to turn **Detect attachments from Claude Code** or
**Detect attachments from Codex** off independently if a future CLI version changes how it
renders file paths. Turning detection off stops the *scanning* of that agent's terminal and Chat
replies. Images you attach, and ones the agent shows in the panel, still appear — those are handed
over deliberately rather than detected.

### The shared browser

**View ▸ Browser** (Cmd+Shift+B) opens a real browser tab belonging to the current session.
It has an address bar, history controls, persistent cookies, responsive viewport testing, and the
Web Inspector. Its overflow menu includes find in page, print, visible-page screenshots, 50–200%
zoom, recent downloads, current-site data clearing, and browser settings. The responsive toolbar
provides editable CSS-pixel dimensions, rotation, and desktop, tablet, foldable, and phone presets;
hiding it returns the page to the panel's natural size. These are honest viewport presets, not
claims of touch, device-scale, browser-engine, or complete hardware emulation.
When the browser tab is visible, Cmd+F opens its native find bar rather than the terminal's.

The agent driving that session sees and acts on this same tab—it can open pages, go back or
forward, reload, read a semantic page outline, click, hover, drag between page elements, type, and
select form options, set checkboxes and switches to an exact state, use single, double, right, and
middle clicks, send keyboard shortcuts with native focus and control behavior, wait for text, URL,
or element-state updates, inspect bounded console and network diagnostics, and return screenshots.
When exact browser or device conditions exceed the visible WebKit browser, the separate isolated
Playwright tool can run a fresh Chromium, Firefox, or WebKit context without importing the live
tab's cookies or credentials.

Use **Annotate Page** to place numbered notes directly over what you are reviewing. While the mode
is on the browser frames itself in the accent colour and shows an **Annotating** badge in its
bottom-left corner, so it is obvious that a click will leave a note rather than follow a link — press
Esc or the toolbar button to leave. The component under the pointer is outlined and named —
`button "Sign in"`, `link "Docs"` — so you can see what a pin is about to land on before you click;
pointing at the word inside a button highlights the button, not the word. Notes stay in
Threading's native UI rather than entering the page DOM, so the site cannot read or alter them.
Click an existing pin while annotation mode is active to edit or delete it. The agent can read the
notes for the currently authorized page with their document-space coordinates, clearly labelled as
user-authored context; it cannot create or change them.

Local development pages are available immediately. Before an agent can read or act on another
website, Threading asks whether to allow it once, always allow that origin, or deny it. Persistent
grants are listed under **Settings ▸ Tools ▸ Website Access**, where they can be revoked. Redirects
are checked again before the destination page is returned to the agent.

Passwords, file selection, download destinations, and form submissions stay with you. Threading
reveals the browser or opens a native sheet for those boundaries instead of passing their secrets
or decisions through the conversation. Console, network, CSS-query, and page-snapshot results are
explicitly marked as untrusted page data; request bodies, response bodies, headers, and cookies
are never captured for the agent.

When an agent reaches a password field, Threading comes forward, selects the session that asked,
opens its browser, and focuses that exact field — so your password manager's own shortcut, which
fills the focused field of whichever app is frontmost, lands where you meant it to even when the
request came from a session you were not looking at. A key-shaped **Private Input** control remains
visible while the field has focus; click it to return keyboard focus to the page after using the
browser chrome. Beside it, when the browser is wide enough, a quiet line names the one-touch ways
in: **Fill with 1Password or system AutoFill**. If WebKit/macOS offers an AutoFill suggestion for
the site, select it; otherwise use your password manager's macOS integration, copy from Apple
Passwords, or type privately. Threading never asks a vault for the credential, and the field's
value is unavailable to the agent, snapshots, waits, traces, and diagnostic logs. Passkey and
WebAuthentication prompts remain WebKit/macOS system UI. Filling a password does not approve
submission — the usual confirmation still applies.

### Visual baselines

A baseline is a picture of a page you have decided is correct. **Browser Options ▸ Save as
Baseline…** keeps the visible page under a name you choose, and the agent can compare the page
against it later without you handing over a file path. The command is also in **View ▸ Save as
Baseline…** with no shortcut assigned; give it one in **Settings ▸ Keyboard** if you use it often.

Deciding what correct looks like is yours, not the agent's. It can capture and compare, and it can
remove baselines it captured itself, but it can never replace, approve or delete one of yours. Some
pages are only yours to capture at all: an agent cannot type in a password field, so anything behind
a sign-in, a passkey or a two-factor prompt is a page only you can put a baseline on.

**Browser Options ▸ Visual Baselines…** lists the project's baselines with a thumbnail, the page they
came from, the conditions they were captured under, when, and who captured them. Rename, delete or
reveal one in Finder from there. **Agent can read this** is a per-baseline switch: anything captured
in a private tab starts off, because a private tab holds signed-in pixels and who captured them is a
different question from who may read them back.

Baselines belong to the **project**, not to one chat, so they outlive the session that made them.
Closing or deleting a chat leaves them alone. Removing the project deletes them, and the removal
confirmation says so.

When the agent compares the page against a baseline, the result opens as a **Visual diff** tab: the
baseline and the current page on the same wipe, crossfade, difference and side-by-side surface the
Compare tab uses, with the computed difference map as a second view. If the change is one you wanted,
**Accept New Revision** records the current capture as the baseline's new approved picture. The
picture it replaces is kept, so an approval is never the thing that destroys the last copy of what
you decided was right. The comparison tab itself is not restored after a relaunch — the page has
moved on by then, and the agent can run the comparison again in one call.

**Browser Options ▸ Hold a Baseline Over This Page…** draws a baseline over the live page with a
draggable seam. The page stays live underneath: every click but the one on the handle reaches the
page, so you and the agent can keep working while you watch it. Arrow keys move the seam. A
full-page baseline follows the page as you scroll; a baseline of a viewport is only true where it was
taken, so scrolling away says so in the badge rather than pretending the missing pixels are there.
Nothing about the overlay reaches the page, so a screenshot taken while it is up is of the page and
not of the overlay.

**Settings ▸ General ▸ Keep the page as it was before each agent action.** Off until you turn it on.
With it on, Threading photographs the page just before each thing the agent does to it, so the agent
can ask what its own click changed rather than guessing. Those pictures live in memory for the chat
only and never join your baselines. It sees the agent's actions and nothing else: your own clicks, a
timer, or a page updating itself are not covered, and the answer says so.

An agent can also compare the page against another open tab rather than against a baseline, which is
how staging is held against production. Both sites need your permission, because both are being
looked at. And a baseline can be captured at an exact device size and compared at that size later,
so a phone layout is checked against a phone baseline rather than being stretched into one.

A comparison can also cover what the page says about itself rather than only how it looks: load and
paint timings, console lines, requests, and accessibility findings, all recorded with the baseline.
Timings are held to a noise floor, so a few milliseconds either way is reported as nothing rather
than as a regression, and a warning that simply happened more often is not called new.

**Browser Options ▸ Show Layout Shifts** outlines where the page moved while it was loading, drawing
each box where the content *was* when you were looking at it. Pages WebKit records no shift data for
say so rather than appearing to have stayed still.

### Execution audit

Open **Execution Audit** from the display panel's **+** menu to review what an agent actually asked
tools to do. It is a factual event ledger, not an AI-generated explanation: tool names, call ids,
inputs, results, phases, timings, sources and provider are shown from their structured execution
feeds. Prompts, reasoning and assistant prose are never copied into it.

Use the category chips for Browser, Shell, Files, Network, Permissions, Subagents, Lifecycle or
other Tool activity. Source chips separate what the provider reported from what Threading's MCP
server actually received and executed; seeing both for one call is expected and exposes the handoff.
Search narrows the visible records. Select one to inspect its complete JSON, including its fidelity,
redaction paths and the ledger's integrity status.

Choose **Browser split** for a vertical workspace with Browser events on the left and the session's
live browser on the right. The Browser filter is locked while split mode is active, and new agent
browser actions appear beside the page they affect. It is the same browser tab, with the same page,
cookies and agent routing—not a replay or a screenshot.

**Exact** means Threading retained the provider's decoded native JSON value. **Exact · redacted**
means the same structure was retained but sensitive values were visibly replaced and listed:
credential-shaped fields and image bytes are redacted. Ordinary browser text and form values stay
exact. There is not yet a share-safe audit export, so review and redact a copy before sharing it
outside the project. Tool output may still contain source code, terminal output, URLs or page data,
so treat the ledger as local project data.

Claude, Codex and Grok Chat expose structured execution events and receive provider-native capture.
Grok Terminal and OpenCode currently expose no equivalent structured feed through Threading's
terminal integration, so Threading does not infer actions from terminal text; their audit may be
empty rather than speculative.

### Signing in to test accounts

When an agent reaches a password field, Threading normally brings the browser forward, focuses that
exact field, and waits for you — it never sees the value. That is right for a real account and
tedious for a throwaway one you re-type all day.

**Settings ▸ Tools ▸ Browser Sign-In** lets you change where sign-in values come from:

- **macOS AutoFill and password managers** (the default) — the behaviour above. Threading never
  sees a password.
- **Threading test credentials** — accounts you store here, which agents may fill without asking,
  on the exact origin each was stored for.
- **1Password** — agents sign in with items you point at, read through the `op` command line.
  Threading stores only the reference; 1Password keeps the value and authorizes every read, so it
  may ask you to unlock.

Choose **Add…** to store one. Give it the origin as a full URL (`http://localhost:3000`), a name
you can recognise (`admin`), an optional username, and the password. Agents ask for it by that
name, and never receive the password itself — Threading fills the page directly and removes the
value from anything the agent reads back afterwards.

Deliberately less protected than a real password manager: it is stored in your Keychain without a
Touch ID prompt, which is exactly what lets an agent sign in unattended. **Store only accounts you
would not mind losing.** Anything that is not on your own machine asks you to confirm it is a
throwaway account first, and well-known providers like Google or GitHub are refused outright.

Signing in is still not submitting: an agent that fills a form must still ask before it submits
one. On an origin you keep a test credential for, that prompt offers **Allow Until I Quit** — the
exemption lasts for the rest of the app run, is never written to disk, and is listed with an **Ask
Again** button on the same settings page. Remove a stored account at any time from the same page, and **Reset Everything** removes them
all.

### Letting an agent use a signed-in Chrome

The in-app browser cannot load browser extensions, which is what makes a one-shortcut 1Password
sign-in possible. For work that genuinely needs your own signed-in session — or an extension, or a
passkey — **Settings ▸ Tools ▸ Signed-in Chrome** sets up a Google Chrome profile that belongs to
Threading, separate from the Chrome you use every day. Choose **Set Up Automation Profile** and a
normal Chrome window opens on it: sign in to the sites you want agents to reach, install your
password manager's extension, and close it. Open it again whenever you want to add a site.

Afterwards an agent can drive that profile with `browser_attach_chrome`. It has to list every
website the run may reach *before* Chrome opens, and you are asked about each one with the same
Allow Once / Always Allow / Deny choice the in-app browser uses; denying any of them cancels the
whole run. Chrome opens visibly so you can watch it, and if a step, a redirect, or a pop-up reaches
a site you did not allow, the run stops there and the agent is told nothing about that page.

Password fields are refused there exactly as they are in the in-app browser, so signing in is still
yours: the agent navigates to the sign-in page and waits, you press your shortcut once, and it
carries on. Threading reads no cookie, no keychain item and no password in any of this — the
credential goes from your password manager into Chrome without passing through the app.

It is a separate profile because Chrome itself refuses to be automated against your default one, a
restriction added in Chrome 136 to stop exactly the kind of session theft this design refuses to
attempt. One Chrome can hold the profile at a time, so close the setup window before an agent uses
it. **Settings ▸ Advanced ▸ Reset Everything** moves the profile aside with the rest of Threading's
data, which signs it out.

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

Threading runs a small MCP server on a loopback port and registers it with each Claude or Codex
session it launches, giving that session a private endpoint. The agent gets four display tools —
`display_image`, `display_scene`, `display_html` and `display_compare_files` — and is told the
panel exists so it reaches for them instead of printing a file path or an ASCII table.

They are pre-approved, so displaying something does not raise a permission prompt every time.
This does not affect any other tool: your normal permission rules and your own MCP servers
are untouched.

Grok Chat registers the same tools through ACP for that process only, without changing Grok's
configuration. Grok Terminal and OpenCode currently leave their own MCP configuration untouched.
OpenCode has a future path through its local TUI server; neither runtime's persistent configuration
is rewritten for those terminal integrations.

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

### Pull requests

For a checkout whose `origin` is on GitHub, Git Review also shows the current branch's pull
request, draft/review state and checks. Its main button always takes one explicit step: push the
branch, create its pull request, push a newer head, or open the existing pull request. Uncommitted
changes are named and stay local.

The creation rule belongs to the repository. Choose it from the project's secondary-click menu
under **Pull Requests**, or from the policy chip in Git Review; linked worktrees share the same
setting. **Review before publishing** is the default and opens an editable title/description
sheet. **Draft with Codex** can fill that sheet, but Codex cannot submit it — only pressing
**Publish pull request** does. Repositories can instead make an explicit Create press publish a
draft or ready pull request directly, or allow pushes without ever creating one.

Threading uses the GitHub sign-in chain shown in **Settings ▸ GitHub**. Without an API sign-in it
opens GitHub's prefilled compare form in the browser; it does not attempt an anonymous write.

### The status card

Whenever the selected session's project is a git checkout, a small floating card sits at the
session pane's top-right corner showing the current branch and the uncommitted totals
(`+N −M`, untracked files included). It updates live as the agent writes — the same watcher
the Review tab uses — and **clicking it opens Git Review**, so the diff is one click away
without asking the agent for it. A clean checkout shows just the branch; a project that is
not a repository shows no card at all.

The card holds more than one destination, so **the pointer says which part goes where**: the
branch and the totals each light on their own and both open Git Review, the children row opens
Subagents, the audience row opens Sharing, and the model line — a reading rather than a
destination — stays quiet under the pointer and does nothing when clicked.

**You can switch the card off.** The header's `▣` button (View ▸ Status Card, rebindable in
Settings ▸ Shortcuts) hides and shows it, and the choice sticks across launches. The card fades
out and tucks toward the top of the pane rather than blinking away.

It also **withdraws on its own when the pane gets narrow** — when it would cover more than half
the width, which is where a floating card stops being an annotation on the terminal and starts
covering the output. Widening the pane brings it straight back. That is not a change to the
switch: the button stays lit while the card is away for width, because it reports what you chose
rather than what happens to fit right now. A long branch name makes the card wider, so the same
pane can be roomy for one checkout and tight for another.

The model line names whatever the session is running, including when you never chose one. If you
pinned a model in the composer, or your Claude account's `settings.json` names one, that is what
it says; otherwise Threading reads the model back out of the conversation's own transcript, so a
session left on the CLI's own default still reports it — and a `/model` typed mid-conversation
moves the line the next time the card refreshes. A terminal session whose own status line already
prints the model shows it once, on that line, rather than twice.

While the agent is working, that card becomes a live run receipt: the branch gives way to a
working orb, the current **Step n / total** when the agent reports a plan, and the number of
changed files beside the live `+N −M` totals. If Claude is running several task-list items in
parallel, the receipt shows **done / total · active** counts instead of pretending the work has
one current step. Agents that do not report a structured plan still show **Working…** and the
diff totals. The card returns to the branch when the turn finishes.

Native subagent rows use the same structured progress. A selected Codex or Claude child shows
its **Step n / total** (or parallel task counts) beside its live tool/time/token detail, and the
label disappears when that child finishes.

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
highlighted** for the languages Threading recognises by file extension; a file it does not
recognise renders plain rather than guessed at.

Secondary-click a rendered line to **Add line to chat** or **Comment on line…**. The staged receipt
keeps the file path, line number, and line text together. The file row's own secondary-click menu
offers the same pair for the complete file.

**A changed image opens too.** A row whose binary file is a raster image (PNG, JPEG, GIF,
WebP, HEIC, TIFF, BMP, ICNS) says `image` instead of `binary` and expands into the same
interactive comparison the display panel's Compare tab uses — wipe, fade, difference, side by
side, and the button that opens it at the window's size — with each side titled for the mode's
endpoints (`HEAD` against `Working Tree`, a commit against its parent, and so on). An added or
deleted image shows its one existing side, which is a picture rather than a comparison: no mode
chip, and nothing to open larger.
Image rows never open automatically; the pictures are read only when you expand them.

### Staging and committing

Two modes offer staging, because only their diffs are measured against the index:

- In **Unstaged**, each file row carries **Stage File** and each hunk a **Stage**.
- In **Staged**, the same controls read **Unstage**, and a composer at the top of the list
  commits what is staged — Return sends, Shift-Return breaks the line. Your message survives
  the pane re-reading itself, so staging more while writing one does not lose it. A ✨ beside
  the composer **drafts a message for you**: one short read-only Codex run over the staged
  diff, written to match the voice of your recent commit subjects. The draft lands in the
  composer for editing — nothing commits until you send it. Offered when a Codex login
  exists; the run uses your default account's usage, which is why it only ever runs when
  clicked.
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

**View ▸ Inspect…** (**Cmd+Option+I**) turns it on. A crosshair appears and the most specific
view under the pointer is outlined live, with its class name and size in a badge. From there
the gesture and the modifiers decide what gets captured — there is one command, not one per
kind of capture:

- **Click** captures the outlined element.
- **Drag** rubber-bands a rectangle and captures it. Nothing is detected while you drag: this
  is for a gap, a misalignment, or the middle of a terminal that is one view however much it
  draws. The outline stays up until the drag is unmistakable, so a click that slips a little
  is still a click.
- **Hold Shift** and nothing is detected at all. Guides follow the pointer across the window
  and a click records the exact spot.

**Esc** backs out, and invoking the command again cancels. A capture ends the mode.

The corner of the overlay lists every control, and the one you are holding is the one drawn
brightest — so the hint is also a readout of what is currently on. It moves to another corner
rather than covering what you are pointing at, and if a drag leaves it nowhere to go it fades
in place instead of chasing you around the window. It is **not** in the captured screenshot:
it explains an overlay nobody reading the filed issue can still see.

> If you had **Inspect Geometry** on **Cmd+Option+Shift+I**, that chord still opens freeflow.
> Nothing special-cases it — the command reads the keyboard, and invoking it that way arrives
> with Shift already held.

### Hierarchy and spacing layers

While an element is outlined, two more modifiers add layers to what is drawn. They are
independent, so either or both can be held, and the hint in the corner says so. Neither does
anything while Shift is held, because there is no element to layer onto; the hint greys them
out to say so.

- **⌃ (Control) — hierarchy.** Every ancestor of the element is outlined too, each in its own
  colour, with a numbered chip at its top-left corner and a key in the opposite bottom corner
  mapping each colour to its class and size. Only the element itself is filled; the ancestors
  are outlines, so an eleven-deep chain stays a hierarchy rather than a wash. The element
  needs no chip — its badge is drawn in its own colour instead, which is what ties it to the
  first row of the key.
- **⌥ (Option) — spacing.** The gaps around the picked element are measured: a dashed line
  with the number of points on it, in the parent's colour. Flush edges are left unmarked — a
  `0` on all four sides of a fitted view says nothing — and a child that *overflows* its
  parent is reported as a **negative** number, which is the one measurement here that is a
  bug on its own rather than a value to judge.
- **⌥ alone** draws the element and the one level outside it, which is the common question
  ("why is this inset like that") without the whole chain.

**The drawing measures one thing; the key measures all of them.** A 14pt sidebar icon sits
eleven levels deep in a real window, so measuring every pair on the canvas puts twenty-eight
numbers around one icon and loses the four that were asked for. Only the picked element's own
gaps are drawn. Every other pair is listed in the key as text (`4 in 5 · leading 4 ·
trailing 32 · top 5 · bottom 5`), where a line costs nothing and covers nothing — which is
also what makes the measurements legible no matter how small the element is.

Numbers that will not fit in the gap they measure step outside it, and a hairline **leader**
runs back to the gap they came from, so a displaced number still says what it belongs to.

A run of views sharing one rectangle — a wrapper that exactly fills its parent — counts as
**one level with several names**, shown as `NSStackView = NSView`. Two outlines on the same
pixels would claim there are two things to look at when there is one. In practice this is
what keeps a real chain readable: the terminal's eleven views collapse to four rectangles.

Whatever is held at the moment you click is what the screenshot shows *and* what the report
text describes, so the legend, the colours and the measurements all arrive in the pasted
markdown. The on-screen key folds if the window is too short to hold every row; the report
always lists them all.

Every capture opens a report sheet holding a screenshot of the whole window with the capture
marked, and the report text:

- Element reports name the view's class, its frame, the view chain above it, and the view
  controllers responsible — the names a conversation about this codebase already uses. If a
  layer was held, they also carry the colour legend (`Orange · 1 · RowView · 372×64 at
  (24, 180)`) and the measured spacing per parent, so the colours in the screenshot can be
  named by anyone — or any agent — reading only the text.
- Point and region reports give the geometry twice: in window coordinates (bottom-left
  origin, what AppKit code speaks) and from the top-left (how anyone reading the screenshot
  counts).

Above the captured details is the **description**: whatever you type there leads the copied
text and the filed issue, so "make this padding smaller" arrives above the evidence for it. It
opens several lines tall — **Return adds a line, ⌘Return submits the issue**.

Two things to do with a capture:

- **Copy Report** puts the text on the clipboard as markdown. The screenshot is referenced by
  its file path (saved under the temporary directory), because a path is the one form of an
  image the agent CLIs can act on — so the pasted report lets an agent read the hierarchy *and*
  open the picture.
- **Submit Issue** files it on Threading's GitHub, labelled `bug`, using whichever GitHub
  sign-in this Mac has (Threading's own connection, `gh`, or your git credential helper — see
  **Settings ▸ GitHub**). The issue opens in your browser when it is created, and **the
  screenshot goes to the clipboard so ⌘V adds it to the issue**. GitHub's API takes markdown
  and nothing else — image upload is a browser-only endpoint — so that keystroke is the whole
  of the manual part.

  With no sign-in at all, Submit Issue opens GitHub's own new-issue form with the title, body
  and label already filled in, and your browser session files it.

The screenshot is taken from Threading's own view tree, so it needs no Screen Recording
permission and can never include another app's window. The one honest gap: content another
process draws — a web page in the display panel — may appear blank in it.

## Appearance

### Sidebar
- **Cmd+Ctrl+S**, or the toggle button at the left of the header: show/hide the sidebar

### Text and terminal size

- **Settings ▸ Themes ▸ Fonts ▸ Text size** scales the app's semantic type immediately,
  including conversations, Settings, and UI rendered by extensions. It keeps the hierarchy
  between headings, body copy, captions, code, and aligned numbers rather than assigning one
  point size to everything.
- **Cmd++** / **Cmd+-** increases or decreases the active terminal's font size.
- **Settings ▸ Profiles ▸ Font** sets a profile's terminal family and size. Terminal text stays
  independent from app text so a dense shell and a comfortably readable interface can coexist.

### Full Screen
- **Cmd+Ctrl+F**: toggle full screen
- **Double-click the strip along the top of the window** — beside the traffic lights, over the
  sidebar, or anywhere across it that isn't a control — to fill the screen, and again to put the
  window back. It does whatever **System Settings ▸ Desktop & Dock ▸ "Double-click a window's
  title bar to"** is set to, including nothing at all.

### Themes

Open **View ▸ Current Theme**, or pick **Current Theme** from the `+` in the display panel beside
a conversation, to inspect the app chrome that is active now. It opens in that panel and stays
open as you move between conversations — it belongs to the app, not to one chat. The page shows
its light/dark variants, material, sidebar treatment, paired terminal colours, and the semantic
colour roles the app actually reads. Built-in and extension themes are shown at full strength but
locked; **Duplicate to Edit** creates and applies a custom copy in one step. A custom theme's
colour changes repaint the open window immediately.

The page stays live while an agent works too. You can say, for example, “Use Threading's
app-theme MCP tools to make my current theme warmer and soften the sidebar.” The agent can inspect
the active document with `get_app_theme`, duplicate and activate a locked source with
`duplicate_app_theme` and `apply: true`, then patch the editable copy with `update_app_theme`;
accepted changes appear in the open editor as they happen.

Configure terminal palettes in **Settings > Themes**:
- 16 ANSI colors (8 normal + 8 bright)
- Foreground, background, cursor, and selection colors
- Import themes from Terminal.app (.terminal files)
- Export themes as JSON
- Duplicate and customize built-in themes (built-in themes are read-only)
- Live preview with sample output

**Use as Default** sets the theme every terminal uses unless it has been given one of its own.

#### Per-project, per-session and per-terminal themes

A theme can be set at three levels, and the narrowest one wins:

| Scope | Where to set it | Applies to |
|---|---|---|
| Session | The session row's `⋯` menu, or right-click ▸ **Theme** | That one terminal |
| Standalone terminal | The terminal row's `⋯` menu, or right-click ▸ **Theme** | That terminal |
| Project | The project row's `⋯` menu ▸ **Theme** | Every chat or terminal shown in it that has no theme of its own |
| Default | Settings ▸ Themes ▸ **Use as Default** | Everything else |

Each menu's **Inherit** item clears that level's choice and names what it falls back to, so
"Inherit (Ocean)" means removing this choice leaves the terminal on Ocean. A theme with no
choice anywhere follows the default wherever it moves — the level is remembered as *inherit*,
not as a copy of whatever was current at the time.

**Follow App Theme** is the other way to not choose, and it is a different one. Inherit takes
whatever the *next level out* says; Follow App Theme takes whatever the **app theme** says,
using the terminal palette that ships with each style — Cyberpunk's neon, Bauhaus's primaries,
Art Deco's brass — and moving whenever you switch chrome. It is a real choice, so it beats the
levels outside it: a session set to Follow App Theme keeps following the chrome even if its
project names Solarized. Under the System theme it also tracks macOS light and dark.

**Out of the box the default is Follow App Theme**, so with nothing chosen anywhere, switching
app theme moves the terminals too. If you have used Threading before and your terminals stay put,
you have a saved profile holding the old fixed palette — pick **Follow App Theme** once in
Settings ▸ Themes ▸ **Use as Default**.

Deleting a theme leaves anything using it inheriting again. Renaming one keeps them.

Sessions shown as a conversation rather than a terminal are drawn in the system's own colours;
a theme sets only the backdrop behind them.

**One theme takes over the whole window frame.** The stock **Windows 98** theme draws the
entire frame itself: the macOS titlebar, traffic lights and rounded corners give way to a navy
title band with its own close, minimize and maximize buttons, square corners, a silver border,
and raised-and-sunken bevelled surfaces throughout. Everything still works the way a window
does — drag the band to move, double-click it for your System Settings titlebar action, resize
from any edge, minimize to the Dock, and enter full screen as usual (the band stays visible
there). The sidebar toggle and Back/Forward move into the band while the theme is worn.
Switching to any other theme brings the native macOS frame straight back, exactly as you left
it. Custom themes can opt into the same takeover through the theme tools.

**The Dock icon follows the app theme.** Choosing anything other than System redraws Threading's
icon in that theme's ground and accent — Cyberpunk's neon green on near-black, Bauhaus's red
with its hard printed shadow — and the ⌘-Tab switcher shows the same. The chevron itself never
changes shape, so the app stays findable by silhouette. This lasts while the app runs: Finder,
Spotlight and the Dock's own record keep the shipped icon, and choosing **System** puts it back
immediately. The iPhone app has one fixed icon; iOS does not allow an app to draw its own.

An extension's theme can bring its own icon *mark* — its glyph replaces the chevron, but the
tile behind it is still drawn from the theme's own background, so an extension can never make
Threading's icon look like a different app. A contributed theme without a mark gets the same
generated icon every built-in style does.

An installed extension can offer app themes of its own. They appear in the picker labelled by
the extension's name — "Storm — Usage Rain" — while the extension is enabled, and leave with
it; if the one you were using goes away, the app falls back to System and records that as the
choice. An extension theme cannot be edited in place: duplicate it to make an editable copy,
or update the extension that ships it.

**An extension's theme follows its files.** While the extension is enabled, Threading watches
its theme documents and reloads them the moment they change — so a theme can *live*: an
extension may rewrite its own palette to follow the weather or the hour, and an author editing
a theme sees the window follow each save. An edit that does not validate is skipped and the
last good version stays.

#### The sidebar belongs to the theme

A theme can dress the **sidebar** beyond its colours: a gradient or an image behind the
project list (tiled as a pattern, or fitted/filled as a picture, at any opacity), its own
logo in place of the Threading mark, and its own wordmark — different text, an installed
font, a size and weight. Every part is optional; a theme that states nothing keeps the plain
themed column with the Threading mark beside the app's name, and under **System** the
sidebar stays the platform's frosted material untouched.

Extension themes ship these in their package (the theme document references image files
beside it), and an agent can author them live through the app-theme tools — asking for "a
starfield behind my projects" or "put our team's logo in the sidebar" is a one-tool-call
change. A gradient that would swallow the sidebar's labels is refused the way an unreadable
terminal palette is; image legibility is left to the author's eye. Duplicating a theme
copies its sidebar images with it, so the copy survives the original's extension being
disabled.

#### Fonts

An app theme states a **typeface** as well as a palette, because the styles these themes are
drawn from do: Newsprint, Art Deco and Botanical are serif, Cyberpunk and Vaporwave are
monospaced, Claymorphism is rounded, and the rest are the system sans. Switching theme therefore changes
what the app is *set in*, not only what it is coloured with, and the change takes effect
immediately in every open window.

Three things deliberately never follow it:

- **Code** — tool output, diffs, paths and commands stay monospaced under every theme.
- **Numbers** in columns keep their aligned digits, so a usage figure does not shift about.
- **The terminal**, which has always taken its font from **Settings ▸ Profiles** instead.

**Settings ▸ Themes ▸ Fonts** overrides all of it with a font of your own:

| Setting | Applies to | Falls back to |
|---|---|---|
| **Text size** | All semantic app and host-rendered extension text | Default scale |
| **App font** | Every part of the app the theme's typeface would reach | The theme |
| **Conversation font** | The thread in a natively rendered session, including its reply box | The app font, then the theme |

Both lists offer every font family installed on the machine, not a curated set. A conversation
font exists for the same reason the terminal has its own: it is the surface you *read*, and a
face that suits an interface does not always suit a page of prose.

Fonts bundled by an enabled extension count as installed here: they join both lists (and can be
named by the extension's own themes) the moment the extension is enabled, and leave when it is
disabled — the setting then falls back one level, exactly as an uninstalled font does.

Choosing a font that is later uninstalled is not an error — the setting falls back one level at
a time, and the picker returns to its inherit row (**Follow Theme** for the app font,
**Follow App Font** for the conversation) rather than claiming a font that is no longer there.

### Profiles
Configure in **Preferences > Profiles**:
- Font family and size
- Cursor style: Block, Underline, or Bar
- Cursor blink toggle
- **Keep backgrounds in tune with the theme** (default: on)
- Scrollback buffer size (default: 10,000 lines)
- **Convert dropped images agents can't open** (default: on)

**Keep backgrounds in tune with the theme.** Some programs paint their own backgrounds in
24-bit colour rather than using the terminal's palette — an agent's diff is the common case,
where the added and removed rows arrive as a green and a red picked for a generic terminal. The
palette has no say over those, so under a strongly coloured theme they land as two slabs that
belong to nothing else on screen.

With this on, those backgrounds are eased toward the colours your palette actually contains and
their colourfulness is capped, so a diff still reads unmistakably as added and removed while
sitting in the theme rather than on top of it. **How light each background is never changes**,
which means text a program drew on it stays exactly as readable as the program intended. Only
backgrounds are affected — text colour and syntax highlighting are left alone — and programs
that use the ordinary palette were already in tune and are untouched.

Turn it off to see exactly the bytes a program sent.

**Convert dropped images agents can't open.** Neither CLI reads a HEIC or a TIFF, so dropping
one on a session left a path in the prompt that looked exactly like a drop that had worked. With
this on, such a file is written out as a PNG first — keeping its name, leaving your original
where it is — and the agent is handed that. It follows the agent: a GIF reaches Claude Code
untouched and is converted for Codex, because only one of them reads GIFs.

Turn it off when the format is the thing you are working on — debugging HEIC handling, say,
where the agent needs your actual file rather than a PNG of it. The shell drawer never converts
under either setting, since a path typed at a shell has to be the path you pointed at.

## Settings

**Cmd+,** opens Settings, and pressing it again closes it — unlike most Mac apps, where
preferences are their own window and Cmd+W closes them. Here Settings is a *page in this
window*, replacing the session in the pane and the project list in the sidebar, so the chord
that put it there is what takes it away. The **✕** on its tab, and the **Settings** button at
the sidebar's bottom-left, do the same thing.

Closing it returns you to exactly what it covered. If that was a **new-session composer**, it
comes back untouched — the same agent, account, model and checkout, the same attached images,
and the prompt still half-written — so a trip into Settings to change a default costs you
nothing of what you were composing.

While Settings is the page, the header offers no **+**: that button creates a session, and a
preferences page is no context for one.

The search field at the top of the Settings sidebar searches page names and the settings they
contain, not only the visible navigation labels. Searches may contain several words in any
case; every word must match. Extension-provided pages and sections participate with their
localized titles, descriptions, choices, and placeholders, and the query stays in place when
an extension is enabled or disabled.

The sidebar filters immediately while you type and remains a list of pages: searching *mute*,
for example, leaves **General** as the matching destination. The page already open in the right
pane stays put until you choose one of those filtered destinations. Clearing the field restores
the complete page list.

Whenever something is typed, an **Ask AI** button appears beneath the filtered list — with
results and without, because the filter matches words while the setting you *mean* may use
different ones. Clicking it runs a short one-off agent turn (Claude Code if it has a login,
otherwise Codex; the button is absent without either) that reads only the catalogue of
Settings pages and answers in the right pane with up to four suggested pages, each carrying
one sentence on why and an **Open** button. The run uses your own agent login and spends a
small amount of its usage, which is why it only ever happens on the click — typing alone
never launches anything. It can see which pages exist and their keywords, never your values.

The page list is grouped under six quiet captions — **App** (General, Keyboard), **Appearance**
(Themes, Profiles, Motion), **Agents** (Accounts, Tools, Usage), **Access** (Remote Access,
GitHub, Privacy), **Data** (Storage, Archived, Advanced), and **Extensions**, which also holds
any page an extension contributes. Filtering keeps only the sections that still have matching
pages.

Every page keeps its title, a one-line summary and its page-wide actions in a **fixed header**
above the scroll, so where you are — and, on Storage, how much is reclaimable — stays on screen
however far the page scrolls. Pages that list things rather than settings fold those lists into
**collapsible cards**: each MCP tool group on **Tools**, each installed package on
**Extensions**, each checkout on **Storage**, and each command group on **Keyboard** shows one
header row — its name, its size ("31 tools", "12.4 GB"), and its one control (the group's
switch, the checkout's **Remove All…**) — and clicking the header (or pressing Space/Return on
it) unfolds the detail. The fold is remembered for the session, not saved. **Archived** shows
the ten most recent conversations and folds the rest behind an "older conversations" row.

Threading follows the language macOS selects for the app, with English as the per-string fallback.
Menus, built-in Settings navigation, commands, and Settings components use the app string
catalog. Extensions carry their own translations and choose the closest language the app
requests; a missing extension translation falls back to that extension's base string rather
than borrowing an unrelated app translation.

### General
- **New sessions use** — the agent the composer opens on; any other can be picked there
- **Opening Message** — optional text appended once to every new chat's first turn; see
  [Creating](#creating)
- **Name sessions after the agent's own title** — see [Names](#names)
- **Group sessions by branch** — see [Grouping sessions by branch](#grouping-sessions-by-branch)
- **Follow the checkout's branch** — an idle session's recorded branch tracks its checkout,
  however the switch was made; off, it keeps the branch it last ran on — see
  [Grouping sessions by branch](#grouping-sessions-by-branch)
- **Discover project icons** — see [Project icons](#project-icons)
- **Discover account avatars** — see [Icons and names](#icons-and-names)
- **Reopen the last session at launch**
- **Relaunch sessions that were running at quit** — the sessions that were live when the app
  last quit resume in the background at launch, one at a time, so each is already running
  when you open it; see [Resuming](#resuming)
- **Confirmations** — one switch per prompt, plus **Hidden extension messages ▸ Show All**;
  see [Confirmations](#confirmations)
- **Report Claude turn and subagent activity** — see [Agent hooks](#agent-hooks)
- **Hide Claude's status line in Threading terminals** — see [Agent hooks](#agent-hooks)
- **Report Codex turn boundaries** — see [Codex hooks](#codex-hooks)
- **Skip Codex hook review** — see [Codex hooks](#codex-hooks)
- **Shell path** — used by the shell drawer (⌃`); agents always launch via your login shell

### Motion

- **Working indicator** defaults to **Random**, choosing a new orb for each turn without
  immediately repeating the last one. Choose a named orb to use that animation every time. The
  list shows every orb running side by side, so they can be compared without being selected one
  at a time; Random's row re-rolls each time you point at it.
- **Chat name transition** defaults to **Shape Morph**. Point at a transition in the list and
  its row demonstrates it, morphing between the transition's name and the app's own and back for
  as long as you stay on it — one row at a time, and only after a short pause, so a pointer
  crossing the list leaves every name readable. Every transition can also be
  previewed on the page. It plays wherever a name you are already looking at changes: the
  sidebar row, the session header's page tab, and project and checkout rows — whether the change
  came from renaming the session yourself, from the agent naming the conversation, or from
  a checkout switching branch. A row being filled in for the first time, or scrolled back
  into view, simply shows its name.

Animation timing is tuned by Threading rather than exposed as another preference, and transitions
honour macOS Reduce Motion.

#### Agent hooks

Claude's lifecycle reporting is **on by default**, but optional. **Report Claude turn and
subagent activity** passes hooks through the app-managed `--settings` file made for that session;
it never edits `~/.claude/settings.json`. Switching it off takes effect the next time a Claude
session starts or resumes:

- Terminal Claude launches without Threading's hooks and falls back to interpreting terminal
  output for activity. It cannot discover new terminal subagents or their completed usage.
- Native Claude keeps only the `PreToolUse` hook required for Threading's permission cards.
  Structured native turn and subagent rendering continues through Claude's event stream.
- Subagents already saved with the session remain available when switching surfaces or
  relaunching the app.

Use the off switch if a Claude release or another part of your setup conflicts with a hook. A
running Claude process has already loaded its settings file, so it must be restarted or resumed
before the change applies.

**Hide Claude's status line in Threading terminals** (off by default) blanks the line Claude
draws under its composer — the one your own `statusLine` command produces — in sessions Threading
launches. Inside Threading that line mostly repeats what the app already shows: the status card
carries model, effort and branch, and the toolbar pill carries rate limits. Your other terminals
are untouched — the override travels in the same session-only settings file as the hooks, never
in your Claude configuration. Your status-line command still **runs** on every turn with its
output thrown away, so a command with side effects (such as a usage-caching bridge) keeps
feeding whatever depends on it. With the line hidden, Threading's status card stops deferring to
it and shows every fact itself. Codex has no user status line, so there is nothing to hide there.
Applies the next time a session starts or resumes.

#### Codex hooks

Codex can report terminal turn and subagent activity too, but only from entries in
`~/.codex/hooks.json` — a file you own, and one another tool may already be using.

Both settings are **off by default** and do different jobs:

- **Report Codex turn boundaries** adds Threading's entries to each Codex account's `hooks.json`.
  Anything already in that file is kept, and switching the setting off removes only what Threading
  put there.
- **Skip Codex hook review** decides how those entries get permission to run. Codex refuses to
  run any hook until its exact text has been approved once, and that approval happens in the
  Codex terminal app — which a session Threading launches never shows.

Leaving the second setting **off** is recommended. Open `codex` in a terminal once, approve the
hooks when it asks, and they work from then on: Threading's entries are written so their text never
changes between launches, so one approval holds.

Switching it **on** means Threading passes `--dangerously-bypass-hook-trust`, which runs *every*
hook in that config folder without review — not only Threading's. Since an agent can write to
`hooks.json` itself, that would let an agent arrange for its own code to run unreviewed on the
next launch.

### Privacy

Every grant Threading can hold from macOS, what each is for, and whether you have given it. The
page is an inventory rather than a checklist — two of the four are expected to read **Not
allowed** on a machine that has never installed an extension companion, and nothing on the page
treats that as a fault. Opening it asks macOS for nothing; it reads the grants that can be read
and says so plainly for the one that cannot.

| Grant | What it covers | How it is asked for |
|---|---|---|
| **Files & Folders** | Reading and editing the files in a project | macOS asks the first time a project in Desktop, Documents or Downloads — or on an external or network volume — is read. A project anywhere else needs no grant at all. |
| **Notifications** | Turn-finished and needs-you alerts | Threading asks the first time a session has something to say. Off in General settings means it is never used. |
| **Accessibility** | An extension companion that drives the pointer or keyboard | You allow Threading in System Settings, then reload the extension. Threading itself never asks. |
| **Screen Recording** | An extension companion that captures the screen | The same. Inspect Mode draws from Threading's own view tree and needs nothing. |

Each row has an **Open Settings** button that goes to that exact pane rather than to the top of
System Settings. The page keeps reading while it is open, so allowing something over in System
Settings and switching back shows the new answer without reopening anything.

**Live usage from your Claude login** (off by default) is the one place Threading will read a
credential that belongs to an agent. On macOS the Claude CLI keeps its sign-in in the keychain,
not in a file, so without this switch the usage pill can only report what the CLI's local caches
happen to say — numbers that can be hours old. Switched on, Threading reads that sign-in and asks
Anthropic's usage endpoint directly: the token goes there and nowhere else, is never stored on
disk, never refreshed, and never logged. macOS asks once per login when you flip the switch —
answer **Always Allow** and it stays silent — and the row reports where things stand
(`On — reading 2 of 3 logins`). Background refreshes never trigger a keychain prompt: if a grant
is missing, the pill quietly falls back to the caches instead. Switching it off stops the reads
immediately; the keychain approval itself persists until you revoke it in Keychain Access.

**The part worth knowing: agents inherit what you grant Threading.** macOS attributes a directly
launched child process to the app that launched it, and every agent TUI is launched by
Threading. So the files an agent reads are approved against *Threading's* grant, and the prompt you
answer says "Threading" whichever agent actually asked. Allowing the Documents folder once is
allowing it for every agent you subsequently run in a project there. This is how a terminal has
always worked — `Terminal.app` behaves the same for anything you type into it — but it is worth
saying out loud, because the name on the prompt is not the name of the thing reading the file.

Extensions are the exception, and deliberately so. A safe extension is sandboxed and
Foundation-only. A companion executable declares each capability it wants at install time, and
Threading requests only the grants its reviewed capabilities actually cover — so a companion that
never asked for `inputControl` cannot cause an Accessibility prompt.

**Threading warns you before macOS asks.** The consequence of the paragraph above is that a
system prompt can appear out of nowhere: an agent runs `screencapture`, and macOS puts up a
dialog saying *Threading* would like to record your screen — no session named, no command shown,
no reason given. When Threading can see that coming, it says so first, in a sheet that names the
agent, the chat and project it belongs to, and the exact command about to run. **Continue** lets
the command run and macOS ask; **Deny** stops the command, and the agent is told why rather than
being left with an unexplained failure.

This applies to Screen Recording and Accessibility — the two grants Threading can check without
asking macOS for anything — in chats it renders itself. You see it at most once per grant, since
after the first time macOS has an answer of its own. It is not offered as a setting to switch
off: switching it off would restore the unexplained dialog, which is the problem rather than the
noisier version of it. A chat in **Don't Ask** never sees it, because the command it was about to
warn you about is refused anyway. The Files & Folders prompt is deliberately *not* forecast —
macOS offers no way to check that grant without requesting it, so a warning there could only be
a guess, and a wrong guess is an interruption about a folder you approved years ago.

**Software updates.** Threading checks a release feed on GitHub once a day and installs updates
through **Sparkle**, only after you agree to each one. The request carries the version you are on
and your macOS version, the way any download does — no identifier, and nothing about your
projects. Switch it off under **Settings ▸ General ▸ Software Updates**; **Help ▸ Check for
Updates…** still works when it is off, so turning off background traffic never means losing the
ability to look.

When an update is found, the offer appears as a sheet in Threading's own style: the new
version, what you are on, the release notes rendered right there, and three answers —
**Install Update**, **Remind Me Later** (also what Escape means), and **Skip This Version**.
Skip is withheld for a critical fix, since skipping silences every future prompt for that
version. An update found by the daily background check waits until Threading is frontmost
before it says anything. Download and preparation each show a progress sheet — download can be
cancelled, and once preparing starts the sheet says so instead of offering a Cancel that would
no longer work — and the final step asks before the app quits and reopens as the new version.
The menu command can also be given a keyboard shortcut under **Settings ▸ Keyboard**.

**Reporting something.** **Help ▸ Report a Problem…** files an issue on Threading's GitHub
without leaving the app. Pick whether it is a **Problem** or an **Improvement** — that is the
label the ticket arrives with — give it a title and the details, and press Submit; ⌘Return in
the details field does the same. Three facts travel with it and they are named on screen before
you send: Threading's version, its build, and your macOS version. Nothing else. The issue opens
in your browser once it is filed, and if this Mac has no GitHub sign-in, the form opens
prefilled instead so your browser session can file it.

To report a *visual* problem, use **View ▸ Inspect…** instead and press **Submit Issue**
on the capture: the ticket then carries the view, its frame, the measured spacing and a
screenshot ready to paste.

**Getting help.** **Help ▸ Create Remote Support Report…** writes a file and reveals it in the
Finder. It holds versions, counts, and which OS grants Threading has — no project or session
names, no paths, and no prompts, by construction rather than by scrubbing. Threading never
uploads it; sending it is your decision.

**What is never asked for.** Threading has no analytics and no identifier for your install. It
requests no camera, microphone, contacts, calendar, location or Full Disk Access.
Remote Access does not need the Local Network permission either: the listener binds to
`127.0.0.1`, and the selected HTTPS relay or Tailscale Serve publishes only that loopback
listener. Threading never opens a listener on the physical LAN.

**Stored credentials** live in your login keychain, never in Threading's own database — the GitHub
connection, paired-owner device credentials, any model API keys you enter, and secrets an
extension stores. Agent logins are not
among them: Threading reads *which* accounts exist under `~/.claude` and `~/.codex` so it can
route a session to one, and never reads or copies their credentials.

Threading runs without the App Sandbox. A terminal that cannot open a pseudo-terminal or launch
your shell is not a terminal, and that is the trade the app makes.

### Accounts
Per-account icons and names. See [Accounts](#accounts).

### GitHub

How Threading reads from GitHub on behalf of extensions — the Checks card, for one. Extensions
never receive a credential: they ask Threading, and Threading fetches with the best credential it
holds, trying each tier in turn:

1. **The app connection** — sign in to your own GitHub App with a device code. Paste the
   app's **Client ID** (from GitHub ▸ Settings ▸ Developer settings; enable *Device flow* on
   the app), press **Connect GitHub…**, and enter the shown code on the GitHub page it opens.
   You choose which repositories the app can see when you install it on GitHub, and you can
   revoke it there at any time. Tokens live in the Keychain and renew themselves.
2. **The `gh` CLI** — if you are signed into `gh`, Threading borrows its token for reads.
   Nothing to configure; the page shows whether it was found.
3. **Your git credential helper** — whatever `git credential fill` holds for github.com.
4. **Anonymously** — public repositories only.

Reads report which credential answered, so a private repository that fails names the fix
("connect GitHub in Settings") instead of failing namelessly. Which origins an extension may
ask about at all is part of that extension's install approval.

### Will it last?
The header pill's popover, and **Settings ▸ Usage**, say how much of each window is spent. When
Threading has watched a window long enough to see a *rate*, it also says where that rate leads:

```
5h  ████████████░░░░░░  62%
7d  ████████████████░░  85%
    7d spent by 19:40 · 8h early · Updated just now
```

The line appears only when the projection matters — when the window will run out **before** it
resets. A window that will comfortably outlast its own reset says nothing, because being told
you are fine is noise.

For Codex this works immediately: it records rate limits into its own transcripts, so Threading
recovers the past week from disk the first time it looks. Claude records none, so its
projection appears after Threading has watched the window for a while.

### Usage
Where your tokens went, read from the agents' own transcripts — the question the header's
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

**The page never makes you wait.** Threading surveys the disk quietly in the background — at low
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

### Advanced
Where Threading keeps what it remembers, and how to start over.

Ordinary settings and work live in exactly two file locations, and both are shown with a
**Reveal** button rather than described:

| | Where | Holds |
|---|---|---|
| Settings | `~/Library/Preferences/codes.threading.plist` | Themes, profiles, every preference |
| Data | `~/Library/Application Support/Threading` | Projects, sessions, conversations, panel layouts, icons, caches |

Security capabilities are separate: paired-owner device credentials live in the login Keychain,
not in either file location or the database.

Two ways to start over, because they cost different things:

- **Reset Settings…** puts themes, profiles and every preference back to their defaults. Projects,
  sessions and conversations are untouched. This is the one for "something in my settings is
  wrong", and it is worth trying before the other.
- **Reset Everything…** also clears the data directory and revokes paired-owner credentials, so
  Threading restarts as if newly installed — no projects, no sessions, no conversations, no
  paired devices.

**File state is not deleted.** Both resets *move* the old files into a dated folder,
`~/Library/Application Support/Threading Resets/2026-07-30 14-32-05/`, so a reset you regret is a
drag back rather than a loss, and a database that was corrupt is still there to be looked at. The
folders stay until you remove them, which is the other reason the page reveals that location.
Paired-owner credentials are deliberately not copied there — that would turn a backup folder into
a credential export — so their revocation by Reset Everything cannot be undone from the folder.

Threading restarts itself immediately after a reset. That is not a convenience: the running app
holds your projects and window layout in memory and would write them straight back over the reset
otherwise.

**Only Threading's two file locations and, for Reset Everything, its paired-owner Keychain item
are touched.** Your agent logins, and anything the Claude or Codex CLIs keep for themselves, live
in their own stores and are left exactly where they are — so a reset does not sign you out.

### Profiles, Themes, AI
Terminal font and cursor, colour schemes, and AI provider configuration.

## Diagnostics

**Help > Reveal Diagnostics Log** opens the folder holding Threading's own journal, one file per
day, kept for two weeks:

```
~/Library/Application Support/Threading/Logs/threading-<date>.jsonl
```

Each line is one event — the app launching and quitting, a session being started from the
composer (including the prompt), the command line each agent was launched with, and the exit
code it came back with. It is written as things happen rather than buffered, so the last line
before an unexpected quit is on disk. The quit line says how many sessions were running and
therefore handed to the next launch, and that launch says how many of them it brought back.

A launch that never reaches its quit leaves its marker behind, and the next launch records
`Previous launch did not quit cleanly`, pointing at the macOS crash report from that run in
`~/Library/Logs/DiagnosticReports/`. That pair — what Threading was doing, and what macOS
recorded about it dying — is what a crash needs explaining.

This owner-local log is different from the share-safe remote diagnostics timeline. It can contain
prompts, commands and paths, so it is never populated by or attached through the iPhone/browser
sharing control.

## Keyboard Shortcuts

### Projects & Sessions
| Action | Shortcut |
|--------|----------|
| New Session (opens the composer) | Cmd+N |
| Start the session being composed (Return sends it too, unless you changed Settings ▸ Keyboard ▸ Composer) | Cmd+Return |
| Add Existing Project | Cmd+Shift+N |
| Open in External App (this checkout, in the app you last chose) | Cmd+O |
| Close Tab (the focused drawer/panel tab, else the page on screen; never stops the agent) | Cmd+W |
| Close Session (stops the agent) | unbound by default — assign one in Settings ▸ Keyboard |

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
| Go Back / Go Forward (selection history) | Cmd+Ctrl+Left / Cmd+Ctrl+Right |
| Group Sessions by Branch | Cmd+Ctrl+B |
| Headings for Lone Branches | Cmd+Option+B |
| Terminal (display panel tab) | Cmd+T |
| Browser | Cmd+Shift+B |
| Files (display panel tab) | Cmd+P |
| Git Review | Cmd+Shift+R |
| Save as Baseline… (the visible browser page) | unbound by default — assign one in Settings ▸ Keyboard |
| Session Info | Cmd+Shift+I |
| Shell drawer | Ctrl+` |
| Status Card (the session pane's floating corner card) | unbound by default — assign one in Settings ▸ Keyboard |
| Previous / Next tab (in the focused tab strip — drawer or panel) | Cmd+Shift+[ / Cmd+Shift+] |
| Tab by its place in the strip | Cmd+1 … Cmd+9 |
| Inspect… | Cmd+Option+I |
| …hold while inspecting: freeflow, click marks a point | Shift |
| …drag while inspecting: capture the rectangle drawn | — |
| …hold while inspecting: outline every parent | Ctrl |
| …hold while inspecting: measure the spacing | Option |
| Bigger Font | Cmd++ |
| Smaller Font | Cmd+- |
| Full Screen | Cmd+Ctrl+F |
| Minimize | Cmd+M |
| Settings (opens, and closes again) | Cmd+, |
| Check for Updates… | unbound by default — assign one in Settings ▸ Keyboard |

### In the terminal

Not app commands — these are keys the terminal forwards to whatever is running in it, so what
they do is up to that program. A shell, Claude Code and Codex all read them as word motion.

| Action | Shortcut |
|--------|----------|
| Move a word left / right | Option+Left / Option+Right |
| The same, in xterm's modifier form | Ctrl+Left / Ctrl+Right |

Note the near-miss: bare **Ctrl+Left/Right** is word motion *inside the terminal*, while
**Cmd+Ctrl+Left/Right** is the app's Go Back / Go Forward. Adding ⌘ is what moves the gesture
from the program in the terminal to the window around it.
| Delete the word behind the caret | Option+Delete |

Option is otherwise left to the keyboard layout rather than claimed as a Meta key, so
`~ | \ @ { }` and the rest still compose normally on a non-US layout.

### Changing shortcuts

**Settings ▸ Keyboard** lists every command and the keys it answers to. Click a shortcut and
press the combination you want; Escape cancels and Delete removes the shortcut entirely. A
change takes effect immediately — the menu bar is updated in place rather than at next launch.

Threading's own commands can be rebound. The system ones (Quit, Cut, Copy, Paste, Full Screen and
the like) are listed but fixed, so the page can answer "what already owns this key" without
letting a rebinding leave you unable to quit or paste. A combination already in use is refused
rather than taken from its current owner, and **Reset All** puts everything back.

At the top of the same page, **Composer** holds the one key that is not a command: *When writing
a prompt, press Return to*. It is here because "what is this key already doing" is most of why a
shortcuts page gets opened, and Return is the key people most often mean.

| Choice | Return in a prompt to an agent | Return in a note attached to a report |
|--------|-------------------------------|--------------------------------------|
| **Do What the Composer Expects** (default) | sends | breaks the line |
| **Send** | sends | sends |
| **Start a New Line** | breaks the line | breaks the line |

**⌘Return sends under all three**, and **Shift+Return** (or Option+Return) always breaks the
line, so neither action is ever more than one key away. Return also never sends while an input
method is mid-conversion — with a Japanese, Chinese or Korean IME that press is how you accept
the word you are typing, not how you send it.

## Data Storage

Stored in `~/Library/Application Support/Threading/`:
- `threading.db` — projects, sessions, panel layouts, and resumable agent session ids
- `history/` — per-session command history
- `mcp/` — one file per session pointing Claude at that session's display panel
- `ExecutionAudit/` — bounded, hash-linked JSONL execution ledgers, one chain per session

Displayed images are held in memory only. The panel shows the file on disk; it does not copy
it, and nothing about what was displayed survives a restart.

Settings, including per-account icons and names, live in the app's user defaults.

Conversations themselves are owned by the agents, not Threading, and live under the config
directory of the account that created them:
- Claude Code: `<config-dir>/projects/<folder>/<session-id>.jsonl`
- Codex: `<codex-home>/sessions/YYYY/MM/DD/rollout-<timestamp>-<id>.jsonl`

Removing a project or deleting a session in Threading never deletes these files.
It does delete that session's Threading-owned execution ledger, including its rotated segments.
