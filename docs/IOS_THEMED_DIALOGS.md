# iOS theme boundary

The phone's half of [`THEME_BOUNDARY.md`](THEME_BOUNDARY.md). The filename is historical: the
rules began with dialogs and now cover every application-owned surface in `ThreadingMobile`.

`scripts/check_mobile_theme_boundaries.py` enforces the two mechanical rules below and runs from
`scripts/check_theme_boundaries.sh`, so an ordinary `xcodebuild` fails on a violation.

## Dialogs

Application-owned alerts and confirmation dialogs in `ThreadingMobile` are presented through
`Sources/ThreadingMobile/ThemedDialog.swift`. The component consumes `RemoteThemePalette`, so an
open dialog follows the same live Mac/iPhone appearance update as the view behind it.

Use:

```swift
.themedAlert(
    "Rename session",
    message: "This name is shared with the Mac.",
    isPresented: $isRenaming,
    textField: ThemedDialogTextField("Session name", text: $name),
    actions: [
        ThemedDialogAction("Cancel", role: .cancel),
        ThemedDialogAction("Rename") { rename() },
    ]
)
```

or:

```swift
.themedConfirmationDialog(
    "Forget this Mac?",
    message: "You can pair it again later.",
    isPresented: $isConfirming,
    actions: [
        ThemedDialogAction("Forget Mac", role: .destructive) { forget() },
        ThemedDialogAction("Cancel", role: .cancel),
    ]
)
```

### The two halves are made of different things

`themedAlert` is drawn by this app: a centred panel in the remote theme's material, because an
alert is Threading speaking and it should look like Threading.

`themedConfirmationDialog` is the operating system's action sheet. It used to be a card of our
own and it was wrong twice over. It read as nothing: an iPhone owner knows what an action sheet
standing on the bottom edge of the screen is, and a themed slab floating in the middle of a list
is a message from no one. And it *was* floating, because the overlay a `ViewModifier` adds is
only as tall as the view it decorates, so "anchored to the bottom" meant the bottom of whatever
the modifier happened to be attached to. The share-role chooser shipped that way and the owner
reported it as a prompt that "floats too much".

This is the same exception the boundary already makes below for the share sheet and the
permission prompts, and that the composer's attachment-source sheet already took: a surface whose
presentation and trust story belong to iOS stays native and is not imitated. The system chrome is
the point. Do not re-skin it, and do not read the change as permission to reach for
`.confirmationDialog` at a call site — `scripts/check_mobile_theme_boundaries.py` fails the build
on one outside `ThemedDialog.swift`, so there is still exactly one component for these prompts.

`systemImage` therefore decorates an alert's buttons only. An action sheet draws titles.

### A confirmation asks one question. A chooser is a stage of its own sheet.

The share-role chooser went through both halves above and belonged to neither. As a card it
floated; as an action sheet it read as three bare words with nothing to say what any of them
granted, and it dismissed itself to present a *second* sheet with the answer. Two presentations
for one question.

It is the first stage of the Share Chat sheet now (`ShareChatSheet.swift`): one presentation,
themed rows inside the system's own bottom sheet, and the link-ready stage crossfading in when a
row is tapped. The rule this leaves behind:

- A prompt with **one question and two or three ways to answer it** is a confirmation. The
  surface switch and the two destructive confirmations are that, and stay
  `themedConfirmationDialog`.
- A prompt whose options each need **a name, a glyph and a line explaining them**, or that leads
  somewhere rather than ending, is a sheet stage. Build it as themed content — `ThemedRowGroup`
  and `ThemedRowDivider` — inside a system sheet, and give the stages one chrome so the reader
  never sees two presentations for one decision.

Neither is a licence to reach for `.confirmationDialog` at a call site; the checker is unchanged.

### Extension rule

**Extend `ThemedDialog` as soon as an application-owned dialog needs something it cannot
represent.** Do not introduce a one-off overlay, a locally styled sheet, `UIAlertController`,
SwiftUI `.alert`, or `.confirmationDialog` as a workaround. A new checkbox, icon treatment,
validation state, secure field, multi-field form, or custom action layout belongs in the
shared primitive first, then becomes available to every call site.

The exception is UI whose presentation and trust boundary belong to iOS. Notification,
camera, microphone and tracking permission prompts, the share sheet, document picker, and
similar operating-system surfaces remain native and are not imitated or themed.

### Current contract

The shared primitive owns:

- compact themed alerts, and bottom-anchored confirmations in the system's own chrome;
- standard, cancel, destructive and disabled actions;
- optional text input and keyboard focus;
- resolved semantic colour, light/dark mode, border weight, radii and panel glow, for alerts;
- modal hit testing and VoiceOver announcement;
- Dynamic Type layout and Reduce Motion transitions, for alerts;
- outside-tap dismissal for confirmations, while alerts require an explicit action.

Remote themes own material — colours, radii, border weight and glow — while
`MobileDesign.Spacing` owns stable phone layout insets. Dialog actions always keep that outer
inset from the panel edge, and filled actions use the active theme's control radius. Do not put
spacing into an individual dialog or make it vary by decorative theme.

**An item-backed confirmation captures its item.** An alert still runs its handler before the
presentation binding is cleared, so a handler may read the selected session on the way out. The
system action sheet does not work that way: it clears `isPresented` as part of dismissing and
calls the button's handler afterwards, so a handler that reads the `@State` the binding nils out
reads nothing and does its work on nobody. Build the actions from the item and let the closures
capture it, the way `SessionDashboard.surfaceChangeActions(for:)` does. Three call sites depended
on the old ordering and all three would have silently stopped working.

## Settings surfaces

A `List` or `Form` gets its *rows* from UIKit, not from the theme. Hiding the scroll background
and painting the theme's ground behind it leaves every grouped row on
`secondarySystemGroupedBackground` with `separator` hairlines between them, which is a slab of
system grey standing on an authored palette. That is what shipped on Terminal Keys and its four
editors, Notifications, Diagnostics, Mac appearance, Ask for input and the issue report.

`Sources/ThreadingMobile/MobileSettingsChrome.swift` owns the answer, and only that file may use
`scrollContentBackground`, `listRowBackground` or `listRowSeparatorTint`:

- **`ThemedSettingsSection`** replaces `Section` inside a `List` or `Form`. It *is* a `Section`,
  so inset-grouped geometry, swipe to delete and `EditButton` reordering keep working; only the
  colours stop coming from UIKit. A bare `Section` inside a list fails the checker, because it is
  the construct that silently reintroduces the grey plate. `Section` inside a `Menu` or `Picker`
  is untouched — that is system menu chrome with no plate to paint.
- **`themedSettingsPage`** is the page around it: the theme's ground, and a navigation bar in the
  surface role. Four of the five key-bar screens had a bare bar over a themed body because this
  was applied by hand, one screen at a time.
- **`themedSettingsRow`** is the plate for a plain list whose rows sit on the page rather than in
  a grouped card.
- **`ThemedRowGroup`** is the same plate for a screen assembled from a plain `ScrollView`: rows
  on one inset-grouped card, told apart by **`ThemedRowDivider`**, a hairline in the theme's
  `divider` role inset to where the row's text begins. The settings pages and the session
  dashboard both stand on it; a row inside paints no plate of its own, because the group paints
  `panel` exactly once and a theme's panel may be translucent. A screen picks one: a `List` when
  its rows are editable or reordered, the group when the form is a small fixed shape or the
  screen already builds its rows lazily.

## Placeholder states

`MobileLoadingPlaceholder` is the spinner-and-sentence a surface shows while it has nothing yet:
connecting to a session, waking a Mac, finding attachments, opening an attachment or an
extension panel, loading a review. Use it rather than assembling the three lines again.

The reason it exists is that `background` paints the bounds of the content it is attached to.
A screen that says `.background(theme.ground)` around a state sized to its own words gets the
theme painted as a plate exactly as wide as the sentence, standing on the navigation container's
own system background — a grey box in the middle of an unthemed black screen. That shipped on the
session screen as "Resuming on your Mac…", and the same three lines had been copied to the
attachments, attachment preview and extension-panel screens. The component fills the space it is
offered, paints the ground itself, and tints the spinner with the theme's accent.

`ContentUnavailableView` needs none of this and is still the right answer for a failure or empty
state: it already expands to the space it is given, which is why the failure state beside each of
those placeholders was themed the whole time.

The three states of the session screen are in the iOS evidence catalogue, held still by a debug
fixture because a real Mac passes through them in a moment:

```bash
THREADING_MOBILE_DEMO=session-opening-connecting
THREADING_MOBILE_DEMO=session-opening-resuming
THREADING_MOBILE_DEMO=session-opening-failed
scripts/ui-evidence-ios.sh --only session-opening
```

The two spinner states are captured in `display` mode: a spinner never reaches the pixel-stable
frame the app-owned capture waits for.

## Crossing a presentation boundary

A sheet is its own hosting scene and inherits neither `remoteTheme` nor the presentation values
read from it. `mobileTheme(_:)` in `MobileThemeEnvironment.swift` states all five together —
palette, colour scheme, accent tint, toggle style and label colour — and the checker rejects a
bare `environment(\.remoteTheme,)` outside that file.

Both halves of this were live. The issue report is reached only by a sheet from the root and had
no re-statement at all, so it drew the built-in fallback palette on a phone whose Mac was running
Cyberpunk. The sheets that did re-state re-stated the *palette only*, which left each one with a
system-tinted switch and a blue accent inside an otherwise themed screen.

## The keyboard

Light or dark is the whole of what iOS lets a theme say about the system keyboard. There is no
API for tinting keycaps, and a system-wide keyboard extension is a different product with its own
install and trust story, so `UIKeyboardAppearance` is the entire seam.

`MobileKeyboardAppearance.over(_:)` answers it from sRGB relative luminance, sharing one crossover
with the ink chosen over the accent. The terminal reads it from the session's own terminal
background; every other surface gets it from `preferredColorScheme`, which is why that value
travels with the palette in `mobileTheme(_:)` rather than being left behind at a sheet.

What *is* ours is the strip above the keyboard. `TerminalKeyBar` is fully themed, and
`RemoteTerminalView.dropBuiltInKeyboardAccessory()` removes SwiftTerm's own esc/ctrl/tab/arrow
accessory so the two do not stack. A fully theme-coloured pad remains possible — SwiftTerm
exposes `inputView` as a settable seam and already ships a symbol/function-key pad — but a
replacement alphanumeric keyboard would cost the user's own layout, autocorrect, dictation and
emoji, so any such pad belongs beside the system keyboard, not in place of it.

## Visual review

Debug builds expose deterministic launch modes:

```bash
THREADING_MOBILE_DEMO=themed-dialog-alert
THREADING_MOBILE_DEMO=themed-dialog-confirmation
THREADING_MOBILE_DEMO=share-chat-roles
THREADING_MOBILE_DEMO=share-chat-blocked
THREADING_MOBILE_DEMO=share-chat-link
THREADING_MOBILE_DEMO=shared-link
```

The confirmation fixture shows the surface switch, because that is what a confirmation still is
here. The three `share-chat-*` fixtures are the two stages of the Share Chat sheet plus the
chooser a dormant chat gets; `share-chat-link` reaches the link by choosing a grant rather than
by being handed one, so what it photographs is the transition. `shared-link` is the link stage
on its own, which is what a project terminal's share still presents.

The confirmation fixture is captured in `display` mode. The app-owned capture renders the key
window, and the system's action sheet is not in it; that is the same reason the keyboard states
are captured that way. On iOS 26 the sheet also anchors to the view that presented it rather than
to the bottom edge, and it draws no Cancel button — a `.cancel` action is dropped in that
presentation exactly as it is in an iPad popover, and tapping outside is the cancel. Both are the
system's decisions, verified by giving the fixture a fourth standard action: the fourth one drew,
the cancel did not.

The settings surfaces are in the iOS evidence catalogue instead, including the three editor
destinations that are reachable only from inside the key-bar editor and were therefore the last
to keep UIKit's grey plate:

```bash
scripts/ui-evidence-ios.sh --only settings-terminal-key-catalog-custom-dark,\
settings-terminal-key-snippet-custom-dark,settings-terminal-key-edit-custom-dark
```

Use these modes as the initial fixtures for the future `ThreadingMobileUITests` screenshot target.
When the primitive gains a materially different control or layout state, add a fixture at the
same time. Review at least a compact iPhone, a large iPhone, an accessibility Dynamic Type size,
and a deliberately different remote theme.
