# Browser Focus

> Status: feature draft — researched and implementation-ready, but not scheduled or committed
> product behavior.

## Summary

Add **Browser Focus**, an in-window presentation mode in which the active browser fills the main
window's working area and the current conversation remains available as a compact floating dock at
the bottom.

This complements the detached browser window:

- **Detached browser** moves a browser tab to a separate window, primarily for another display.
- **Browser Focus** keeps a browser in the main window and temporarily gives it the working area.

Browser Focus must be a reversible window-layout state, not another browser host. The same
`BrowserViewController` remains in the display panel throughout, preserving page identity, history,
authentication, private state, downloads, annotations, responsive viewport overrides, and the
agent's page lease.

## Research

### Cursor

[Cursor 3.4](https://cursor.com/changelog/3-4) is the closest direct precedent. Its browsers,
terminals, files, and other tabs can fill the working area, replacing the normal agent chat with a
floating prompt bar. Entry and exit are available from an expand/contract control in the panel
header, the command palette, and `Cmd/Ctrl+Shift+M`.

The useful parts to adopt are:

- the panel-header affordance;
- a reversible focus mode rather than a new window;
- a compact prompt/conversation surface over the focused content;
- a direct keyboard route.

Threading should retain more conversation context than a prompt-only bar: the active turn and
attention state are valuable while inspecting the page.

### OpenAI desktop browser

[OpenAI's built-in desktop browser](https://help.openai.com/en/articles/20001277-using-the-built-in-browser-in-the-chatgpt-desktop-app)
keeps the person and agent on the same page and browser state, including tabs, sign-in, downloads,
and annotations. This supports the single-live-browser rule: changing presentation must not create
a second browser or a visual copy of the first.

### Replit

[Replit's Project Editor](https://docs.replit.com/learn/projects-and-artifacts/project-editor)
keeps conversation and preview as persistent side-by-side panels. This preserves context, but it is
effectively Threading's current layout and does not solve the screen-space problem. Browser Focus is
the deliberate alternative when the page itself needs attention.

## Product contract

Use **Focus Browser** and **Exit Browser Focus** in the UI. Do not call it Full Screen: macOS full
screen remains a separate, compatible window mode.

### Entry points

- Show an expand/corners control in the display-panel header when the selected tab is a direct
  browser tab.
- Change it to the contract glyph while Browser Focus is active.
- Add **View -> Focus Browser** as a rebindable `AppCommand`.
- Use `Shift-Command-M` as the proposed default. It is currently unclaimed and matches Cursor's
  convention.
- Do not enable the action for a hidden browser owned by an ordinary Execution Audit tab. A direct
  `.browser` tab is required.

### Entering

1. Confirm that the selected session and direct browser tab are still current.
2. Save the sidebar state and width, display-panel width, selected session and browser tab, the
   middle pane's collapse behavior, and the first responder.
3. Keep the display panel open.
4. Collapse the sidebar and the main chat/terminal split item through the normal pane-transition
   machinery.
5. Leave the browser installed in the display-panel host.
6. Borrow the live conversation into the floating compact dock when the session has a native chat.
7. Focus the browser, not the composer.

### Exiting

1. Dismiss transient menus or popovers owned by the compact composer.
2. Remove the floating dock.
3. Return the borrowed conversation to the main content pane.
4. Restore the exact prior split-item states and widths.
5. Restore the previous first responder if it remains valid; otherwise focus the normal
   conversation prompt.

Browser Focus is transient. Do not restore it after relaunch, and do not write its whole-window
geometry over the user's ordinary pane widths.

## Focused layout

The browser fills the working area below Threading's existing window chrome. Traffic lights,
toolbar behavior, native sheets, and actual macOS full screen remain unchanged.

The compact conversation dock is bottom-centered, capped to the existing readable composer width,
and nearly edge-to-edge when the window is narrow. Its root overlay passes clicks through to the
browser everywhere outside the dock.

The default **peek** state contains:

- a header using the conversation's real status, such as `Working for 11s`;
- a chevron that collapses or expands the transcript portion;
- the visible tail of the current turn, including active tool calls, permission cards, failures,
  or the latest assistant output;
- the existing live composer with its attachments, model/mode/effort controls, microphone,
  queue/steer behavior, and stop button.

The collapsed state shows the status header and composer only. The peek state adds a bounded,
scrollable transcript. It should use the existing conversation rows rather than introduce a second
mini-chat model.

An active permission or attention card expands the dock and scrolls into view automatically. The
dock may not make an interaction-blocking state invisible.

## Architecture

### Focus is layout state, not tab location

The detached browser is correctly a third `TabHostID` because the tab genuinely moves into another
host. Browser Focus does not move the tab. Its host remains `.displayPanel` before, during, and after
the transition.

Do not add another `TabHostID`, run a `TabTransferCoordinator` move, rebuild the browser, or change
`SessionBrowserResolver` ordering for this feature.

Add a `BrowserFocusCoordinator` owned by `MainWindowController` with an explicit state machine:

| State | Meaning |
| --- | --- |
| `inactive` | Normal split layout |
| `entering(snapshot)` | Layout and conversation are moving into focus mode |
| `active(context)` | Browser fills the workspace and the compact dock is live |
| `exiting(context)` | Conversation and exact prior layout are being restored |

The saved context names both the session and browser tab so a stale transition cannot act on a
different session or a neighboring browser.

### Main-window layout

In `MainWindowController`:

- retain the middle `NSSplitViewItem` as a property rather than a local;
- temporarily allow that item to collapse while Browser Focus is active;
- collapse both the sidebar and middle item through `SidebarSplitViewController` and
  `PaneTransition`;
- guard sidebar- and display-width recording while focus geometry is being applied;
- extend leading-header inset handling so the display-panel tabs clear the traffic lights when the
  display panel becomes the leading pane;
- make panel hiding, window teardown, and incompatible surface changes exit Browser Focus first.

The display-panel browser remains installed throughout, so browser resolver, host-window prompts,
agent navigation, downloads, and page leases keep their existing paths.

### Display-panel affordance

Add the focus control beside the existing new-tab and panel-close controls in
`DisplayPaneController`. This mode changes the workspace, not page navigation, so the pane header is
a better home than `BrowserChromeBar`.

Expose narrow callbacks for:

- toggling Browser Focus;
- reflecting whether focus is active;
- notifying the window before the active tab changes, closes, or leaves the host.

Adding another persistent trailing control changes the panel's hard chrome floor. Update
`DisplayPaneDefaults.slimmestWidth` as a sum of its visible parts and extend the existing header and
minimum-width tests.

### One conversation and one composer

`ConversationViewController` already owns the authoritative `PromptView`, stream, timeline, draft,
attachments, queue, outbox, configuration controls, and stop behavior. Browser Focus must reuse
that controller rather than create a second prompt or send path.

Add a presentation mode such as:

```swift
enum ConversationPresentation {
    case standard
    case browserDock(transcript: BrowserDockTranscriptState)
}
```

In browser-dock presentation:

- keep the same `PromptView` instance and callbacks;
- hide the minimap and sticky-step chrome;
- cap the transcript height and keep it at the active tail;
- switch between peek and composer-only constraint groups;
- preserve outbox, scheduled messages, queue, steer, stop, attachments, and configuration controls;
- expose permission and attention states rather than collapsing over them.

Add narrow borrow/return APIs to `TerminalContainerViewController`. A borrow token records the
normal parent and constraints, prevents double restoration, and keeps the controller alive without
terminating its stream.

All main-surface changes should pass one pre-transition seam that exits Browser Focus before the
container detaches its current child. Do not scatter restoration calls across individual sidebar
and Settings actions.

### Nonmodal floating host

Use the overlay geometry already provided by `WindowChromeHostViewController`, but do not install
the compact dock through `InWindowOverlay` directly. That primitive's scrim and modal dismissal
semantics would block the browser.

Add a design-system-owned nonmodal floating host that:

- constrains the dock inside the window overlay and safe area;
- passes hit testing through outside the dock;
- owns the elevated surface, semantic border, radius, and shadow;
- updates with live themes and Increase Contrast;
- uses `Design.Motion`, including a Reduce Motion path;
- arbitrates with existing modal inspectors so top-level overlays do not fight for z-order.

Feature controllers supply content and state; the design-system component owns visible chrome and
pointer behavior.

## Lifecycle rules

- Switching from one direct browser tab to another keeps Browser Focus active and updates the
  pinned browser-tab identity.
- Selecting a non-browser tab exits first.
- Closing, dragging, detaching, or transferring the focused browser exits before the operation.
- Selecting another session, project, Settings page, or interface exits first.
- Hiding the display panel exits and then hides it.
- Opening a conflicting modal compare or media inspector exits or suspends Browser Focus through
  one overlay coordinator.
- Agent navigation does not exit; the same shared browser remains visible.
- Website-access, credential, download, and destructive-action prompts remain attached to the main
  window through the existing host resolver.
- Private browsers are supported because the browser does not move and focus state is not
  persisted.
- Responsive viewport overrides remain active. Entering focus must not silently reset them.
- Do not bind bare Escape to exit. Web pages, find UI, annotations, sheets, and popovers already use
  it. The contract button and `Shift-Command-M` are the reliable exits.

The detached browser remains the second-display workflow. A browser already in a detached window
is not silently moved back by the main window's Focus Browser command. A later explicit **Move to
Main Window and Focus** action can be considered separately.

## Terminal/TUI sessions

A native chat can provide the complete compact composer. A terminal/TUI session cannot safely do
so: manufacturing a `PromptView` that writes into the PTY would bypass TUI editing, paste handling,
permissions, and provider-specific interaction.

For the first version:

- keep Browser Focus available;
- show a compact read-only activity/status card;
- offer **Return to Terminal to reply**;
- do not present it as an equivalent composer.

A terminal-specific compact interaction surface is separate future work.

## Implementation sequence

### 1. State and layout foundation

- Add `BrowserFocusCoordinator`, its layout snapshot, idempotent transition rules, and width-recording
  guard.
- Retain and temporarily collapse the middle split item.
- Add leading-edge header inset behavior for the focused display panel.

### 2. Entry points

- Add the display-header expand/contract control.
- Add `AppCommands.ID.focusBrowser`, View-menu wiring, validation, and the proposed shortcut.
- Add localized titles, tooltips, unavailable-state explanations, and accessibility labels.

### 3. Compact conversation presentation

- Add standard and browser-dock constraint groups.
- Add safe borrow/return APIs to `TerminalContainerViewController`.
- Implement current-turn peek, collapsed state, permissions, status, and the unchanged composer.

### 4. Floating host

- Add the pass-through design-system component.
- Integrate it with `WindowChromeHostViewController`.
- Cover resizing, live themes, contrast, motion, and overlay arbitration.

### 5. Lifecycle integration

- Cover tab activation, closure and transfer; session and surface changes; window closure; app
  termination; and detached-window operations.
- Add the terminal-session fallback.

### 6. Durable documentation

When implementation begins:

- add the host-versus-presentation distinction to `docs/architecture/mcp-and-display.md`;
- document conversation borrowing in `docs/architecture/native-conversations.md`;
- document nonmodal overlay behavior in `docs/architecture/window-chrome.md` and the design-system
  rationale where appropriate;
- update the user guide and keyboard shortcut inventory.

## Verification

Tests must prove that:

- the `BrowserViewController` object and `.displayPanel` host identity are unchanged throughout;
- URL, history, page lease, private context, responsive override, annotations, and authentication
  survive;
- sidebar and content panes restore exactly, including an initially collapsed sidebar;
- focus geometry is never persisted as the normal display-panel width;
- the same `PromptView`, draft, attachments, outbox, queue, steer, and stop state survive;
- one submission results in one send;
- an active permission cannot be hidden behind a collapsed transcript;
- tab changes, closure, drag-out, session changes, Settings, and window closure exit cleanly;
- pointer events outside the dock reach the `WKWebView`;
- focus order, expand/contract controls, keyboard operation, restoration, and VoiceOver announcements
  are correct.

Rendered-state fixtures should cover:

- peek and collapsed states;
- idle, working, permission, and failure states;
- long assistant and tool-call content;
- narrow and wide windows;
- System plus at least two themes;
- Increase Contrast and Reduce Motion.

Add a visible `WKWebView` integration test proving that collapsing the sibling panes does not
produce the never-shown blank-snapshot failure. Put every new unit-test source below the
filesystem-synchronized `Tests/ThreadingTests` directory, then run the theme and architecture
boundary checks, the fast suite, and the complete visible-WebKit suite.

## Acceptance criteria

The draft is ready to graduate into implementation when the following product behavior is agreed:

- one gesture makes the selected main-window browser occupy the working area;
- the live browser is not reconstructed or transferred;
- a native chat retains its live status, current turn, and exact composer in the compact dock;
- the browser remains directly interactive outside the dock;
- all normal layout and input state returns exactly on exit;
- private browsers and agent-driven navigation continue to obey their existing security boundary;
- terminal/TUI sessions use the explicit read-only fallback rather than an unsafe imitation
  composer.
