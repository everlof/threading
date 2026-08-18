# Remote access

Remote access mirrors Threading sessions to a browser or to the native `ThreadingMobile` iOS app.
It is an opt-in beta feature: open the dedicated **Settings → Remote Access** page on the Mac,
choose a connection, and turn on **Remote Access**:

- **Hosted Direct** becomes the native owner-device default after Sign in with Apple. It uses the
  Threading service only for identity, ICE signaling and TURN fallback; ordinary traffic goes
  directly between iPhone and Mac whenever ICE succeeds.
- **Relay** keeps the existing Cloudflare path and supports ordinary public share links.
- **Tailscale** publishes Threading only inside the owner's tailnet. It is the private option for
  owner devices and can also share a chat with somebody already in that tailnet.
- **Private + Sharing** uses Tailscale for owner pairing and starts the public relay only when a
  one-chat link is created. **Owner Relay Fallback** and **Keep Sharing Relay Ready** are separate,
  off-by-default controls for people who prefer availability over the fail-closed private path.

All transports terminate at the same loopback server, protocol and authorization checks. A transport
changes who can route packets to Threading; it never expands what a bearer may do.

## Pair an iPhone

1. Keep Threading running on the Mac.
2. For zero-install access, sign in with Apple under **Hosted Direct**. Relay and Tailscale remain
   optional compatibility/private choices; their readiness cards identify setup problems.
3. In Threading on the iPhone, choose **Pair a Mac** and scan the QR code shown on the page.

**A reason never lives only in a readiness row.** `TailscaleReadinessIssue` carries the row's
line, the failure stated as a fact, the remedy, the row it belongs to, and the title of the page
that fixes it; the readiness card and the pairing panel both read that one value, and
`RemotePairingCardState.connectionUnavailable` carries the resulting sentence and the optional
remedy into the panel beside **Retry Connection**. Before that, the panel said only "Private
connection unavailable" while "Enable Tailscale Serve for this tailnet" sat three rows above it.

**Coming up is a state with a fact in it.** The transport observes the command it is running and
nothing more: it has `tailscale status` in flight, or it has asked `tailscale serve` to publish
and has not been answered. It does not probe the tailnet HTTPS endpoint, so the page says what it
is waiting for rather than claiming to know why — `TailscaleReadiness.startupStatement` is that
sentence, shown by the status row, the readiness row and the pairing panel alike, and it changes
when the command's stage changes rather than on a timer. The publish stage also gets its own
90-second ceiling (`RemoteTailscaleDefaults.publishTimeoutSeconds`) because a tailnet's *first*
certificate issuance was measured at close to a minute, and the twelve seconds every other
command gets had the app killing Serve and reporting a failure while the door was still opening.

The hosted QR carries two independent scopes in its URL fragment: a temporary rendezvous-only
credential that can form an encrypted ICE/TURN route to this Mac, and the existing one-time owner
bootstrap that must still be redeemed by the loopback remote server. The Mac exchanges the
bootstrap for a unique 256-bit, device-bound owner credential, rotates the code, issues the
phone's durable hosted credential, and revokes the temporary pairing route. Relay/Tailscale QR
codes redeem the same owner bootstrap over their selected route. The Mac stores the device record
in the login Keychain and iOS stores the paired host and its credentials in its Keychain. Pairing therefore
survives a Threading restart and also survives turning Remote Access off and back on. Settings
lists each paired owner device with an explicit **Revoke** action; **Reset Everything** also
deletes the Mac-side owner credentials. A browser owner pairing deliberately remains tab-scoped.
Any number of named iPhones and iPads can be paired with the same Mac. They use independent
device-bound credentials, can connect at the same time, and appear separately in Sharing and
diagnostics; revoking one does not disturb the others.

Those devices can also participate in the same session at once. Input control is a live,
per-session choice rather than something fixed when the chat starts:

- **Collaborative** lets every participant with reply access send. Native prompts and the
  iPhone/browser terminal composers still submit atomically, so two drafts cannot splice into
  one prompt or terminal line.
- **Focused** names one controlling person. Everyone else can continue watching and editing a
  private draft, but Send, raw terminal keys, paste, drop, mouse reporting and remote PTY writes
  are rejected at the Mac until control is handed over. The current controller or the owner can
  hand off; the owner can always reclaim or return the session to Collaborative.

Choose the default for newly shared sessions under **Settings → Remote Access → New shared
chats**. The owner can switch the current session from its **Sharing** pane; iPhone and browser
controls expose the actions each signed-in person is allowed to take. Ownership is per person,
not per socket: two paired owner devices share the owner's authority, and two tabs belonging to
one accepted member share that member's turn. Closing one tab therefore does not release their
control. If a guest controller's last connection disappears, Threading holds the turn for 30
seconds so an ordinary route change or Tailscale reconnect does not steal it, then returns it to
the owner. Revoking that member returns it immediately.

A watcher can choose **Request control**. That is the same human-only attention path as the
explicit **@** action: it sends no prompt and no terminal bytes, and the current controller's
independent **Requests for my input** notification preference decides whether it also becomes a
push. Mode changes and handoffs themselves are quiet live collaboration events, not new push
categories. Focused mode does not attempt to recognize questions drawn by a Claude Code or Codex
TUI; only structured Native questions/permissions and explicit human requests can create the
corresponding notifications.

An owner pairing is stored as one logical Mac identity, not as one hostname. iOS attempts its
durable hosted ICE/TURN credential first, then only the Relay/Tailscale endpoints allowed by the
owner's selected fallback policy. Owner responses
advertise the currently usable Tailscale and/or relay endpoints plus an explicit `privateOnly`,
`relayOnly`, or `preferPrivate` policy. The iPhone orders only HTTPS endpoints allowed by that
policy, prefers Tailscale when requested, records the successful route, and can move to another
advertised route without creating a duplicate device. Unknown future policies fail closed to
private-only. Guest shares never receive the Mac's private endpoint list.

The iOS app shows all unarchived
sessions grouped by project or ordered by recent activity, including dormant sessions. Pinned sessions
stay at the top on both Mac and iPhone, and the archive is available from the dashboard.

**A row says who is talking, the way the Mac sidebar does.** Its tile is the runtime's own mark —
Claude's starburst, OpenAI's knot, an SF Symbol for a runtime we bundle no artwork for — with an
alternate account's chip on the bottom-trailing corner and the account's name beside the state. The
Mac resolves that chip (`RemoteAccountBridge` → `RemoteSessionAccountDTO`: the emoji the login was
given, else its initial and the hue `AccountBadge` hashes from the login address), so one login looks
the same on both screens instead of two hash implementations agreeing until one is edited. A
discovered avatar stays on the Mac: it would be image bytes per row. As in the sidebar, the CLI's
**default** login sends no chip at all, which is also what keeps the projection off the account
directories for most rows.

Before this the tile was a **terminal glyph on every chat**, because a mirrored agent TUI and a plain
shell were drawn with the same icon — so a list of Claude and Codex chats looked like a list of
shells and named neither provider nor login. `terminal` now means a terminal: it marks the *surface*
in the row's second line, beside a speech bubble for a natively rendered conversation, and
`MobileAgentIdentity` owns the runtime half of that vocabulary. The row is also two lines tall and
fixed — a three-line title over a 46-point tile made rows up to 110 points, and five chats filled a
phone screen.

**The surface is a type, not a string.** `RemoteSessionSurface` (`.terminal` / `.conversation`)
replaces the `surface == "conversation"` comparisons that were spread across both apps and five
DTOs. It stays a string *on the wire*: a newer Mac may show a surface an installed phone has never
heard of, and that row must decode, list and round-trip rather than fail the whole payload. Leniency
runs one way — an inbound create or switch naming an unknown surface is refused (`isKnown`) rather
than guessed at.
On a paired owner device, the dashboard's options menu also offers **Usage** when the Mac
advertises support. It opens the Mac's prepared 7-, 30- and 90-day Overview and Limit History in a
native iPhone sheet. The phone receives bounded semantic totals and chart points, not transcripts,
filesystem paths, credentials or the raw limit journal. Banked resets show the selected
account/window's current inventory and nearest expiry; zero is distinct from unavailable, and a
historical banked-reset marker means a credit was observed being used rather than merely being
available. One-chat guest links cannot discover or read this whole-host data.

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
toolbar buttons. The session screen keeps a single trailing **…** control for the same reason:
Workspace and the terminal palette are entries in that menu rather than glyphs of their own,
because three of them plus a back button left the session's name a truncated stub at phone width.
A swipe in from the right edge opens Workspace without the menu, and the menu still appears for
any of the three permissions that used to reveal a button of its own — a share that may recolour
a terminal without managing the session still gets it. When an agent opens or navigates a browser
tab, the phone never changes screens: the **…** control receives one quiet pulse and an unread
dot. Opening **Browser** follows the
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
In Focused mode only the controlling person's devices participate in that resize lease, so a
watcher's narrow window cannot reflow the controller's TUI. A Tailscale/relay route change does
not change the person's control identity; reconnecting receives the Mac's authoritative current
mode before input is accepted.

Entering a terminal-backed session commits the navigation destination without a width animation.
A navigation push that reveals the destination through intermediate widths is not cosmetic for a
terminal: every width becomes a SwiftTerm grid, a viewport message, a PTY resize/SIGWINCH and a
full-screen agent repaint. The immediate route installs the one useful final grid. Native
conversation sessions retain the standard navigation transition because their virtual rows do not
control a remote process viewport.

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

**Scrolling a mirrored TUI needed both halves of what the Mac does, and the phone had neither.**
An agent's terminal is scrolled two different ways depending on who owns the wheel. When the
program tracks the mouse — Claude Code does — the wheel belongs to it and it moves its own
transcript; otherwise the wheel moves the terminal's local scrollback. On iOS SwiftTerm draws the
whole buffer inside a `UIScrollView`, and it pinned the offset to the bottom on every emulator
scroll, so a session that was producing output could not be scrolled back at all: each line undid
the drag. A drag over a mouse-tracking program was reported as a press and a drag, which is a
selection gesture and moves nothing. Both are fixed in the fork — see
[`dependencies.md`](architecture/dependencies.md) — and the touch mapping now reads: one finger
scrolls the program when it is tracking the mouse and the mirror's own scrollback when it is not,
two fingers always scroll the mirror.

A joining client is seeded with a repaint of the *visible screen* (`RemoteScreenSeed`), which
carries no DEC private modes, so a phone that connects to an already-running agent does not know
the program is tracking the mouse until the program says so again. Until it does, one finger
scrolls the phone's own mirror rather than the agent's transcript. Both scroll something, which is
why this is a fidelity gap rather than a broken surface, and seeding the sticky modes beside the
repaint is what closes it.

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

The first-run iPhone screen exposes **Settings** before any connection exists. App icon,
notification preferences, in-app presence/typing, independent terminal drafts and local
diagnostics are useful without a Mac and stay available from the dashboard's `…` menu after
pairing. The stock icon picker is manual because iOS confirms every icon change; when a connected
Mac uses a built-in style, the picker names that style as the matching choice.

The Mac and paired iPhone share one in-app appearance. Choose **Appearance** in the iPhone
dashboard's `…` menu, use **Settings → Mac appearance**, or choose an app theme on the Mac; the
other side changes immediately.
Resolved semantic colours, light/dark mode, corner radii, border weight and optional panel glow
are sent to both iOS and the browser. Terminal palettes remain session-scoped. A terminal
session's palette button on iPhone offers **Inherit**, **Follow App Theme**, and the Mac's theme
library, while session and project overrides still carry their full foreground, background,
cursor, selection and ANSI colours to the remote terminal. The iPhone keeps native system
typography rather than trying to transfer a Mac-only font. Application-owned iOS alerts and
confirmations use the same palette and live updates; their shared component and mandatory
extension policy are documented in the [iOS theme boundary](IOS_THEMED_DIALOGS.md), together
with the themed settings chrome, the sheet-crossing rule and what a theme may say about the
system keyboard.

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
  device-bound membership without a 24-hour timer. Unused invitations and accepted memberships
  are stored in the Mac login Keychain, so turning Remote Access off, restarting Threading, or
  changing between Tailscale and Relay suspends the route without silently removing the share.
  The member keeps access until **Stop Sharing** or their named membership is revoked. Create
  another invitation for another person; forwarding an already accepted invite does not clone
  the membership. A credential that cannot be restored exactly fails closed rather than creating
  a replacement identity.

Use **Open in Browser** to test the browser client without leaving the Mac. The owner pairing link
can also be copied from the pairing sheet, but it is intentionally not presented as a general
sharing action.

## Starting a chat from the phone, and seeing it work

**Start opens the chat it started.** The New Session sheet's Start used to create the session and
then leave you on the dashboard, watching a row appear. The Mac answers the create with the new
session's id *and* the whole refreshed catalogue, so the row the navigation stack resolves against
is already published by the time the sheet closes; the push therefore needs nothing but the
result Start already had. It waits for `onDismiss` rather than pushing from the submit, because a
push ordered while the sheet is still on screen is dropped by the stack. Tapping a row and
starting a chat now go through one function, so a new chat is opened with the transition its
surface can survive — a terminal still commits its final geometry immediately rather than being
resized through every intermediate width. The session's own screen owns the wait: a brand-new
session is not yet running, so it shows "Resuming on your Mac…" until the agent answers.

**The chat's title says when the agent is working.** The navigation title's status line carries
the dotted thinking orb — the same mark, the same nine animations and the same accent tint as the
Mac's conversation status — while a turn is in flight. One variant is chosen per turn and never
repeats the previous turn's.

It stands **in the connection dot's place**, not beside the title. Beside the title it took a
column of its own and pushed the session name off the bar's centre every time a turn started, and
it left two marks on one line saying two different things at once. In the dot's place it costs no
width and the title never moves; the dot has nothing to add meanwhile, because the orb only ever
appears on a connected session, which is what the green dot was there to say. It is drawn at the
caption line's size rather than the preset's own 20pt, since a taller status line would push a
two-line title past the 44pt bar.

The phone is never told "working" in words: no status word crosses the wire. What does cross is
`canSend`, which each transport defines as `isRunning && input != nil && !isTurnInFlight &&
pendingPrompt == nil` and the Mac then narrows to the asking viewer's own capability. So a client
that *would* be allowed to type and is told it cannot is being told a turn is in flight, and that
is the reading `MobileAgentTurnActivity` encodes. Both narrowings matter as much as the signal: a
view-only viewer is sent `canSend: false` with no turn running at all, and a collaborator holding
Focused input control makes it false for everyone else. Neither is the agent working, so both
answer no rather than spinning an orb about someone else's keyboard. Our own prompt still being
acknowledged answers yes, because that turn has begun on this side before the Mac has said so.

## Sending a file from the phone

The composer's paperclip attaches a photo or a document to the next prompt. It is the only route
by which a remote client can cause the Mac to keep a file, so it is worth saying exactly what it
does and where it stops.

**The bytes go over first, and the prompt names them afterwards.** `POST …/attachment-upload`
carries one chunk of base64 inside the same JSON envelope every other mutation uses; chunk 0
mints a host-side upload id and later chunks carry it. The transfer is chunk-shaped even though a
phone normally re-encodes an image small enough for one request — a single-shot upload is chunk 0
of 1 — so full-fidelity transfer stays an additive client change rather than a second route. The
prompt then carries upload **ids**, never paths: a client never learns where a file landed, so it
cannot name one it did not send or one belonging to another session.

**Nothing is attached until a prompt claims it.** A completed upload waits in a staging directory
under the app's own temporary directory. Claiming happens on the server queue before the main
actor is touched, so two submissions racing for the same upload cannot both name it. An abandoned
transfer — a draft never sent, an app killed mid-upload — is reaped after thirty minutes with its
bytes, and staging is emptied outright when Remote Access stops. That is the property that keeps
an interrupted attach from leaving a half-sent picture in somebody's conversation.

**What the host will take:**

| Bound | Value | Why |
|---|---|---|
| Scope | paired owner device, `allSessions`, `interact` | The feature is not advertised to a view-only or guest connection, so its composer draws no paperclip rather than one it would be refused for. |
| Per file | 24 MB | The ceiling the download side already applies. Declared up front, so an oversized transfer is refused on its first chunk. |
| Per message | 8 files | Also the bound on the phone's strip; `RemoteAttachmentUploadLimits` is shared so the two cannot drift. |
| In flight | 24 uploads | Beginning one past the cap is refused rather than evicting somebody else's staged file. |
| Type | whatever the attachments pane can show | The extension is re-derived from the declared uniform type and the assembled bytes are put through `AttachmentReferenceDetector.kind(for:)` — the same question the scanner asks. A `.command` renamed `photo.png` lands nowhere. |

Every refusal answers `400` with no detail. Saying which bound was hit would let something that
has not proved it owns any staged state enumerate the host's: whether an id exists, whose device
it belongs to, how far a transfer got.

**A claimed upload becomes an ordinary user attachment.** The host hands it to
`SessionAttachmentStore` through the declared door with `origin: .user` and appends its quoted
path to the prompt — the identical contract `PromptView.submittableText` uses on the Mac, shared
through `ComposerAttachmentHandover`. So a picture sent from a phone reaches the agent as the same
prompt it would have from the Mac, and appears in the Attachments tab beside what the agent makes
of it. If custody cannot be taken for every file, the submission is rejected rather than sent
without them: someone who attached a picture and pressed send meant to send the picture.

## Diagnostics sharing

iOS and the browser keep a small seven-day journal of typed connection events on that client.
Every connect attempt ends in one of them: connected, ended, or failed with a stated reason, so a
phone that never reached the Mac leaves a record rather than a silence. Each carries the kind of
route it used and a hash of the address it aimed at, never the address itself.
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

## Reporting a problem from the phone

Shaking the iPhone opens a report sheet. Everyone can send it to Threading's private intake or
share the files. An owner device that may manage sessions, and that can see the Threading project
on the paired Mac, also gets **Send to Mac**: the report becomes the opening prompt of a new chat
in that project, screenshot path and all.

**What that chat comes up as is the Mac's answer, forwarded by the phone.** The phone used to
choose out of two literals — Codex, and the standard login — which is how a report could land on
an agent nobody had used in weeks. The catalogue now publishes the answer per project, as
`RemoteProjectChoiceDTO.reportLaunch`:

- **Launch choices inherited from the chat most recently used in that project**
  (`InheritedLaunchConfiguration`, shared with the development build's own report chat): agent,
  login, model, reasoning level, speed, permission mode and surface. Anything this Mac would
  refuse on arrival is dropped before it is published, so a signed-out login or a retired model
  costs the reporter nothing.
- **The workspace chosen in Remote Access settings** under *Reports from your phone*: the
  project's own checkout, or a worktree of its own that is either merged when the agent finishes
  or kept for review. It is offered only where the checkout can host a worktree and the agent can
  perform the finish handshake. See
  [managed-workspaces.md](architecture/managed-workspaces.md).

The request carries the workspace back as `RemoteCreateSessionRequestDTO.managedWorkspace` and
`handleCreateSession` validates it again rather than trusting what the catalogue produced.
Publication is refused on this route: a phone cannot open a change request.

## Notifications

Notification preferences can be set before pairing from the iPhone's Settings. If permission is
still undecided after pairing or accepting a shared chat, the dashboard explains what
notifications do before iOS is asked. The system prompt appears only after **Turn on
notifications**. Notification settings keep five choices independent:

- a chat shared with this phone;
- a Native chat waiting for a permission decision;
- a session whose provider-neutral activity state changed to waiting for the user's response;
- another participant explicitly asking for this person's input;
- an update the user explicitly asked the agent to send.

The response-needed event is an activity edge supplied by the hook/BEL/session layer; the
notification service never scrapes Claude Code or Codex terminal text. A structured Native
permission request uses its more specific permission notification instead of also sending the
generic response-needed event. Notification sounds have a master switch and an independent
switch for every category, so a useful banner does not have to imply an audible interruption.

Opening a notification deep-links to the relevant chat. A requested agent update may additionally
carry one closed, authenticated destination: an attachment id, a browser-tab id, or an extension
and panel id. These are Threading-owned identities, not an agent-authored path, URL, or application
deep link. Each client resolves the destination again inside the named session and presents it in
its own navigation: the Mac reveals the current panel/drawer/window host, while iPhone pushes an
attachment preview, Browser Follow, or a native rendering of the extension SDK's semantic panel
tree. The extension process stays on the Mac and iPhone relays native control events back to that
exact process generation. A restart restores the newly registered panel before another action can
run. Companion pixel surfaces are not streamed to the phone: their required semantic root remains
the mobile fallback, and an isolated `customSurface` truthfully stays Mac-only.

Permission notifications intentionally
contain no command, path, tool arguments or diff on the lock screen, and do not offer lock-screen
Allow/Deny actions; the authenticated chat remains the place to review the evidence. Claude/Codex
permission prompts drawn inside their terminal UI are not parsed, so only Threading's structured
Native permission cards currently produce this notification.

Sessions receive the `notify_user` MCP tool. It can post to this Mac without Remote Access; iOS
delivery additionally requires Remote Access and an eligible paired phone. The tool is for an
explicit request such as “notify me with a summary when you are finished”: the agent calls it
once the requested milestone has actually been reached, and still writes its normal answer in
the chat. “Me” defaults to the participant who wrote the current turn. A request may explicitly
target the owner, everyone in this chat, or another member by exact display name — useful when
the agent needs that person's input. Targeting never crosses the current chat, and delivery
requires that recipient to have enabled **Requested agent updates**.

Display and navigation tools return an opaque, session-scoped `target_ref` after they have
successfully produced something addressable. `display_image` and `display_html` capture immutable
Attachments; `browser_navigate` names the live browser tab; activating a Browser or extension tab
does the same for that live surface. Passing that reference to `notify_user` binds the notification
to the already-resolved object. The reference cannot be manufactured from a filesystem path or
URL, expires from a bounded in-memory registry, and cannot be consumed by another session.
`delivery` is `mac`, `ios`, `both`, or `auto`; `auto` currently means both, and each delivery is
reported independently so a disabled phone path does not suppress an allowed Mac notification.
For an extension target, tapping on iPhone fetches the registered `ExtensionPanel` over the
owner-authenticated session route, validates the SDK node budget again, and renders native SwiftUI
text, controls, disclosures, images, and scenes. Package images use a separate bounded resource
route; neither package paths nor arbitrary URLs are accepted as notification destinations.

The explicit `@` control beside the iPhone or browser composer is a different path. It opens an
**Ask for input** sheet over both Native and agent-UI terminal sessions, lists interactive chat
members even when they are currently away, and sends an app-owned `attentionRequest` frame to the
selected stable member id. The optional note is notification copy. It is never inserted into the
Native prompt, never parsed out of composer text, and never written to the PTY; typing a literal
`@` in Claude Code or Codex therefore retains its ordinary terminal meaning. The sheet states this
boundary before sending.

A deliverable request produces a targeted live/APNs notification and one quiet collaboration
event in every currently open view of that chat. It does not become an agent transcript row.
**Requests for my input** is independent from requested agent updates, permission requests and
share notifications. A person who is online can receive the in-chat event without push; an away
person must have that notification kind enabled. Repeating the same request id is idempotent, and
new requests from the same participant to the same person are collapsed for 30 seconds. The
initial slice records delivery and visibility, not assignment, ownership or a task workflow.

**That idempotency is a bounded map, and its eviction had to be counted from both sides.**
`RemotePromptReplayCache` and `RemoteAttentionRequestPolicy` each keep an `entries` dictionary
beside an `order` array, and both dropped a re-stored key from `order` *before* the eviction loop
read `entries.count`. The count therefore still said "full", so re-storing a key already held
evicted the oldest **other** entry to make room for something that needed none — and this is the
ordinary path, not an edge: every prompt stores its key twice, once when it is accepted and again
when its status settles. What went with the evicted entry was its replay state, so the next retry
of that unrelated request read as new and was run a second time — a prompt submitted twice, or a
person poked twice. Both tests that covered these caches stored each key exactly once, which is
precisely why neither saw it.

Native remote prompts carry their member name to the provider while keeping the visible message
bubble clean, so the agent can resolve speaker-relative requests. Terminal attribution follows
the latest real input source; local keyboard input takes ownership back from a remote
controller.

While any shared session is open, the Mac sends an ephemeral roster over the existing
authenticated WebSocket. A distinct presence id represents every live device or browser tab, so
one person's iPhone and iPad can appear and leave independently. Clients announce `typing`/`idle`;
other phones show the device-aware participant label and otherwise show who is viewing. Presence
is advisory, expires with the connection, and never locks a composer or grants authority. The
iPhone lets people-presence and typing indicators be hidden separately.

Each remote Native composer owns its draft. The iPhone's terminal also uses an independent local
composer by default and sends the completed text plus Return as one PTY write. This does not make
the terminal multi-user: it creates a safe atomic boundary at submission so concurrent devices
cannot interleave individual characters. The key bar's controls remain immediate terminal
controls. **Independent terminal drafts** can be disabled in the iPhone's collaboration settings
when raw direct terminal typing is required.

The key bar itself is a customizable, Termius-style keyboard, and deliberately exceeds Termius's
model where agent TUIs need it: a key can be a *chord* (⇧⇥ — Claude Code's permission-mode
cycle, which Termius cannot put on its bar at all), a snippet that types saved text and
optionally submits it, a raw escape sequence, or a latching ⌃/⌥ that arms for the next key —
including the next keystroke typed on the system keyboard — locks on a second tap, and releases
on a third. `RemoteTerminalKeyboard` in `ThreadingRemoteKit` owns the model and the sequence
encoder (xterm `;N` modifier parameters, DECCKM-aware arrows/Home/End — the fixed bar this
replaced always sent normal-mode arrows); `MobileTerminalKeyboardStore` persists custom layouts
per agent kind with the continuity store's versioned/quarantined archive pattern. Layouts are
device-local on purpose — a phone and an iPad earn different bars — and the stock layout per
agent kind returns on reset. The archive has one 1 MiB encoded ceiling plus layout/key/string
cardinality checks; duplicate key identities and oversized actions are refused without replacing
the active or durable layout. Keys ride the existing `input` frame, so the server's
capability/Focused-mode/size checks apply unchanged and no protocol bump was needed.

It is the only bar over the keyboard. SwiftTerm fits its own `TerminalAccessory` — a fixed
esc/ctrl/tab/arrow row — from `TerminalView`'s initializer, which stacked a second row of nearly
the same keys under this one; `RemoteTerminalView.dropBuiltInKeyboardAccessory()` clears it
through SwiftTerm's own documented assignment seam, once, because that is the only place it is
installed. The dismiss control that row carried moves onto the key bar, where it appears only
while a keyboard is actually up: the terminal is a first responder rather than a focusable
SwiftUI field, so there is no other way back from the keyboard.

That control shipped doing nothing. It broadcast `resignFirstResponder` through
`UIApplication.sendAction(_:to:from:for:)`, the idiom that dismisses a `UITextField`, and the
broadcast does not reach this terminal — `TerminalKeyboardDismissalTests` measures exactly that
and keeps it measured. `TerminalKeyBridge` already holds the live terminal for DECCKM, so it owns
dismissal too: it resigns that view directly and lets the window answer for a composer that took
the keyboard instead. Two smaller faults rode along. The bar's visibility came only from the
keyboard notifications, which say what *changed*, so arriving at a session whose keyboard was
already up produced no notification and no button — it now asks the bridge on appear. And both
trailing controls are a bare `Image` in a reserved 44pt frame with no fill behind it, which
answers taps on the glyph alone; the key caps are hit-testable across their whole cap only
because each carries a background. `contentShape` makes the reserved area the real one.

iPhone and browser continuity is scoped to the exact saved Mac and session. Native and atomic
terminal drafts are written locally as they change, pending request ids survive a reconnect, and
the last open route and reading position are restored without copying one person's draft to
another device. The records are versioned. If one is corrupt, the client preserves a quarantine
copy for diagnosis and fails closed instead of overwriting it with a new blank record. Continuity
mutations build, prune and validate a bounded candidate, persist and verify it, and only then make
it visible to the running UI; a refused oversized draft therefore cannot create state that appears
saved until the next launch disproves it.

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

The environment-selected `.p8` file must be a regular UTF-8 file no larger than 64 KiB. It is
read through the opened-file streaming limit before CryptoKit parses it; a metadata preflight is
not trusted because the configured path can be replaced or grown between inspection and read.

### Hosted service

The implemented Cloudflare Worker/D1/Durable Object service owns Sign in with Apple, bounded daily
Apple grant validation, scoped host/device credentials, bounded ICE signaling and TURN
provisioning. It never receives the remote HTTP/WebSocket payload carried inside WebRTC. A later
push slice should keep the APNs key in the service, deduplicate/collapse bounded events, and store
only sanitized notification or widget projections. Presence should remain connection-derived
rather than a database heartbeat.

The Mac remains authoritative for session contents, permission evidence and actual tool
decisions. No hosted store may become a public transcript store or an alternate way around a
revoked membership.

The Mac also selects the hosted-service origin. It includes that origin in the one-time owner
pairing link, and iOS validates and stores it with that paired Mac. There is intentionally no
app-wide iOS control-plane URL: different paired Macs may use the operated service, a local
development Worker, or a self-hosted service. The report-intake URL is configured separately
because an iOS user must be able to send a diagnostic report before pairing a Mac.

This also gives a clean product boundary for an open-source app: direct/local and self-hosted
remote access remains available, while an official paid iOS/hosted service can sell reliable
rendezvous, account-backed invitations, push delivery and cross-network presence. Payment buys
operated infrastructure and convenience, not a proprietary chat format or an artificial local
feature lock.

## Security model

- The remote server is separate from Threading's MCP and extension servers, and it binds one
  listener per **door** rather than one listener bound to everything. A door is a network the Mac
  will answer on, and each of its listeners is pinned to one address with `requiredLocalEndpoint`;
  `0.0.0.0` is never bound. Turning one door on therefore cannot start answering on another
  network, which is what keeps "publishes Threading only inside the owner's tailnet" true at bind
  time instead of in a later token check.
- Loopback is not a door anyone chooses. `127.0.0.1` is bound whenever Remote Access is on,
  because the Hosted Direct bridge and Tailscale Serve both forward to it, and it stays cleartext
  for the same reason. **No routable door is offered in Settings yet**, so a shipped build still
  listens only on `127.0.0.1`. A `lan` door exists in the model and can be turned on by writing
  the `remoteAccessDoors` default, but it is deliberately not in the UI until the listener
  presents its own TLS identity: a LAN listener over plain HTTP would put a bearer token on
  whatever Wi-Fi the Mac has joined. While it is on, the Mac advertises each bound address, its
  `.local` name and any `remoteAccessAdvertisedHostname` override as `lan` endpoints, and an
  iPhone drops them, because it keeps only `https` candidates.
- The listener's port is sticky. It tries the configured port, `8760` by default and editable
  between 1024 and 65535, and on a collision walks `8760` to `8769` in order and reports the port
  it actually took. It never falls back to a port the kernel picked: an ephemeral port meant the
  Mac's address changed on every launch, which is what made a paired phone re-scan after a
  restart. A client walks the same range before deciding the Mac has moved. If every port in the
  range is taken, Remote Access fails with that as the reason rather than starting somewhere
  nobody can predict.
- Interfaces come and go, so the listener set is rebuilt when the network path changes rather
  than enumerated once at start. A door whose interfaces are absent reports itself as not
  currently reachable and takes nothing else down with it. `socketfilterfw` supplies a
  best-effort hint about the macOS Application Firewall; it is only ever a hint, because a probe
  from this Mac to its own address is local traffic the firewall does not filter. Only a phone
  that connected proves reachability.
- In **Relay**, or while **Private + Sharing** needs a public share/fallback, `cloudflared` opens
  an outbound tunnel to that one listener. No router
  port or inbound firewall rule is opened. Traffic passes through Cloudflare, where TLS is
  terminated, so use that transport only for work you are comfortable sending through it.
- In **Tailscale** or **Private + Sharing**, Tailscale Serve exposes the same listener as HTTPS/WSS on dedicated
  port 8443, reachable only according to the tailnet's identity and ACL policy. Threading removes
  only that exact Serve handler when it stops and never runs `tailscale serve reset`, which could
  erase unrelated services. Before starting, it reads `tailscale serve status --json` and refuses
  to replace an existing HTTPS handler on 8443; remove that handler explicitly and retry. Serve
  runs in acknowledged background mode and every CLI probe has a bounded timeout, so a wedged CLI
  cannot leave Remote Access permanently in Starting. Tailscale still relays encrypted WireGuard
  traffic when peers cannot connect directly. Enabling Tailscale HTTPS publishes the
  machine/tailnet DNS name in public certificate-transparency logs; it does not publish chat
  contents or make the service public.
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
- Pairing-link decoding re-enters the same failable initializer as scanned and programmatic links.
  Synthesized `Codable` would otherwise bypass the HTTP(S), host, user-info and non-empty-bearer
  checks and manufacture a value its non-optional endpoint accessors could not safely represent.
  The validated share URL is derived once at construction, while only the normalized origin and
  bearer are persisted.
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
  plus checkout reads including Git Review, repository files, and detected image/PDF/HTML/archive/document/diagram attachments,
  also require that owner scope. Handing the Mac a file to send with a prompt requires it too, and
  is the only write into the host filesystem a remote client has; see
  [Sending a file from the phone](#sending-a-file-from-the-phone) for its bounds. View-only and
  guest links cannot change host state, read checkout
  files, or receive browser pixels. Permanent deletion remains a Mac-only action.
  Archiving a live session immediately disconnects any remote viewer already attached to it.
- Authentication failures are rate-limited globally and per device, and slow WebSocket consumers
  are dropped instead of being allowed to back-pressure an agent's terminal.
- Native REST mutations carry a request id. The Mac coalesces concurrent duplicates and keeps the
  bounded result for five minutes, while rejecting the same id with a different path or body.
  The iPhone can therefore retry a lost response, including over another advertised endpoint,
  without starting two sessions or applying an action twice. Native prompts and atomic terminal
  lines use the same five-minute principle on their WebSocket: the draft stays visible until an
  authoritative result arrives, and reconnect retries the same id only inside a shorter client
  window. The cache retains a fingerprint and status, never prompt text. Live terminal and
  conversation output frames are not replayed as actions; reconnect receives authoritative state.
- Unused invitations expire after 24 hours; accepted guest memberships remain in Keychain until
  that share or member is explicitly revoked. Turning Remote Access off or quitting Threading
  disconnects every open socket immediately and empties the live authority map; starting again
  rehydrates only the still-valid durable records. Paired owner credentials follow the same
  suspend/rehydrate rule; revoke the named device in Settings to remove one permanently.

Treat the owner QR code and every copied share URL like passwords. The owner code is intentionally
much stronger than a guest URL; only show it to devices you control.

## Beta limitations

Hosted Direct is implemented but not production-deployed by this repository checkout. The
checked-in Worker configuration contains a deliberately invalid D1 identifier, and the production
hostname, Cloudflare Realtime key, Sign in with Apple server key, rate-limit namespaces and Apple
server-notification registration must be provisioned or confirmed before distributed builds can
use it. A forced TURN-only run and the broader NAT/sleep/handoff matrix remain release gates.

The automatic relay still uses a Cloudflare Quick Tunnel. Quick Tunnels are intended for
development and testing, have no uptime guarantee, and receive a new public hostname whenever
Threading starts. The durable device credential survives, but an iPhone paired to that old origin
needs another reachable advertised route to discover the new Quick Tunnel. Hosted Direct supplies
that route for signed-in owner devices; a legacy relay-only build must still scan again. The
logical-host model now prefers an advertised stable relay URL, so a
future named Cloudflare Tunnel can replace the quick endpoint without changing pairing or
authorization. Provisioning and operating that named tunnel is not part of this phase. Tailscale already has a
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
Arbitrary filesystem access, browser control from the phone, and private browser pixels are not
exposed. Composer attachment uploads are — narrowly, and only as described under
[Sending a file from the phone](#sending-a-file-from-the-phone); the phone can put a file in the
attachment store of one session it may already write to, and can do nothing else with the
filesystem.

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

The loopback transport does not locate `AppDelegate`, a window, or a process singleton. Its
composition root supplies separate typed capabilities for session queries, durable mutations,
runtime status, settings mutations, and structured logging, together with its remote-specific
mirror, notification, archive, attachment, and extension collaborators. `RemoteSessionCommands`
remains the narrow main-actor capability for creating or resuming a session and reconciling
navigation after durable metadata, archive, or surface changes. These are also integration-test
seams: the real HTTP server proves routing and refusal behavior through recording capabilities
with no AppKit window graph or ambient project/runtime lookup.

## Implementation map

- `Sources/Threading/Core/Remote`: the HTTP/WebSocket server and its per-door listener set
  (`RemoteListenerSet`, `RemoteAccessDoors`), durable owner-device registry, authentication,
  pluggable Cloudflare/Tailscale transports, routing, the application command capability, and
  live session mirrors.
- `Sources/Threading/Resources/RemoteClient`: dependency-free browser client.
- `ThreadingRemoteKit`: versioned wire DTOs and pairing-link parsing shared by macOS and iOS.
- `Sources/ThreadingMobile`: SwiftUI iOS shell, UIKit Native-conversation timeline and SwiftTerm
  terminal surface.
- `docs/NOTIFICATION_E2E.md`: opt-in real APNs and Claude → MCP → APNs verification.
- `docs/REMOTE_DIAGNOSTICS.md`: privacy boundary, cross-device tracing and support workflow.
