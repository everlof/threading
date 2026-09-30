# Physical iPhone pane

Threading has one physical-iPhone pane per session. It lives in the ordinary display panel and
shares the design-layer device framebuffer with the Simulator, but it does not share the
Simulator's lease or input authority. The pane provides a bounded screenshot preview and, after
an explicit grant for the exact selected phone, user-driven taps and drags through CoreDevice's
DisplayService-authenticated Universal HID route. This note is the shipping contract for that
first control slice. A persistent low-latency media stream, keyboard and hardware-button input,
and agent input remain in
[`../feature-drafts/physical-iphone-pane.md`](../feature-drafts/physical-iphone-pane.md).

## Identity and discovery

`xcrun devicectl list devices --json-output` is the authoritative device catalogue. The decoder
admits only paired, currently reachable iOS phones. CoreDevice keeps historical pairings, so a
record whose tunnel is `unavailable` is not a selectable device; a reachable Wi-Fi phone may still
report a `disconnected` tunnel and remains selectable.

Two identities are kept deliberately separate:

- CoreDevice's UUID-shaped identifier describes its catalogue record.
- The hardware UDID targets the phone in both Apple and libimobiledevice commands and is the only
  identity persisted by the pane.

Never resolve a command target by the device's mutable display name. Device records and command
outputs are bounded before decoding. USB sorts ahead of Wi-Fi, followed by the person's device
name only for presentation order.

## Capture lifetime

The pixel path has two explicit backends. iOS 27 and newer use pymobiledevice3's DVT screenshot
API over the rootless native tunnel; Apple's old `screenshotr` service is no longer advertised
there, so Threading does not attempt the legacy helper on those releases. Older phones prefer
`idevicescreenshot` and can fall back to DVT. A successful choice is cached per hardware UDID so
the one-frame-per-second loop does not repeatedly launch a known-incompatible helper. Cached
choices are revalidated against the current OS release so an upgrade cannot retain `screenshotr`.
Missing tooling or unavailable developer services is an in-pane failure with a retry route, not a
launch failure and not a reason to fall back to a different phone.

Before the first screenshot for one hardware UDID, Apple `devicectl device info ddiServices
--auto-mount-ddis` checks and, if necessary, mounts the current developer disk image. That result is
cached only for the control object's lifetime. A screenshot failure evicts it so an explicit retry
prepares services again after a disconnect instead of trusting stale state.

Discovery and screenshot commands run through a bounded child-process group off the main actor.
Each operation has a deadline and output cap. Screenshot files live in a mode-`0700` temporary
directory, are capped at 32 MiB and must carry a PNG signature. ImageIO decodes the full frame on a
worker before the main actor wraps its immutable `CGImage` for AppKit.

`RealDevicePaneViewController.setPresented(_:)` is the demand boundary:

- no discovery or capture starts for a restored or background-session tab;
- presenting discovers the selected device and starts at most one screenshot loop;
- the fallback requests no more than one frame per second and retains only its latest local frame;
- hiding, switching away, closing or terminating cancels discovery, the capture loop and its
  current child process;
- selecting a hardware identity while hidden only records that preference.

A hidden controller may retain its last `NSImage` for immediate local redisplay. That is not a
capture lease and performs no device work.

The toolbar's Device Logs button carries the selected hardware UDID to the window-owned tab
router. That router moves the session's one bundled Device Logs plugin into the bottom drawer and
retargets it, so the preview stays visible beside the log stream and no second reader is created.

## Managed tooling and runtime data

Threading does not bundle `pymobiledevice3` or its GPL runtime in the application.
**Settings → Advanced → iPhone Tooling**
offers an explicit **Install Latest** action which creates a private Python environment below
Threading's Application Support directory. Each candidate is version-checked before an atomic
`current` symlink switch; a failed update leaves the prior version active, and inactive versions
are removed on a later ordinary launch. Nothing is downloaded merely because Settings or a device
pane opened.

Resolution considers the developer override `THREADING_PHYSICAL_DEVICE_PROBE_PATH` first, then the
Threading-managed executable, then fixed Homebrew/local/system paths, and requires version 11.13.1
or newer. The executable is resolved when a compatibility check begins rather than when the pane
is constructed, so installing it and pressing the pane's retry control needs no app restart. The
same managed executable owns the modern screenshot fallback. Missing or older tooling produces
**Control check unavailable**; on iOS 27 it also leaves the preview unavailable until the managed
tool is installed, while older phones can continue through `idevicescreenshot`.

Every device command gives pymobiledevice3 a mode-`0700`, Threading-owned runtime directory and
cache. A narrow `sitecustomize` adapter points pymobiledevice3's data-folder variable at that cache
without replacing `HOME`, touching an existing `~/.pymobiledevice3`, or inheriting user Python
packages. This matters for iOS 27: automatic preparation may download and cache the matching
Cryptex1 developer image, and a legacy directory left root-owned by an old sudo invocation must
not break the managed tool.

## Capability and preparation

For the exact selected hardware UDID, the bounded worker sets `PYMOBILEDEVICE3_UDID`, removes
inherited tunnel-selection overrides and uses the rootless macOS `--native` tunnel. It performs a
linear, fail-closed probe:

1. DisplayService `get-media-support-info` must return a nonzero `supportedFeatures` value. A zero
   value is **Media streaming unavailable** even when both service names exist.
2. Universal HID `list-connected` must contain the real main-touchscreen service id `257`.

Do not infer failure from the absence of legacy raw RSD service names. iOS 27 can execute these
concrete operations without advertising the names an older probe expected; that false inference
was the original reason control was incorrectly reported unavailable. Probe responses use the
ordinary 64-KiB command bound and are not retained. No response, device name or UDID enters UI copy
or diagnostics. Every command has a deadline and shares the pane's cancellable serial worker.
Hiding, switching, refreshing or terminating the pane cancels the probe, and only the one selected
visible device is examined.

If the direct probe fails, the control button offers **Prepare iPhone Control**. A Wi-Fi-only phone
fails preparation immediately with a cable/unlock instruction. Over USB, preparation runs
`mounter auto-mount --native` for the exact UDID with a five-minute deadline. That route uses the
ordinary personalized developer image on supported older releases and the matching Cryptex1 image
on iOS 27. It is deliberate user work because it can download a developer image and install it on
the phone; Threading never starts it merely because the pane appeared. After success the pane
re-probes the concrete operations. Already-prepared phones may still be controlled wirelessly.

## User input and consent

`SimulatorScreenView` is the design-system framebuffer component, not Simulator authority. The
physical pane leaves it unavailable until all of these are true:

- the exact selected hardware UDID is still visible and selected;
- the concrete DisplayService and main-touchscreen probes succeeded; and
- the user approved the warning sheet from that pane.

The grant lives only in that controller, is keyed by hardware UDID and is not persisted. Hiding
the pane, switching phones, closing it or ending the session revokes the grant and cancels any
in-flight input process. A denial is remembered so screen clicks cannot repeatedly pressure the
user; only pressing **Retry iPhone Control** clears it and presents the sheet again. Pairing, Mac
trust, developer mode, a healthy screenshot and a successful probe are never consent.

The first slice supports clicks and drags only. The framebuffer converts the fitted, y-up AppKit
point into the phone's normalized y-down image space. The device adapter validates finite values
inside `0...1`, rounds them into Universal HID's `0...65535` coordinate space and invokes the
`tap` or bounded 18-step `drag` command. pymobiledevice3 opens the required DisplayService media
session for HID authentication. Commands are serialized, only one input operation can be in flight,
and every operation rechecks the visible pane, exact device, grant and capability before sending.

This command-per-gesture transport proves real control but does not claim interactive streaming
latency. Keyboard input, hardware buttons, passcode or unlock automation, lock-screen interaction
and agent-driven physical-device input are absent. The latter requires its own separately reviewed
authority surface; a user grant to click in the pane must never become an agent grant implicitly.

## Persistence and host ownership

The tab kind and optional hardware UDID use panel document format 4. Restore is lazy: it constructs
the controller and selected identity without consulting hardware. The pane is a singleton per
session, matching the device-ownership rule of the Simulator pane.

The body is deliberately host-only. Threading keeps exact device identity, trust/developer-service
truth, capture demand, input consent, normalized HID routing and transport teardown. Extensions may customize the
existing protected display-pane chrome, but cannot replace this authority surface or provide a
second capture/control route. The logs shortcut is also host-owned placement and identity routing;
the Device Logs plugin continues to own source discovery, streaming, filtering and history.

The agent description distinguishes user control from agent authority. There is no
physical-device agent input tool in this slice, so an agent cannot mistake presence of the tab or
the user's visible grant for authority to operate the phone.

## Verification

`PhysicalDeviceCatalogTests` owns filtering, ordering, identity validation and catalogue bounds.
`PhysicalDeviceControlTests` owns exact-UDID screenshot backend selection and caching, direct
operation probes, tool-version refusal, media/touchscreen gates, preparation, coordinate
validation and exact tap/drag command mapping. `Pymobiledevice3InstallationTests` owns the managed
runtime cache boundary. `RealDevicePaneTests` owns lazy restore, singleton persistence, failure
containment, preparation, consent, real input dispatch, revocation and hidden-pane inactivity.
The `physical-iphone-pane` UI-evidence entry captures both system appearances in the real
conversation/window/display-panel shell.

The persistent stream slice must retain the same identity and grant boundary, then add a measured
lease lifecycle, latest-frame replacement, hard frame/byte budget and rotation coverage before it
can replace the screenshot fallback.
