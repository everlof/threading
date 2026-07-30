# Remote access

Remote access mirrors Threading sessions to a browser or to the native `ThreadingMobile` iOS app.
It is an opt-in beta feature: open the dedicated **Settings → Remote Access** page on the Mac
and turn on **Remote Access**. The page follows the local listener and secure relay live, then
shows the iPhone pairing code in place once the connection is ready.

## Pair an iPhone

1. Keep Threading running on the Mac.
2. Wait for the Remote Access status to say the secure relay is ready.
3. In Threading on the iPhone, choose **Pair a Mac** and scan the QR code shown on the page.

The iOS app stores the paired host and bearer token in the Keychain. It shows all unarchived
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
  chats, can manage sessions and themes, and may approve bounded Native permission requests.
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
  another person; forwarding an already accepted invite does not clone the membership.

Use **Open Locally** to test the browser client without leaving the Mac. The owner pairing link
can also be copied from the pairing sheet, but it is intentionally not presented as a general
sharing action.

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
- `cloudflared` opens an outbound tunnel to that one loopback listener. No router port or inbound
  firewall rule is opened. Remote session traffic passes through Cloudflare's relay, where TLS
  is terminated, so use this beta only for work you are comfortable sending through that service.
- Every launch mints a random 128-bit owner-device bearer token, and every chat invite mints an
  independent random 256-bit single-use token scoped to one session. It arrives in the URL
  fragment, so the browser does not include it in its initial HTTP request or referrer. On
  acceptance the host replaces it with a fresh device-bound membership bearer. iOS stores that
  bearer in Keychain; the browser stores accepted guest membership for that origin while keeping
  owner pairing tab-scoped. The fragment is removed from the address bar and history.
- The owner token is base32 and 128-bit rather than base64url and 256-bit *because it has to be
  photographed*. Its whole payload is a QR code, and QR's alphanumeric mode — 5.5 bits per
  character against byte mode's 8 — has no lower case, so a mixed-case token forces the densest
  possible symbol. Written as base32, alongside an upper-cased scheme and host
  (`RemoteConnectionLink.scannablePayload`), a median relay host encodes in 37 modules instead of
  41. 128 bits remains an unguessable online-only bearer held behind a secret relay hostname,
  in memory, revoked when Remote Access stops. Invitation and device bearers are unchanged at
  256-bit base64url: they travel by copied link, never by camera, so they buy nothing from it.
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
- Unused invitations expire after 24 hours; accepted memberships do not. Stopping a share,
  turning Remote Access off, or quitting Threading revokes the relevant membership tokens and
  disconnects already-open sockets immediately.

Treat the owner QR code and every copied share URL like passwords. The owner code is intentionally
much stronger than a guest URL; only show it to devices you control.

## Beta limitations

The automatic relay uses a Cloudflare Quick Tunnel. Quick Tunnels are intended for development
and testing, have no uptime guarantee, and receive a new public hostname whenever Threading starts.
The iPhone therefore needs to be paired again after the Mac app restarts. A production release
should replace this with an account-backed stable relay or a rendezvous service, named-device
approval/revocation, and account-backed invitations. Without recipient accounts Threading cannot
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

## Implementation map

- `Sources/Threading/Core/Remote`: loopback HTTP/WebSocket server, authentication, relay lifecycle,
  routing and live session mirrors.
- `Sources/Threading/Resources/RemoteClient`: dependency-free browser client.
- `ThreadingRemoteKit`: versioned wire DTOs and pairing-link parsing shared by macOS and iOS.
- `Sources/ThreadingMobile`: SwiftUI iOS shell, UIKit Native-conversation timeline and SwiftTerm
  terminal surface.
- `docs/NOTIFICATION_E2E.md`: opt-in real APNs and Claude → MCP → APNs verification.
- `docs/REMOTE_DIAGNOSTICS.md`: privacy boundary, cross-device tracing and support workflow.
