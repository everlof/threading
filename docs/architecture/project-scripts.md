# Repository-defined project scripts

Project scripts are checked-in conveniences, not lifecycle hooks. A repository may name a
bounded set of commands; Threading discovers them for the checkout on screen and offers them
through the same `CommandRegistry` as built-in and extension commands. Nothing in discovery,
checkout creation, app launch, session launch, refresh, or preview handling executes repository
code.

## File contract

The configuration is `.threading.json` at the active checkout's repository root. Its first
version is deliberately small:

```json
{
  "$schema": "./docs/schemas/threading-project.schema.json",
  "version": 1,
  "scripts": [
    {
      "id": "web.dev",
      "name": "Web development",
      "command": "npm run dev",
      "icon": "play.fill",
      "workingDirectory": "web",
      "previewURL": "http://localhost:3000"
    }
  ]
}
```

The source schema is [`docs/schemas/threading-project.schema.json`](../schemas/threading-project.schema.json).
`$schema` is optional, bounded editor metadata; discovery never fetches it. `version` is required and is
exactly `1`. Unknown root and script fields are errors so a misspelling cannot look supported
while being ignored.

The implementation applies limits before or while parsing: the file is a non-symlink regular
file no larger than 128 KiB; `scripts` has at most 32 entries; diagnostics stop at 16. IDs are
lowercase, unique, stable, 1–64 UTF-8 bytes and use `[a-z0-9._-]`. Names are at most 96 bytes,
commands 4096, icons 64, working directories 512 and preview URLs 2048. User-facing text and
commands are non-empty and contain no control characters, which makes every command one terminal
line. The JSON Schema's character limits help editors; the runtime's stricter UTF-8 byte limits
are the security boundary.

`workingDirectory` is optional and defaults to `.`. It is always relative to the execution
checkout's repository root, never the app process, current terminal, or logical Project folder.
Absolute paths, `~`, empty path components and `..` components are rejected while parsing. At
invocation the path is standardized, symlinks are resolved, containment is checked again, and
the result must still exist as a directory. A valid script whose directory is absent remains
visible but unavailable with the reason, which is more useful than silently dropping it.

`previewURL` accepts absolute `http` or `https` URLs with a host and no embedded credentials.
It is printed in the terminal receipt after the command. Discovery and execution do not open it
automatically: navigating a browser would hide the visible terminal and would turn metadata into
an extra repository-controlled action.

## Checkout routing and refresh

`MainWindowController.currentExecutionDirectoryURL` names what the visible page executes in:

- a session uses `ProjectStore.workingDirectory(forSessionID:)`, including its managed worktree;
- a standalone terminal uses its live cwd, which resolves back to that worktree's root;
- a project composer uses the project's folder;
- Settings has no checkout and clears project commands.

`ProjectScriptService` resolves that directory through `GitInfo.worktreeLocation`. This is why a
managed session reads the `.threading.json` checked out in its managed worktree rather than the
base project's file. Non-git projects use the selected folder as their root.

Only one `ProjectScriptConfigurationWatcher` exists for the active root. It uses a path-based
FSEvents stream because editors replace JSON files atomically; it filters for `.threading.json`
before hopping to the main queue and coalesces save bursts. A refresh reparses the bounded file,
compares the catalog, and atomically replaces `project.script.<id>` registry entries. It never
starts a process. Changing selection stops the old watcher, and changing a config updates the
Project ▸ Scripts menu and an open command palette predictably.

This passes the scaling gate: one active watcher, one bounded file, 32 commands, a virtualized
palette table, 16 displayed diagnostics, and no views built per project hidden in the sidebar.

## Invocation and receipts

Project scripts are non-rebindable registry entries. A repository cannot claim a global keyboard
shortcut. They appear in Project ▸ Scripts and in the app command palette (`⌘K`); both dispatch
the same host-owned menu item, so there is no second shortcut or execution system.

Every invocation goes through the non-suppressible `runProjectScript` confirmation. The sheet
shows the repository-authored command and resolved cwd, defaults Return to Cancel, then resolves
the script again after approval. If the config, checkout, or directory changed while the sheet
was open, nothing runs.

An accepted invocation creates a named standalone project terminal in the resolved cwd, selects
it so output is visible, and sends one host-built line. The repository command is a quoted
argument to `/bin/sh -lc`; it cannot splice into the host suffix. The child shell isolates an
authored `exit` or shell-state mutation from the interactive terminal. The suffix prints the
actual child exit status and optional preview URL. `ProjectScriptExecutionReceipt` means only
that this validated command reached that visible PTY; completion is the exit line the user can
see, not an optimistic in-memory status.

## Trust boundary and automatic setup

The repository owns the command and it may do anything the user's shell account may do. Current
safety comes from bounded passive discovery, transparent command/cwd display, a confirmation on
every run, execution in a visible terminal, and an exit-status receipt. Threading reads no
credentials for scripts, adds no remote-shell API, and offers no unattended, scheduled, or
worktree-creation route.

Automatic setup is intentionally not implemented. A future design would need a separate trust
model rather than reusing “the user ran a script once”: an explicit grant tied to repository
identity and reviewed configuration content, invalidation when that content changes, revocation
and audit UI, a capability limit for environment/network/filesystem access, and a durable receipt
that distinguishes queued, started, completed, refused and interrupted work. Until all of those
exist, creating or opening a checkout must remain data-only.

Those five requirements were worked through in full in
[`docs/decisions/repository-setup-hooks.md`](../decisions/repository-setup-hooks.md), and the
conclusion is that one of them has no answer today: an execution-authorizing grant cannot live in
`UserDefaults`, because an agent in this app has a shell that can rewrite it — the same reasoning
that put `BrowserSubmissionExemptions` in process memory. A capability limit is also unavailable
rather than merely unbuilt: a setup command's job is network access, arbitrary writes inside the
checkout and subprocess spawn, which is not a containment boundary. The record therefore rejects
automatic execution outright, keeps it closed for scheduled, remote and unattended sessions under
any future recommendation, and proposes instead that a repository may *name* its setup script so a
freshly provisioned managed worktree can offer it — one press through the confirmation, terminal
and receipt described above, with no new execution path.
