# Editable file previews

> Status: **decision record** (2026-08-12). **Reject** an editable file preview on the Mac.
> **Wait for demand** on one narrow slice — a single-file, hash-guarded, explicit-save text edit
> for the remote client, which is the only surface with no way out to an editor.
> The write contract in §4 is specified anyway, so that if the slice is ever built it is built
> once and correctly. Not implementation work.

Part of the [decisions index](README.md). Read alongside
[`external-apps.md`](../architecture/external-apps.md) (the stated product position and Open In),
[`mcp-and-display.md`](../architecture/mcp-and-display.md) (the Activity tab and the display
panel), [`git.md`](../architecture/git.md) (the containment discipline, the no-discard rule, the
staging capability matrix), [`persistence.md`](../architecture/persistence.md),
[`REMOTE_ACCESS.md`](../REMOTE_ACCESS.md) and
[`design-system.md`](../architecture/design-system.md).

**The one-sentence version.** Threading's stated position is that it is *"where an agent is
watched, not where its output is edited"*, and Open In already answers the Mac case in one press
with the user's real editor at the right line — so an in-app editor would be a worse editor
competing with a better one, at the cost of a text-editing surface the design system does not have.
The one place the argument does not hold is the iPhone, which has a read-only Files browser and no
editor to leave to; that is the slice worth keeping the contract for.

---

## 1. User problem and concrete use cases

1. **The one-character fix.** The agent left a typo in a string. The user is looking straight at it
   in a Git Review diff. Fixing it means leaving for an editor, finding the line, changing one
   character, coming back.
2. **The wrong constant.** A generated config has `3000` where it should be `3001`. Same shape,
   same annoyance.
3. **Reading a file that is not in the diff.** The user wants to look at a file the agent
   *mentioned* but did not change. Today the Activity tab's outline opens it in the default
   application (`NSWorkspace.open`), which is a context switch to read four lines.
4. **The phone.** Away from the Mac, watching a session on the iPhone. The Workspace's Files
   browser is explicitly read-only, and there is no editor to hand off to. A typo seen here cannot
   be fixed at all without asking the agent to do it.
5. **Reviewing without a checkout open.** A user reviewing a managed workspace's diff has no editor
   pointed at that detached worktree, so Open In lands them somewhere they did not expect.

Cases 1–3 and 5 are Mac cases with an existing answer of varying quality. Case 4 has no answer.

---

## 2. Existing Threading behaviour and overlap

**The position is stated, not accidental.** [`external-apps.md`](../architecture/external-apps.md)
opens with it: *"Threading is where an agent is watched, not where its output is edited. Every
session already ends with the user going somewhere else."* Open In is therefore built as a
first-class control rather than a menu item — the pane header's split control, ⌘O, project and
session row menus, the Activity tab's rows, and a Git Review file row's right-click, which opens
**the file at the first line the diff changes**, in the *new* numbering, using the editor family's
own position syntax (`--goto path:line`, `--line N path`, or glued). Last used wins, resolved
through LaunchServices by bundle identifier rather than a `PATH` probe.

That last row is the direct competitor to case 1, and it is good: the review pane is the only
surface that knows which line the reader is looking at, and it hands the user their real editor
positioned there.

**There is no in-app text editing of repository files today, and no component for it.**
`UI/Design/` has `ThemedTextView` (a themed `NSTextView` used for prompts), `PromptView` (the
composer), `CodeContextPreviewView` (a bounded, presentation-only slice of code for comment sheets)
and `GitReviewDiffTextView` (one selectable TextKit document per hunk, read-only, with cached
change washes). `isEditable = true` appears in exactly three places in the app: the composer, an
accounts field, and the component gallery. An editable code surface is a **new design-system
component**, subject to the theme boundary in full: behaviour, accessibility, live-theme-switch and
rendered-state tests.

**Threading writes to a repository in exactly two places, and both are narrow.** `GitIndexWriter`
stages, unstages and commits — and Git Review deliberately has **no discard**, on the recorded rule
that *"every other action here is undone by the control beside it while throwing away a change an
agent just made is undone by nothing."* And `.worktreeinclude` copies selected ignored files into a
new managed worktree, refusing symlinks, paths escaping either root, and existing destinations.
Everything else Threading writes goes to its own Application Support directory.

**Path containment already has a house style.** `GitReviewReader.repositoryFile` resolves symlinks,
proves the root prefix, requires a regular file, and adds an `ls-files` membership check for paths
that came from a remote request; `boundedWorktreeBytes` enforces an allocation cap in the same
helper, on the stated reasoning that *"an untracked symlink can name bytes outside the checkout and
a generated file can grow after `status` reports it."* Any write contract inherits this.

**`RecoverableFileStore` is not the answer for repository files.** It is a `Codable` app-state store
under Application Support with size policies and quarantine. A user's source file has different
semantics: Threading does not own it, must not quarantine it, and must not rewrite its encoding.

**The remote client is explicitly read-only.** [`REMOTE_ACCESS.md`](../REMOTE_ACCESS.md) describes
the iPhone Workspace as gathering "Browser, Review, the **read-only** repository Files browser, and
Attachments". Remote authority is already modelled properly — paired owner scope, Collaborative vs
Focused input control, a 30-second hold on a dropped controller's turn — so a write would have a
place to hang, and a decision to make about which roles get it.

**Two adjacent things that look like this feature and are not.** `display_html` writes agent-supplied
bytes into the session attachment store as an immutable capture — attachments, not the checkout.
And Codex 0.147.0's app-server defines an `fs/*` family (`fs/writeFile { path, dataBase64 }`,
`fs/readFile`, `fs/watch`, `fs/getMetadata`, …) in which the *provider* asks the *client* to touch
the host filesystem. Threading implements none of it. That is a separate decision about hosting a
provider's remote-execution surface and must not be smuggled in behind a user-facing editor.

---

## 3. Lessons from t3code

They built it, and the implementation is the argument for specifying the contract carefully.

`apps/web/src/components/files/FilePreviewPanel.tsx` renders a third-party editor
(`@pierre/diffs/editor`) and drives `fileSaveCoordinator.ts` — 76 lines, and what it does *not* do
is the interesting half:

- **Debounced autosave, no explicit save.** `change()` bumps a revision, marks pending, and
  schedules a write after a fixed debounce. `dispose()` flushes.
- **No expected-content precondition.** `persist(contents)` sends the whole buffer. There is no
  base hash, no mtime, no version. A file changed underneath the editor — by the agent, by a
  formatter, by a `git checkout` — is silently overwritten by whatever the editor last had.
- **No conflict surface.** On failure the coordinator simply leaves `pending` true and retries on
  the next change. The user is not told which write lost.
- **Identity is content-derived.** `fileContentRevision.ts` keys the editor on
  `editor:${environmentId}:${projectFileCacheKey(cwd, relativePath, contents)}` — deliberately so
  that *locally edited* contents keep a stable editor identity while *external* contents rotate it.
  That is a real insight (an incoming refresh must not remount the editor under the typist) and it
  is also the whole of their external-change handling: rotate the component, discard the state.
- **The write itself is one `projects.writeFile` command** with no atomicity, encoding or line-ending
  contract visible at the call site.

This is exactly the shape that is fine in a product where the agent is a server-side actor whose
edits arrive as events, and dangerous in Threading, where the agent is a **local process writing the
same bytes concurrently** and where Claude's own write tool has a freshness precondition (§4.3) that
an unguarded host write would race.

The other t3code lesson is the one Threading already applied: their open-in-editor matrix covers
VS Code/Cursor/Zed/the JetBrains suite — they shipped *both*, which suggests the editor did not
remove the need to leave.

---

## 4. Proposed domain and host contract

Scope first, because "editable file preview" is a phrase that grows.

### 4.1 Intended editing scope

**A correction, not an authoring surface.** The unit is: open one text file already visible in a
review or file listing, change a few characters, save, and see the diff update. Explicitly not an
IDE: no multi-file editing, no project-wide find and replace, no completion, no language server, no
refactoring, no new-file creation, no rename, no delete, no format-on-save, no linting, no build.

If the user needs any of those, they need their editor, and Open In is one press away.

### 4.2 The host write contract

Any repository-file write Threading ever performs must satisfy all of the following. These are
stated as one list so a later implementation cannot pick a subset.

**Target admission**

1. The path resolves inside the *execution* checkout after symlink resolution and root-prefix
   proof — `repositoryFile`'s discipline, including the `ls-files` membership check when the
   request arrived from a remote client.
2. The target is a **regular file** that already exists. No creation, no directories, no devices.
3. The target is not a symlink. A symlink is refused, not followed: the containment proof would
   pass while the bytes landed somewhere else.
4. The file is not ignored **unless** it was reached from a surface that shows ignored files, and
   even then it is never created.
5. Size and encoding are admissible per §4.3.
6. POSIX permissions allow writing, and the current mode is preserved across the write. A file that
   is read-only on disk is refused with that reason rather than chmod'd.

**Content admission**

7. The file decodes as **UTF-8**, and only UTF-8 is editable. UTF-16, Latin-1 and everything else
   are read-only with the encoding named. Round-tripping an encoding Threading guessed is how a
   file quietly becomes mojibake, and the guess is not recoverable from the result.
8. A BOM present on read is preserved on write; a BOM absent is not added.
9. **Line endings are preserved, per file, as observed.** A file that is entirely CRLF is written
   back CRLF; a file that is entirely LF, LF. A **mixed** file is refused for editing and says so —
   normalising it would produce a diff touching every line, which is worse than not editing.
10. Trailing-newline state is preserved exactly. `git.md` already records the cost of getting the
    inverse wrong: `\ No newline at end of file` passed through unprefixed, because "dropping it
    silently re-adds a newline the file never had."
11. Binary content — git's own NUL heuristic, the same one the diff synthesis uses — is never
    editable.
12. A size ceiling applies before the file is read into a view, not after. The existing
    `GitReviewDefaults.maximumDiffBytes` cap is the precedent; an editor needs its own, smaller,
    because a 5 MB single-line generated file is a text file and is not editable.

**The write**

13. **Expected-content hash is mandatory.** The request carries the SHA-256 of the bytes the editor
    was opened on. Immediately before replacing, Threading re-reads the file and compares. A
    mismatch is a **conflict**, refused, with the user offered: discard mine, keep editing, or open
    both in the external editor. It is never resolved by writing.
14. **Atomic replacement**, with the temporary file in the *same directory* so the replace is a
    rename within one filesystem, followed by an `fsync` of the file before the rename. `.atomic` is
    the existing spelling used elsewhere in the app; what it does not do by itself is preserve mode
    and extended attributes, so those are read before and restored after.
15. The write **never touches the index**. Staging is `GitIndexWriter`'s, it is a separate user
    decision, and `GitStaging.capability(for:)` already holds the rule about which comparisons may
    speak to the index at all.
16. `--no-optional-locks` does not apply; this is not a Git operation. But the write must not run
    while `index.lock` is held by the agent's own git, for the same reason a stage does not:
    `GitFailure.indexLocked`'s stated answer is "try again".
17. The write is refused while a **turn is in flight in any session standing in this checkout**
    (`worktreeIdentity`, as `CheckoutBranchFollower` establishes). This is the one rule that makes
    the whole feature safe: the agent and the user do not write the same tree at the same time.
18. One file per request. No batch.

**Save model**

19. **Explicit save, not autosave.** ⌘S, plus a save on close with an explicit prompt. Autosave to a
    file a local agent process is also reading is a race with no upside: it multiplies conflicts,
    and it writes the user's half-typed state into a file the agent may read next.
20. Unsaved state is **not persisted anywhere.** No draft, no restore across launch. It is the same
    rule composer image attachments follow (`persistence.md`): a half-edit whose base file moved is
    worse than a lost half-edit. Closing with unsaved changes prompts.
21. **Undo is the editor's own** (`NSUndoManager` on the text view), scoped to the open document and
    discarded on close. Nothing here writes a checkpoint; a saved edit is undone the way any other
    change to the checkout is — by Git Review, or by the restore in
    [Revert to this message](revert-to-message.md) if that ships.
22. A successful save produces a receipt naming the file, and the checkout watcher refreshes Git
    Review through its existing path.

**Remote authority**

23. A write from the remote client requires **paired owner scope**. A guest with reply access may
    not write files; a one-chat share link may not see the surface at all.
24. Under **Focused** input control, only the controller may save; under **Collaborative**, saves are
    atomic per file and last-writer-wins is prevented by the hash in (13), which is exactly the case
    it was designed for.
25. The bytes cross the wire under the same bounded-snapshot rule approvals follow: a file too large
    to send as one bounded payload is read-only on the phone and says so, rather than being sent
    truncated. Threading never offers an edit against a partial file, for the same reason it never
    offers an approval against a partial diff.

### 4.3 The provider interaction, measured

This is the fact that decides the save model, and it is good news.

Claude Code 2.1.228's write tools carry a read-freshness precondition. Measured in the binary, the
two refusal strings are verbatim:

> `File has not been read yet. Read it first before writing to it.`
>
> `File has been modified since read, either by the user or by a linter. Read it again before
> attempting to write it.`

So a host-side save into a file the agent has read does **not** silently lose: the agent's next edit
is refused with an actionable message and it re-reads. The interaction is safe in the direction that
matters, provided the host write is atomic (14) and the host does not write mid-turn (17).

The CLI also exposes a `seed_read_state { path, mtime }` control request, which tells it to consider
a file read at a given mtime. **Threading must never call it.** Its only effect would be to suppress
the very check that makes the above safe, and suppressing it would convert a clean refusal into a
silent overwrite of the user's edit.

Codex's `apply_patch` is a patch against expected context, which fails on its own when the context
moved — the same property reached differently. Grok and OpenCode are not modelled here because the
gate in (17) is provider-neutral.

### 4.4 The alternative it is measured against

Open In, today: one press, the user's real editor, the right file, the right line, no new
component, no write contract, no conflict model, full undo, full language support, and the user's
own key bindings. The honest comparison for cases 1–3 is not "editor vs no editor" but "a
deliberately crippled editor vs the good one that is already one press away".

The two places Open In genuinely falls short: case 4 (no editor to leave to), and case 5 (an editor
pointed at a detached managed worktree the user did not open) — and case 5's better fix is Open In
learning to open the managed checkout, which is a much smaller piece of work.

---

## 5. Security, privacy, destructive-action and scaling analysis

**Destructive.** Writing a user's source file is the second most destructive thing in this document
set, after a worktree restore. The specific hazards:

- **Overwriting the agent's concurrent work.** Answered by (17) and (13).
- **Overwriting the *user's* work in another editor.** Answered by (13) only — the hash is the whole
  protection, and it is why it is mandatory rather than best-effort.
- **Encoding and line-ending damage.** A save that silently normalises line endings produces a diff
  touching every line in the file, which destroys the reviewability of everything else in that
  turn. Answered by (7)–(10), and it is why mixed line endings are refused rather than fixed.
- **Symlink escape.** Answered by (3): refuse rather than follow. Note this is *stricter* than the
  read path, which resolves and proves containment; a write through a resolved symlink is still
  a write to a path the user did not name in the file listing.
- **No agent-callable tool.** The agent already has file-write tools with its own permission
  brokering; a Threading MCP tool that writes files would be a second, unbrokered path to the same
  bytes, bypassing `PreToolUse`, the permission cards and the execution audit.

**Privacy.** The bytes are already local. What changes is the wire: a remote edit sends file contents
to a phone. That is already true of the read-only Files browser and of Review diffs, so the boundary
is unchanged — but the write path must reuse the same redaction and bounding rules, and a private
browser tab's rule (provenance is not permission) has an analogue here: a file readable in a Review
diff is not thereby writable.

**Scaling.** Apply the [scaling gate](../../CLAUDE.md#scaling-gate). File size and line count are
externally sized:

- The size ceiling is applied **before** constructing the text view, per the gate's "collapse,
  paginate and cap before constructing views, attributed documents, images or constraints".
- One document, one file, editor never mounted for a file over the cap.
- The hash is computed off the main actor on both read and pre-write re-read.
- A single very long line is the adversarial case for TextKit and is what the byte cap is really
  protecting against.
- Stress fixture: a 2 MB file with 40,000 lines, and a 400 KB file that is one line, both opened,
  edited at the end, and saved, with the watcher live.

---

## 6. Dependencies on earlier roadmap goals

Shipped and depended on: `GitReviewReader`'s containment and bounding helpers, `GitCheckoutWatcher`,
`GitFailure.indexLocked`, the turn-admission fence (which is what makes "no turn in flight" a
knowable fact), remote access's scope and input-control model, `ToastPresenter`.

Owed, and substantial:

- **A themed editable code surface in `UI/Design/`.** The theme boundary forbids feature code from
  constructing an AppKit control; this needs a component with behaviour, accessibility,
  live-theme-switch and rendered-state tests, plus a decision about whether it reuses `Syntax`
  highlighting (it should) and how selection colours resolve (`SelectionSurface.stated` already
  answers it).
- **A repository-file write service** implementing §4.2 in one place, with its own typed refusals —
  not a `Data.write` at a call site.
- On the remote side, a wire shape for read-with-hash and save-with-hash, plus the role checks.

Not depended on: the restore work in [Revert to this message](revert-to-message.md), though the two
would share the "no turn in flight in this checkout" precondition and should share its
implementation rather than each growing one.

---

## 7. Smallest shippable slice

**If, and only if, §12's trigger fires: a single-file text edit on the remote client's Files
browser.**

- Owner scope only, controller only under Focused.
- One file, UTF-8, under the bounded-payload ceiling, single line-ending convention, not a symlink,
  not ignored, not binary.
- Read returns bytes plus the SHA-256; save sends bytes plus that hash; a mismatch is a conflict
  card, not a write.
- Refused while a turn is in flight in that checkout.
- Explicit save. No autosave, no draft persistence.
- Nothing changes on the Mac.

That ordering is deliberate and is the opposite of the obvious one. The Mac is where an editor is
easiest to build and least needed; the phone is where it is hardest and most needed. Building the
Mac version first would produce a surface that competes with Open In and still leaves case 4
unanswered.

---

## 8. Explicit non-goals

- Any editor on the Mac's display panel or Activity tab.
- Creating, renaming, moving or deleting files from any Threading surface.
- Multi-file editing, project-wide replace, completion, a language server, formatting, or linting.
- Autosave of a repository file, in any surface, ever.
- Persisting unsaved edits across a relaunch.
- Editing non-UTF-8 files, binary files, files with mixed line endings, or symlinks.
- Editing while a turn is in flight in the same checkout.
- Any MCP tool that writes a repository file.
- Calling Claude's `seed_read_state`, or any other suppression of a provider's own write-freshness
  check.
- Implementing Codex's `fs/*` host-filesystem request family. That is a separate decision about
  hosting provider-driven filesystem access and shares nothing with a user pressing ⌘S.
- Turning the read-only Activity tab into an editor "while we are here". Its rows already open in
  the right application.

---

## 9. Acceptance and failure tests

Acceptance:

1. A UTF-8 LF file is edited and saved; the bytes on disk differ in exactly the edited region, the
   trailing-newline state is unchanged, and mode bits are unchanged.
2. A CRLF file is edited and saved; every unedited line still ends CRLF and `git diff` shows one
   changed line.
3. A file with no trailing newline keeps none after a save that did not touch the last line.
4. A file with a BOM keeps it; a file without one does not gain one.
5. Saving refreshes Git Review through the watcher, preserving the reader's first visible path and
   within-row offset.
6. The index is untouched: content staged before the edit is still staged, with its old bytes.
7. On the phone: an owner saves; a guest with reply access is offered no save; under Focused, a
   non-controller is refused at the Mac.

Failure, each refusing with the file untouched and a stated reason:

8. The file changed on disk since it was opened — conflict, offering discard/keep-editing/open
   externally, and **never** writing.
9. A turn starts in another session in the same checkout while the editor is open; the save is
   refused and says which session.
10. `index.lock` is held.
11. The path resolves outside the checkout, or is a symlink, or is not a regular file.
12. The file is not valid UTF-8.
13. The file has mixed line endings.
14. The file is binary by git's NUL heuristic.
15. The file is over the size cap — the editor never mounts, and the surface stays read-only with
    the reason.
16. The file is read-only on disk.
17. The process is killed mid-save — the original file is intact and no temporary file is left in
    the checkout (which is why the temporary lives in the same directory with a name the cleanup
    knows, not in `/tmp`).
18. The agent writes the same file immediately after a successful host save — Claude's own
    "modified since read" refusal is the observed behaviour, and the test asserts the app does
    nothing to suppress it.

Boundary test, in the spirit of `check_architecture_boundaries.sh`: no MCP tool and no non-owner
remote route reaches the write service.

---

## 10. Estimated complexity and maintenance burden

**Large, and mostly not where it looks.** The editor component is a week; the write contract in §4.2
and its failure matrix in §9 are the actual feature, and every one of those seventeen clauses is
there because omitting it produces a silent data-loss bug rather than a visible one.

Maintenance is **moderate and permanent**: an editable surface accretes requests (find, replace,
multi-cursor, "why is there no autocomplete") that all have the same honest answer — use your
editor — and a surface whose honest answer to most requests is "no" is a support cost. The write
contract itself is stable once written; encodings and line endings do not change.

The comparison that decides it: Open In cost one registry, one launcher, one menu builder and a
split control, and it delivers a strictly better editing experience for every Mac case.

---

## 11. Recommendation

**Reject an editable file preview on the Mac.** The product position is stated and correct, Open In
already wins on every axis for cases 1–3, and the design-system and write-contract cost is
disproportionate to "fix a typo without switching apps".

**Two smaller things are worth doing instead, and neither needs this record's machinery:**

- Make Open In understand a **managed worktree**, so case 5 lands in the right checkout.
- Consider a bounded read-only **preview** in the Activity tab for the case-3 user who only wants to
  read four lines. That is `CodeContextPreviewView`'s and `GitReviewDiffTextView`'s territory, needs
  no write contract at all, and is a different, much smaller decision.

**Wait for demand on the remote slice**, with the contract above held ready. It is the only case
with no alternative, and it is also the one where a careless implementation would be most dangerous
— which is why the contract is written now, while nobody is under pressure to ship it.

---

## 12. What should reopen this

**Build the remote slice** when: a user reports wanting to fix something from the phone and instead
asks the agent to do it, more than once. "I told Claude to fix a typo because I could not" is the
signal — it spends a model turn on a keystroke.

**Reopen the Mac rejection** only if one of these becomes true:

- Open In stops being one press for a common case — for example if managed worktrees become the
  default and editors cannot follow them; or
- a measured pattern emerges of users leaving for an editor and *not coming back* within a session,
  which would mean the app is losing the watching role the position depends on. This is observable
  locally from the existing last-used-app preference plus session focus, and must not be measured
  any other way.

**Reopen the write contract separately** if Threading ever needs to write a repository file for
another reason — a `.threading.json` editor, an extension writing into the checkout, a Codex `fs/*`
implementation. In that case §4.2 is the contract and this record is its home, whatever surface
calls it.

**Watch:** Claude's write-freshness precondition. Everything safe about §4.3 rests on it. If a
future CLI relaxes it, or if a runtime Threading supports gains a write tool with no equivalent
check, the host write becomes a genuine race and the answer changes from "guarded" to "not while an
agent is attached at all".
