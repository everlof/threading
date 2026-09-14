# Simulator pane: element-level interaction via the accessibility tree

**Status:** **Phases 1–2 implemented.** Phase 1 (read path + inspector overlay + `simulator_snapshot`)
is **verified live** — the embedded helper returned SpringBoard's real tree on the running build.
Phase 2 (tap/type by `eN` ref or semantic locator, resolved against a fresh snapshot) is built and
unit-tested, pending a relaunch to verify live. Phases 3–4 (live pointer hit-test overlay, human
annotations) remain. The exact read recipe was proven in our own host code (below). Extends
[`docs/architecture/simulator-pane.md`](../architecture/simulator-pane.md) (the signed direct
helper, framebuffer and Indigo HID input) and deliberately mirrors the agent browser
([`agent-browser.md`](../architecture/agent-browser.md)): its accessibility-oriented snapshot,
stable `eN` refs, semantic locators, and the annotation/probe overlay. Prompted by the pane driving
the device only through screenshots and guessed pixel coordinates.

## The problem

Today an agent (and a person) interacts with the adopted device by looking at a screenshot and
computing a normalized `(x, y)` to tap. That is brittle: a coordinate means nothing after a layout
change, a scroll, a different device size, or a localized string; there is no notion of "the
**General** row" or "the **Continue** button," only pixels. The browser solved exactly this — it
reads a compact accessibility snapshot, gives each interactive element a stable `eN` ref, lets
tools address elements by ref or by a rerender-safe **semantic locator** (role + name / label /
test-id), and returns a fresh snapshot after every action. We want the same for the Simulator: an
element tree the agent targets by ref, and a pane overlay that outlines and names the element under
the pointer — an Accessibility-Inspector-grade surface, host-owned.

## Validated live (2026-09, iPhone 17 Pro, iOS 26.5, Xcode 26.5)

`idb ui describe-all` / `describe-point` were run against the booted device's foreground app as a
feasibility spike (idb is a reference implementation of the exact host-side call we would make). The
whole loop came back real:

- **Snapshot:** 23 elements for the app — `Application` root at `402×874` points, then `Button`,
  `Image`, `StaticText`, `Heading`, `Group`, each with `role`, `AXLabel`, `AXFrame`, and
  `AXUniqueId` (= `accessibilityIdentifier`) where the app set one (`hybrid_level_1` etc.).
- **Hit-test:** `describe-point 66 146` returned the correct element (Image "1 vibration",
  `hybrid_level_1`) — the overlay's "element under the pointer" mechanism.
- **Coordinate mapping to our existing tap:** normalized center = `(frame.midX/W, frame.midY/H)`
  with `W×H` = the app's logical point size — e.g. the "Try notification backend" button →
  `tap(0.905, 0.096)`. That feeds `simulator_tap` (normalized) directly, so **tap-by-ref reuses the
  Indigo HID path already shipped.**

So the design below is not speculative; the remaining work is doing the same fetch **in our signed
helper** instead of shelling out to idb, then wiring refs, the agent tools, and the overlay.

### Proven in our own host code (standalone spike, not idb)

A throwaway host-side ObjC tool — *our* code, no idb, no XCUITest — drove the whole private path
against the booted device and confirmed each load-bearing selector on this exact toolchain
(Xcode 26.5, macOS 26 host, iOS 26.5 runtime). It:

1. `dlopen`s `CoreSimulator`, the active Xcode's `SimulatorKit`, and the **host-side**
   `/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework` (the macOS copy a
   host process links — *not* the runtime's iOS copy).
2. Resolves the `SimDevice` through the same `SimServiceContext` →
   `defaultDeviceSetWithError:` → `devicesByUDID` path the helper already uses.
3. Takes `+[AXPTranslator sharedmacOSInstance]` (the concrete host singleton is
   `AXPTranslator_macOS`), sets `setAccessibilityEnabled:`/`enableAccessibility` and
   `setSupportsDelegateTokens:YES`, and installs a bridge delegate via `setBridgeDelegate:`.
4. Implements the **`AXPTranslationTokenDelegateHelper`** delegate: its
   `accessibilityTranslationDelegateBridgeCallbackWithToken:` returns a block
   `(AXPTranslatorRequest*) -> AXPTranslatorResponse*` that relays each opaque request to
   `-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]` and blocks on a
   semaphore (the async-XPC → sync-delegate bridge the draft calls mandatory). The relay
   round-trips were logged: real `AXPTranslatorRequest`/`AXPTranslatorResponse` objects come back
   from the guest.
5. Resolves the foreground app: `device.accessibilityPlatformTranslationToken` →
   `frontmostApplicationWithDisplayId:bridgeDelegateToken:` (returns an `AXPTranslationObject`) →
   `platformElementFromTranslation:` (returns an `AXPMacPlatformElement` reporting role
   `AXApplication`).

**The full tree now comes back in our own code.** With the mechanism below the spike printed the
identical 23-element tree idb returns — same labels, frames, and `hybrid_level_1/2/3` identifiers —
proving the entire Phase 1 read primitive host-side, no idb.

#### Implementation-ready recipe (verbatim from the working spike)

Setup, once per snapshot session (all on one serial queue — the singleton is process-wide):

- `translator = [AXPTranslator sharedmacOSInstance]` (concrete class `AXPTranslator_macOS`).
- `[translator setAccessibilityEnabled:YES]; [translator enableAccessibility];
  [translator setSupportsDelegateTokens:YES]; [translator setBridgeDelegate:self];`
- The bridge delegate implements **`AXPTranslationTokenDelegateHelper`**:
  `accessibilityTranslationDelegateBridgeCallbackWithToken:` returns a block
  `(AXPTranslatorRequest*) -> AXPTranslatorResponse*` that relays via the device (below);
  `accessibilityTranslationRootParentWithToken:` returns nil;
  `accessibilityTranslationConvertPlatformFrameToSystem:withToken:` is identity.
- `token = [device accessibilityPlatformTranslationToken];`
- `root = [translator frontmostApplicationWithDisplayId:0 bridgeDelegateToken:token];` → an
  `AXPTranslationObject` for the foreground app.

Per element (`root`, then recurse):

- `req = [AXPTranslatorRequest requestWithTranslation:<translationObject>];`
- `req.requestType = 5;` (**MultipleAttribute** — `FBAXPRequestTypeAttribute` is 2, single).
- `req.parameters = @{@"attributes": @[@8,@21,@25,@27,@33,@45,@51,@53]};` — **leave `clientType`
  unset**; setting it makes the guest answer from a stale `automationElements` override and children
  come back empty (this is exactly why the earlier NSAccessibility walk returned only the root).
- **Send to the guest, not `processTranslatorRequest:`** (that selector is the *guest-side* entry and
  returns nil data on the host):
  `[device sendAccessibilityRequestAsync:req completionQueue:q completionHandler:^(AXPTranslatorResponse *r){…}]`,
  bridged to sync with a semaphore (5 s timeout).
- `resultData` is an `NSDictionary` keyed by `NSNumber` attribute id:
  `8`=Children (an `NSArray` of child translation objects → recurse), `21`=Frame (`NSValue` rect,
  points, top-left, screen space), `25`=Identifier (= `accessibilityIdentifier`), `27`=IsEnabled,
  `33`=Label, `45`=Role (numeric `AXPUIElementType`), `51`=Subrole, `53`=Value.

Role arrives as a number; observed values `1`=Application, `2`=Button, `5`=Group, `6`=Heading,
`7`=Image, `14`=StaticText. The helper carries a static `AXPUIElementType`→AX-role-string map (the
per-node `platformElementFromTranslation:` + `accessibilityRole` gives the string only for the root,
so it is not a per-child substitute). Frames land on the framebuffer as `pixels = points × displayScale`.

Two findings that shape the helper implementation:

- **The full tree comes from an AX *tree dump*, not a recursive `AXChildren` walk.** Walking the
  `AXPMacPlatformElement` via NSAccessibility (`accessibilityChildren` / legacy
  `accessibilityAttributeValue:@"AXChildren"`) returned the root only — empty children — whereas idb
  returns the whole flat 23-element array live at the same moment. idb (and we should) issue a
  **tree-dump-typed request** relayed through `sendAccessibilityRequestAsync:` and read
  `-[AXPTranslatorResponse treeDumpResponse]`; the flat array carries `AXFrame`, `AXUniqueId`,
  `AXLabel`, `role`/`type`, `AXValue`, `enabled`, `role_description`, `custom_actions` per node.
  The translator's own `generateAXTreeDumpTypeOnBackgroundThread:completionHandler:` is **abstract**
  on `AXPTranslator_macOS` (`cannot be sent to an abstract object … Create a concrete instance!`) —
  it is not the host entry point; the request goes to the guest. This is the one piece to port
  verbatim from idb's open source (`AXTranslationDispatcher.swift`, `FBAccessibilityKeys.swift`)
  rather than re-derive.
- **`AutomationEnabled` is a per-app-launch cache, not a live gate.** idb returned the full tree
  with the guest's `com.apple.Accessibility AutomationEnabled = 0`; toggling it to `1` did not
  change our recursive-walk result, and `ApplicationAccessibilityEnabled` was already `1`. So the
  identifier/fidelity difference the draft cites is about what the *foreground app* cached when it
  launched, and the reliable read path (tree dump) does not depend on flipping the pref at read
  time. The helper should still assert `ApplicationAccessibilityEnabled`, but automation mode is
  best treated as a launch-time setting for apps we install, not a per-read toggle.

## The tree is reachable from our helper directly — no idb, no XCUITest

The decisive finding: the live accessibility hierarchy of the **foreground** app in a booted
simulator is available to a **host process that already links CoreSimulator** — which the signed
helper does — through the same private path Apple's Simulator.app, Xcode's Accessibility Inspector,
and idb's default backend use. It needs nothing injected into the guest and no XCUITest runner.

**The path (idb's `--api ax` backend, which is a reference implementation of this exact call):**

1. Take the process-wide `AXPTranslator` singleton from the private
   `AccessibilityPlatformTranslation.framework` (shipped in Xcode's Simulator runtime).
2. Resolve a root translation object: `frontmostApplicationWithDisplayId:0 bridgeDelegateToken:`
   for the whole app, or `objectAtPoint:displayId:bridgeDelegateToken:` to hit-test a point.
3. Install ourselves as the translator's token delegate. The translator fetches every attribute
   **lazily**, calling back `accessibilityTranslationDelegateBridgeCallbackWithToken:`; we forward
   each opaque `AXPTranslatorRequest` to
   `-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]` and hand the
   `AXPTranslatorResponse` back. **We never build the request by hand** — the translator builds it
   and we relay it, which is why adoption is small (idb's `AXTranslationDispatcher` is ~200 lines).

`SimDevice.h` states this route "in Xcode 12 … replaces SimulatorBridge related accessibility
requests." The strings are already present in the frameworks on this machine:
CoreSimulator exports `-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]`,
`accessibilityConnection`, `com.apple.CoreSimulator.accessibility`; SimulatorKit exports
`SimAccessibilityManager`, `AXTestingSnapshotParameterizedAttribute`, `AXPTranslatorResponse`, and
`accessibilityTranslationConvertPlatformFrameToSystem:withToken:`.

### The element shape we get (enough for browser-style refs)

Per element: `AXLabel`, `AXFrame`, `AXValue` (a text field's contents come through here),
**`AXUniqueId` = `accessibilityIdentifier`**, `type`/`role`/`subrole`, `traits`, `enabled`,
`custom_actions`, `role_description`, `help`, `pid`, and — in the nested format — real `children`.
That is the same primitive set a browser AX snapshot is built from: `identifier` is the stable
anchor when the app sets one, and a `(type + label + sibling-index)` path is the fallback when it
does not, exactly as with DOM refs. Whole-tree reads are bounded (idb caps depth 50 / 3000 nodes
and flags `truncated`).

### Coordinate mapping onto our framebuffer

Frames come as **points**, top-left origin, in the device's **screen** space. Our rendered
framebuffer is **pixels = points × displayScale** (2× / 3× Retina). So `pixel_rect = ax_frame ×
scale`, with the scale read from the device's display, not guessed. No extra transform is needed —
idb's `accessibilityTranslationConvertPlatformFrameToSystem:` implementation is identity, and
rotation is already reflected in the numbers (re-read after rotating; do not apply your own
rotation). The status bar needs no offset — frames are absolute in screen space.

### Two operational facts that decide whether this works at all

- **Automation mode.** With `com.apple.Accessibility AutomationEnabled` off, UIKit collapses
  subtrees and drops most identifiers (idb measured 98 elements / 12 identifiers off vs
  176 elements / 58 identifiers on); and `ApplicationAccessibilityEnabled` must be set or reads come
  back **empty**. The helper must assert both (consulted per read, no app relaunch) before a
  snapshot is meaningful.
- **The translator is a process-wide singleton with unsynchronized state.** Concurrent use
  over-releases shared token storage → `EXC_BAD_ACCESS`. Every translator interaction must funnel
  through **one serial queue**, and the async `SimDevice` XPC must be bridged to the translator's
  synchronous delegate (idb uses a `DispatchGroup` with a 5 s timeout). This is a correctness
  requirement, not a nicety.

### Cost / staleness

Pull-only, no change notifications — poll. First read of a screen is 1–2 orders of magnitude slower
than warm reads. The ordinary read (all elements, frames, labels, identifiers) is milliseconds once
warm; the two reachability keys `interactable` / `occluded_by` hit-test every node (one screen: 16
ms → ~2148 ms), so ask those only **per point, per interaction**, never per-tree per-frame. This
maps cleanly onto the Scaling Gate: a snapshot is externally sized, so it is fetched off-main,
bounded, and turned into a value model before any view or ref is built.

### Ranked alternatives (documented so the choice is on the record)

1. **`AXPTranslator` + `sendAccessibilityRequestAsync` (above)** — host-side, no guest install, what
   Apple's tools use. **Recommended.**
2. **Legacy `SimulatorBridge` XPC** (`accessibilityElementsWithDisplayId:` returns a ready-made dict
   tree; `performPressAction:`/`Increment:`/`Decrement:`) — simpler to call, but the path Apple
   superseded in Xcode 12; keep as a fallback / cross-check.
3. **idb's `axbridge`** — a helper **inside** the guest gives XCUITest-level fidelity (typed,
   labelled elements where the host view reports one composite) in one round trip, but requires
   building, signing, and shipping a guest binary. Only if the host-side view's composite-collapsing
   proves limiting.
4. **XCUITest / `XCUIApplication`** — the true snapshot, but needs a built, attached UI-test runner;
   too heavyweight for live inspection. Fallback of last resort.
5. **Shelling out to `idb`** — produces the same data but adds a subprocess + gRPC hop over the same
   private API we can call in-process. Avoid.

## Proposed shape (mirroring the browser)

### 1. Helper: an accessibility-snapshot request over the existing wire

Add a control request the app sends the signed helper: "snapshot the foreground app" and
"hit-test point `(x, y)`." The helper runs the `AXPTranslator` dance on its serial input-adjacent
queue, walks the tree to the bound, translates each frame to framebuffer pixels, and returns a
compact value tree: `{ role, subrole, label, value, identifier, traits, enabled, frame, children }`.
It asserts automation + application accessibility first. This is a read capability the helper does
not have today — it widens the direct-helper boundary and belongs in the `SimulatorHelperTrust`
review and `simulator-pane.md`.

### 2. App: refs + the snapshot contract

The pane assigns stable `eN` refs to interactive elements (anchored on `identifier` where present,
else a structural path), holds the value tree, and exposes it. Every input returns a fresh snapshot;
a truncated tree is recoverable by re-snapshotting a subtree — the browser's exact contract.

### 3. Agent tools

- `simulator_snapshot` — returns the current element tree with refs (bounded; text labelled as
  untrusted external data, as the browser does).
- `simulator_tap` / `simulator_type_text` / etc. accept **a ref or a semantic locator** (role +
  label / identifier) as well as the existing normalized coordinate, resolved against a fresh
  snapshot immediately before acting; ambiguous matches fail rather than silently pick the first.
  The tap still actuates through the Indigo HID path we already have (ref → element frame center →
  touch); the accessibility tree is the *addressing* layer, not a new actuation layer.

### 4. Pane overlay (the "annotation style")

An Accessibility-Inspector-grade overlay over the live framebuffer, built on the
`BrowserAnnotationOverlay` / `BrowserBaselineOverlay` precedent: while inspection mode is on, the
overlay outlines and **names** the element under the pointer (pointer move → helper `objectAtPoint`
hit-test → role + name), and can draw all element bounds. Human annotations (pinned notes with
`user_authored` provenance, kept separate from the untrusted tree) mirror `browser_annotations`.
Host-owned picking, provenance and focus, exactly as the browser overlay is.

## Phasing

1. **Read path.** ✅ **Implemented.** Helper AX-snapshot request over the existing signed wire
   (protocol v3, `accessibilitySnapshot`/`accessibilitySnapshotResult` + `SimulatorAccessibilityElement`);
   the `AXPTranslator` dance on a dedicated serial queue with the async-`SimDevice` → sync bridge; a
   read-only `simulator_snapshot` agent tool (role/label/identifier + normalized `tap=(x,y)` per
   element); and the inspector overlay that outlines every element over the framebuffer to verify the
   device-points → framebuffer mapping. Point hit-test (`objectAtPoint`) is deferred to Phase 3 with
   the live pointer overlay. Automation mode: the helper does not toggle it per-read (a per-launch
   cache; see the finding above); `ApplicationAccessibilityEnabled` handling stays a follow-up.
2. **Target by ref.** ✅ **Implemented.** `simulator_tap`/`simulator_type_text` accept an `eN` ref
   or a semantic locator (label/identifier, optionally narrowed by role) as well as a normalized
   coordinate. The UI router (`SimulatorAgentInputRouter`) takes a fresh snapshot and resolves the
   target to a normalized centre immediately before acting (`SimulatorElementResolver`); an ambiguous
   locator fails with candidates rather than guessing, and typing focuses the resolved field with a
   tap first. Refs are numbered over one shared `SimulatorElementListing` used by both the renderer
   and the resolver, so a ref the agent saw resolves to the same element. Actuation still goes
   through the shipped Indigo HID tap — the tree is the addressing layer, not a new actuator.
3. **Inspector overlay.** Outline-and-name-under-pointer in the pane; optional all-bounds overlay.
4. **Human annotations.** Pinned notes with provenance, mirroring the browser.

## Risks and boundaries

- **Private-API/ABI fragility.** `AXPTranslator`, the `AXPTranslatorRequest/Response` types, and the
  `SimDevice` accessibility selectors are private and have moved before (the Xcode 12 migration).
  Every adopted signature needs a per-Xcode disassembly check and the compatibility probe extended
  to cover a snapshot — the same class of risk the Indigo input path already carries.
- **Singleton concurrency.** The serial-queue funnel + sync bridge is mandatory; getting it wrong is
  an `EXC_BAD_ACCESS` in the helper, not a soft failure.
- **Trust boundary.** Reading the guest app's accessibility tree is a new capability for the signed
  helper; revisit `SimulatorHelperTrust` and the consent copy (it is a read, not input, but it is
  device content leaving the guest).
- **Automation mode is a side effect.** Turning on `AutomationEnabled` changes how the guest app
  reports itself; decide whether that is always-on while the pane is adopted or scoped to snapshot
  windows, and document it.
- **Coordinate correctness** must be verified by rendering bounds over the framebuffer (Retina scale,
  orientation), the same way the browser's element-screenshot geometry is a tested tripwire.
- **Fidelity ceiling.** The host-side `ax` path collapses custom-drawn composites into one element;
  if that blocks real targets, `axbridge` (guest helper) is the escalation, at real cost.

## Open questions

- Does the app already load / can it `dlopen` `AccessibilityPlatformTranslation.framework`, or does
  only the helper need it? (The helper is the natural home — it already links CoreSimulator and
  loads the active Xcode's SimulatorKit.)
- Always-on automation mode vs. per-snapshot, and its effect on the app under test.
- Snapshot cadence for the live overlay: hit-test on pointer-move is cheap (one point); a full-tree
  refresh is not — bound it and debounce, per the Scaling Gate.
- Do we expose `custom_actions` (accessibility custom actions) as agent-invocable, or only
  tap/type/scroll to start?

---

*Not yet indexed in [`README.md`](README.md) — add a row under the appropriate tier when
prioritized. On implementation, move the durable helper/wire and trust decisions into
`docs/architecture/simulator-pane.md`. Primary research: idb's accessibility backends and element
shape (fbidb.io/docs/accessibility, fbidb.io/docs/idb/ui), the idb source
(`AXTranslationDispatcher.swift`, `FBAccessibilityKeys.swift`) and private headers
(`AXPTranslator.h`, `SimDevice.h`, `SimulatorBridge-Protocol.h`).*
