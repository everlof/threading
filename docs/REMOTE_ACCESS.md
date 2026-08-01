# Remote access

Remote access mirrors Threading sessions to a browser or to the native `ThreadingMobile` iOS app.
It is an opt-in beta feature: open the dedicated **Settings → Remote Access** page on the Mac,
choose a connection, and turn on **Remote Access**:

- **Relay** keeps the existing Cloudflare path and supports ordinary public share links.
- **Tailscale** publishes Threading only inside the owner's tailnet. It is the private option for
  owner devices and can also share a chat with somebody already in that tailnet.
- **Both** uses Tailscale for owner pairing and the relay for one-chat share links. Selecting it
  explicitly starts both transports while Remote Access is on.

All three terminate at the same loopback server, protocol and authorization checks. A transport
changes who can route packets to Threading; it never expands what a bearer may do.

## Pair an iPhone

1. Keep Threading running on the Mac.
2. Choose **Relay**, **Tailscale**, or **Both** and wait for the selected pairing connection.
3. In Threading on the iPhone, choose **Pair a Mac** and scan the QR code shown on the page.

The QR value is a one-time bootstrap. The Mac exchanges it for a unique 256-bit, device-bound
owner credential, rotates the code immediately, and stores the device record in the login
Keychain. iOS stores the paired host and its credential in its Keychain. Pairing therefore
survives a Threading restart and also survives turning Remote Access off and back on. Settings
lists each paired owner device with an explicit **Revoke** action; **Reset Everything** also
deletes the Mac-side owner credentials. A browser owner pairing deliberately remains tab-scoped.

The iOS app shows all unarchived
sessions grouped by project or ordered by recent activity, including dormant sessions. Pinned sessions
stay at the top on both Mac and iPhone, and the archive is available from the dashboard.
Opening a dormant session resumes it
in its existing agent UI or Native surface. Agent UI sessions mirror the CLI's terminal
scrollback and accept keyboard input; Native sessions render user messages, assistant responses, code and tool
activity natively, expose a composer when the agent can accept another prompt, and present
one-shot allow/deny cards (including edit diffs) when a headless agent requests permission.
If a diff is too large to send as one bounded remote snapshot, the card stays visible but must
be reviewed and decided on the Mac; Threading never offers an approval against a partial diff.

The Native conversation is a deliberate hybrid. SwiftUI still owns navigation, banners and the
composer, while a UIKit `UICollectionView` with a diffable data source owns the potentially long
timeline. Only visible reusable cells are mounted. The initial frame contains the newest bounded
window; **Load earlier messages** (or pulling near the top) requests prepend-only history pages
without moving the message under the reader's finger. Live updates carry revisioned
append/update deltas, and token streaming updates only its visible synthetic cell. A revision
gap requests a fresh recent window instead of guessing. Markdown is parsed off the main actor
and cached by source.

An owner can start a session from the iPhone and choose the Mac checkout, agent account, model,
reasoning effort and UI surface. The stable default is the agent's own Claude Code or Codex UI;
Threading's Native UI remains an explicit experimental choice. Account choices include the Mac's
latest normalized rate-limit usage, while credentials and config paths stay on the Mac. The
session is created through the same Mac launch path as a local session and appears on both
devices immediately. Owners can also rename, pin, archive, restore and switch a session between
Native and its agent UI from either side. A UI switch stops the current process, then resumes
the same provider conversation identifier on the other surface. The session row's **Interface**
submenu shows both choices with the active one checked on Mac and iPhone, and catalogue changes
are pushed immediately so another open device follows the switch without waiting for polling.

A session's iPhone **Workspace** gathers **Browser**, **Review**, the read-only repository
**Files** browser, and **Attachments** under one route so companion surfaces do not accumulate as
toolbar buttons. When an agent opens or navigates a browser tab, the phone never changes screens:
the Workspace button receives one quiet pulse and an unread dot. Opening **Browser** follows the
Mac-owned tab through bounded, read-only snapshots; clicks, scrolling, and form entry continue to
run only on the Mac and merely refresh an already visible follow view. Routine browser mutations
do not repeatedly animate the badge. Private tabs remain generic in the list and never send
pixels to the phone. Browser state, checkout reads, and attachment previews are owner-only.
Attachment metadata is fetched first and the selected image or PDF body is fetched on demand.
Attachments are bounded to 24 MB per file and accept only real supported files whose
symlink-resolved path remains inside that session's checkout.

When an interactive iPhone opens a Claude Code UI or Codex UI terminal, the phone's visible
SwiftTerm grid temporarily owns the shared PTY size. The Mac sends the ordinary terminal
resize/SIGWINCH to the agent, which redraws its real TUI at mobile width; the iPhone renders the
relayed ANSI stream locally rather than receiving a scaled screenshot. The Mac shows
**Fit to iPhone · columns×rows** while this lease is active and explains that its desktop size
returns when the remote view closes. Rotating the phone updates the lease, and disconnecting
restores the newest natural Mac grid (or another phone that is still controlling the session).

**The chat says who can see it.** For a long time the app could report that a session was
shared and nothing else — not who accepted a link, not whether anyone was on it, not how many
links were still lying around unused. That was a privacy gap and a debugging one: two clients
quietly holding the same terminal is what made the grid flip between sizes, and the only way to
notice was to screenshot the corner card.

The session status card grows an `eye` row whenever the chat is reachable from outside this Mac
— `2 following` while somebody is on it, `Shared` while only a link exists. It opens
`SessionSharingViewController` in the side pane, which groups by the lifecycle rather than by
source, because a link, a person and a connection are three different things with three
different verbs:

| Group | What it holds | What you can do |
|---|---|---|
| **Watching now** | live sockets, from `RemoteSessionMirrorRegistry.followers(of:)` — guests and the owner's own paired devices alike | nothing; a connection ends by itself |
| **With access** | members who accepted an invitation and are not here, from `RemoteAccessCoordinator.access(for:)` | Revoke, which asks first |
| **Invited** | invitations nobody has used yet | Copy, Revoke |

A member who *is* watching appears once, in the live group, where there is more to say about
them — both sources know that person, and listing them from each reads as two people with one
name. The owner's paired devices carry no Revoke in a single chat: they are paired with the Mac
rather than members of that share. The section links to Settings, where the device itself can be
revoked.

Revoking a person is a `ConfirmationPrompt` case (`revokeChatAccess`, `alwaysAsks(.irreversible)`)
because the way back is a *different* action the owner has to know to take — the invitation was
single-use, so letting them back in means sharing again. Withdrawing an unused link asks nothing:
nobody has become anybody yet.

**Clients say what they are.** `RemoteClientMessage.deviceName` is an optional, additive field on
the auth frame — the iPhone sends its model, the browser a user-agent-derived label — so rows read
"iPhone" or "Safari on Mac" rather than a column of UUID fragments. It is a label and never an
identity: `device` is what authorization binds to, and the host runs the label through
`RemoteInboundPolicy.normalizedDeviceName`, which is the member-name rule. A client that predates
the field omits it and the pane falls back to the pseudonym the diagnostics log uses, which is why
this needed no protocol bump.

**Two clients settle on the grid both can show**, not on whichever asked last. One PTY has one
size, and the Mac broadcasts every grid it applies to everybody watching, so last-writer-wins had
no fixed point: the client that could not display the new grid answered by re-asking for its own,
the other answered that, and the agent was reflowed and repainted several times a second for as
long as both stayed open. `RemoteSessionMirrorRegistry.resolvedViewport` takes the intersection —
the smallest column and row count across every live lease — which every viewer can see whole and
which does not depend on arrival order. A second viewer joining costs one resize.

**A remote-controlled terminal is laid out at a pixel size that disagrees with its grid**, so
every AppKit layout pass proposes a grid nobody asked for. Suppressing the PTY resize is not
enough, because SwiftTerm has already reflowed the emulator by the time the process is consulted,
and putting it back runs the resize path again — which ends in `softReset()`. A full-screen agent
therefore lost its scrolling region on every pass, including passes that set the identical frame,
which is what the Fit-to-iPhone banner's own text change caused. Both sides now answer
`shouldApplyFrameSizeChange` — a fork seam ahead of the emulator, not behind it — so a managed
grid is never left, even briefly. `EmojiFixedTerminalView` keeps `shouldApplyProcessSizeChange` as
the second gate, on the PTY rather than the renderer. Re-applying an unchanged lease is not a
resize either, for the same soft-reset reason.

Every applied grid is written to the event log as `Remote viewport applied` with the grid and the
number of clients holding a lease. Diagnosing the argument above meant reading it out of
screenshots, because nothing recorded what the clients had asked for.

**The browser client takes the same lease.** It shipped without one, rendering the Mac's grid at
a fixed 13px into whatever box the window happened to be: a browser narrower than the Mac ran the
session off its own frame and put the rest behind a scrollbar, and only resizing the *Mac* ever
changed it — `term.resize(msg.cols, msg.rows)` was the file's one sizing call, and it takes the
host's numbers. An interactive page now asks for the grid it can actually show, on connect and on
every window resize, clamped to the range the server validates so a request is answered rather
than refused as `invalidViewport`.

View-only clients never resize the process — the server refuses them a lease, which is the point
of the capability. So the browser gives them the other half instead: whatever grid the Mac
settled on, the page shrinks its own type until the whole of it, width and height, is inside the
frame. Height counts as much as width there, because the rows that fall off the bottom are the
live ones. A grid that already fits is restored to full size, which is also what returns an
interactive page to 13px once its lease is honoured.

The Mac and paired iPhone share one app appearance. Choose **Appearance** in the iPhone
dashboard's `…` menu or choose an app theme on the Mac; the other side changes immediately.
Resolved semantic colours, light/dark mode, corner radii, border weight and optional panel glow
are sent to both iOS and the browser. Terminal palettes remain session-scoped. A terminal
session's palette button on iPhone offers **Inherit**, **Follow App Theme**, and the Mac's theme
library, while session and project overrides still carry their full foreground, background,
cursor, selection and ANSI colours to the remote terminal. The iPhone keeps native system
typography rather than trying to transfer a Mac-only font. Application-owned iOS alerts and
confirmations use the same palette and live updates; their shared component and mandatory
extension policy are documented in [iOS themed dialogs](IOS_THEMED_DIALOGS.md).

Pairing and sharing are deliberately different actions:

- **Pair iPhone** is for your own trusted devices. A paired owner device sees your unarchived
  chats, can manage sessions and themes, and may approve bounded Native permission requests. Its
  credential remains paired across Mac/app restarts until explicitly revoked.
- **Share Chat…** in a session's `…` menu creates a single-use invitation for exactly that chat.
  Approval is a separate per-member, per-chat right: a trusted collaborator can review a complete
  Native permission request caused by their work without gaining settings, lifecycle, project, or
  other-chat access. The sheet names all three and says what each withholds, because the grant is
  the whole decision and a button title cannot carry it — "Collaborator + Approval" is a
  permission model written as a label, and nothing on screen used to connect it to *letting the
  agent run commands and change files without asking you*:

  | Grant | Can | Cannot |
  |---|---|---|
  | **View only** | Follow the chat as it happens | Type, send a prompt, or answer a permission request |
  | **Collaborator** | The above, plus typing in the terminal and sending prompts | Answer permission requests — those still come to you |
  | **Collaborator + approval** | The above, plus answering permission requests | — |

  View only waits for a running chat, and says so beside its dimmed button: a viewer cannot wake
  a dormant one, so there would be nothing to watch. The three live in `ShareLinkGrant`, which is
  what replaced a `switch` on the alert's button *index*.
- An unused invitation expires after 24 hours. Accepting it consumes that URL and creates a new
  device-bound membership without a 24-hour timer. The member keeps access until **Stop
  Sharing**, Remote Access is disabled, or the Mac app exits. Create another invitation for
  another person; forwarding an already accepted invite does not clone the membership. Guest
  memberships remain launch-scoped: turning Remote Access off or quitting the Mac revokes them.

Use **Open in Browser** to test the browser client without leaving the Mac. The owner pairing link
can also be copied from the pairing sheet, but it is intentionally not presented as a general
sharing action.

## Diagnostics sharing

iOS and the browser keep a small seven-day journal of typed connection events on that client.
They do not send it to the Mac by default. A paired interactive owner can open **Diagnostics** on
iPhone, or use the control beside the Mac in the browser session list, and choose **Share
diagnostics for 30 minutes**. The existing bounded history is sent first and new events follow
until the timer expires or **Stop sharing diagnostics** is chosen. Consent is memory-only, so
closing or reloading the client ends it early.

The receiver accepts no raw log strings. It permits only the versioned event vocabulary and
compact structural tokens, applies strict request/record/time bounds, replaces the authenticated
device id with a pseudonym, and appends the result to the Mac's separate share-safe support
journal. Messages, prompts, terminal output, paths, URLs, notification text and credentials are
never eligible. Guest and view-only links cannot upload diagnostics.

## Notifications

After pairing or accepting a shared chat, the iPhone dashboard explains what notifications do
before iOS is asked for permission. The system prompt appears only after **Turn on
notifications**. Notification settings keep three choices independent:

- a chat shared with this phone;
- a Native chat waiting for a permission decision;
- an update the user explicitly asked the agent to send.

Opening a notification deep-links to the relevant chat. Permission notifications intentionally
contain no command, path, tool arguments or diff on the lock screen, and do not offer lock-screen
Allow/Deny actions; the authenticated chat remains the place to review the evidence. Claude/Codex
permission prompts drawn inside their terminal UI are not parsed, so only Threading's structured
Native permission cards currently produce this notification.

When remote access is enabled, sessions also receive the `notify_user` MCP tool. It is for an
explicit request such as “notify me with a summary when you are finished”: the agent calls it
once the requested milestone has actually been reached, and still writes its normal answer in
the chat. “Me” defaults to the participant who wrote the current turn. A request may explicitly
target the owner, everyone in this chat, or another member by exact display name — useful when
the agent needs that person's input. Targeting never crosses the current chat, and delivery
requires that recipient to have enabled **Requested agent updates**.

Native remote prompts carry their member name to the provider while keeping the visible message
bubble clean, so the agent can resolve speaker-relative requests. Terminal attribution follows
the latest real input source; local keyboard input takes ownership back from a remote
controller.

While a shared Native chat is open, clients send ephemeral `typing`/`idle` presence over the
existing authenticated WebSocket. Other phones show **Name is typing…**. Presence is advisory,
expires with the connection, and never locks the composer or grants authority.

An open iOS app receives these events over its authenticated live socket. Background and
lock-screen delivery uses APNs. Development/self-hosted builds can enable the Mac's provider
with:

```sh
THREADING_APNS_KEY_ID=...
THREADING_APNS_TEAM_ID=...
THREADING_APNS_PRIVATE_KEY_PATH=/path/to/AuthKey_....p8
THREADING_APNS_TOPIC=codes.threading.mobile
```

The topic is optional and defaults to the iOS bundle identifier above. Without provider
credentials the settings page says **Live only**: events still work while the authenticated
connection is alive, but a suspended app cannot receive a remote push. A distributed build
should move the provider key to a stable relay rather than ship it in either app.

### Hosted Firebase service

Firebase is a sensible production transport, but not the chat's source of authority:

- Firebase Authentication gives invitations a real recipient identity and enables “shared with
  you” push before the link is opened.
- Cloud Functions plus FCM hold the APNs provider secret and deliver background notifications.
- Realtime Database can hold short-lived presence at
  `/presence/<chat>/<member>` with server timestamps, `onDisconnect` cleanup and strict
  membership security rules. The current direct WebSocket remains the lower-latency path while
  both peers are connected.
- The Mac remains authoritative for session contents, permission evidence and actual tool
  decisions. Realtime Database must not become a public transcript store or an alternate way
  around a revoked membership.

This also gives a clean product boundary for an open-source app: direct/local and self-hosted
remote access remains available, while an official paid iOS/hosted service can sell reliable
rendezvous, account-backed invitations, push delivery and cross-network presence. Payment buys
operated infrastructure and convenience, not a proprietary chat format or an artificial local
feature lock.

## Security model

- The remote server listens only on `127.0.0.1` and is separate from Threading's MCP and extension
  servers.
- In **Relay** or **Both**, `cloudflared` opens an outbound tunnel to that one listener. No router
  port or inbound firewall rule is opened. Traffic passes through Cloudflare, where TLS is
  terminated, so use that transport only for work you are comfortable sending through it.
- In **Tailscale** or **Both**, Tailscale Serve exposes the same listener as HTTPS/WSS on dedicated
  port 8443, reachable only according to the tailnet's identity and ACL policy. Threading removes
  only that exact Serve handler when it stops and never runs `tailscale serve reset`, which could
  erase unrelated services. Tailscale still relays encrypted WireGuard traffic when peers cannot
  connect directly. Enabling Tailscale HTTPS publishes the machine/tailnet DNS name in public
  certificate-transparency logs; it does not publish chat contents or make the service public.
- Every launch mints a random 128-bit, one-time owner bootstrap, and every chat invite mints an
  independent random 256-bit single-use token scoped to one session. It arrives in the URL
  fragment, so the browser does not include it in its initial HTTP request or referrer. On
  acceptance the host replaces it with a fresh 256-bit device-bound bearer. Native owner
  credentials live in Keychain on both Mac and iPhone; browser owner access remains tab-scoped.
  The fragment is removed from the address bar and history.
- The owner bootstrap is base32 and 128-bit rather than base64url and 256-bit *because it has to be
  photographed*. Its whole payload is a QR code, and QR's alphanumeric mode — 5.5 bits per
  character against byte mode's 8 — has no lower case, so a mixed-case token forces the densest
  possible symbol. Written as base32, alongside an upper-cased scheme and host
  (`RemoteConnectionLink.scannablePayload`), a median relay host encodes in 37 modules instead of
  41. It remains an unguessable online-only bootstrap held in memory, is accepted once (with a
  short same-device retry window for a lost response), and rotates immediately. Invitation and
  durable device bearers remain 256-bit base64url: they travel by copied link or protocol
  exchange, never by camera, so they buy nothing from the QR trade.
- **The 128-bit choice is forced by the host, not by the token, and should be revisited when the
  relay moves to a short custom domain.** A 52-character `trycloudflare.com` hostname is most of
  the payload, which is what leaves the token paying for the last version. Measured at level M
  against a `k7m2qx.threading.app`-shaped origin: 33 modules with a *256-bit* base32 token — still
  better than the 41 this shipped with — and 29 with the current 128-bit one. So once the host
  shortens, full 256-bit entropy costs one version rather than four, and going back to it is the
  cheaper side of the trade. Upper-casing the origin keeps earning either way (a bare
  `threading.app` with the old base64url token is 37 lower-case against 33 upper-case).
- API and WebSocket access require the accepted bearer and matching device id. Only a paired
  interactive all-sessions owner may
  create, rename, pin, archive or restore sessions, or select the shared app appearance and a
  session's visual terminal theme. Workspace browser metadata and bounded visible-tab snapshots,
  plus checkout reads including Git Review, repository files, and detected image/PDF attachments,
  also require that owner scope. View-only and guest links cannot change host state, read checkout
  files, or receive browser pixels. Permanent deletion remains a Mac-only action.
  Archiving a live session immediately disconnects any remote viewer already attached to it.
- Authentication failures are rate-limited globally and per device, and slow WebSocket consumers
  are dropped instead of being allowed to back-pressure an agent's terminal.
- Unused invitations expire after 24 hours; accepted guest memberships do not expire while that
  launch continues. Stopping a share, turning Remote Access off, or quitting Threading revokes
  guest memberships and disconnects every open socket immediately. Paired owner credentials are
  suspended while the listener is off and reloaded from Keychain next time; revoke the named
  device in Settings to remove one permanently.

Treat the owner QR code and every copied share URL like passwords. The owner code is intentionally
much stronger than a guest URL; only show it to devices you control.

## Beta limitations

The automatic relay still uses a Cloudflare Quick Tunnel. Quick Tunnels are intended for
development and testing, have no uptime guarantee, and receive a new public hostname whenever
Threading starts. The durable device credential survives, but an iPhone paired to that old origin
cannot discover the new Quick Tunnel and must scan again. The planned stable Cloudflare hostname
can replace this transport without changing pairing or authorization. Tailscale already has a
stable tailnet origin, so an owner paired through Tailscale reconnects after a Mac/app restart
without rescanning as long as Tailscale is available on both devices.

On iPhone, Tailscale must be connected before its `*.ts.net` origin is reachable. iOS permits only
one active packet-tunnel VPN at a time, so another VPN may prevent that connection; use Relay in
that situation.

An operated release can add account-backed rendezvous and invitations. Without recipient
accounts Threading cannot
push to a friend *before* they accept a share link; their messaging app carries the invitation,
then Threading registers that accepted capability and can notify the device from then on.

Remote access cannot wake a sleeping or offline Mac. A remotely resumed session starts in the
background and does not activate or bring Threading's Mac window to the front.

Remote session creation intentionally exposes only checkouts the Mac already knows. Git Review,
the read-only repository browser, detected image/PDF previews, and browser follow snapshots have
separate owner-only and size boundaries; file surfaces additionally enforce path containment.
Phone-to-Mac attachment uploads, arbitrary filesystem access, browser control from the phone, and
private browser pixels are not exposed.

If `cloudflared` is not installed, local browser mirroring still works. Install it with:

```sh
brew install cloudflared
```

For Tailscale mode, install and sign in to Tailscale on the Mac and iPhone, enable HTTPS for the
tailnet, and make sure its ACLs allow the iPhone identity to reach the Mac. Threading invokes the
local `tailscale` CLI; it does not sign in, change tailnet ACLs, or enable the VPN for you.

At the server boundary, socket parsing remains on one serial network queue. Successful
authentication publishes one immutable `RemoteAuthenticatedPeer` under a lock — authorization,
device id, display name and authentication time become visible together. Main-actor sharing and
notification code reads that snapshot once per decision; it never assembles an identity from
independently mutable connection fields.

## Implementation map

- `Sources/Threading/Core/Remote`: loopback HTTP/WebSocket server, durable owner-device registry,
  authentication, pluggable Cloudflare/Tailscale transports, routing and live session mirrors.
- `Sources/Threading/Resources/RemoteClient`: dependency-free browser client.
- `ThreadingRemoteKit`: versioned wire DTOs and pairing-link parsing shared by macOS and iOS.
- `Sources/ThreadingMobile`: SwiftUI iOS shell, UIKit Native-conversation timeline and SwiftTerm
  terminal surface.
- `docs/NOTIFICATION_E2E.md`: opt-in real APNs and Claude → MCP → APNs verification.
- `docs/REMOTE_DIAGNOSTICS.md`: privacy boundary, cross-device tracing and support workflow.
