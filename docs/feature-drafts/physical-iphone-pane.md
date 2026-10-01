# Physical iPhone pane

**Status:** Active prototype. The preview shipped on 2026-09-28; direct capability probing and the
first user-controlled tap/drag slice were implemented on 2026-09-30. Focused user keyboard input
followed on 2026-10-01. Persistent DisplayService streaming, hardware buttons and agent control
are not implemented.

The durable contract for the shipping preview is in
[`../architecture/physical-iphone-pane.md`](../architecture/physical-iphone-pane.md). This draft
keeps the remaining control work and its gates.

## User contract

Threading should be able to keep a paired physical iPhone beside a conversation in the same right
display panel used by the adopted Simulator. The visible device must be the exact hardware device
the user selected, its capture must stop when the pane is hidden, and a failure must stay in the
pane with a retry path.

Pairing or trusting a Mac is not permission for Threading to operate the phone. User touch is
available only after an exact-device, visible-pane warning grant. Hiding the pane or switching
phones revokes it. That user grant does not authorize an agent to operate the phone.

## Implemented slice

- The New-tab menu has an **iPhone Device** command and each session owns at most one such tab.
- `/usr/bin/xcrun devicectl list devices --json-output` is the authoritative catalogue. Threading
  accepts only currently reachable, paired iOS phones and keeps CoreDevice's UUID separate from
  the hardware UDID used to address the device. USB sorts ahead of Wi-Fi.
- A selected hardware UDID is persisted in panel format 4. Restoration constructs the pane but
  does not discover or capture until the tab is presented.
- `idevicescreenshot` from libimobiledevice is an optional screenshot backend on older releases.
  iOS 27 and newer use pymobiledevice3's DVT screenshot route over the native tunnel. A GUI app
  does not inherit the user's shell path, so only the managed tool and explicit Homebrew, local
  and system binary paths are considered. Apple `devicectl` checks and auto-mounts current
  developer services once per selected device before capture. Missing tooling produces an
  in-pane explanation.
- Screenshot work runs in a bounded child-process group off the main actor. Output and PNG size
  are capped, temporary directories are mode `0700`, the PNG signature is checked, and decoding
  happens on a worker before AppKit receives the immutable image.
- The fallback requests at most one frame per second, only while presented. Hiding or terminating
  the tab cancels discovery/capture and its child process; no background mirroring continues.
- The surface uses the shipping display-panel, tab, theme and device-framebuffer components. It is
  deliberately host-only: Threading owns exact device identity, capture lifetime and future input
  authority even if surrounding panel chrome remains customizable.
- When `pymobiledevice3` 11.13.1 or newer is available, a bounded rootless probe calls
  DisplayService media support and Universal HID touchscreen discovery directly for the exact
  selected UDID. It does not infer absence from legacy raw RSD service names.
- **Prepare iPhone Control** explicitly runs the tool's exact-device automatic developer-image
  mount. On iOS 27 that can download and install the matching Cryptex1 DDI. Tool data goes to a
  Threading-owned private cache without changing `HOME` or touching a legacy user cache.
- The hand button asks for a non-persistent, exact-device control grant. Once approved, clicks and
  drags map from the aspect-fitted framebuffer into Universal HID's 16-bit coordinate space.
  Hiding, closing or switching devices revokes the grant and cancels in-flight input.
- Standard US text and editing keys work while the granted pane owns keyboard focus. Hardware
  buttons, unlock/passcode automation and agent-driven physical input remain unavailable.

This fallback is a proof of the product path, not the eventual transport. It requires the device's
developer image/services to be available and may be visibly slow over Wi-Fi.

## Persistent media backend still required

The reference implementation that motivated this work, [omarchy-iphone-mirror
v0.1.3](https://github.com/DanielLemky/omarchy-iphone-mirror/releases/tag/v0.1.3), uses Apple's
RemoteXPC device services: DisplayService supplies the media stream and Universal HID sends input.
Its active media stream also gates HID availability. Threading's app-owned helper now keeps one
private control session open and delivers warm HID requests in under two milliseconds on the
measured phone. Preview remains a separate full-resolution screenshot session, though, so the
picture—not input delivery—is still the latency boundary.

The next implementation therefore needs to extend that bounded helper with:

1. one bounded stream lease per visible physical-device pane, latest-frame replacement and a hard
   frame/byte budget;
2. exact mapping from pane coordinates through aspect fit, orientation and device pixel bounds;
3. reuse of the existing visible exact-device grant before Universal HID opens;
4. immediate HID teardown when the tab hides, the device changes, the phone disconnects or the
   session ends;
5. no passcode entry, unlock automation, lock-screen interaction or attempt to bypass iOS trust;
6. content-free diagnostics that record backend state and refusal class, never frames, taps,
   typed text, device names or UDIDs.

USB should be the preferred control path. Wi-Fi can remain available, but the pane must show its
transport honestly and never imply low latency when the route cannot provide it.

## Verification gate for the persistent slice

Before replacing the screenshot preview path, prove on supported iOS versions and on both USB and
Wi-Fi that:

- the active DisplayService stream is necessary and sufficient for HID;
- hide, close, disconnect and app termination release both services promptly;
- coordinate transforms remain correct through rotation and every fitted pane size;
- a stale device identity or changed trust state fails closed;
- text input cannot silently cross from the chat composer into the phone;
- every grant and refusal remains visually attributable to the exact selected device;
- no persistent service remains after revocation even if a gesture or frame request is in flight.

The screenshot fallback remains useful if the private stream breaks after an iOS update, but it
must never silently inherit a previous input grant.
