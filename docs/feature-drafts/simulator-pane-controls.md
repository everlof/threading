# Simulator pane: a real device-control surface

**Status:** draft, partly implemented. Phase 1 has shipped: Home/Lock/Side/Volume hardware buttons,
continuous-touch panning (click-drag and trackpad scroll), and the input-latency rework below.
Extends [`docs/architecture/simulator-pane.md`](../architecture/simulator-pane.md) (the in-panel iOS
Simulator, its signed direct helper, and the Indigo HID input path) and the shared-memory frame
transport. Prompted by the pane shipping with only tap / drag-swipe / typed text and no hardware
buttons, and with trackpad panning that did nothing.

## Input latency — why a pan lagged when the frame stream did not

Observed: driving the device from Simulator.app looked perfectly smooth *in Threading's own view*
(the shared-memory frame path handles rapid updates fine), but panning *through* the pane lagged.
So the lag was entirely in input injection, and it had two round-trip bottlenecks, both removed:

- **App side — a per-move authorization round-trip.** Each streamed move ran the full
  `authorizedInputSession` path (a spawned task, a consent re-check, an `awaitInputSession` poll,
  MainActor hops) and then *waited for its ack* before sending the next. Now `began` authorizes
  once and captures the live session; moves go through a new `SimulatorLiveStreamSession.streamInput`
  — **ordered** (the client's state queue serializes every send) and **fire-and-forget** (no pending
  continuation, the ack is ignored). The reliable AF_UNIX stream guarantees delivery and order; a
  dropped move is corrected by the next. `began` stays awaited (reliable start), `ended` is streamed
  ordered after the last move (reliable release over the reliable socket).
- **Helper side — a per-touch HID-completion wait.** `sendMessage` blocked the serial input queue on
  a semaphore until the private HID `sendWithMessage:…completion:` callback fired, serializing moves
  at the HID rate. Streamed **moves** now dispatch the HID send non-blocking (`sendTouch(…,wait:false)`);
  `began`/`ended`/tap/button stay blocking for correctness.

Together these make a pan a fast ordered stream with no per-event round-trip, matching the frame
path's smoothness. Momentum on release (the arm64 inertia caveat below) is still open.

## The problem

Today the pane can tap, drag (as a single swipe), and type. A person watching the device cannot
press **Home**, **Lock**, **Volume**, cannot **rotate** or **shake**, and **two-finger trackpad
panning does nothing** — the screen view has no scroll handler, and a click-drag flick has its
duration floored to 100 ms, so it barely imparts momentum. The agent tools mirror the same three
verbs. We want the pane to feel like a device you can actually drive, and the agent to have the
same reach.

## The one structural fact that shapes everything

**`xcrun simctl` cannot inject a tap, swipe, long-press, pinch, or any hardware-button press.**
Every tool that drives a simulator's input — Apple's Simulator.app, Meta's `idb`, AXe,
XcodeBuildMCP, and Anthropic's own Claude Code Desktop simulator pane — does it through the
**private CoreSimulator / SimulatorKit "Indigo" HID wire**, via `SimDeviceLegacyHIDClient.send()`.
`simctl` owns only lifecycle, media, permissions, appearance, status bar, location, push,
pasteboard, and screenshot/record.

So the control set splits across **two seams we already own**:

| Seam | What it can do | Where it lives |
|---|---|---|
| **Indigo HID** (live input) | tap, swipe, long-press, pinch/rotate, scroll, hardware buttons, shake/motion, force touch | the signed helper's `SimulatorPrivateBridge` — the same path the pane and agent input already use |
| **Public `simctl`** (state/data) | appearance, status bar, Dynamic Type, permissions, push, open-URL, add-media, pasteboard sync, location, screenshot/record | `SimulatorControlling` — the app's existing lifecycle path, no helper change |

Rotation and Face/Touch ID are the two exceptions that sit in neither cleanly (below).

## How Claude Code Desktop and the industry do it

Anthropic ships an official **Claude Code Desktop iOS Simulator pane**
(`code.claude.com/docs/en/desktop-ios-simulator`) that is essentially this same product path: it
"drives the simulator directly, so it doesn't need computer use and never takes over your screen,"
with tunable video, per-device consent, session-isolated devices (≤4 per session), and org
controls. It cannot control a physical device, and Android is "in the works." This is confirmation
that our architecture (own the pane, drive CoreSimulator through a signed helper, no
Accessibility/Screen-Recording) is the right one — this draft is about closing the *control-set*
gap against a mature panel.

The reference layouts elsewhere converge on the same shape: a **persistent hardware-button
toolbar** (home / lock / volume / rotate / screenshot) + a **mouse-as-finger canvas** with
continuous-touch scrolling + an **"Extended controls / Features" surface** for state (location,
appearance, biometrics, permissions, status bar, media). Android Studio's Extended-controls panel
and BrowserStack App Live's toolbar are the two clearest references; scrcpy is the best-documented
open reference for the *input mechanics*.

## Panning and gestures — the mechanics that actually matter

The survey found three ways to turn host pointer input into device scrolling, and the difference is
the whole reason panning feels dead today:

- **Path A — continuous synthetic touch (best, native momentum).** Emit one `touchDown`, then a
  stream of interpolated `touchMove`s that follow the cumulative delta, then `touchUp` on release.
  The **device OS's own velocity tracker computes the fling from the last moves** — the host
  synthesizes no momentum. This is what scrcpy click-drag, Android Studio click-drag, Appetize's
  interactive mouse, and Sauce/BrowserStack "click-and-move" all use.
- **Path B — discrete two-point swipe with a duration** (`from → to over N ms`). What we do now,
  and what AWS Device Farm / Appetize's SDK / Appium do. Repeatable but linear; it only flings if
  the intermediate moves carry realistic accelerating timestamps near release, which a
  fire-and-forget "A→B over 300 ms" call does not — hence automated swipes feel dead.
- **Path C — injected scroll-wheel event** (`IndigoHIDMessageForScrollEvent`, which SimulatorKit
  does expose). Precise for standard scroll containers, **no fling**, and it breaks touch-only
  views (games). scrcpy's docs say a wheel event "doesn't simulate a finger swipe."

**Recommendation:** route trackpad two-finger scroll and click-drag through **Path A** — a
*continuous touch protocol* the helper streams to the digitizer — and let the guest OS fling. Keep
Path C (`ScrollEvent`) only as a precision fallback for scroll containers.

> **Apple-silicon caveat (load-bearing):** on arm64 simulators the guest's own inertia-on-release
> is documented to **freeze instantly** (Apple Developer Forums thread 668488), while
> Intel/Rosetta decelerates like a device. So Path A may *still* produce no momentum on our target
> hardware. If it doesn't, the helper has to **synthesize a decaying tail of `touchMove`s after
> release** (emit moves along the release velocity vector, decelerating, before `touchUp`). This is
> the one piece that needs a measured prototype before we commit a feel.

The current `.drag(from,to,duration)` is atomic (down → interpolate → up in one message); it cannot
express "keep following my finger" or "hold, then drag." **Path A, long-press-then-drag, pinch, and
rotate all want a continuous touch stream** — separate `touchBegin` / `touchMove` / `touchEnd`
messages keyed by a touch id, with the pane driving them live from `NSEvent`s. That is the central
architectural change this draft proposes.

## Master control inventory

Effort is relative: **S** reuses an existing seam, **M** adds a bridge method + wire case, **L**
needs new investigation or a protocol concept.

### Live input — Indigo HID (signed helper)

| Control | Mechanism | Effort | Notes |
|---|---|---|---|
| Tap | `IndigoHIDMessageForMouseNSEvent` | — | have it |
| Swipe (discrete) | interpolated touch | — | have it (`.drag`) |
| **Continuous touch / pan** | new `touchBegin/Move/End` stream to digitizer | **L** | Path A; the momentum work lives here |
| **Scroll (precision)** | `IndigoHIDMessageForScrollEvent` | **M** | Path C fallback |
| **Long-press** | touchDown, hold, touchUp | **S** | duration param |
| **Pinch / zoom** | two mirrored touch points (`_scale_event`) | **M** | Simulator.app = Option-drag; scrcpy = Ctrl-drag (mirror a 2nd finger about center) |
| **Two-finger rotate** | `_rotation_event` | **M** | |
| **Force / 3D touch** | `IndigoHIDMessageForPressureEvent` (`_force_event`) | **M** | pressure value |
| **Home / Lock / Side** | `IndigoHIDMessageForButton` sources 0/1/3000 | **S** | wire + helper have it; **only the pane UI is missing** |
| **Volume ± / ringer-mute** | `IndigoHIDMessageForButton` (more key codes) or `IndigoHIDMessageForHIDArbitrary` (consumer usage page) | **M** | bridge currently hard-rejects any source ≠ 0/1/3000 — relax + map |
| **Shake / motion** | `IndigoHIDMessageForDeviceMotionLiteEvent` (`_accelerometer_event`) | **M** | |
| **Siri** | hold Side/Home, or a dedicated trigger | **M** | ⚠ injecting Siri via Indigo is reported to crash `backboardd` — validate carefully |
| Hardware keyboard / modifiers | `IndigoHIDMessageForKeyboardNSEvent` / `ForModifierKeyBit` | **M** | we type via `KeyboardArbitrary`; passing real key events is richer |

### System / state — public `simctl` (`SimulatorControlling`)

| Control | `simctl` | Effort |
|---|---|---|
| Appearance dark/light | `ui appearance` | **S** |
| Dynamic Type / contrast | `ui content_size` / `increase_contrast` | **S** |
| Status-bar overrides (time, battery, cellular, wifi, operator) | `status_bar override` | **S** |
| Permissions grant/revoke/reset | `privacy` | **S** |
| Push notification | `push` | **S** |
| Open URL / deep link | `openurl` | **S** |
| Add photos / videos | `addmedia` | **S** |
| Pasteboard sync with Mac | `pbcopy` / `pbpaste` / `pbsync` | **S** |
| Simulated location (custom + scenarios + GPX) | `location` | **M** |
| Screenshot / screen recording to host | `io screenshot` / `io recordVideo` | **S** (screenshot exists) |
| Erase / restart | `erase` / lifecycle | **S** |

### The two awkward ones

- **Rotate device (portrait/landscape).** Not an Indigo event — it is a `SimScreenUIOrientation`
  on the device screen (`landscapeLeft/Right`, `portrait`, `portraitUpsidedown`, with a
  `SimDisplayUIOrientationChangeDelegate`). Reachable through SimulatorKit on the same object the
  helper already holds; needs the exact selector confirmed. Also implies the pane must re-fit and
  re-map input to the rotated frame. **M–L.**
- **Face ID / Touch ID.** Enroll toggle + match / non-match. No `simctl` path; Simulator.app does
  it through SimulatorKit / a biometric notification (`com.apple.BiometricKit_Sim.*`, injectable
  via `simctl spawn notifyutil` inside the guest). **M**, but its own investigation.

## Proposed shape

### 1. A continuous touch protocol (the core change)

Add to the wire (protocol v3): `touchBegin(id, x, y)`, `touchMove(id, x, y)`, `touchEnd(id, x, y)`,
plus `scroll`, `button(arbitrary)`, `motion`, and `force`. Keep the existing atomic `.tap` /
`.drag` as convenience/back-compat. The helper maps a touch id to a digitizer contact; the pane
drives begin/move/end live from `mouseDown/Dragged/Up` and from `scrollWheel` (translating scroll
phase → a synthetic contact). This is what unlocks native panning, long-press-then-drag, pinch, and
rotate, and it is the honest fix for "panning isn't working properly." The Apple-silicon inertia
caveat is prototyped here.

### 2. Relax the button vocabulary

`SimulatorBridgeButton` currently is `{home, lock, side}` and the bridge rejects any other source.
Widen the enum (volume up/down, ringer) and either map to `IndigoHIDMessageForButton` key codes or
`IndigoHIDMessageForHIDArbitrary` consumer usages. Home/Lock/Side need **no** protocol work — just
pane buttons.

### 3. A state plane over `simctl`

Most "Features"-style controls are pure `SimulatorControlling` additions (appearance, status bar,
permissions, pasteboard, media, url, location, push) and need no helper or wire change. They belong
behind a **Features / Extended-controls popover**, not the always-visible toolbar.

### 4. UI

Reuse existing components — **no new design primitives**:
- A **device-control toolbar** under (or over) the screen, following the `BrowserDeviceToolbar`
  precedent, built from `ControlButtonGroupView` / `ToolbarButtonGroupView` themed icon buttons:
  Home, Lock, Volume ±, Rotate, Shake, Screenshot. An overflow `ThemedMenu` for the long tail.
- A **Features popover** (`ThemedActionPopover` / `ThemedPopover`) for the simctl state plane.
- The screen canvas gains `scrollWheel` (→ continuous touch), Option-drag pinch, and a long-press
  timer, matching Simulator.app's own pointer conventions.

### 5. Agent surface

The agent already has `simulator_tap/swipe/type_text/press_button`. Extend the same command service
with the new verbs (scroll, long-press, pinch, rotate, shake, button vocabulary, and the simctl
state actions), so the agent and the human converge on one input path exactly as they do today.

## Phasing

1. **Buttons + panning (highest value, mostly ready).** Pane toolbar with Home/Lock/Side (no
   protocol work) + Volume (relax bridge). The continuous touch protocol + `scrollWheel` panning
   with the arm64 momentum prototype. Ships the two things the user actually asked for.
2. **Richer gestures.** Long-press, pinch/zoom, two-finger rotate, force touch, shake/motion.
3. **State plane.** Features popover over simctl: appearance, status bar, permissions, pasteboard,
   add-media, open-url, location.
4. **The awkward two.** Device rotation (with pane re-fit + input re-map) and Face/Touch ID.

## Risks and boundaries

- **Xcode wire-format fragility.** iOS/Xcode 26 changed the Indigo mouse signature (5→9 args, must
  run on `MainActor`), which broke `idb`/AXe/XcodeBuildMCP until patched. Our helper already works
  on Xcode 26.5, but every new Indigo builder we adopt (`ScrollEvent`, `PressureEvent`,
  `DeviceMotionLiteEvent`, arbitrary buttons) is another private signature that can shift under an
  Xcode update — each needs the compatibility probe to cover it, and a codec/verify path.
- **Trust boundary.** New HID operations widen what the signed helper can do to a device; they stay
  within the existing host-owned, per-device-consent model (`simulator-pane.md`), but the consent
  copy and the `SimulatorHelperTrust` review should be revisited when the input vocabulary grows.
- **Known-crash inputs.** Siri-via-Indigo and some motion events are reported to destabilize the
  guest; gate them behind validation, not the default toolbar.
- **arm64 momentum.** As above — do not promise native fling until measured; be ready to synthesize
  the decay tail.
- **Rotation** changes the frame geometry the shared-memory transport and input normalization both
  assume; it must re-fit the pane and re-map normalized coordinates, or input lands rotated.

## Open questions

- Confirm the exact `IndigoHIDButtonKeyCode` values for volume/ringer, or commit to the
  `HIDArbitrary` consumer-usage route.
- Confirm the SimulatorKit selector for setting device orientation and whether it round-trips to
  the framebuffer surface size the helper reads.
- Does native fling ever appear on arm64, or is the decay-tail synthesis mandatory? (prototype)
- Which controls are always-visible toolbar vs. Features popover vs. agent-only?

---

*Not yet indexed in [`README.md`](README.md) — add a row under the appropriate tier when this is
prioritized. Cross-check against `docs/architecture/simulator-pane.md` before implementing; move
durable decisions there as phases ship.*
