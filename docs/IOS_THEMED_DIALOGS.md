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

### A confirmation is anchored to the control it came from

The system draws the sheet's tail at the view `themedConfirmationDialog` decorates, so *where the
modifier is attached* is the placement. The terminal key bar's paperclip shipped with the chooser
held on `TerminalRemoteView`'s root stack, and the tail pointed at the middle of the terminal:
the same "floats too much" the themed card was replaced to fix, arrived at from the other side.
It is held on the attachment key itself now, and the sheet stands on the key bar with its tail on
the paperclip.

Attaching it to the control does not mean presenting the *result* from there. A control on the
bar can go away with the sheet — the paperclip's whole row is conditional — so Photos and Files
still present from the owner's stable hierarchy once the chooser has dismissed.

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
- an opaque `floating_surface` plate over live content (flattened over the theme ground if an
  authored role carries alpha), never the ordinary `panel` role that System defines as a faint
  wash, for alerts;
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

## Anchored application popovers

`mobileThemedPopover` is the boundary for an anchored transient surface whose chrome belongs to
Threading. SwiftUI applies `presentationBackground` to a compact popover on iOS 26 but ignores
`presentationCornerRadius`, leaving UIKit's large system mask around an authored theme. The
shared presenter therefore uses the public `UIPopoverPresentationController` background-view
seam and draws the body and arrow from `RemoteThemePalette`: floating surface, border, border
weight and panel radius. UIKit still owns anchor placement, edge adaptation and outside-tap
dismissal.

The content supplies no second plate or outer border. It receives the complete theme through
`mobileTheme(_:)`, just like a sheet crossing the hosting boundary below. Use this primitive for
application-owned popovers only; action sheets, document pickers, permission prompts and other
iOS trust surfaces keep their native chrome.

The background view must be born with its style, not styled after the fact. UIKit instantiates
`popoverBackgroundViewClass` itself during `present`, and the first hook the presenter gets to
the created instance is the presentation's completion — after the pop-in has run. Styling only
there shipped as a visible defect: the grid arrived over a clear body and the theme's box faded
in behind content that was already standing. The presenter therefore stages
`MobileThemedPopoverBackgroundView.pendingStyle` immediately before `present`, the initializer
adopts it, and the completion clears the staging and reapplies the current style as the ordinary
update path.

UIKit also remains the sole owner of the popover layer's shadow. Do not assign a `shadowPath`
from `layoutSubviews`: the anchor moves with the composer while its keyboard dismisses, and that
assignment starts a second implicit path animation that visibly trails the body. The background
view draws only the themed fill, border and arrow.

**A chooser keeps the keyboard when it has the room.** UIKit fits a popover into the container
inside the safe area and its own ten-point layout margins, and *shrinks* one that asks for more,
so the hosted content is laid out short and clipped. The draft's three choosers used to end the
prompt's focus before presenting, unconditionally, for the height the model-by-effort matrix
might need — and picking a model became a two-keyboard-animation detour on a phone that had the
room. The presenter now measures: `MobileThemedPopoverRoom` compares the content's fitted height
with the room on the arrow's side of the anchor, between the navigation bar's bottom (a popover
over the bar would hide Back behind a modal surface) and the bottom safe area, and calls the
host's `makeRoom` only when the answer is no. The draft ends focus there and nowhere else. The
arrow is the only chrome counted between the body and the anchor; UIKit's ten-point layout
margin is charged where UIKit charges it, at the safe-area edge, and charging it again at the
bar made a full five-row page of the picker one point too tall for a phone with nine to spare.
Read off the simulator: the matrix stands above the keyboard-riding composer on an iPhone 17
Pro, its five-row page with the pager at 360 points under a 116-point bar with the action row
at 497; an iPhone SE fits three rows and asks for the keyboard's room at five. The presentation
itself is unchanged in the no-room case — the popover is presented while the keyboard is still
leaving and UIKit lays it out again as the anchor rides down, exactly the order the
unconditional drop always used.

The new-session model-and-effort, speed and permission choosers are the first consumers. Keeping
all three on this boundary matters for square themes in particular: SwiftUI's compact-popover
mask otherwise rounds away their authored corners. This is a correction to existing host-only
surfaces, not a new extension component: Threading continues to own catalogue validity,
inherited/default resolution and the choices submitted to the runtime. Themes own presentation
material, while extensions do not replace those operational decision surfaces.

**A popover follows its content's height.** UIKit sizes a popover from `preferredContentSize`
once, at presentation, so content whose height follows a choice made *inside* it was either
clipped under the old height or left standing over empty room. The presenter measures the root
view again whenever it is replaced and hands UIKit the difference, which UIKit animates itself.

**The anchor is a view, not a view controller.** A `UIViewControllerRepresentable` needs
containment in a parent controller, and inside a SwiftUI **toolbar item** there is none to be
had. The presenter began as one, and attaching it to the draft screen's account disc left the
navigation bar standing over an empty screen: the ground, the project sentence and the whole
composer never mounted, and the evidence run for the *existing* `new-session` fixture failed with
a window that contained no editable control at all. The anchor is now a plain `UIView` that draws
nothing, takes no touch, and finds its presenting controller through the responder chain — where
UIKit itself looks for the controller a view belongs to. The three composer choosers render
pixel-identically across that change; `new-session-model-effort-picker-custom-dark` is the proof.

**A bar item keeps the plate its neighbours wear.** The draft's disc is a `Button` and the chat's
is a `Menu`, and the two bars must show one control for one login, so the draft's does *not* take
`.buttonStyle(.plain)` — that dropped the bar item's own plate and made the draft the one screen
whose trailing control was a bare circle.

**The draft's identity picker is the fourth consumer, and the first to hang from the bar.**
`MobileIdentityPicker` replaced a system `Menu` on the navigation bar's account disc that listed
the runtime and the login as one scrolling column: five identical sparkles for five runtimes,
the chosen one's glyph replaced by a checkmark, and every login's usage folded into its title
behind three spaces — "Default 5h 38% · 7d 36% · 7d Fable 33%" wrapped to three lines — with
"Loading usage…" and "Usage unavailable" as wider names rather than states. It closed on the
first choice, so "Codex on the work login" was two openings. The picker is the two decisions as
the two things they are: the runtimes as a strip of their own marks at one width each (a sixth
starts a second row, padded so no tile widens), and the logins as rows on one `ThemedRowGroup`
plate, each led by the toolbar's own disc — the login's emoji or initial, ringed by that login's
reading — so the picker is a row of the discs the bar might wear, and the words under each name
are the exact reading those rings stand for. Tapping a runtime keeps the popover open and the
rows beneath follow it, which is what the re-measure above exists for; tapping a login commits
and closes. The chosen tile takes the accent as a *ring* on its disc rather than a fill: a brand
mark keeps its own colour by design, and Claude's coral on an accent-filled disc is two brands
arguing. It hangs *down* from the bar, so the keyboard bounds the far edge of its room rather than the
near one and a phone with the height keeps it up, which the composer's own choosers cannot
promise. It still asks `makeRoom` first: the login list caps and scrolls, and below that cap a
small phone drops the keyboard rather than letting UIKit shrink the panel and clip a login away.
Measured on an iPhone SE, at the cardinality a real Mac has rather than the demo's two runtimes:
five agents and two logins stand between 71 and 339 points, so the keyboard is never asked for.

**Each group is one scrub surface, not a stack of buttons.** Buttons were the first shape and the
owner reported both ways they were wrong: *the hit area of the providers is only on the items it
feels like*, and *I can't tap and drag to switch, that feels like a natural thing to do.* A button
answers only the finger that lands and lifts inside its own drawn frame, so the group's margin and
the gaps between plates swallowed touches that plainly pointed at a runtime, and a moving finger
was answered by nothing at all. `MobileIdentityPickerHitTest` divides each surface by arithmetic
the way `MobileModelEffortPicker` divides its matrix: every point inside a group belongs to exactly
one item, including the padding around what is drawn, so the touch target is the whole cell while
the plate stays inset. **Each group is `mobileScrubSurface`, the one modifier the matrix stands
on too, and it is one `DragGesture` with no minimum distance** — not a tap composed with a drag.
Begun on touch-down, the drag lights and ticks the item under the finger before it moves, follows
every sample with a selection tick at each crossing, and commits on the lift with the matrix's
impact; a tap is the same gesture with no travel between the two. The split that looked cleaner
shipped twice broken: a `SpatialTapGesture` given first refusal over the drag held the drag back
across the runtime strip on the phone, and the login rows still carried a tap recognizer of their
own for their scrolling shape, which as the child gesture took every stationary touch off the
group and dropped it — on the simulator, a tap on a login left the popover open while a drag
across the same rows committed and closed it. So "the zero-distance drag made taps disappear",
the reading that led to the tap-first split, had named the wrong recognizer: it was the rows'
own. Two recognizers on one surface are two arbitrations, and the surface has one question —
which item is under the finger — so the modifier owns the whole surface and nothing inside it
carries a gesture of its own. `MobileScrubTracker` is the rule beneath it, pure and pinned:
one tick per crossing, nothing while the finger rests, a lift outside the surface takes the last
item crossed rather than snapping to the edge the finger left, and a touch that never found an
item commits nothing. While a finger is down the scrubbed item is the one that reads as chosen,
and the committed login keeps its checkmark throughout, so the panel says both what is current
and what lifting now would take. Logins past what the cap can show scroll instead, and scroll
only — they stay off the modifier: a `DragGesture` inside a scroll view keeps the scroll from
starting, and a surface that sometimes scrolls and sometimes scrubs would answer one drag two
ways.

## Settings surfaces

**A Settings row that leads to another Settings page stays in the same navigation stack.** The
top-level Settings surface is already the user's modal detour from the app; opening a second sheet
inside it makes a destination look temporary, starts it at a partial-height detent, and replaces
the established Back path with another Done button. Fixed Settings destinations use
`SettingsNavigationRow` and supply page content without their own `NavigationStack`. Sheets inside
those destinations remain appropriate for temporary system workflows such as sharing a report.

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

## Prominent application actions

Feature code never applies SwiftUI's `.buttonStyle(.borderedProminent)` directly. That system
style chooses its foreground independently of the Mac-supplied accent: a white or bright accent
can therefore become a pale fill carrying pale text and a pale symbol. The Usage dashboard's
banked-reset action shipped in exactly that state.

Use `MobileThemedActionButtonStyle` for application-owned primary and secondary actions. It owns
the accent-derived foreground, authored control radius, pressed response and disabled opacity as
one construction:

```swift
Button("Apply") { apply() }
    .buttonStyle(MobileThemedActionButtonStyle(
        kind: .primary,
        theme: theme
    ))
```

The default width fills its container. Pass `width: .intrinsic` where a compact action belongs in
a horizontal row or extension-provided stack. Do not repair a raw prominent button by adding a
local foreground modifier: that still leaves radius, pressed and disabled chrome split between
the system style and feature code. `scripts/check_mobile_theme_boundaries.py` rejects the raw
style before compilation, including when its argument is split across lines.

## System menus stay bounded

An iOS `Menu` is system chrome, but it is not a general scroll container. On iOS 26 an upward
drag in the dashboard's over-height **…** menu dismissed the menu and continued into the session
row underneath, opening a chat instead of revealing the last menu action. The gesture is inside
UIKit's private menu presentation, so there is no app-owned recognizer to repair.

The dashboard menu therefore renders a fixed directory of at most six root destinations:
Organize, Sessions, Appearance, Usage, Settings and Macs. Organization and session filters live
in short, fixed-cardinality submenus; Mac pairing and forgetting share another. Appearance opens
the existing `MacAppearanceSettingsView`, whose `List` virtualizes the Mac-supplied theme
catalogue instead of putting an externally sized catalogue in another system menu. At the
all-capabilities stress point the root remains six rows, each fixed submenu remains at five or
fewer, and no scroll gesture is required.

`marketing-main-menu` in the iOS evidence catalogue opens the shipping menu against the complete
owner fixture and waits for all six destinations. Do not weaken the fixture by removing a
capability to make a screenshot fit; new dashboard actions join the destination that owns them,
or earn a new bounded surface and an explicit revision of this contract.

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

The draft attachment Quick View is a full-screen `NavigationStack`, not a system Quick Look sheet:
images reuse the themed zoom surface and movies use the native player against a device-local staged
file. Because the cover creates a separate hosting scene, its caller reapplies the complete mobile
theme; the navigation bar, close action, ground and player surround must not fall back to system
chrome while the composer underneath uses a Mac-supplied palette.

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

**A context-menu preview is the same boundary.** The `preview:` of `.contextMenu` is hosted by
UIKit in a hosting controller of its own, and the environment the row was drawn in does not reach
the views inside it. The dashboard's lifted row (`MobileLiftedSessionRow`) painted its plate in
the list's palette — `theme` is read where the row *builds* the preview — while the title, the
caption's glyphs and the age each read `\.remoteTheme` afresh inside the preview and were
answered with the fallback. On Swiss Minimalist that was the fallback's near-white label on the
theme's white panel: a lifted row whose name could not be read, reported from a screenshot. The
preview restates the theme through `mobileTheme(_:)` like any sheet, and
`MobileLiftedSessionRowTests` reads the title's ink off pixels with no environment above it.

The preview's *shape* is a second thing UIKit decides on its own. The platter clips a preview to
its own large corner radius whatever the content draws, so a square-cornered theme lifted its
two-point-bordered row as a borderless pill. `contentShape(.contextMenuPreview, _:)` is the one
content shape the platter reads; the lifted row states the theme's panel radius there, and the
row in the list states the same shape so the lift UIKit snapshots before the preview arrives
already has the theme's corners. A radius of exactly zero is read as no shape at all and gets
the pill back — Editorial's five points came through, Swiss Minimalist's zero did not — so a
square theme asks for one point, which is square to the eye and is the smallest radius the
platter honours.

## The keyboard

Light or dark is the whole of what iOS lets a theme say about the system keyboard. There is no
API for tinting keycaps, and a system-wide keyboard extension is a different product with its own
install and trust story, so `UIKeyboardAppearance` is the entire seam.

`MobileKeyboardAppearance.over(_:)` answers it from sRGB relative luminance, sharing one crossover
with the ink chosen over the accent. The terminal reads it from the session's own terminal
background; ordinary application surfaces get it from `preferredColorScheme`, which is why that
value travels with the palette in `mobileTheme(_:)` rather than being left behind at a sheet.
The new-session editor is the narrow exception: it takes focus on the first frame of the
navigation push, when the system's `.default` appearance can briefly resolve against the
transition scene and flash before settling on the destination. It explicitly assigns the same
light/dark answer from the resolved colour scheme before becoming first responder. This keeps the
keyboard in the push without delaying focus or changing the composer's entrance choreography.

What *is* ours is the strip above the keyboard. `TerminalKeyBar` is fully themed, and each
device-local key chooses its top or bottom row while the host keeps the action controls fixed.
Apple Color Emoji outgrows the text face's nominal line box, so a compact cap preserves a
34-point ink well rather than clipping user-authored emoji. A snippet that submits travels through
the host's atomic terminal-submit path: its text and Return are separate PTY writes, because agent
TUIs treat a single combined chunk as pasted content and leave it unsent. A non-submitting snippet
remains raw terminal input. Finally,
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
