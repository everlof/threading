# iOS themed dialogs

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

## Extension rule

**Extend `ThemedDialog` as soon as an application-owned dialog needs something it cannot
represent.** Do not introduce a one-off overlay, a locally styled sheet, `UIAlertController`,
SwiftUI `.alert`, or `.confirmationDialog` as a workaround. A new checkbox, icon treatment,
validation state, secure field, multi-field form, or custom action layout belongs in the
shared primitive first, then becomes available to every call site.

The exception is UI whose presentation and trust boundary belong to iOS. Notification,
camera, microphone and tracking permission prompts, the share sheet, document picker, and
similar operating-system surfaces remain native and are not imitated or themed.

## Current contract

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

## Visual review

Debug builds expose deterministic launch modes:

```bash
THREADING_MOBILE_DEMO=themed-dialog-alert
THREADING_MOBILE_DEMO=themed-dialog-confirmation
```

Use these modes as the initial fixtures for the future `ThreadingMobileUITests` screenshot target.
When the primitive gains a materially different control or layout state, add a fixture at the
same time. Review at least a compact iPhone, a large iPhone, an accessibility Dynamic Type size,
and a deliberately different remote theme.
