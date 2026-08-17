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

- compact alerts and bottom-anchored confirmations;
- standard, cancel, destructive and disabled actions;
- optional text input and keyboard focus;
- resolved semantic colour, light/dark mode, border weight, radii and panel glow;
- modal hit testing and VoiceOver announcement;
- Dynamic Type layout and Reduce Motion transitions;
- outside-tap dismissal for confirmations, while alerts require an explicit action.

Remote themes own material — colours, radii, border weight and glow — while
`MobileDesign.Spacing` owns stable phone layout insets. Dialog actions always keep that outer
inset from the panel edge, and filled actions use the active theme's control radius. Do not put
spacing into an individual dialog or make it vary by decorative theme.

Action handlers run before the presentation binding is cleared. This preserves item-backed
dialogs whose handler needs to read the selected session before dismissal.

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

`ThemedSettingsGroup` in `MobileSettingsView` remains the vocabulary for a screen assembled from
a plain `ScrollView`. A screen picks one: a `List` when its rows are editable or externally
sized, the group when the form is a small fixed shape.

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
```

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
