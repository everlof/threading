# Android devices in the Simulator workspace

An Android emulator (an AVD) or a USB Android device can be a member of the session's Simulator
workspace, beside iOS Simulators, so one app can be compared on both platforms in one pane. It
uses the same pane chrome, consent, notes, recording, presenter window and `simulator_*` agent
tools as an iOS member. Nothing about an iOS member changed.

Part of the [CLAUDE.md](../../CLAUDE.md) index. Read [`simulator-pane.md`](simulator-pane.md)
first: everything there about leases, consent, stream demand, the workspace and the agent route
holds for Android members too. This file covers only what differs.

## One identity, routed per member

`SimulatorDeviceID` has three forms and no parallel model:

| Form | Platform | Why this is the identity |
|---|---|---|
| `<UUID>` | iOS Simulator | CoreSimulator's UDID, stored bare so every pre-Android document decodes unchanged |
| `android-avd:<AVD id>` | emulator | stable across boots, like a UDID; the adb serial (`emulator-5554`) is not |
| `android-usb:<adb serial>` | USB device | the serial is the device |

The validating initializer still refuses anything else. Android names are limited to
`[A-Za-z0-9._:-]` and 128 characters, so an identity can never carry shell syntax.
`platform` is derived from the identity rather than stored beside it, so the two cannot disagree.

The pane and workspace keep talking to the existing seams:
- `PlatformRoutingSimulatorControl` sends each call to `SimctlSimulatorControl` or
  `AndroidDeviceControl` by `deviceID.platform`.
- `PlatformRoutingStreamCoordinator` does the same for streams, sending each device to the
  signed iOS helper or `AndroidStreamCoordinator`.

The catalogue asks both planes concurrently, and one plane failing never hides the other. With
no Android SDK, the list is exactly the iOS list it always was. A wedged `adb` cannot blank the
iOS Simulators beside it.

An unnamed preparation keeps its historical meaning: an iOS Simulator. The pane's automatic
choice stays on iOS unless something asks for Android: an agent's `platform: "android"`, or the
**Android Emulator** panel command. Otherwise a running emulator would displace the iPhone a pane
has always opened.

**One automatic-choice rule.** `SimulatorAutomaticChoice` picks a booted device of the requested
platform (a running emulator or a connected phone counts as booted), else the first available
one, never one the workspace already holds. The pane's own preparation, the panel commands and
`simulator_prepare` all ask it, so "Android" means the same device whichever door it came through.

**Side by side without device ids.** Mixing platforms is meant to need no catalogue knowledge:

- The **iOS Simulator** and **Android Emulator** panel commands (`.simulator` / `.androidDevice`)
  share `DisplayPaneController.showSimulatorPlatform(android:for:)`. No tab: a new workspace whose
  lone member's automatic platform is set before its first presentation, so the Android command
  never boots an iPhone on the way. A tab with a member on that platform: select it. Otherwise
  `SimulatorWorkspaceViewController.addAutomaticMember(android:)` reads the catalogue once, picks
  with the shared rule and adopts the result as a new member; a lone member still reaching for a
  device keeps it rather than being rebound. A full workspace without the platform is refused
  synchronously by `panelCommandRefusal`; no other device of that platform is a themed alert.
- `simulator_prepare` takes `beside: true` (add the automatic choice as a new member instead of
  switching a lone one) and `layout` (`row` side by side, `column`, `grid`, `focus`,
  `automatic`). In a workspace of several devices, `platform` alone addresses that platform's
  only member, or adds one when it has none; with neither a device id nor a platform it is still
  refused as ambiguous. The decision is the pure `SimulatorAgentCommandService.preparationRoute`,
  which is where its table is tested. Every preparation result carries `workspace`: the layout
  and each member's `device_id`, `platform`, name and selection, so an agent that built a mixed
  view can see it and address each device.
- A lone member asked for the other platform without `beside` still switches, as it did before
  this existed; `beside` is the explicit way to keep it.

**Persistence.** A workspace with any Android member always writes `simulatorWorkspace` and
requires panel format 6. A build that predates Android therefore refuses the document instead
of restoring the workspace minus its Android member and saving that loss back. iOS-only documents
still write format 3 or 5. The consent grant list, annotation keys, the panel signature and the
agent brief all key on `rawValue`, so they needed no change.

## Lifecycle: `AndroidDeviceControl`

**Locating the SDK.** The SDK is found at `$ANDROID_HOME`, then `$ANDROID_SDK_ROOT`, then
`~/Library/Android/sdk`. Only an absolute, executable `platform-tools/adb` is accepted. Every
command reuses `SimulatorCommandRunner`: one serial queue off main, its own process group, a
deadline, cancellation and bounded output.

**Catalogue.**
- AVDs are read straight from `~/.android/avd/*.ini` and each AVD's `config.ini` (512 AVDs at
  most, 64 KB per file). Reading the files avoids paying a process for `emulator -list-avds`.
- A running emulator is matched to its AVD through its discovery file,
  `~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini`. In that file **`avd.id` is the
  identifier and `avd.name` is the display name**; reading `avd.name` first matched nothing.
- An emulator without a discovery file (launched with no gRPC) is asked `adb emu avd id`.
- USB devices come from `adb devices -l`, 64 at most. An `unauthorized` device is listed but
  unavailable, with "Allow USB debugging on the device". An AVD whose system image is missing is
  unavailable too.

**Leases.** The same rule as CoreSimulator applies:
- A device found running is `.user` and is never stopped.
- An emulator Threading boots is `.threading`. Release stops it with `adb emu kill`, then
  terminates its process group.
- A USB device is never rebooted or shut down.

**Booting.** Threading starts an emulator with:

```text
-no-window -no-audio -no-boot-anim -read-only -grpc <free port> -grpc-use-jwt -grpc-allowlist <ours>
```

- `-read-only` is the rule that matters: Threading never writes to somebody's AVD (no snapshot
  save) and may run beside another instance of it.
- Boot waits for the discovery record, then for `sys.boot_completed=1`, within 180 s. A failed
  boot reports the tail of the emulator's private log.

**Install and launch.**
- The control runs `adb install -r -t`, resolves the launcher activity with
  `cmd package resolve-activity --brief`, then runs `am start -W -S -n`.
- `bundle_identifier` is the applicationId. Each launch argument arrives as a string extra
  `threading.argument.<index>`.
- `adb shell` joins its arguments and hands them to the device's `sh`, so every caller-supplied
  value is single-quoted (`AndroidShellQuoting`), never interpolated. A test passes `it's; reboot`
  through and checks that it arrived quoted.

**Screenshot and appearance.** `adb exec-out screencap -p` (about 0.75 s) is the fallback poll.
Appearance is `cmd uimode night yes|no`.

## Live transports

### Emulator: its own gRPC control service (default)

The emulator serves `android.emulation.control.EmulatorController` over cleartext HTTP/2 on
loopback. Android Studio's embedded emulator uses the same service. `ThreadingAndroidKit`
speaks it without a third-party runtime:
- an h2c client (`HTTP2ClientConnection`, a sans-I/O state machine driven by `GRPCChannel`
  on one queue);
- a full HPACK decoder (static and dynamic tables, Huffman), pinned against RFC 7541 Appendix C
  and against bytes from an independent encoder;
- gRPC framing;
- hand-encoded protobuf for the dozen messages used.

The protocol is the SDK's `emulator/lib/emulator_controller.proto`.

**Frames.** `streamScreenshot` asks for RGBA8888 with the long side capped at 1,280. It uses
the MMAP transport: the emulator writes pixels into a private file Threading creates (mode 0600,
unlinked on deinit), and the app copies them into a CGImage once, off main. The emulator delivers
upright pictures. Its `Image.format.rotation` says how the device is turned. A change of
rotation or size ends the stream with `.geometryChanged`, and the pane renegotiates once, as it
does for an iOS device.

**Input.**
- Touches are `sendTouch` in natural-orientation display pixels (`AndroidGeometry.nativePixel`
  maps the upright 0…1 point back).
- Moves are coalesced newest-wins behind one ordered operation at a time. gRPC may run unary
  calls concurrently, so ordering is the client's job.
- Buttons and text are `sendKey` with W3C key values (`GoHome`, `GoBack`, `AppSwitch`, `Power`,
  `AudioVolumeUp`).
- Rotation is `setPhysicalModel(ROTATION)`. On emulator 37.1, z = +90° reports `LANDSCAPE` (1)
  and −90° `REVERSE_LANDSCAPE` (3). Android counts rotation anticlockwise, so Rotate Left is +1.
  The first table had the sign inverted, and a device left in landscape was "rotated" into
  upside-down portrait, which a phone refuses. The live suite now taps an element in both
  landscape directions and requires the app to open what is under it.

**Liveness is a unary call, not a PING.** The frame stream is silent whenever the screen is still,
so frame silence proves nothing. The first version pinged every 2 s, and the emulator closed the
connection with GOAWAY `too_many_pings`. gRPC servers enforce a minimum ping interval. The
session now calls `getStatus` every 2 s.

### Authorization

The emulator accepts ES256 JWTs from any key whose public half sits in the `grpc.jwks` directory
it advertises. Each method is admitted per issuer by an allowlist. Threading holds one P-256 key
per process, in memory, and writes only the public half.

- **An emulator Threading starts** gets Threading's own allowlist. The `threading` issuer may call
  exactly the methods `EmulatorControlMethod` lists, and nothing is unprotected.
- **An emulator somebody else started** has the SDK's default allowlist. Its
  `gradle-utp-emulator-control` entry admits `streamScreenshot`, `getScreenshot`, `sendTouch`,
  `sendKey`, `getStatus` and `setPhysicalModel` **only when a method is named in the token's
  `aud`**. Threading issues exactly that audience-scoped token. It neither edits SDK files nor
  borrows the unrestricted `android-studio` issuer. A token whose audience omits a method is
  refused (a live test checks this).
- The key file is a **JWK Set** (`{"keys":[…]}`). A bare JWK is rejected as "does not contain a
  valid jwk" and deleted by the emulator.
- The token has **no `typ` header**. With one, the emulator refuses: "token has type header set,
  but validator not".
- Threading waits up to 3 s for `active.jwk` to list its `kid`. The file is reference-counted per
  emulator and removed when the last session using it stops.

This widens what Threading touches outside its own files: one public key in a directory the
emulator created for exactly that purpose, for as long as a session streams it. It grants no
authority beyond the methods named.

### USB devices, and the emulator fallback: `adb`

A USB device has no gRPC, and an emulator started without `-grpc` has none either. Both stream
through `adb exec-out screenrecord --output-format=h264 --size <capped> -`:
- The Annex-B stream is split into access units (`AnnexBStream`) and fed to the same
  VideoToolbox decoder the iOS helper's H.264 uses.
- `screenrecord` emits a picture only when the screen changes, so a NAL's end is only known at
  the next start code. The reader declares the tail complete after 12 ms of quiet; without that,
  a still screen never showed its last frame.
- Before API 34 there is no `--time-limit 0`, so the recorder is restarted at 170 s. More than six
  early exits a minute is a failure, not a loop.
- Below API 29 the device stays on screenshot fallback.

Input is `adb shell input` (tap, swipe, `motionevent DOWN/MOVE/UP`, `keyevent`, `text`, quoted),
about 65 ms a command on API 36, with moves coalesced as above. Rotation is polled every 2 s from
`dumpsys display` (`mCurrentOrientation`, about 50 ms). A change ends the stream with
`.geometryChanged`, because the recorder's size was fixed for the old orientation. The same poll
is the transport's liveness.

A refused or unreachable gRPC service falls back to this path, and the reason is logged.
`AndroidStreamCoordinator` admits four Android streams app-wide, separately from the iOS helper
budget: one is processes, the other connections, and neither may starve the other.

### Accessibility

Both transports read the window hierarchy with `adb exec-out uiautomator dump /dev/stdout`
(about 2 s on API 36), bounded at 4 MB and 5,000 nodes before anything is built.
`AndroidAccessibilityReader` maps it onto `SimulatorAccessibilityElement`:
- the class becomes an AX role, with the raw class kept in `subrole`;
- `content-desc` or the text becomes the label;
- an EditText's text becomes its value, never a password field's;
- `resource-id` becomes the identifier;
- bounds are in pixels of the current orientation, with the root spanning the display.

Element refs, locators, `simulator_wait` and the inspector therefore work unchanged. The 2 s dump
is the limit on how fast `simulator_wait` can notice a change on Android.

## The pane

- `SimulatorPlatformTraits` holds what a member offers for the platform it holds: its buttons in
  row order, whether Device Logs exists (not yet for Android; logcat is a follow-up), the
  placeholder name and the glyph.
- Every platform's buttons exist once. The ones the held device lacks are hidden, so a member
  whose chooser switches it between platforms re-flows without rebuilding.
- `SimulatorHardwareControlsView` takes any count and balances wrapped rows: nine buttons in an
  eight-wide pane are 5 + 4, not 8 + 1.
- Android shortcuts follow Android Studio: ⌘⌫ Back, ⇧⌘H Home, ⌘O Overview, ⌘P Power, ⌘↑/↓
  volume, ⌘←/→ rotate on an emulator. A hidden button claims no chord.
- Device menus get iOS and Android headers only when both platforms are present.
- The tab is named for what it holds: "iOS Simulator", "Android", or "Simulators", and an
  Android-only tab shows the Android glyph. A member still choosing counts as the device it is
  reaching for (`SimulatorWorkspaceViewController.platformMix`).
- An Android member's own controls and messages say "device" where an iOS member says
  "Simulator" (`SimulatorPlatformTraits.string(_:)`, `SimulatorScreenView.namesDevice`,
  `SimulatorRecoveryView.namesDevice`). Each wording is a whole localized string, not a noun
  spliced into one, so it translates. Workspace-level copy ("Add Device", "four devices") is
  neutral.
- A USB device asks under the physical-device prompt, with copy that says it is a real device and
  that control reaches its other apps.

## Verification

- `scripts/test-packages.sh` runs `ThreadingAndroidKit`: HPACK, HTTP/2 and gRPC framing,
  protobuf golden bytes, JWT verification, and the parsers against fixtures, including a real
  `screenrecord` capture.
- `AndroidDeviceTests` (fast) covers identity, persistence, routing isolation, the control
  through a scripted adb, geometry, buttons and the agent vocabulary.
- The opt-in live lane is `scripts/android_workspace_verify.sh`. It creates and boots a
  dedicated `Threading_Verify_API36` AVD (read-only, headless) and never touches any other AVD or
  running emulator. It runs the package's `LiveEmulatorControlTests` and the app's
  `AndroidLiveIntegrationTests`:
  - the catalogue and an adoption lease;
  - gRPC frames carrying real pixels, touch, keys, text and rotation;
  - a landscape tap in both directions landing on its element;
  - the uiautomator tree;
  - the adb fallback;
  - install and launch when an APK is supplied.

Measured on 2026-10-10 against emulator 37.1.11, API 36, a software GPU (SwiftShader):

| Path | Measurement |
|---|---|
| gRPC `sendTouch` round trip | median 0.5 ms, max 0.9 ms (40 calls) |
| `adb shell input` command | 61–67 ms |
| gRPC frames during a launcher swipe | median gap 35 ms |
| `adb exec-out screencap -p` | 728–757 ms |
| `uiautomator dump` | 2.0–2.2 s |
