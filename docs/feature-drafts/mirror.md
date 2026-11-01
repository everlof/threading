# Mirror

**Status:** Phase 1 implemented on 2026-10-31; its durable rules are in
[`docs/architecture/phone-mirror.md`](../architecture/phone-mirror.md). Not yet measured on a
physical iPhone, so Phase 0's spikes still owe their numbers. Phases 2–5 below are still design
(drafted 2026-10-30; revised 2026-10-31 for no prompts, the invite notification and the controls
guide).

**What Phase 1 built differently from this draft.**
- Localhost goes through the tab's existing browser-tunnel grant, renewed by asking again,
  rather than a new mirror-scoped grant. Extra `mirrorOrigins` are not built.
- `mirrorOffer`/`mirrorUpdate` are one `mirrorState` frame; the phone declares itself with a
  `mirrorHello` signal after the first events frame (the events socket has no `hello`).
- The capsule holds Reload, Interactive / View only, Lock Rotation, **?** and End Mirror. Follow
  panel and Send to chat arrive with Phases 2 and 3, so the guide's second callout is Reload.
- The quiet offer floats below the top bar rather than inside each screen's own bar.
- The broker change is written and tested (notification protocol 5) but not deployed.

**The one-sentence version.** When you design or build something meant for a phone, such as a
mobile web page or an iOS app, you see it on a real phone with no setup.

- Turn Mirror on at the Mac and it appears on the paired iPhone. Neither device asks a question.
- If Threading is not open on the phone, a notification takes you straight into the stage.
- A web page renders in the phone's own WebKit and swaps revisions without a flash as the agent
  edits.
- A Simulator streams as video, with your finger forwarded back.
- The phone can hand a marked-up capture back to the conversation.
- A phone you are using (keyboard up, finger on the screen) is never taken over.
- The first arrival teaches the one gesture that brings up the controls.

Read with [`REMOTE_ACCESS.md`](../REMOTE_ACCESS.md) (routes, the browser tunnel, the events
socket), [`simulator-pane.md`](../architecture/simulator-pane.md) (helper transports, input
consent), [`agent-browser.md`](../architecture/agent-browser.md),
[`mcp-and-display.md`](../architecture/mcp-and-display.md),
[`notification-delivery.md`](../architecture/notification-delivery.md) and the Live Activity half
of [`ios-glanceable-surfaces.md`](ios-glanceable-surfaces.md).

---

## 1. The problem and the people

At the desk, the phone is idle while the work it is *for* happens on the Mac. Today, seeing a
prototype on a real device takes one of these:

- a QR code to a LAN address that only works when the dev server binds `0.0.0.0`;
- a deploy;
- an Xcode install;
- **Browse on iPhone**, which already works for a localhost tab but has to be reached by hand
  through Workspace ▸ Browser, does not follow edits, and opens public URLs in Safari, which
  Threading cannot reload.

Each iteration repeats the walk.

**Concrete cases**

1. **Developer, dev server.** Vite at `localhost:5173` with HMR. They want the phone in a stand
   beside the laptop showing the page live, so they can see on real hardware that `100vh` is
   wrong under the Dynamic Island.
2. **Designer, agent-written HTML.** An agent rewrites `prototype/index.html` (plus `styles.css`
   and images) every turn. They want each revision to appear on the phone *where they were
   scrolled*, and to circle a problem with a finger and send it back.
3. **Public prototype.** `https://festina-prototype.netlify.app` should open full-screen,
   controllable and reloadable. A stakeholder holds the phone and taps through it.
4. **Simulator.** The agent drives an iOS Simulator. The developer wants that screen in their
   hand at true size, and to tap it, without a signing round-trip.
5. **Agent verification.** After a CSS change, the agent wants to know how it rendered on a
   *real* iPhone: viewport, safe-area insets, console errors, a phone-rendered screenshot.

Companion players are the genre reference: Figma Mirror follows the desktop selection, and
ProtoPie Player and Origami Live turn a phone into a dedicated viewer. What they share:

- the phone has one job while it mirrors;
- the content follows the desktop without being asked;
- the controls stay out of the way until a deliberate gesture calls them.

Threading has one advantage none of them have: the thing producing the content is an agent in the
same app, so the loop can close in both directions.

## 2. Principles

1. **See it on the target.** Mirror is for the device you are designing or building for. A mobile
   page or an iOS app is only truly seen on a real phone, so Mirror puts it there with no setup.
   That decides how each source travels:
   - **What the phone can render itself** (a web page) renders in the phone's own WebKit, because
     that *is* the target: its viewport, safe areas, touch, scroll physics and quirks. Mac-rendered
     pixels of the same page would show the Mac, not the target.
   - **What it cannot** (a Simulator) arrives as pixels at true size in your hand. That is the
     closest easy step towards the target. The rung above it is the app itself running on the
     phone (§9, Later).
2. **The phone is a controller or a target, never both at once.** A phone you are prompting from,
   reading or typing in is never taken over. At most it shows a quiet, non-modal note that a mirror
   is ready (§4.2). Mirror takes the screen only of an idle phone.
   - The rule "the Mac never changes the phone's screen" (`REMOTE_ACCESS.md`, Browser Follow) stays
     true outside Mirror.
   - A mirror exists only because a person started it, on the Mac or on the phone. Starting it on
     the Mac *is* the consent. The phone is the owner's own paired device, so it asks nothing more.
   - Agents can present onto a stage they are bound to. They can never open one.
3. **Fluent means no question, no flash, no jump, no wait.**
   - Turning it on asks nothing, on either device.
   - A revision replaces the page without a white frame.
   - The scroll position survives the replacement.
   - Arriving takes under a second on LAN, whether from the Mac's click on a foreground phone or
     from a notification tap on a warm app.
4. **Never a dead end.** Mirror is a layer above whatever the phone was showing. Every exit (phone,
   Mac, Live Activity, revocation) returns to that screen, unchanged. A half-written draft is never
   pushed aside by an arriving mirror.
5. **Exit is deliberate but never hidden.** No gesture a prototype is likely to use, and no
   invisible edge zone. There is one gesture, taught on the first arrival, plus visible exits on
   the Mac and in the Live Activity.

## 3. What already exists

| Need | Existing seam | Gap |
|---|---|---|
| Authenticated phone↔Mac channel on every route | Pinned TLS HTTPS/WSS on LAN, VPN, Tailscale and Hosted Direct; `hello.features` negotiation | — |
| Mac-initiated action on a foreground phone | `/ws/events` and the `mobileDiagnosticsCaptureRequest` precedent | A typed mirror frame family |
| Mac localhost page rendered live on the phone | **Browse on iPhone**: `MobileBrowserProxy` (loopback CONNECT forwarder) + WKWebView `ProxyConfiguration`, plus `RemoteBrowserTunnel` grants on the Mac; WebSockets (HMR) work | A grant is tied to one browser tab's current origin and capped at one hour |
| Mac-rendered pixels of a tab | `RemoteBrowserFollowView` + `browser-preview` PNG on `workspaceChanged` | Only agent tool calls signal changes. User navigation, reload and HMR do not. |
| Agent HTML on the phone | `RemoteHTMLView` (`loadHTMLString`, `baseURL: nil`) | Relative assets break; no change push; no file server |
| Simulator pixels | `threading-simulator-helper`: H.264 AVCC with SPS/PPS, JPEG, normalized 0…1 touch | Nothing sends frames to the phone. Single digitizer contact. Fixed 6 Mbps at native size. Replacing a P-frame breaks decode. |
| Touch consent | Per-device simulator input grant (`SimulatorInputConsent`) | No user-vs-agent touch lease |
| Annotated screenshot | `MobileScreenshotMarkupController`, dictation, attachments upload | Not wired to a phone-rendered capture with device context |
| Background presence | `ThreadingGlance` widget extension, app group | No ActivityKit; `NSSupportsLiveActivities` absent |
| Push to a suspended phone | Hosted broker (`Service/ThreadingControlPlane`), on every channel since 2026-09-27 | New kinds need a Worker deploy |

Most of Mirror is composition. The new pieces are:

- the mirror session itself;
- a mirror-scoped tunnel grant;
- a confined file server;
- the double-buffered web stage;
- a frame socket with credit flow control;
- the invite notification kind;
- the controls guide;
- the Live Activity.

## 4. Product contract

### 4.1 Sources

| Source | Renders on | Interaction | Update signal |
|---|---|---|---|
| Mac browser tab, loopback origin | **Phone** WKWebView through the tunnel | Local, native | Mac tab navigation and reload (new event); HMR is the page's own |
| Public URL | **Phone** WKWebView, direct | Local, native | Mac tab navigation and reload; `mirror_reload` |
| HTML file in the checkout | **Phone**, from the Mac's confined file server through the tunnel | Local, native | File-system revision on the file's directory |
| Session's latest attachment ("follow latest") | Phone (HTML) or image viewer | Local | `SessionAttachmentsDidChange` |
| Image (PNG/JPEG, exports, screenshots) | Phone image stage: fit, double-tap for 1 image pixel = 1 device pixel, pan | View | Attachment change |
| iOS Simulator / Android emulator | **Mac** pixels, H.264 to the phone | Forwarded touch (one contact on iOS, multi-touch possible on the Android emulator) | Every frame |
| Panel selection ("Follow panel") | Whichever of the above the selected tab is | As above | Panel tab selection |

**Follow panel** is the Figma-Mirror mode. The phone shows whatever the session's display panel is
showing, so switching from the HTML preview tab to the Simulator tab on the Mac switches the
phone. When the selected tab has no mirrorable form (chart, scene, Git Review), the stage keeps
the last content and shows a quiet line saying why. **Pinned** keeps one source regardless of
the panel. Starting from the panel header defaults to Follow panel. Starting from one specific
item defaults to Pinned.

Private browser tabs never mirror.

### 4.2 Starting a mirror

**On the Mac**
- A registered command, `mirror.toggle` (**Mirror to iPhone**), is reachable from:
  - the palette;
  - the browser chrome bar overflow;
  - a panel tab's context menu;
  - the attachment action menu;
  - the Simulator pane header.
- It is distinct from the existing `simulator.presenter.toggle` and `iphone.presenter.toggle`,
  which open a *Mac window*. Copy has to keep the two apart.
- **Which phone.** The owner device that was active most recently. With several online, the chip's
  popover switches phones. The Mac does not ask.

**On the phone it just appears**
- One click on the Mac is the whole start. Pairing already lets this Mac reach the phone, so there
  is no prompt, no first-time sheet and no arming step.
- An idle phone with Threading in the foreground takes the stage at once.
- A phone where Threading is in the background, suspended or locked gets the **invite
  notification** (§4.6). Tapping it opens straight into the stage.
- Settings ▸ Mirror holds one switch per Mac, **Allow Mirror from this Mac**, on by default. With it
  off, the Mac's chip reads *Mirror is off on iPhone* and nothing reaches the phone. It is a
  setting, never a prompt.

**A phone in use is never taken over.** This is the one exception to "it just appears". The phone
counts as in use when either holds:
- the keyboard is up, or a composer has focus;
- a finger is on the screen, or left it within the last five seconds.

Two things deliberately do not count:
- Having used the phone a minute ago. The click on the Mac is itself the newest human input: you
  have moved to the Mac.
- An unsent draft. Mirror is a layer above it, and every exit returns to it untouched.

While the phone is in use:
- An arriving mirror becomes a quiet offer: a small *Mirror ready · Show* glyph in the top bar. It
  takes no focus, plays no haptic and never covers the composer.
- The Mac's chip reads *iPhone in use — waiting*.
- The offer never promotes itself into a takeover when the phone later goes idle. A tap opens it,
  or the Mac starts the mirror again.

**A fresh start wins on activation.** If the app becomes active within 30 seconds of the Mac's
click, by any route, it enters the stage: you clicked and picked up the phone. A keyboard that the
system restores on activation is not new input. After 30 seconds, only the notification, the Live
Activity or a tap on the quiet offer opens the stage, because opening Threading later may be for
prompting.

**Standby** is the stage's resting state, not a gate. It shows:
- the Mac's name;
- a slow breathing ring;
- a black OLED backdrop.

The idle timer stays off. The stage falls back to standby when its source ends or goes quiet
(§4.3). **Use as Mirror** on the dashboard opens it directly, for a phone in a stand. Anything the
Mac then mirrors appears there.

**Agents**
- `mirror_show` presents onto a stage that is already bound to the calling session, or that is
  following its panel.
- With no such stage, the call is refused with `no_stage`. The Mac shows a one-click offer chip
  (*"Agent wants to show prototype/index.html on iPhone — Mirror"*).
- So the person opens the stage once and the agent iterates on it freely.

### 4.3 The stage on the phone

**Entering**
- The content resolves behind a pill naming the Mac and the source (*MacBook Pro ·
  festina-prototype*).
- The pill fades after about 1.2 s.
- One soft impact plays on arrival.
- For the first three arrivals after the controls guide (§4.4), the pill carries a second line,
  *two fingers · controls*.

**While mirroring**
- Status bar and home indicator hidden.
- System edge gestures deferred.
- Idle timer disabled.

**Orientation**
- Web and image stages rotate freely; the controls offer an orientation lock.
- A Simulator stage follows the Simulator's orientation and changes when it rotates.
- When the phone's model matches the simulated device, the stage is pixel-exact. Otherwise it fits
  inside the phone's screen with letterboxing.

**Energy**
- After 15 minutes with no revision and no touch, the stage dims to standby.
- The idle timer is restored on exit, on background and on standby.
- Serious thermal state or Low Power Mode lowers a Simulator stream's frame rate.

**Fluent revisions**

The web stage holds two WKWebViews at most. On a new revision:

1. The new page loads into the hidden one at the same size.
2. It waits for `didFinish`, `document.fonts.ready` and two animation frames.
3. It restores the scroll anchor. That anchor is the element at the viewport's top plus an
   offset, falling back to the scroll ratio.
4. It cross-fades for about 150 ms and tears down the old view.

The visible page never blanks. Dev servers with HMR update themselves; the stage reloads them
only on navigation or an explicit reload.

### 4.4 Controls and exit

**Opening the controls**
- A **two-finger hold** (about 0.5 s, stationary) anywhere opens the controls capsule. Neither a
  prototype nor the forwarded single-contact Simulator input uses that gesture.
- In view-only stages, a single tap also opens it.
- `accessibilityPerformEscape` (the VoiceOver two-finger scrub) opens the capsule too, so assistive
  technology always has a way out.

**Learning the controls (the first arrival)**

The first mirror on a phone teaches the gesture by having the person do it. Two short steps run
over the live content, which stays visible but dimmed:

1. *Hold two fingers on the screen to bring up the controls*, with a two-finger illustration. It
   advances only when the person makes the gesture, and the real capsule opens.
2. The capsule with three numbered callouts: **End Mirror**, **Send to chat** and **Interactive /
   View only**. One line adds *You can also end it from the Mac or the Lock Screen.* **Got it**
   closes the guide.

- It takes a few seconds and asks nothing. **Skip** is always there.
- It is shown once per phone, not once per Mac. The state lives in the phone's own defaults.
- The capsule's **?** and Settings ▸ Mirror replay it.
- With VoiceOver running, step 1 teaches the two-finger scrub instead, because VoiceOver owns
  two-finger gestures.
- The first Simulator stage in **Control** adds a line of its own: *One finger drives the
  Simulator. Two fingers bring up the controls.*
- Under Reduce Motion the illustration does not move.

On the Mac, the first mirror gives the chip a one-time callout: *Your iPhone is showing this.
Click to switch phone or stop.*

**What the capsule contains**

It sits at the bottom, is themed, and auto-hides after about 4 s.

- Source and Mac
- **Reload**
- **Interactive / View only** (for a Simulator: **Control / View**)
- **Follow panel / Pinned**
- Orientation lock
- **Send to chat** (§4.5)
- **?**, which replays the controls guide
- **End Mirror**

**Ways out**
- **End Mirror** on the phone.
- **Stop Mirroring** on the Mac's chip.
- **End** in the Live Activity.
- Revoking the device or turning Remote Access off.

All of them return the phone to the screen beneath and tell the other side. The Mac's chip then
reads *"iPhone left the mirror"*, with **Mirror again**.

**Away is not ended**
- Leaving the app, or locking the phone, starts a 120-second grace period. This is the same
  period the terminal viewport lease already uses.
- Within the grace period, returning resumes instantly.
- After it, the Mac keeps the session waiting for up to 30 minutes. A foreground return inside
  that window rejoins the session directly while the per-Mac switch is on, because the stage is
  the screen the person left.

There is no shake, pinch, double-tap or edge zone. The app already uses shake for issue reports,
pinch for terminal font size and double-tap for zoom, and the workspace drawer owns the right edge.

### 4.5 Talking back

1. **Touch.**
   - Web and image stages are local, with zero added latency.
   - A Simulator stage in **Control** forwards one contact as normalized 0…1 coordinates. The
     helper's existing input vocabulary carries it: `began` and `ended` are acknowledged, while
     `moved` is fire-and-forget.
   - Forwarded touch needs the existing per-device Simulator input grant, plus a new **touch
     lease**. While the person's finger holds the lease, agent input to that device waits or is
     refused with a reason. The Mac pane benefits from the same lease.
   - The grant never becomes a question on the phone. A session-created Simulator already holds
     its grant. An existing one without a durable grant shows the Mac's grant sheet once, when
     Mirror starts in **Control** at the Mac where the person is clicking, and that grant then lasts
     across launches. A stage started in **View** asks nothing.
2. **Send to chat.** This captures the *phone-rendered* stage: `WKWebView.takeSnapshot` for web,
   or the decoded frame for a Simulator. It opens the existing markup editor and allows an
   optional dictated note, then posts the result into the bound session as a message with an
   attachment. It carries a **device context** block:
   - model;
   - CSS viewport and device pixel ratio;
   - safe-area insets;
   - colour scheme;
   - Dynamic Type size;
   - URL;
   - scroll offset;
   - revision.

   The agent receives *"this is what it looks like in my hand"* together with the numbers it
   needs to act on.
3. **Real-device diagnostics.** The web stage forwards `console` errors, warnings and unhandled
   rejections from its own WebKit to the Mac. They are bounded to a ring of 200 entries and
   attributed to a revision.
4. **`mirror_inspect`** (agent tool) returns:
   - the device context;
   - the last console entries;
   - optionally a fresh phone-rendered screenshot.

   An agent can therefore verify a change on real hardware without provisioning anything.
   It reads only the stage bound to its session.

### 4.6 Away from the app

| Phone state | What happens |
|---|---|
| Foreground, idle | Takes the stage at once through `/ws/events` |
| Foreground and **in use** (§4.2) | Quiet offer only, never a takeover |
| Background, suspended or locked; new mirror | The **invite notification** (below). Tapping it opens straight into the stage. |
| Background, mirror already running | The **Live Activity** started at mirror start shows in the Dynamic Island and on the Lock Screen (§5.6). Tapping it returns to the stage. |
| App opened some other way, offer pending | Within 30 s of the Mac's click it enters the stage. Later it shows the quiet offer (§4.2). The Mac holds the offer for 10 minutes. |
| No push available (a broker below notification protocol 5, no hosted credential, or notifications not allowed) | No notification can reach a suspended phone. The Mac's chip reads *Open Threading on iPhone*, and the 30-second rule does the rest. |

**The invite notification**
- **Kind.** A new `RemoteNotificationKind`, `mirrorInvite`, classified in
  `RemoteNotificationKind.lifecycle` as an independent event.
  - It lives 120 s, the same as `secretApproval`.
  - It is retracted when the phone joins, when the mirror ends and when the lifetime runs out.
  - The Worker needs a deploy for the new kind.
- **Collapse.** `apns-collapse-id` is the mirror session, so clicking again replaces the banner
  instead of stacking a second one.
- **Interruption level: time-sensitive.** The person asked for it seconds ago at the Mac, and it
  expires in two minutes. That needs the time-sensitive entitlement. It plays no sound, only the
  default haptic.
- **Content.**
  - It reads *Mirror from MacBook Pro* / *festina-prototype — tap to show*. With preview consent
    off for this device, the body drops the source title.
  - The payload carries opaque ids only: the host and the mirror session. The URL, the path and
    anything else about the source never travel through APNs or the broker.
- **Tap.**
  - The app routes to `.mirror(id)` before the connection is up. It shows the stage at once in its
    connecting form: black, with the arrival pill naming the Mac, and the source title when preview
    consent allowed it.
  - The content resolves behind the pill as soon as the events socket joins.
  - If the Mac ended the mirror meanwhile, the stage says so for a moment and returns to the screen
    beneath. That is never a dead end.
  - From the Lock Screen the system asks for Face ID first. Nothing bypasses it.

This is the experience the owner asked for (2026-10-31), and it needs push. Push to a suspended
phone goes through the hosted broker, which every channel offers since 2026-09-27 (an earlier
version of this draft said otherwise). What it needs is the broker deployed at notification
protocol 5 (§10).

### 4.7 On the Mac

**The chip**

While a mirror runs, a quiet chip sits in the source's header strip: *● iPhone · festina-prototype*.
Its state reads one of:
- **Showing**
- **Interacting** (the person is touching it)
- **Away**
- **Connecting**
- **Notified** (the invite went to a suspended phone)
- **iPhone in use — waiting** (the quiet offer is showing)
- **Open Threading on iPhone** (no push is available)
- **Mirror is off on iPhone** (the per-Mac switch is off)

**The popover** (from clicking the chip) holds:
- the device, with a switch to another phone when several are online;
- Follow panel / Pinned;
- Interactive / View only;
- **Reload on iPhone**;
- **Stop Mirroring**.

**Other surfaces**
- The source tab carries a small mirror badge.
- The command palette shows **Stop Mirroring to iPhone** while a mirror is running.

## 5. Architecture

### 5.1 The mirror session (Mac-owned)

```
MirrorSession
  id: MirrorSessionID
  hostID, deviceID                    // exact owner device; never a guest in v1
  sessionID: AgentSessionID?          // binding for agents, Send to chat and Follow panel
  source: MirrorSource                // .browserTab(PaneTabID) | .url(URL) | .file(CheckoutPath)
                                      // | .latestAttachment | .attachment(ID) | .simulator(UDID)
                                      // | .androidDevice(ID) | .panelSelection
  mode: .interactive | .viewOnly      // Simulator: .control | .view
  revision: UInt64                    // monotonic; bumps on navigation, reload, file change, swap
  state: offered → joining → live ⇄ away → ended(reason)
```

- The Mac is authoritative. The phone renders what the session says and reports `MirrorPresence`:
  - foreground or away;
  - touching or idle;
  - device context.
- **Bounds:**
  - one live session per phone;
  - at most four sessions at once, one per owner device;
  - the pending-offer table is bounded the same way.

### 5.2 Control frames

Additive under `hello.features: ["mirror.1"]`. An old client never receives them.

| Direction | Frame |
|---|---|
| Mac → phone (`/ws/events`) | `mirrorOffer{session, sourceTitle, kind, age}` (also carried by `hello` while an offer is pending; `age` is measured on the Mac, so the 30-second rule needs no shared clock), `mirrorUpdate{session, revision, render}`, `mirrorEnd{session, reason}` |
| Phone → Mac | `mirrorJoin`, `mirrorOfferHeld{session, reason: inUse \| disabled}` (drives the chip), `mirrorPresence{state, touching, deviceContext}`, `mirrorLeave{reason}`, `mirrorConsole{entries}` (bounded batch) |
| REST | `POST …/mirror/<id>/feedback` (the existing chunked upload), `POST …/mirror/<id>/end`, used by the Live Activity intent while the events socket is closed |

`render` describes how to show the source:
- `.web(origin, path, tunnelGrant)`
- `.public(URL)`
- `.image(attachmentID)`
- `.stream(route, codec, geometry)`

### 5.3 Live web path

**Mirror-scoped tunnel grant.** Generalize `RemoteBrowserTunnel` grants from "the origin a shared
tab currently shows" to "the origins a mirror session admits":
- bound to the session, not to a tab;
- renewed while the session lives, instead of expiring after a fixed hour;
- revoked when the session ends.

A dev server whose API sits on another port needs that port admitted too:
- `.threading.json` can declare up to four extra `mirrorOrigins` beside `previewURL`
  (`project-scripts.md`);
- anything else is refused, as today.

Unchanged:
- page bytes, forms and WebSockets keep the original origin;
- HTML is never rewritten;
- Mac cookies never leave the Mac.

**Confined file server** (for `.file` and HTML attachments).
- A loopback-only `NWListener` on the Mac, reached only through the tunnel grant.
- Its root is the HTML file's directory, which must resolve inside the checkout. Symlinks are
  resolved before the check, and anything resolving outside is refused.
- `GET` only, with MIME types by extension and no directory listing.
- Refused outright: dotfiles and dot-directories (`.env`, `.git`) and anything matching the secret
  scan's path rules.
- It injects no script. Reload arrives over the events channel, so the page under test is
  byte-identical to the file.

**Revision source.**
- One FSEvents stream per live file-backed mirror, on the root directory only.
- Coalesced over 150 ms, so an agent writing five files becomes one revision.
- Mac tab navigation and reload come from `BrowserViewController`'s existing `url`/`title` KVO and
  load-finish callbacks, as a new `onMirrorableChange`. This also fixes Browser Follow, which
  today sees only agent-initiated changes.

**Public URLs** load directly from the phone in the stage's own WKWebView. They do not go to
`SFSafariViewController`, which the stage cannot reload, snapshot or overlay. Each mirror gets a
non-persistent website data store. Persisting a login per Mac and origin is a later option.

### 5.4 Pixel path

**A dedicated route.** `/ws/mirror/<id>` carries binary frames with a one-byte tag:
- key frame;
- delta frame;
- parameter sets;
- geometry.

Binary frames on the other routes are untagged PTY bytes, so the two must not share a route.

**Source.** A second helper connection for the same UDID. It is negotiated with
`supportsSharedMemory: false`, codec `.h264`, and new hello fields `scale` and `bitrate`. It adds
frame demand the way the presenter window does ("mirrors, does not own"), so a hidden pane does
not return the helper while the phone is watching. It uses one of the four helper slots.

**Encoding**
- LAN: native size at about 6 Mbps.
- Hosted Direct: half scale at about 1.5 Mbps. Hosted Direct is one reliable, ordered data
  channel with 256 KiB stream windows, so a single stream sustains about 1.7 MiB/s at 150 ms
  round-trip time, shared with API traffic.

**Flow control.** Credit-based, with at most two frames unacknowledged.
- The Mac never lets the 2 MiB socket backlog fill. Filling it would force-close the socket.
- When credit runs out, the Mac drops frames until it can send a keyframe, then asks the helper
  for one. That needs a new `requestKeyframe` message.
- Delta frames are never replaced in a queue, since a replaced P-frame corrupts decode until the
  next IDR.

**Damage.** The helper checks `IOSurfaceGetSeed` and skips unchanged ticks on this connection, with
a heartbeat frame so the liveness monitor keeps its meaning.

**Phone.** `VTDecompressionSession` → `AVSampleBufferDisplayLayer` on a decode queue, never on the
main actor. A frame is decoded only while the stage is visible.

**Android.** The emulator gRPC stream (RGBA, change-driven) is encoded once on the Mac with
VideoToolbox and sent through the same route. `adb screenrecord` H.264 can be forwarded without
re-encoding.

**Stills first.** Phase 4a sends JPEG stills at most twice a second, through the Browser Follow
pattern. It is view only, cheap, and proves the stage before video.

### 5.5 Agent tools

| Tool | Effect | Refusals |
|---|---|---|
| `mirror_show{source, note?}` | Swaps the content of the stage bound to this session; returns device and viewport | `no_stage` (and raises the Mac offer chip), `source_not_mirrorable`, `private_tab` |
| `mirror_reload` | Bumps the revision | `no_stage` |
| `mirror_inspect{screenshot?}` | Device context, console ring, optional phone-rendered capture | `no_stage`, `phone_away` |

Agents cannot start or end a mirror, change its mode, or forward touch into the phone's web view.
The tool catalogue says so in its instructions.

### 5.6 Live Activity

- `NSSupportsLiveActivities` goes in the app. A `MirrorActivityAttributes` configuration goes in
  `ThreadingGlance`, which follows `GlanceDesign` system containment, not the app palette.
- The activity is **started locally at mirror start**, while the app is necessarily in the
  foreground, so no push is needed. ActivityKit shows it only while the app is not frontmost.
  - **Compact:** mirror glyph + *Mirroring*.
  - **Minimal:** glyph.
  - **Expanded / Lock Screen / StandBy:** Mac name, source title, a locally ticking "updated"
    time, **Return** (deep link) and **End** (a `LiveActivityIntent` that calls `POST …/end`).
- `staleDate` is the end of the grace period. The app ends the activity itself on its next
  foreground if the Mac has ended the session meanwhile.
- With the broker, a `liveactivity` push can update and end it, as planned in
  [`ios-glanceable-surfaces.md`](ios-glanceable-surfaces.md). Push-to-start for a fresh invite is
  the step after that.

### 5.7 Phone routing

- A typed `MobileNavigationRoute.mirror(MirrorSessionID)` presented from the root as a
  full-screen layer, with `mobileTheme(_:)` applied because it is its own hosting scene.
- `restoreRouteIfPossible` never restores it, and continuity never saves it.
- Opening it does not disturb the route beneath.
- The deep link `threading://mirror/<id>` admits only a session the active Mac currently reports.
- A notification response routes before the connection is up. Admission is checked when the events
  socket reports its sessions. A session the Mac no longer reports shows the ended line and
  returns to the route beneath.

## 6. Scaling contract

| Quantity | Expected | Stress | Rule |
|---|---|---|---|
| Live mirror sessions | 1 | 4 (owner devices) | One per phone; offers bounded alike |
| Web views on the stage | 1 | 2 | Double buffer; the old one torn down after the swap |
| Revisions | ~1 per agent turn | Bursts of tens per second while an agent writes many files | 150 ms coalescing; O(1) per event; no tree rescan |
| File server requests | A page's assets | A page with hundreds of assets | Streamed off the main actor; per-file size cap equal to the attachment cap |
| Video frames | 30 fps while touched; ~0 while static | 60 fps request | Two unacknowledged at most; damage-skipped; nothing while the stage is hidden |
| Console entries | A few | A runaway `console.log` loop | Phone ring of 200; batched at most twice a second; Mac ring of 200 per session |

Encoding, file serving, tunnel bytes, FSEvents handling and decode all run on workers. The
main-actor phase on each side is a state change: the chip on the Mac, the stage's revision on
the phone.

## 7. Security and privacy

- **Owner devices only** in v1. Guests and share links are out of scope; a "mirror to a guest" is
  its own decision.
- **No prompt is a deliberate trust choice.** A paired owner Mac can put a mirror on the screen of
  an idle phone without asking. These bound it:
  - owner devices only;
  - the in-use rule;
  - the per-Mac switch;
  - every exit within one gesture;
  - agents never opening a stage.
- The invite notification carries opaque ids only. Its title respects the device's preview consent.
- The tunnel grant admits only declared origins, for one session's life, and is revoked on end,
  on device revocation and when Remote Access turns off. Other local ports stay refused.
- The file server is confined to one directory inside the checkout, read-only, and refuses
  dotfiles and secret-scan paths. It is reachable only through an authenticated grant. It
  enumerates nothing.
- Private browser tabs never mirror, in any mode.
- The phone's web stage uses a non-persistent data store. No Mac cookie or credential is exported.
- `mirror_inspect` returns what the person can see on their own phone, for the session the stage
  is bound to.
- Forwarded touch needs the existing per-device Simulator input grant. The touch lease ensures that
  a person and an agent never share the single contact at once.
- The product doc's scope sentence ("mirrors nothing outside Threading") stays true: every
  source is a Threading-owned tab, file, attachment or device pane. Mirror is not remote desktop.

## 8. Rejected alternatives

- **Stream the Mac browser's pixels for web content.** This works for any origin, but it shows the
  Mac's rendering instead of the target's. It loses touch latency, scroll physics, the real
  viewport and safe areas, and WebKit on iOS. It stays only as the fallback for Mac-only state,
  through the existing Browser Follow.
- **Taking over a phone in use, even behind a banner.** The phone is then the controller, not the
  target. Cutting into a prompt being written costs more than a mirror arriving late.
- **A consent prompt on the phone, even once per Mac.** The person already said yes by clicking on
  the Mac. Asking again on the phone is the friction Mirror exists to remove. The in-use rule, the
  per-Mac switch and the exits do the protecting.
- **A two-minute "recently used" window.** It would make a phone you put down a minute ago refuse
  the mirror you just asked for. The click on the Mac is newer evidence than any earlier touch.
- **Asking which phone.** The most recently active owner device is nearly always right, and the
  popover switches it.
- **`SFSafariViewController` for public URLs.** The stage could not reload, snapshot or overlay
  it, and the system controls break the full-screen stage.
- **Injecting a live-reload script into served HTML.** The page under test would differ from the
  file, and the injection is a cross-site-scripting surface. Reload belongs on the control
  channel.
- **A QR code to the Mac's LAN address.** It needs the dev server to bind `0.0.0.0`, is
  cleartext, works only on the LAN, and duplicates a tunnel that already exists.
- **JPEG frames on `/ws/events`.** That would mean untagged binaries alongside JSON, one ordered
  socket, head-of-line blocking for notifications, and a 2 MiB backlog that force-closes the
  socket.
- **A WebRTC video track for Hosted Direct, now.** It is the right long-term transport (unreliable
  delivery, real congestion control), but it is new peer-transport work. Reopen it when Phase 4
  measures Hosted Direct as the limit.
- **Letting agents open a stage.** It breaks principle 2, and the offer chip already makes it one
  click.
- **AirPlay or screen recording of the Mac display.** That is remote desktop, outside the
  product's scope sentence, and it shows the Mac's layout rather than the phone's.

## 9. Phases

**Phase 0 — spikes (gates everything; the numbers go into this file)**

- **a.** Double-buffered WKWebView swap with scroll-anchor restore on a real iPhone. Measure the
  time from revision to visible and confirm there is no blank frame, against a fixture with an
  agent-shaped burst of file writes.
- **b.** Helper H.264 to the phone over LAN and Hosted Direct, using the existing WebSocket stack.
  Measure glass-to-glass latency (p50/p95), bitrate, and recovery from a forced backlog. Measure
  touch→visible for a forwarded tap.
- **c.** ActivityKit started locally in this app on iOS 17 and current iOS: when it shows, how it
  goes stale, whether the `End` intent can reach the Mac while the events socket is closed.
- **d.** Notification tap to stage, through the development broker. Measure tap to first content
  for a warm and a cold app on LAN. Confirm time-sensitive delivery under a Focus, and that
  `apns-collapse-id` replaces a repeated invite.

**Phase 1 — Mirror the web (live).**
- Sources: browser tab, public URL and localhost through the mirror-scoped grant.
- On the Mac: the command, the chip and its one-time callout.
- On the phone:
  - instant start with no prompt, and the per-Mac switch;
  - the in-use rule, its quiet offer and the 30-second activation rule;
  - the full-screen stage, standby and the two-finger controls;
  - the controls guide on the first arrival;
  - every exit;
  - keep-awake;
  - navigation and reload following (`onMirrorableChange`).
- The invite notification, wherever the broker runs notification protocol 5.
- The local Live Activity return path ships here, because it is cheap and it is what makes
  leaving the app safe.

**Phase 2 — Agent files and Follow panel.**
- The confined file server and FSEvents revisions.
- Follow latest attachment and Follow panel.
- Fluent swaps.
- `mirror_show` and `mirror_reload`.

**Phase 3 — Back to the Mac.**
- Send to chat with markup, dictation and device context.
- Console forwarding.
- `mirror_inspect`.

**Phase 4 — Simulators.**
- **a.** Stills, view only.
- **b.** H.264 stream with credit flow control and keyframe on demand.
- **c.** Forwarded touch with the touch lease.
- **d.** Android emulator.

**Phase 5 — Background reach.** Live Activity updates and ending by push where the broker exists;
push-to-start after that.

**Later:**
- **Run on this iPhone**, the top rung of principle 1 for an iOS target: build for device, install
  and launch on the paired phone through the existing `devicectl` path that the physical iPhone
  pane uses. The phone then runs the app itself, with its real GPU, performance, sensors and
  haptics. Signing is the gate.
- other targets: an iPad, or an Android phone through the browser companion;
- one source to several phones at once, for multi-size review;
- scroll following from the Mac;
- element comments on the phone, feeding `browser_annotations`;
- rotating the phone to rotate the Simulator;
- persisted logins per origin.

## 10. Decisions

**Decided by the owner (2026-10-31)**
- **No prompt anywhere.** Starting on the Mac is the consent. The phone has a per-Mac switch, on
  by default (§4.2).
- **A suspended phone gets a notification that opens straight into the stage** (§4.6).
- **The first arrival teaches the controls** (§4.4).
- **"In use" is the keyboard, or a finger on the screen within five seconds.** The click on the
  Mac counts as the newest input. This follows from the first decision: the two-minute window
  proposed earlier would have made a phone you just put down refuse the mirror you asked for.

**Open**
1. **Deploying the broker at notification protocol 5.** The change is written and tested; the
   invite reaches no suspended phone until it is deployed. Until then the Mac says *Open Threading
   on iPhone*, and the 30-second rule does the rest. (The earlier question — whether public builds
   get the broker at all — was already answered on 2026-09-27: they do.)
2. **Is "Run on this iPhone" part of Mirror** or a separate feature? It is the true target for an
   iOS app, but signing makes it a project of its own.
3. **The control gesture.** *Recommendation: two-finger hold*, with a tap in view-only mode and the
   accessibility escape. The alternative is a visible but faint corner handle, which costs pixels
   on a stage meant to be clean. The guide teaches whichever wins.
4. **Follow panel as the default** when starting from the panel header, versus always Pinned.
5. **Product scope sentence.** Whether to amend `docs/product/remote-companion.md`'s "mirrors
   nothing outside Threading" to name Mirror explicitly, since it now shares a word with it.

## 11. Tests

- **Mac**
  - Mirror state machine: offer, join, away, grace, rejoin, every end reason, revocation and Remote
    Access off.
  - Grant scoping: declared origins only, renewal, revocation.
  - File server confinement: symlink escape, `..`, dotfiles, secret-scan paths, size cap.
  - FSEvents coalescing under a write burst.
  - Credit flow control never exceeding the backlog, and keyframe requests after a drop.
  - Agent tool refusals.
  - Invite notification:
    - kind classification;
    - the collapse id;
    - retraction on join, end and expiry;
    - preview consent hiding the title;
    - no source details anywhere in the payload.
  - Phone choice: the most recently active owner device, and switching from the popover.
- **Phone** (`Tests/ThreadingMobileTests` is not synchronized; each new file needs all four
  project entries)
  - Route: never restored, deep-link admission, return to the route beneath.
  - No start ever shows a prompt. With the per-Mac switch off, the start is refused with a reason.
  - The in-use rule:
    - keyboard or composer focus, and a touch within five seconds, each give the quiet offer;
    - a draft alone, and a touch older than five seconds, do not;
    - the offer never promotes itself.
  - The 30-second activation rule, including that a keyboard restored on activation is not input.
  - Notification response:
    - a cold and a warm launch both go straight to the stage;
    - an ended session returns to the screen beneath;
    - a notification tapped after retraction does nothing.
  - The controls guide:
    - shown once per phone;
    - advances only on the real gesture;
    - Skip;
    - the VoiceOver variant;
    - replay from the capsule.
  - Gesture ownership, including that two-finger hold does not reach the page.
  - Scroll-anchor restore on a fixture page.
  - Idle-timer restoration on every exit.
  - Console ring bounds.
- **Render tests**, light and dark, per the design-system rule, for:
  - the chip and popover;
  - the standby and connecting stages;
  - both steps of the controls guide;
  - the controls capsule;
  - the Live Activity layouts.
- **A UI scenario** (`ui-scenario-testing.md`) for start → revision → exit with recorded traffic.
- **A performance fixture** for the swap path and the frame path, recorded in
  [`performance.md`](../architecture/performance.md).
