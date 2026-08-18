# Open In

Handing a checkout, or one file of it, to the app the work is actually done in.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

Threading is where an agent is *watched*, not where its output is edited. Every session already
ends with the user going somewhere else — an editor, a terminal, Finder — and before this that
crossing was a copied path. So the way out is a first-class control rather than a menu item
buried three levels down: the content pane's header carries it beside the session's actions,
and ⌘O is bound to it, which is the platform's Open and the only opening this app does.

That sentence is a decision, not a description, and it has been re-tested against the obvious
counter-proposal: an editable file preview inside the app.
[`docs/decisions/editable-file-previews.md`](../decisions/editable-file-previews.md) rejects one for
the Mac — a deliberately limited editor competing with the good one a press away, at the cost of a
new themed text surface and a repository-file write contract — and keeps the contract specified for
the one surface with no way out, the iPhone's read-only Files browser. Two smaller things it points
back here for: teaching Open In about a managed worktree, and the fact that a right-clicked review
row already opens at the first changed line, which is the real answer to "let me fix this typo".

`ExternalApp` is the registry, `ExternalAppLauncher` finds and opens, `OpenInMenu` is the one
list every surface offers.

## Installed is a bundle identifier, not a command on `PATH`

This is the substantive decision, and it is a macOS one. The obvious implementation — the one
the cross-platform tools use — probes `PATH` for `code`, `cursor`, `zed`. On a Mac that answers
the wrong question twice over:

- `code` exists only for someone who ran *Shell Command: Install 'code' command in PATH*, while
  `com.microsoft.VSCode` is there the moment the app is in `/Applications`. A `PATH` probe
  offers a user with VS Code installed nothing at all, which is exactly the case this feature
  is for.
- A GUI app does not inherit the interactive `PATH` — the same fact that makes every agent
  launch here go through a login shell (`AgentLauncher.loginShellPath`). So a probe would have
  to *spawn a shell* before it could answer, per app, at the moment a menu opens.

`NSWorkspace.urlForApplication(withBundleIdentifier:)` answers from LaunchServices, in
microseconds, correctly. The list is cached and dropped on `refresh()`, which the header's
dropdown calls as it opens — the one moment the answer is about to be read and the one moment
it can have changed since it was last needed.

**The command line is still recorded, for the one thing `open` cannot express: a line number.**
Opening `Sources/App.swift` is `NSWorkspace.open`; opening it *at line 42* is `code --goto
path:42`, and that needs the CLI, and therefore the login shell after all. So the shell is paid
for only where a target actually carries a line, off the main actor, cached per command for the
process. A missing CLI is not a failure: the file still opens through LaunchServices, at
whatever line the editor last left it. Being one scroll away beats being told to install a
shell command.

Three families spell the position three different ways, each read off that family's own CLI:
`--goto path:line` (VS Code, Cursor, Windsurf, VSCodium), `--line N path` (every JetBrains IDE,
and Xcode's `xed`), and the position glued to the path (Zed, Sublime Text). A wrong form fails
*quietly* — the editor opens the file and ignores the argument — which is why the shapes are
pinned in `OpenInTests` rather than left to a reviewer's eye.

## What may be offered depends on what is being opened

`ExternalApp.Accepts` is the whole of it, and it exists for one case: **a terminal takes a
directory and never a file**, because handing Terminal a file *runs* it. That is the one
outcome an "Open in" menu must not be able to produce, so it is a property of the registry —
asserted once — rather than a filter each of the four call sites has to remember.

Finder is the other special case, and the only entry that *reveals* rather than opens: a folder
is revealed rooted at itself (selecting it inside its parent answers "where does this live",
which is not what someone opening a checkout asked), and a file is selected in its folder,
which is exactly what they asked.

## Last used wins

There is no Settings row for a preferred editor, because the choice is made in the act of
opening: whatever the chevron's menu was last used for becomes what the button's press does.
A stored id outlives the app it names — an editor gets uninstalled, and a *file* menu cannot
offer the terminal that a folder menu could — so `ExternalApps.resolvePreferred(storedID:among:)`
falls back to the first app on offer rather than leaving the control dead. It is pure and
separate from the launcher for the same reason: what this Mac has installed is not assertable,
and the rule is.

The preference goes through `PreferenceStore`, not `.standard`. It records a **choice the user
made**, and the hosted test suite runs inside the shipping app — see
[`persistence.md`](persistence.md) for the bug that rule came from.

## Where the offer appears

One builder (`OpenInMenu`), two forms, four surfaces — the same reason
`populateSessionActions` is shared between the sidebar row, its right-click and the pane
header's Context button. A second list that quietly held fewer apps is the drift this prevents.

| Surface | Target |
|---|---|
| The content pane's header, as a split control | the visible page's checkout |
| ⌘O, and Project ▸ Open in External App | the same checkout, in the app used last |
| A project row's menu, and a session row's | that project's checkout |
| Overview's Activity filesystem rows | a folder, or a file at no particular line |
| A Git Review file row's right-click | **the file at the first line the diff changes** |

That last row is the one that earns the feature. A review is the only surface in the app that
knows *which* line the reader is looking at, so it is the only one that can open an editor
where the change is. The **new** numbering is what an editor needs — a removed line's old
number points into a version that is no longer on disk — so a hunk of pure removals lands on
the context line beside it, and a binary change lands nowhere in particular
(`GitReviewFileRow.firstChangedLine`).

## The header control

A split control: the target app's own icon opens the checkout in one press, and the chevron
beside it chooses a different one. Its own control (`SplitIconButtonView`), *beside* the
session's actions rather than inside them — those four act on the pane (its menu, its renderer,
its two drawers) while this one leaves for somewhere else entirely, and a run of six identical
squares would have said they were the same kind of thing.

**One plate, two halves — not two buttons in a group.** It started as a
`ToolbarButtonGroupView`, which is the right container for the four actions beside it: those act
on four different things and are spaced as the separate controls they are. These two act on
*one*, and spaced apart they read as an app's icon with an unrelated chevron floating next to
it. Hover is where that gave itself away — each half raised a rounded rect of its own, so
pointing at the control cut it in two at exactly the moment the pointer claimed it was single.

So the surface is drawn once, by the control, and the halves draw none
(`ThemedIconButton.drawsSurface`). A raised half fills **inside** the plate's silhouette, clipped
to it: the outer end keeps the plate's corner and the join is a straight edge that exists only
while the pointer is on one side of it. Nothing is drawn between the halves at rest — the join is
what the control is, and a rule down the middle would argue with it. The halves are also not the
same width (`Design.Size.splitMenuWidth`): the press is the point and the chevron is the
exception, and equal halves offer them as the same choice twice. `chrome-05-open-in-states` in
the storybook renders all three states side by side, which is the only place the seam is
reviewable.

**It is the only control in that strip carrying colour**, and deliberately: the one question it
has to answer at a glance is where the press sends you, and no glyph the app could draw says
"Xcode" as fast as Xcode's own hammer. `ThemedIconButton.setImage` is the documented exception
that allows it — the same argument that puts Finder's icons in the file tree and keeps Claude's
coral mark its own colour (see [`icons.md`](icons.md)).

That exception carries a trap worth keeping: **`NSImageView` applies its `symbolConfiguration`
to whatever image it is given**, and a configuration sized for an 11pt glyph applied to a
rendered app icon draws *nothing at all*. The button was empty in the middle of the header, and
the render — not an assertion — is what caught it; `setImage` clears the configuration and
`setSymbol` restores it.

With no checkout there is nothing to open, so the control hides rather than pointing at
whatever was open last, and the menu-bar item validates to disabled instead of beeping at a
chord the menu said would work. Settings is the page that has no checkout.
