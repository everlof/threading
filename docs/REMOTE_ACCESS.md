# Remote access

Remote access mirrors Threading sessions and standalone project terminals to a browser or to the
native `ThreadingMobile` iOS app.
It is an opt-in beta feature: open the dedicated **Settings → Remote Access** page on the Mac,
turn on **Remote Access**, and switch on the ways in you want. There is no connection *mode* any
more: a mode forced one choice between overlapping things, and a way in is one switch per network,
each stating who can reach it, who can see the traffic, what survives a restart, and whether it
works away from home.

- **This network** (`remoteAccessDoors`, `lan` by default) binds this Mac's own addresses on the
  networks it is attached to, one listener per address, each presenting this Mac's pinned
  certificate. The port is sticky, so a paired phone reconnects tomorrow without scanning again.
- **Through a VPN** is the same listener reached from a tunnel into that network, including UniFi
  Teleport and WireGuard. It follows **This network** and has no switch: a tunnel usually hands the
  phone an address inside the home network, which the LAN listener already answers.
- **Tailscale** (`remoteAccessTailscaleEnabled`, off by default) publishes Threading only inside the
  owner's tailnet. It is a listener on the address this Mac holds there, presenting the same pinned
  certificate as every other routable door, on the same sticky port
  (`RemoteTailscaleDoorImplementation.listenerDoor`). The iOS app therefore takes one code path
  everywhere: it pins what it scanned, whether it reaches this Mac on the Wi-Fi, over a VPN, or on
  the tailnet. Both of the addresses a tailnet hands out are bound, and this Mac's MagicDNS name is
  advertised beside them on the same port.
  - *Sub-option:* **Open in a browser on your tailnet** (`remoteAccessTailscaleServeEnabled`, off by
    default) runs `tailscale serve --bg --https=8443` against the loopback listener. It is a
    **browser convenience and not a way in**: what it buys is a publicly trusted certificate for
    the `*.ts.net` name, which is the only thing that stops a browser meeting a full-page
    interstitial against a pinned self-signed identity. It costs a public
    certificate-transparency entry naming this Mac and the tailnet, so the page says that beside
    the switch. **Serve's origin is never advertised to a phone**: it is terminated by a
    certificate this Mac does not hold, and a phone told to pin it would fail at the next renewal.
- **Hosted Direct** becomes the native owner-device default after Sign in with Apple. It uses the
  Threading service only for identity, ICE signaling and TURN fallback; ordinary traffic goes
  directly between iPhone and Mac whenever ICE succeeds.
- **Relay is gone.** The Cloudflare Quick Tunnel's address changed every launch, which is fatal to
  "pair once, reconnect tomorrow", and a third party terminated its TLS. Nothing starts it, nothing
  advertises it, and `cloudflared` is no longer a dependency of anything. It was the only public
  origin Threading had, so public guest links went with it; see
  [Pair an iPhone](#pair-an-iphone). `RemoteHostEndpointKind.relay` stays on the wire as
  decodable vocabulary, because an installed phone holds records that carry it.

Because every way in is bound separately, "tailnet only" and "this network only" are both
expressible, which is the guarantee behind *publishes Threading only inside the owner's tailnet*: a
person who chose the tailnet for its privacy is not also listening on hotel Wi-Fi.

All transports terminate at the same loopback server, protocol and authorization checks. A transport
changes who can route packets to Threading; it never expands what a bearer may do.

**The wire policy is now always `privateOnly`.** `RemoteHostConnectionPolicy` stays on the wire
because an old phone decodes it and maps anything it does not understand to `privateOnly` as well;
`relayOnly` and `preferPrivate` are never sent again.

**The settings screen's copy rules.** A way in is never presented without its four lines; a way in
whose four lines are embarrassing is one to fix or remove, not to describe vaguely. A status line
states a fact, an address and a port or the specific reason there is none, and never a mood. A
reason and its remedy live in the panel that shows the failure, not in a row somewhere else on the
page. Nothing claims to be reachable on the strength of a firewall reading: the Mac cannot observe
whether an incoming connection was allowed, because a probe from this Mac to its own LAN address is
local traffic the Application Firewall does not filter, so a bound address behind a suspect
firewall reads *May not be reachable* with the address and the fix in the same line.

**Certificate management is on the page.** `RemoteIdentityCardPresentation` prints the
26-character pairing code of the certificate the routable ways in present, offers **Prepare
Rotation** and **Activate Rotation** as two steps, and puts **Reset Identity…** behind a
confirmation that says plainly that every paired device has to scan again. Rotation is announced
over the pinned channel, so a device that has connected since the announcement follows the switch
with nothing to do; a reset is the answer for a lost or unreadable key, not the ordinary way to
change certificates.

**One migration, and then the mode is gone.** `remoteAccessConnectionMode`,
`remoteAccessAllowsOwnerRelayFallback` and `remoteAccessKeepsRelayReady` are no longer settings:
`AppSettings.migrateRemoteAccessConnectionMode()` reads the three raw defaults keys once, carries a
stored `tailscale` or `tailscaleAndRelay` over to the tailnet switch, and then deletes them. `relay`
carries nothing and lands on the shipped default, `This network`. The marker
(`didMigrateRemoteAccessDoors`) is written last, so an interrupted migration re-runs and a second
run finds nothing to carry.

**Retiring Serve as a route is what breaks an old phone.** An old client under `privateOnly`
filters to `kind == "tailscale"`, and that endpoint is now `https://100.x:<port>` with a
certificate it cannot pin, so it fails TLS rather than connecting. The phone update carrying
pinning has to be installed before this reaches anyone; here it already is. **Tailnet ACL rules
written against port 8443 were written for Serve.** The way in is the listener's own port, `8760`
by default, so a rule that restricts Threading has to name that one; nothing about ACL enforcement
itself changed, because Tailscale filters packets between nodes whatever port they are on.

## Pair an iPhone

1. Keep Threading running on the Mac.
2. **This network** is on by default, so a phone on the same Wi-Fi needs nothing else. For
   zero-install access, sign in with Apple under **Hosted Direct**; **Tailscale** is the way in
   for reaching this Mac from anywhere, and its readiness card identifies setup problems.
3. In Threading on the iPhone, choose **Pair a Mac** and scan the QR code shown on the page.

**A reason never lives only in a readiness row.** `TailscaleReadinessIssue` carries the failure
stated as a fact, the remedy, the readiness row it belongs to (or `nil` for the Serve-only ones),
and the title of the page that fixes it. Before that, the pairing panel said only "Private
connection unavailable" while "Enable Tailscale Serve for this tailnet" sat three rows above it.
The panel now reads a *way in* rather than a transport (`RemotePairingCardState.resolve(wayIn:)`,
fed by `mostAdvanced(of:)`), so what it shows is the door's own status line, which already carries
the fact and its remedy as words. Serve's failures reach the sub-option's row instead, with the
admin-console button beside them: a browser convenience is not what a pairing code waits for.

**The tailnet way in's readiness is two CLI facts and one listener fact.**
`RemoteTailnetReadinessPresentation.resolve` builds three rows: Tailscale installed, signed in and
running, and this Mac's tailnet address. The first two come from `tailscale status --json`
(`TailscaleHostFacts`), which is the only way to tell "not installed" from "signed out" from "not
running" and is also where the MagicDNS name comes from; the third is what `RemoteListenerSet`
bound. **A bound door outranks the probe**: an address in `100.64.0.0/10` on a `utun` exists only
because `tailscaled` is installed, signed in and running, so a probe that could not answer leaves
the rows waiting rather than accusing the Mac of anything. The probe is one short-lived child
process with a deadline, run when the way in is switched on and when the page appears, never on a
timer.

**Coming up is a state with a fact in it.** The door says `Binding to this Mac’s tailnet address…`
while its listeners are coming up, and the status row, the readiness row and the pairing panel all
show that same sentence. Serve's own wait is separate and longer:
`TailscaleReadiness.startupStatement` says what command is in flight, and the publish stage gets a
90-second ceiling (`RemoteTailscaleDefaults.publishTimeoutSeconds`) because a tailnet's *first*
certificate issuance was measured at close to a minute, and the twelve seconds every other command
gets had the app killing Serve and reporting a failure while it was still coming up.

The hosted QR carries two independent scopes in its URL fragment: a temporary rendezvous-only
credential that can form an encrypted ICE/TURN route to this Mac, and the existing one-time owner
bootstrap that must still be redeemed by the loopback remote server. The Mac exchanges the
bootstrap for a unique 256-bit, device-bound owner credential, rotates the code, issues the
phone's durable hosted credential, and revokes the temporary pairing route. A QR code for a bound
door redeems the same owner bootstrap over that door. The Mac stores the device record in the
data-protection Keychain when the signed build can access it and iOS stores the paired host and its
credentials in its Keychain. An ad-hoc Mac build falls back to the login Keychain and says so in
Settings. Pairing therefore survives a Threading restart and also survives turning Remote Access
off and back on. Settings
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

An owner pairing is stored as one logical Mac identity, not as one hostname. For the read-only
catalogue request, iOS starts a constant-size race: its durable hosted ICE/TURN credential and at
most four private-network lanes. LAN and VPN each keep one sequential lane; Tailscale gets up to
two so its IPv4 and IPv6 doors can start together, with later tailnet names continuing in those
lanes. The first valid `/api/me` response wins and cancels every other lane. A failed fast route
does not suppress a slower success. One advertised door and its sticky port range always stay in
one lane; a door that answers ends the rest of its port walk, and so does one whose address nothing
was reachable at. The concurrency ceiling does not grow with endpoint or port count. Mutations deliberately keep
the established sequential failover and one idempotency key; racing operations with side effects
would make the transport optimization part of mutation semantics.

**Attempts are ordered by what each one is evidence about, in three waves.** The first wave is one
address per route — the leading address of each admitted kind, in the policy's own deterministic
order. The second is the Mac's other addresses on a route already represented. The third is the
sticky-port range, and it is carried by one address per route rather than by each of them, because
ten ports answer "which port did this Mac's listener take" and that answer does not change between
two addresses of the same Mac. A discovered address leads its route and carries its range, since it
is where the Mac is now. This is the 2026-08-21 defect: a Mac advertising two `lan` addresses
produced twenty attempts before any other route was tried once, and the phone reached the tailnet
address that was working at attempt 22 of 23, ninety seconds in.

**The read-only walk has a ceiling.** `RemoteRouteWalkBudget` gives a route's own address four
seconds, a guessed port two, and the whole walk twelve. The per-address choice is based on the
complete race, not the size of one lane: splitting one Tailscale door into a lane of its own must
not silently restore the ordinary twenty-second request timeout while other routes are racing.
At twelve seconds the race is cancelled before the caller receives the ordinary named transport
failure. Recovery may then start a fresh generation with one owner. The former behavior let the
old race continue beside recovery; the new generation necessarily discarded an otherwise valid
late success, which is the 2026-08-24 defect. A race of exactly one candidate has no short ceiling
and keeps the ordinary request timeout, because there is no other route to get on with. Mutations
keep their sequential failover and their longer per-attempt timeout; they gain the wave ordering
but no ceiling, since abandoning an operation with side effects is not the same trade as
abandoning a read.

Owner responses carry the addresses each way in is currently answering on, tailnet included, plus an
explicit policy that is now always `privateOnly`; `relayOnly` and `preferPrivate` are still
decoded by an older phone and are never sent again. The iPhone orders only HTTPS endpoints allowed
by that policy, with no preference between the private-network kinds — which of this Mac's own
addresses is reachable is a fact about where the phone is standing, and it finds out by trying them
in order — records the successful route, and can move to another advertised route without creating
a duplicate device. Unknown future policies fail closed to
private-only. Guest shares never receive the Mac's private endpoint list.

The iOS app shows all unarchived sessions grouped by project or ordered by recent activity,
including dormant sessions. The navigation title names the connected Mac and carries its live
connection status; the leading Mac button switches paired hosts, so the dashboard does not repeat
that same device as a card in its content. Project headings are destinations. Opening one replaces
the mixed dashboard with one plain, project-scoped chat list, names the project above the same
connection status, and scopes the navigation-bar **+** to that project. Pinned sessions stay at the
top on both Mac and iPhone, and the archive is available from the dashboard.

This mobile browser is deliberately host-owned. Threading retains project/session navigation,
launch scoping, connection truth, row actions and the native fallback; the macOS extension
composition engine neither runs nor renders on iOS, so this surface does not advertise a visual
replacement contract it cannot honor.

Before the first catalogue arrives, the dashboard names only the operation happening now:
checking saved connections, trying a way in, or loading sessions after the Mac has answered.
The session screen borrows the same vocabulary once a walk has run past its first failure: it says
"Opening chat…" while the walk is still young, and names the route it is on — "Trying Tailscale" —
once something has failed, because from there the wait is long enough that a bare spinner reads as
a frozen app. That is what the 2026-08-21 reporter was looking at for ninety seconds.
These values come from `RemoteAppModel.fetchMe` at the point the bounded race begins and when its
winner is known;
there is no cosmetic timer that can claim a different step from the work the transport is doing.
LabelMorph's traveling fade periodically crosses the unchanged current phrase, while Reduce Motion
leaves it still. The navigation status names the same current route. The surface remains host-only
because connection truth and fallback policy remain Threading's responsibility even while
presentation changes. The card always renders one status row; endpoint and sticky-port
cardinality never create retained views per network attempt.

Debug builds expose those same two render components through **Settings → Developer → Connection
progress**. `MobileConnectionProgressLab` can hold the body card, navigation item, or both at each
authored checkpoint without starting a network request. The deterministic evidence scene is
`THREADING_MOBILE_DEMO=connection-progress-lab`; it enters through `RootView` and renders
`MobileConnectionProgressCard` plus `MobileConnectionNavigationTitle`, so the lab cannot become a
parallel mock of the shipping UI. Its five stories and three surface choices are a fixed
developer-authored set, independent of the number of endpoints or retries on a real Mac.

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

**The activity is a lossless enum, not a reflected name.** `RemoteSessionActivity` gives the Mac
and iPhone exhaustive `.dormant` / `.idle` / `.working` / `.awaitingUser` / `.needsAttention` /
`.limitReached` cases. The host maps `SessionActivity` explicitly; `String(describing:)` used to
turn an internal case rename into an undeclared protocol change, and the phone compared those
values against misspellable literals. The JSON remains the same plain string for installed-client
compatibility. `.unknown(String)` preserves a newer host's value through decode and re-encode, so
one future state cannot make an older phone lose the entire session catalogue.

On a paired owner device, the dashboard's options menu also offers **Usage** when the Mac
advertises support. It opens the Mac's prepared 7-, 30- and 90-day Overview and Limit History in a
native iPhone sheet. The phone receives bounded semantic totals and chart points, not transcripts,
filesystem paths, credentials or the raw limit journal. Banked resets show the selected
account/window's current inventory and nearest expiry; zero is distinct from unavailable, and a
historical banked-reset marker means a credit was observed being used rather than merely being
available. One-chat guest links cannot discover or read this whole-host data.

An open chat's **… ▸ Chat Settings** puts its operational controls beside that chat. **Account**
shows the current login and its normalized usage, and can move a live conversation to another
login for the same agent after warning that the running process will stop. **When the Limit Is
Reached** selects the resolved per-chat answer: stop and wait for the person, continue at reset,
continue on the best login, or continue on one named login. **Usage** opens the same whole-host
dashboard without making the person return to the session list. These controls are owner-only;
guest summaries omit both `accountID` and `limitRecovery`, and guest requests to either mutation
route are denied.

The account catalogue already sent once per owner response is the scaling boundary here. Each
session adds only two optional scalars—the routed account handle and resolved recovery policy—and
the phone joins those to the top-level agent/account catalogue only for the selected chat. It does
not copy an account or usage array onto every session row, and the settings sheet builds account
menus only when opened.

Structural refreshes are bounded on both sides. The Mac builds one short-lived common catalogue
projection for paired owners and layers each device's share metadata onto it, invalidating the
projection immediately for known row, structure, account and theme changes and expiring it after
one second. Thus a coalesced iPhone refresh from several connected devices does not ask the main
actor to repeat the same all-session walk for every client. A one-chat or one-terminal guest uses
the store's exact identity index and never enters that owner cache.

Chat Settings is deliberately host-owned under the customization-surface gate. Threading keeps
account discovery and credentials, transcript migration, recovery execution, usage provenance,
confirmation, and compatibility fallback. The iOS extension composition engine has no contract
for replacing operational session settings, so this sheet does not advertise one.

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
devices immediately. Owners can also rename, pin, archive, restore, move a running chat between
accounts, set its limit recovery, and switch it between Native and its agent UI from either side.
A UI or account switch stops the current process, then resumes
the same provider conversation identifier on the other surface. The session row's **Interface**
submenu shows both choices with the active one checked on Mac and iPhone, and catalogue changes
are pushed immediately so another open device follows the switch without waiting for polling.

REST refusals use the same bounded `RemoteErrorDTO` envelope as WebSocket refusals: the HTTP
status remains the compatibility fallback, while `code` names the guard that refused the action
and optional `detail` is restricted to a machine token. Launch choices therefore distinguish a
withdrawn project/agent, account, model, reasoning level, permission mode, speed, surface, role
and workspace instead of presenting every one as “HTTP 422.” An open iPhone draft reconciles when
the host catalogue changes and refreshes it after one of those authoritative refusals, preserving
the prompt and every choice that is still valid. Older hosts with empty error bodies still work
and retain the status-only message. Authorization and scope failures remain deliberately generic.
For sequential mutations, only a status-only 502/503/504 may belong to a route gateway and
continue to the next route. A coded refusal is the Mac's authoritative answer and ends the walk.
In particular, a project store paused by a full disk answers `storageExhausted`; iPhone tells the
person to free space on the Mac instead of allowing a later TLS failure to replace that cause.

A session's iPhone **Workspace** gathers **Browser**, **Review**, the read-only repository
**Files** browser, and **Attachments** under one route so companion surfaces do not accumulate as
toolbar buttons. The session screen keeps a single trailing control for the same reason:
Workspace and the terminal palette are entries in that menu rather than glyphs of their own,
because three of them plus a back button left the session's name a truncated stub at phone width.
That control is the **account disc** (`MobileAccountDisc`) rather than an ellipsis: the
runtime's mark ringed by the session's login's usage fraction, joined from the catalogue by
`accountID` the way the settings screen joins it, so the bar says which login is paying for the
turn and how close it is to its limit. It is the same disc the draft's bar wears to choose that
account, so starting a chat keeps the control where it was; a share or an older host with no
usage to report gets the mark alone.
A swipe in from the right edge opens Workspace without the menu, and the menu still appears for
any of the three permissions that used to reveal a button of its own — a share that may recolour
a terminal without managing the session still gets it.

**Workspace is a drawer from the right, and it follows the finger.** It was a sheet: the edge
swipe came from the right and the panel rose from the bottom, which is two directions for one
gesture. It is now a panel that slides in from the right edge over the chat, leaving a tap
target's width of the chat visible under a scrim (`SessionWorkspaceDrawer.reveal`), and the
right-edge pan pulls it in by as far as the finger has travelled; a rightward pan on the panel
pushes it back the same way, a tap on the scrim or the panel's close button dismisses it, and a
release settles whichever side a throw was heading — the same fifth-of-a-second projection the
dashboard row swipe reads. The panel has to cover the chat's navigation bar (a panel with a bar
of its own under the chat's bar is two bars), which a SwiftUI overlay on a destination cannot
do, so the drawer is a UIKit custom modal presentation hosting the SwiftUI workspace, with a
`UIPercentDrivenInteractiveTransition` scrubbing an interruptible property animator. Only the
theme crosses into the hosted tree (`mobileTheme`), as it did into the sheet; the Mac's
thumbnail capability is carried in by value for the same reason. The opening recogniser is a
plain `UIPanGestureRecognizer` whose `shouldBegin` states the edge rule
(`SessionWorkspaceDrawer.isOpeningEdgeTouch`): `UIScreenEdgePanGestureRecognizer` on the hosting
view received every bezel touch and never began, over the conversation's collection view and
the terminal alike, while the system's own back swipe on the same touches did. The edge is
judged where the touch *began* — the location less the translation at the moment the pan would
begin — because by then the finger has already travelled the recogniser's hysteresis, and on a
frame the terminal was busy drawing however far it got before the next touch arrived; judged
where the finger had got, a quick swipe from the bezel was declined more often than it opened.
The direction is the path since touch-down for the same reason, with velocity answering only
for a pan that reports no travel. The pans on scroll views under either drawer pan are made to
wait for it (`shouldBeRequiredToFailBy`, `isCompetingPan`), which is what lets the edge win over
the timeline's scroll and the terminal's mouse pan — only the pans, because a pan under a
resting finger never fails, and a long press made to wait for one fires at touch-up, which is
what the terminal's word selection did while every recogniser on its scroll view waited. The
closing pan declines a drag that is not rightward and sideways, one inside a horizontally
scrollable view, and one at the panel's leading edge when the workspace's own navigation stack
has something to pop. A release settles on a spring handed the finger's throw
(`SessionWorkspaceDrawer.settle`): a percent-driven transition otherwise finishes an
interruptible animator on its cubic `completionCurve`, so a flick eased out from wherever it
let go; the remainder now runs at the finger's speed, capped so a flick released short of home
does not overshoot, and a release a few points from home is slowed to a least settle rather
than snapped. The rules are arithmetic in `SessionWorkspaceDrawer` and tested as such.

**An attachment opens in a gallery, with its neighbours a swipe away.** A row in **Attachments**
used to push one preview; it now pushes `RemoteAttachmentGallery` at that row, a horizontal
paging scroll of the same previews built lazily (`LazyHStack` inside `scrollTargetBehavior
(.paging)`, so a session with a hundred attachments mounts the one on screen and its neighbours),
with the Mac inspector's detail under the name in the bar — "3 of 27 · 1219 × 874 · 188 KB",
the pixels once the image has decoded — and the inspector's rail as a ledger underneath: every
attachment as a thumbnail, the current one outlined in the accent and kept in view, a tap going
there. Thumbnails come from a new owner-only route, `GET …/attachment-thumbnail?id=`, gated
exactly like the attachment route it shrinks and advertised as
`RemoteRESTFeature.attachmentThumbnails`; the Mac rasters an image or a PDF's first page under
`BoundedImageDecodePolicy.thumbnail` at no more than `RemoteAttachmentThumbnail.maximumPixelDimension`
a side whatever was asked (`RemoteAttachmentThumbnailRenderer`), answers a JPEG, and 404s every
other kind, which the ledger draws as the kind's glyph. The phone asks per cell as the lazy row
brings it on screen, once per attachment (a failure is not retried), through a cache bounded at
`RemoteAttachmentThumbnailStore.capacity`; a Mac that does not advertise the feature is never
asked, and a notification that names one attachment opens the gallery on it with the listing
that resolved it as the set.

**A page stops asking for its bytes only once it holds them** — never because an attempt is
already running. `RemoteAttachmentPreviewLoad.shouldRequestBytes` is the whole rule, and it
takes no in-flight flag, because the page shipped with one and it was how a preview could
strand. SwiftUI cancels a lazy page's `.task` the moment the page leaves the retained window;
the cancelled attempt is suspended off the main actor, so it cleared `isLoading` only after
hopping back — *after* SwiftUI had already started the page's next task in the same layout
pass. The retry read a stale `true` and returned without asking, the cancelled attempt then
cleared the flag with nobody left to read it, and the page kept its loading placeholder for as
long as it was on screen: no bytes, no error, no **Try Again**, and — because cancellation is
correctly not a degradation — nothing in the journal either. The reported shape was an image
whose ledger thumbnail drew and whose page never did, which is exactly the asymmetry: the
ledger's own store already separates a cancelled request from a failed one so the next
appearance retries, and cells reappear constantly while a page gets one chance.

So the page takes its chance more than once. `RemoteAttachmentPreviewContent` runs its load as
`.task(id: isCurrentPage)`, so the attachment a person is actually looking at asks again the
moment it becomes the current page, and a page that already holds its bytes costs that nothing.
Two overlapping requests for one 24 MB-bounded file cost a duplicate GET; a page that stops
asking costs the person the file.

When an agent opens or navigates a browser
tab, the phone never changes screens: the account disc takes one quiet breath (a scale phase,
since a brand mark is not a symbol and takes no symbol effect) and an unread
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
returns *shortly after* the remote view closes — see the grace period below. Rotating the phone
updates the lease, and a departure that is not taken back restores the newest natural Mac grid
(or another phone that is still controlling the session).
In Focused mode only the controlling person's devices participate in that resize lease, so a
watcher's narrow window cannot reflow the controller's TUI. Moving between advertised routes does
not change the person's control identity; reconnecting receives the Mac's authoritative current
mode before input is accepted.

**A released lease is held for a grace period rather than dropped.** A lease change is a real
`SIGWINCH` and a full TUI repaint, and backgrounding the iOS app drops the socket exactly as a
deliberate close does — so a glance at a notification and a return cost a working agent two
reflows in each direction. On release the lease becomes *expiring* and its grid still counts in
`resolvedViewport`; a request from the same device inside the window cancels the expiry and
applies **no** viewport change at all. On expiry the grid drops and the Mac restores exactly as
it always did. The intersection rule below is untouched: this changes only *when* a lease ends.

Keeping the last grid indefinitely — "the phone set it, so leave it there" — was considered and
rejected. It trades a flap for a stuck state: a Mac pinned at iPhone width with no phone
attached, a banner that is either a lie or has nothing left to close it, and no obvious way for
the person to work out what happened. A grace gets the whole benefit for the case that hurts and
ends on its own.

Three properties make it safe:

- **The pending lease is keyed by device, not by connection.** A reconnecting phone is a new
  `RemoteConnection` object and would fail to match its own pending release, which is precisely
  the case this exists for. Identity is the authenticated peer's `deviceID`; a connection that
  authenticated without one cannot be recognised on its return, so its release stays immediate.
- **The grace holds a grid, never a subscriber and never an authorization.** A held lease keeps
  no socket subscribed, keeps no peer permitted, and never appears in `followers(of:)`. Discard,
  archival (`closeUnavailableSessions`), turning Remote Access off, and any loss of write
  permission drop it **immediately** rather than at expiry. The releasing peer's authorization
  is kept on the expiring entry for exactly one question — may this device still write? — and a
  `false` ends the lease; it never grants anything. In Focused mode that means the 30-second
  `focusedControllerDisconnectGrace` ends a departed controller's viewport lease too, ahead of
  the longer window, which is correct: once control is back with the Mac owner, the phone that
  left is not a client whose grid the PTY answers to.
- **A mirror that is being torn down cannot hold a grid**, because nothing would be left to
  expire it. The last subscriber leaving a mirror that does not survive puts the terminal back
  to its Mac frame before the mirror goes.
- **A Mac renderer looking at the chat cancels held grids.** A disconnect while that chat is
  selected restores the desktop grid immediately, and selecting it after a grace began ends the
  hold then. This affects departed devices only; an iPhone that is still actively rendering
  remains a participant in the shared-grid intersection.

Agent sessions and standalone project terminals share one implementation of all of this.
`Remote viewport lease held` and `Remote viewport lease expired` are written to the event log
beside the existing applied/released lines, with the surface, the grid and a pseudonymised
device.

**The window is a behavioural setting with no Settings row** — registered in
`AppSettingDefinitions` with no `presentations`, so its `remotePolicy` is `.hidden` and it
neither produces a row nor crosses to the phone's settings mirror. It defaults to **120 seconds**:
long enough for a notification glance, an app switch, a lock and unlock or a walk between rooms,
short enough that a phone genuinely put down leaves the Mac wrong for at most two minutes with a
banner on screen saying why. It is read at release time, so a change takes effect without a
relaunch:

```bash
defaults write codes.threading remoteViewportLeaseGraceSeconds -int 30
defaults write codes.threading remoteViewportLeaseGraceSeconds -int 0   # kill switch
```

`0` is a legal value and means "release immediately", reproducing the behaviour the grace
replaced. Validation **clamps** rather than refuses (0–900 seconds): the nearest allowed delay is
what somebody typing a number meant, unlike a listener port, where the number *is* the meaning
and a privileged one has to be refused.

Pinching the iPhone terminal changes its monospaced font on a bounded 9–24 point, whole-point
ladder and saves the result on that device. Whole-point crossings, rather than every gesture
sample, are the only events that can recompute an interactive phone-owned grid and send
SIGWINCH. A view-only phone keeps the Mac's authoritative grid and changes only its renderer's
cell dimensions, so zoom never takes control or reflows the shared TUI. Hardware-keyboard and
VoiceOver increase/decrease actions use the same setting. Font sizing remains host-owned rather
than becoming an extension surface: it controls renderer/PTY geometry, while an extension may
continue to customize only the content it owns.

Terminal-backed sessions keep the ordinary system navigation transition, including interactive
Back, without making that transition terminal layout. `RemoteTerminalLayoutView` retains one
settled SwiftTerm width and lets the navigation container clip it while the destination travels;
otherwise every intermediate width would become a grid, a viewport message, a PTY
resize/SIGWINCH and a full-screen agent repaint. A width commits only after the navigation
coordinator ends with the terminal still on screen, or an ordinary resize holds still; a successful
Back discards its outgoing proposal before teardown. The inset is inside that host, so its retained
width is the terminal's real content width rather than the whole screen. Native conversation rows
need no corresponding boundary because they do not control a remote process viewport.

**Only a settled grid becomes a lease.** Whole-point crossings bound the pinch locally, but a
single gesture still crosses many points — the Mac's journal recorded nineteen `Remote viewport
applied` entries from one pinch, each a soft reset, a full scrollback reflow and an agent
repaint, and the hellos queued behind that churn took seconds, which a phone experiences as
"entering a chat is very much slower" precisely when the font is small and the grid is large.
`RemoteSessionConnection.updateTerminalViewport` therefore applies every crossing to the local
renderer immediately but leases to the Mac only the first grid of a lease (so entering sizes the
agent at once) and thereafter the grid that has held still for
`RemoteMobileConnectionDefaults.viewportSettleDelay`. The browser client has debounced its fit
for the same reason all along. For the same event-frequency reason,
`TerminalViewRepresentable.apply` installs a terminal theme only when the theme actually changed:
`updateUIView` runs for every published change on the connection, and reinstalling an identical
palette clears SwiftTerm's attribute caches and repaints every visible cell cold.

**A joining client states how much replay it can keep.** The phone's emulator holds SwiftTerm's
default 500-line scrollback, so the Mac's whole 512 KB ring was parsed in full and immediately
trimmed down to that — 330–350 ms of main-thread time on every chat entry, most of it thrown
away. The `auth` frame may therefore carry `replayBudget`, a statement about the client's own
emulator rather than a request for a privilege, and the Mac holds it to its own range like every
inbound value: a stated budget is clamped up to `minimumTerminalReplayBudgetBytes` (16 KB, a
floor on the tail so the ask still buys scrollback worth having — screen exactness never depends
on it) and down to the ring, because no more history exists than the ring holds. A budget the
ring already fits inside changes nothing, and the field must be a JSON integer: the auth decoder
is strict, so a float would refuse the whole frame rather than just the field.

When the budget does cut the ring, the replay becomes two binary frames instead of one: CAN
(0x18) followed by the ring's newest `budget` bytes, then a freshly synthesized repaint of the
visible screen. Both halves are load-bearing. CAN is there for the reason the mode seed also
begins with one — a byte window over a raw PTY stream can end inside an escape sequence, and
cutting the head off the ring means it can now *begin* inside one too. The fresh repaint is what
keeps the visible screen exact: the ring was seeded at capture with a repaint of the screen as it
stood then, and that seed lives at the head, which is precisely the part a budget cuts away. The
tail exists to give the client scrollback — but it is raw output, and its emulator side effects
persist except where the two seeds restate them, which is why the repaint selects ASCII into G0
before painting (a tail can end inside a line-drawing burst that CAN does not undo) and why it is
sent from the main queue *behind* any broadcast the ring had not yet absorbed — the emulator runs
ahead of the ring, and a repaint containing bytes the client then receives again would apply
them twice. The mode seed still has the last word. A truncated replay records
`Remote replay bounded` in the journal with the ring size and the budget applied. Back-compat
runs both ways with no protocol bump: a client that omits the field — every earlier build, and
the browser client — receives the whole ring byte for byte, and a host that predates the field
ignores it and does the same.

**A current host says when initial terminal presentation is complete.** Replay completion alone
is not enough for an interactive phone: its first final-width viewport sends SIGWINCH, and Codex
or Claude can repaint the entire application after an arbitrary scheduling gap. A host advertising
`terminalHydrationBoundary` therefore accepts a request id on each `viewport` generation sent
before reveal, observes the resulting PTY output on the Mac, and queues a final screen seed, mode
seed and `terminalReady(requestID:)` after the local burst settles. WebSocket ordering makes that marker a
proof about every earlier binary frame; network packet timing is not used as a repaint heuristic.
The phone reveals only the marker matching its current viewport transaction, and if SwiftTerm has
not mounted yet, the marker waits until its buffered output has been delivered to the renderer.
A view-only terminal has no viewport lease and receives an untagged boundary after attach.

PTY applications expose SIGWINCH but no portable "repaint finished" acknowledgement, so the host
uses bounded local timing: 200 ms quiet after the first resize output, one second if the application
does not repaint, and three seconds for continuous output, always followed by a fresh authoritative
screen seed. The phone keeps a four-second failure escape. Compatibility remains additive: an
older phone ignores the feature and marker; a current phone connected to an older host retains its
one-second input-silence fallback.

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
the smallest column and row count across every lease, live or inside its grace — which every
viewer can see whole and which does not depend on arrival order. A second viewer joining costs
one resize; a viewer leaving and coming straight back costs none.

**A remote-controlled terminal is laid out at a pixel size that disagrees with its grid**, so
every AppKit layout pass proposes a grid nobody asked for. Suppressing the PTY resize is not
enough, because SwiftTerm has already reflowed the emulator by the time the process is consulted,
and putting it back runs the resize path again — which ends in `softReset()`. A full-screen agent
therefore lost its scrolling region on every pass, including passes that set the identical frame,
which is what the Fit-to-iPhone banner's own text change caused. Both sides now answer
`shouldApplyFrameSizeChange` — a fork seam ahead of the emulator, not behind it — so a managed
grid is never left, even briefly. `EmojiFixedTerminalView` keeps `shouldApplyProcessSizeChange` as
the second gate, on the PTY rather than the renderer. Re-applying an unchanged lease is not a
resize either, for the same soft-reset reason. Font assignment has to enter that same early seam:
SwiftTerm's original `resetFont()` called `resize` directly and therefore bypassed the managed-grid
answer. It now recomputes iOS cell dimensions through `processSizeChange`; a view-only renderer can
refuse the grid change while still invalidating its glyph, accessibility and scroll geometry.

Every applied grid is written to the event log as `Remote viewport applied` with the grid, the
number of clients holding a lease and the number of grids still held inside their grace.
Diagnosing the argument above meant reading it out of screenshots, because nothing recorded what
the clients had asked for.

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
two fingers always scroll the mirror. Knowing *whether* it is tracking is the next paragraph:
until the modes were stated at attach, a phone that joined a running agent believed nothing was.

When the terminal owns that local scrollback and the viewport is above its live end, the iPhone
shows one floating down-arrow over the lower trailing corner. It returns SwiftTerm to the live end
and resumes following. A tap first cancels UIKit's active pan or deceleration, because returning to
the live end is a semantic reset rather than a new destination for the old gesture's velocity. The
arrow is deliberately absent while the TUI owns one-finger scrolling
(mouse tracking or an alternate buffer), because in that state Threading cannot truthfully say
that the TUI has more content below. Its presence reads SwiftTerm's exact reachable end and input
mode in constant time; it does not inspect scrollback or send a PTY message.

**The sticky modes are stated at attach; the ring cannot be trusted to carry them.** A joining
client is seeded with a repaint of the *visible screen* (`RemoteScreenSeed`), which carries no DEC
private modes, and in front of that seed is a 512 KB window over raw output. A TUI arms its modes
once, when it starts, so by the time a phone connects those sequences have long rolled out of the
ring. Each of them decides how the *client* behaves, and each failed the same way: the phone's
emulator sat at `mouseMode == .off`, so it swallowed every tap and gave one finger its own mirror
rather than the agent's transcript; the key bar asked that same emulator whether an arrow should
be SS3 or CSI (DECCKM) and got the wrong answer; a paste went out unbracketed, which runs a
multi-line paste line by line.

`RemoteTerminalModeSeed` states them instead. `RemoteTerminalState.modes` — mouse tracking and its
encoding, application cursor keys, bracketed paste, and kitty keyboard-enhancement flags — is read
off the Mac's live emulator, and `attachTerminal` sends the mode statement **after** the ring,
because the ring is replayed history and history holds modes that stopped being true: an agent
that has since exited to a shell would otherwise leave the phone reporting clicks into a prompt
as pasted escape text. The statement is authoritative rather than additive — every tracking mode
and every encoding is reset before the ones in force are set, kitty flags are replaced even when
the answer is zero, and tracking is set last, because resetting an encoding also stops tracking
on this emulator.

**A tap also has to be the button a TUI listens for.** Two things in the fork stood between an
armed phone and a click. iOS encoded every tap as xterm button 1, the *middle* button, where the
Mac passes `NSEvent.buttonNumber` and sends 0 — so the phone was pressing something no program
answers, and "click to go to bottom" ignored it. And the gesture as a whole was gated on the
terminal holding the keyboard, so the first tap after the keyboard was put away was spent taking
it back. A tap over a tracking program is now that program's left click, press and release
together, and it leaves focus where the person put it; `TerminalKeyBar` carries the way back to
the keyboard in both directions rather than only the way out.

**The way back has to be reachable, twice over.** The bar's show control read
`terminalView?.canBecomeFirstResponder` as a computed property over an unpublished weak
reference, and both of its inputs change outside SwiftUI's sight — the terminal attaches only
after the bar's first render, and input mode can flip on a live view — so nothing ever
invalidated the bar and only the dismiss half appeared. `TerminalKeyBridge.canShowKeyboard` is
published now, refreshed on attachment and after `setAllowsKeyboardInput`. And because a control
on a bar is not where a decade of muscle memory reaches for a keyboard, a **double tap** on the
terminal takes it back too: over a tracking program the pair's first tap is still that program's
click (the single-tap recognizer fires on it regardless), and the second tap answers the person
instead of repeating the click. With the keyboard already up, or nothing tracking, a double tap
keeps its old meanings — the program's click and word selection respectively.
`RemoteTerminalTapTests` pins all of it.

**Selecting text had to survive the thing being selected.** SwiftTerm's iOS view cleared the
selection on every line feed whenever the program tracked the mouse — which on the phone is
whenever it can type, and which is exactly while an agent is printing the lines someone is
trying to select. The Mac's view had already replaced that with the honest rule, and the fork's
iOS view now shares it: a selection is dropped only when the buffer rows it names stop holding
the same text, because a full scrollback recycled from the top or the alternate screen scrolled
in place; output that merely appends beneath it leaves it alone. The gesture changed with it. A
**long press selects the word under the finger directly**, with handles, and brings the edit
menu up when the finger lifts — moving before lifting extends from that word, a press inside an
existing selection keeps it — instead of a "Select" menu standing between the finger and the
word. It never takes the keyboard: the old path called `becomeFirstResponder` because the
pre-iOS 16 menu controller could not show without it, so a view-only phone, whose view refuses
first responder, could not copy at all. The menu is `UIEditMenuInteraction` now, an interaction
on the view rather than a responder-chain service, and it takes the system's own localized
Copy / Select All / Paste when the system offers them. Over a tracking program the first tap is
still that program's click and a double tap still asks for the keyboard; neither route moved.

**The selection becomes part of the message, not only the pasteboard.** Beside Copy the menu
offers **Add to message**, the fork's one host seam here (`extraSelectionMenuActions`). The
selected text becomes a chip — "2 lines" and the first line of it — and the highlight is
cleared as Copy clears it, because the buffer keeps moving under the range and the chip is what
gets sent; the chip's × is the cancel. In the independent composer the chip rides with the
draft and Send delivers both. Under a direct-input TUI the chip stands above the key bar with an
insert control, as staged attachments do, and inserting types the lines at the TUI's cursor
without Return. Both paths wrap the lines in bracketed paste when the program has turned it on
(`RemoteTerminalSelectionQuote`, ThreadingRemoteKit), which is what keeps an agent's prompt from
reading every line break as Return — Claude Code shows the block as one "[Pasted text]" token —
and go in as typed otherwise, exactly as a paste would. A view-only phone is offered Copy but not
the quote and not Paste, since nothing it sends arrives. `RemoteTerminalSelectionTests` and
`RemoteTerminalSelectionQuoteTests` pin this; the `terminal-selection-quote` evidence capture
shows the handles, the themed selection and the chip together.

**The draft box needed the same rule, and did not have it.** The quotes were delimited and what
was *typed* beside them never was — and the host writes a submitted line into the PTY as it
stands before appending Return, so a draft carrying a line break arrived as several Returns: the
first line submitted and the rest landed in whatever the agent asked next. Typing cannot produce
a line break there, because Return sends; pasting is the only way one gets in, which is exactly
the case that broke. `submissionText` now delimits a multi-line draft too, trimming the blank
edges the host's own trim can no longer see past the delimiters. The quotes stay a separate
block from the instruction rather than being folded into one: an agent's prompt collapses a
pasted block into a single token, and burying "fix this" inside it would hide what was asked.
`RemoteTerminalPaste` owns the delimiters and the 64 KB write bound now, shared with
`RemoteAccessDefaults.maximumTerminalInputBytes` so a client can ask the host's own question
before sending rather than pasting into silence.

**And the TUI's paperclip carries the clipboard too.** Under a direct-input TUI **From
Clipboard** does the obvious thing for what it finds: files take the upload route, because a
program reading a PTY has nowhere to put a picture, and text is typed at the cursor as one paste.
That second half is the edit menu's own Paste reached without the long press — worth having on a
screen where the thing being aimed at is one prompt line an agent is drawing over. A clipboard
that emptied between the entry being drawn and being chosen says so, and so does one holding more
text than a single write carries; a raw terminal write is acknowledged by nothing, so silence
would otherwise be the only answer.

**A pick is finished when its last file is, not its first.** Uploads start as each file is read,
and the pickers read them one at a time across suspensions — a photo may still be coming down
from iCloud. Insertion waits for the whole pick as well as for the tray to settle, because
without that the first photo's upload could finish inside the gap before the second was staged:
it went in alone, the acceptance that followed cleared the tray, and clearing cancels uploads
still in flight. Three photos chosen, one inserted, two gone and nothing said. A Mac that answers
**busy** is waited out rather than emptied — busy means one submission is already in flight, the
bytes are on the Mac already, and the insertion is retried up to twice when the terminal stops
submitting. `rejected`, `unavailable` and `conflict` do clear the staged files, because those do
not become true again by waiting.

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
notification preferences, in-app presence/typing, the default terminal input style and local
diagnostics are useful without a Mac and stay available from the dashboard's `…` menu after
pairing. The stock icon picker is manual because iOS confirms every icon change; when a connected
Mac uses a built-in style, the picker names that style as the matching choice.

**Settings → Advanced** controls the bounded warm-session pool. Its defaults are 60 seconds and
three connections; hold time can be set from 5–300 seconds and size from 0–8, with zero disabling
reuse. Popping a chat parks only its authenticated WebSocket. The host first removes it from PTY
and conversation fan-out, releases its viewport, presence, typing and input-control state, and the
phone retains no terminal renderer. Reopening that same chat resumes through the ordinary hello
and bounded replay/snapshot path. A Mac that does not advertise `sessionConnectionParking` is
always disconnected normally.

The same page exposes the evidence for changing those defaults: current and peak occupancy,
reuse hits and misses, hit rate, actual hold timing, holds that ended without reuse, each expiry or
eviction reason, unsupported hosts, and fixed reuse/unused age buckets. These aggregates persist
only on that iPhone and contain no Mac id, session id, title, prompt or per-connection history.
Backgrounding or a memory warning drains the pool; lowering either setting applies immediately.

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
  **The person on the other end needs the Threading app and a way onto one of your networks.**
  The invitation points at a bound way in, LAN first and the tailnet otherwise, and carries the
  same 26-character fingerprint the owner's pairing code carries, so their phone pins this Mac's
  certificate from the code it was sent. `/api/me` never teaches a one-chat capability an identity,
  which is why the code has to. With no way in bound there is no origin to mint against and the
  sheet refuses with *Turn on a way in first*.
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
- **Share Terminal…** in a standalone terminal's `…` menu creates the same kind of durable,
  device-bound membership, scoped to that `TerminalID` rather than a `SessionID`. **View only**
  receives the bounded screen seed and subsequent output but cannot start a stopped shell, type,
  paste, send keys or resize the PTY; the button therefore waits until that shell is running.
  **Full control** may start it and send arbitrary PTY input and viewport changes. It is the same
  authority as sitting at that terminal on the Mac: commands run as the Mac user, and the project
  folder is only the shell's starting directory, not a security boundary. A terminal capability
  can never approve an AI permission request, discover chats or other terminals, manage the host,
  or create another share.
- **An invitation is addressed to the app, because only the app holds the pin.** The link points
  at a private door on a LAN address or a tailnet name and carries this Mac's fingerprint in its
  fragment, so the guest's phone can pin the certificate before its first request. Sent as the
  bare `https` URL that was unreachable in practice: tapping it opened Safari, and Safari can only
  offer the certificate interstitial, because the pin lives in the app and no browser can learn
  it. The owner met exactly that.

  `threading://` is registered by the iPhone app (`CFBundleURLTypes` in
  `Sources/ThreadingMobile-Info.plist`) and carries two payloads. `THREADING://PAIR#…` is the
  hosted rendezvous credential the QR code already used; `threading://join#…` is a one-chat
  invitation, the base64url of the whole `https` URL including its fragment. `RemoteInvitation`
  in `ThreadingRemoteKit` is the only parser for any of them, so the scanner, the paste field and
  a tapped link cannot drift apart, and `MobileInvitationRoute` adds the application's own rule
  that a door must be `https`. The scene delegate is the delivery point, including the cold
  launch: SwiftUI's `onOpenURL` never fires in this app, because the scene is UIKit's and the
  SwiftUI tree lives in a hosting controller rather than a `WindowGroup`.

  What is shared is composed once, by `RemoteInvitationShare`, for the Mac's two copy actions and
  the iPhone's share sheet alike: a sentence naming the app and the network, then the
  `threading://` line, then the `https` line. **The `https` line stays** because a custom scheme
  is not reliably tappable everywhere a link travels. `NSDataDetector(types: .link)` does match
  `threading://join#…` on iOS 26 — measured, on both macOS 26.5 and the iOS 26.5 simulator
  runtime, and Messages drives that same detector — but third-party clients (WhatsApp, Telegram,
  Slack) are documented not to linkify custom schemes, Messages leaves links from an unknown
  sender inert until you reply once, and a message carrying two URLs gets no rich preview either
  way. A Universal Link is not the alternative here: the entitlement takes a fully qualified
  domain, the association file is fetched by an Apple CDN that cannot reach a LAN address, and
  Apple has stated that universal links do not support custom ports. A public `https` redirector
  is the only established way to make one tap work in every client, and that is a service
  decision rather than a code change.

  **Follow-up, not built:** the Mac-served page at
  `Sources/Threading/Resources/RemoteClient/index.html` is what a browser reaches when somebody
  taps the `https` line and accepts the interstitial. Its first screen could say that this chat
  opens in the Threading app and offer the `threading://` link when the user agent is iOS, which
  would turn the fallback into a bridge.
- **A guest cannot be somebody with only a browser any more.** That worked because the Cloudflare
  Quick Tunnel gave Threading a public origin; removing the relay removes the origin, and this is a
  real capability loss rather than a tidy-up. The browser client is unchanged and still speaks the
  whole session protocol, so guest links return when it can be served over an ICE data channel;
  the shim that needs is the same one Hosted Direct needs, and the two are planned together. A
  proxy route through Threading's own infrastructure is deliberately not the answer: it would put
  session bytes through a service that promises never to see them.
- An unused invitation expires after 24 hours. Accepting it consumes that URL and creates a new
  device-bound membership without a 24-hour timer. Unused invitations and accepted memberships
  use the same protected-when-available Mac Keychain policy as paired owner devices, so turning
  Remote Access off, restarting Threading, or switching a way in suspends the route without
  silently removing the share.
  The member keeps access until **Stop Sharing** or their named membership is revoked. Create
  another invitation for another person; forwarding an already accepted invite does not clone
  the membership. A credential that cannot be restored exactly fails closed rather than creating
  a replacement identity.

Standalone terminals remain a separate wire type. `RemoteMeDTO.terminals` is optional and carries
`RemoteProjectTerminalSummaryDTO`; a terminal is never adapted into `RemoteSessionSummaryDTO`, so
an older client ignores the new catalogue instead of inventing agent, transcript, archive,
workspace or permission behavior for a shell. WebSockets use `/ws/terminal/<TerminalID>`, lifecycle
uses `/api/terminal/<TerminalID>/…`, and `RemoteScope.projectTerminal` compares the typed identity
on every request. Even a terminal and chat containing identical UUID bytes do not share authority.

The terminal catalogue applies the session-sized scaling gate: one bounded summary per durable
terminal, one lazy dashboard row per visible result, and no retained view or timer per hidden
terminal. A detail screen opens one socket and one bounded replay only when selected. This surface
is deliberately host-owned under the customization-surface gate. Threading keeps terminal
identity, PTY lifetime, authorization, sharing, replay and input enforcement; the iOS extension
composition engine has no contract for replacing a raw project shell.

Use **Open in Browser** to test the browser client without leaving the Mac. The owner pairing link
can also be copied from the pairing sheet, but it is intentionally not presented as a general
sharing action.

## Starting a chat from the phone, and seeing it work

**Start opens the chat it started, on the screen that started it.** The draft is a route on the
navigation stack (`MobileNavigationRoute.draft`), pushed by **+** — the toolbar's, or the one on a
project's heading, which seeds that project — from whichever list asked for it, so Back from the
chat returns there. It was a sheet: Start created the session, the sheet
dismissed, and the dashboard pushed the new chat from `onDismiss` — two motions with the list
flashing between them, and before that, no push at all. Now the Mac answers the create with the
new session's id *and* the whole refreshed catalogue, the model records which session the draft
became (`noteDraftStarted`), and `SessionDraftView` fades the drafting screen out over
`SessionDetailView` where it stands. The path does not change: the draft route keeps its identity
and `RemoteAppModel.sessionID(for:)` resolves it, so continuity records the chat, a notification
for it does not stack a second copy, and a row tap is the same no-op it is for the chat already on
top. Rewriting the path entry to `.session` was rejected because it rebuilds the detail screen and
shows its loading placeholder for a frame. The fade is the draft's, not the chat's: both live
surfaces are UIKit-hosted and do not take SwiftUI's opacity ramp, so fading the chat in cut it in
over a draft still fading. The session's own screen owns the wait: a brand-new session is not yet
running, so it shows "Resuming on your Mac…" until the agent answers. Tapping a row still goes
through `MobileSessionNavigationTransition.push`, so a terminal commits its final geometry
immediately rather than being resized through every intermediate width.

**The draft is one composer, not a form.** Three kinds of choice at three weights, none of them
a box on the ground. *What and where* — "Agent in AnotherTerminal" — is one sentence of two plain
dropdowns in the middle of the ground under the role's glyph, its branch beneath it; the role
dropdown appears only when the catalogue says `supportsManagerRole`, so an older Mac is never
sent a word it would ignore. *Who* — agent and account — is the disc at the navigation bar's
trailing edge: the runtime's mark (`MobileAgentMarkGlyph`, the same drawing the dashboard rows
use) on the toolbar's circle, ringed by the account's usage fraction; the words the old capsule
spelled out are in the menu beside each account. *How* is the composer's action row under the
prompt, and it never scrolls: model, effort and speed are one line of text
(`SessionDraftRunSummary` — the model, then only the choices that depart from its defaults) over
one sectioned `Menu`, and permissions and the interface are one glyph each, accent-tinted once
set. A `Menu`'s button keeps the width it was first measured at, so each text menu is keyed by
its value (`.id`) and re-made when the word changes — "Agent" became "lanager" before that. The
composer rides in the bottom safe-area
inset with SwiftUI's keyboard avoidance, so it sits on the keyboard's top edge and follows the
interactive dismissal; it is full-bleed with a hairline above it rather than a bordered panel. The
action row unfolds with the prompt's focus and folds when the keyboard goes, leaving one line —
the prompt and Start — on the home indicator. Opening a chip's menu does not dismiss the
keyboard, which is what makes chips inside the composer workable at all. Focus rather than the
keyboard's frame decides the fold because the two agree whenever it matters and focus is what
the evidence harness drives; the `editorFrameRestored` assertion holds because the folded shape
before the keyboard opened is the folded shape after it closed.

**Connected to the Mac and attached to one chat are separate truths.** The dashboard's connected
state means a route answered and returned the current catalogue; entering a row then opens that
session's own live socket for replay, conversation deltas, presence and input. An available row
therefore says "Opening chat…" rather than claiming the phone is connecting to the Mac again. A
dormant row keeps "Resuming on your Mac…" until the process is ready, then passes through the same
opening state. Leaving the detail screen closes that session socket without unpairing the phone or
taking the dashboard offline.

The navigation status is one changing phrase, so `MobileMorphingTitleLabel` uses LabelMorph's
whole-line scroll rather than its character-by-character name morph. The scroll clears one full
caption line and one synchronized, shallow opacity breath shares its 650 ms budget. This is
deliberately not a traveling wave: when "Opening chat…" gives way immediately to a Mac name, a
staggered pulse leaves the trailing `Book Pro` fully lit while the leading half flickers, and the
phrase stops reading as one line. Dashboard route progress, SwiftUI terminal chrome and UIKit
Native-conversation chrome all enter through this same mobile design boundary. Reduce Motion
lands the next phrase synchronously with no scroll or fade.

The same boundary reserves LabelMorph's raster overflow inside its clipping frame. The package
draws each glyph into a padded tile so overhanging ink survives; clipping the wrapper at the
typographic advance instead cut the leading edge of the first character in the navigation bar.
The connection dot fades out at its old position and back in at its new one on every phrase
identity change, even when its colour did not change, because the centred dot-and-phrase row moves
horizontally when the new phrase has a different width. Hiding the real dot during that reflow is
what prevents the first frame from teleporting before an ordinary opacity animation could start.
Reduce Motion lands both the dot and the phrase without that transition.

An automatic dashboard reconnect does not present the full recovery card on its first transient
route miss. While recovery is already scheduled, the existing compact connection card says
“Connection interrupted. Trying again…” and the navigation line says “Trying again…”. Three
consecutive complete route races make the failure settled enough to disclose the actionable
recovery card. Once disclosed, that card remains stable through the next attempt and leaves only
after success, rather than alternating page-sized progress and error surfaces on every backoff
tick. Failures whose remedy is not another connection attempt — identity, permission, pairing or
upgrade failures — remain immediate. Connection truth, retry policy, recovery actions and this
presentation are host-owned; no extension may relabel a transient miss as success or a retry as a
settled failure.

**A chat has one name, wherever it is drawn.** The list draws the catalogue's
`AgentSession.displayTitle` and so does every title on the screen that list opens —
`MobileSessionChrome.navigationTitle(for:in:liveTitle:)` resolves it against `model.me` rather
than against the summary the screen happened to be opened with, so a rename that lands while a
chat is open moves both.

The socket's own title is not that name, and is called `mirroredCaption` so that reading it as one
is visibly wrong. It is what the mirrored surface calls itself right now: for a terminal, the
agent's OSC title exactly as it was sent. The Mac never shows that string either —
`ProjectStore.updateAgentTitle` strips its decoration, drops the captions that name the product or
the working directory, and ranks reported against provider against chosen; `displayTitle` then
applies the user's choice about agent titles at all. None of that has happened on the wire, so a
phone reading the caption is not showing a slightly different name, it is showing a different
*kind* of string. It stays a bootstrap for a catalogue value that is still empty, and nothing else.

This was wrong twice for one structural reason: the rule was applied to SwiftUI's
`navigationTitle`, which **nothing on a session screen draws**. A conversation installs its own
`navigationItem.titleView` and a terminal supplies a principal toolbar item, and both read the
connection directly — so the list said "Licensing strategy" and the screen it opened said
"✳ Claude Code". Both surfaces now ask the one function, and `MobileSessionChromeTests` asks the
shipping controller, inside the navigation controller it ships in, what its title view actually
says: a value-level test of the rule passed the whole time.

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

**A terminal session resolves one typing surface at a time.** `MobileTerminalInputMode` is one
answer rather than two booleans: `direct` sends keystrokes to the PTY,
`independentComposer` writes in an iOS text area and submits the whole line atomically, and
`none` offers nothing. A caller reading only one of two booleans eventually offers both surfaces
or neither. While solo, the key bar switches between Direct and Compose without changing or
restarting the Mac session. That device-local choice is remembered for the host/session pair;
**Settings → On this iPhone → Terminal keys** supplies Direct-by-default or Compose-by-default
only for terminal sessions this phone has not seen before.

The mode also waits for the roster. `hello` and the first `inputControl` frame are two messages
with a render between them, and treating that gap as "roster unknown, keep the safe atomic path"
put the line composer on screen for a frame and then removed it — a flash of the non-TUI text area
on the way into every solo terminal session, since the default for independent drafts is on. A
host that supports the roster is now given that one frame to send it, and only a host too old to
send one at all — which never will — keeps the atomic composer as its settled answer. A real
second participant also requires Compose regardless of the stored solo preference, so two people
cannot interleave characters; when the terminal becomes solo again, its saved Direct/Compose
choice returns. The wait costs nothing else: raw keystrokes should not start before we know
whether somebody else holds the session either.

## Sending a file from the phone

The composer's paperclip attaches a photo or a document to the next prompt. A direct-input TUI
keeps the same paperclip as a fixed utility cap at the start of its control-key bar; picked files
appear in a bounded tray above the bar, and its explicit Insert action types their quoted session
paths at the current cursor without Return. The explicit step matters because an upload may
finish after the person has moved the TUI cursor. Neither mode lets asynchronous transfer mutate
the terminal unexpectedly. This is the only route by which a remote client can cause the Mac to
keep a file, so it is worth saying exactly what it does and where it stops.

**The clipboard is the third source, because it is where the thing already is.** Photos and
Files are both places to go *looking*, and a picture copied out of a web page, a message or
another app's share sheet is in neither until somebody saves it somewhere first. Pasting one into
the composer did nothing at all — `UITextView` asks whether it can insert *text*, so a
picture-only clipboard left the edit menu with no Paste in it to begin with. The
composer's text view now offers Paste for that clipboard and hands it to the attachment strip
instead of to the sentence, and the paperclip carries **From Clipboard** beside the two pickers
for the same act reached the other way. Text is untouched by both: it keeps the text view's own
paste, insertion point and undo and all. `ComposerClipboard` is the one reader —
`ComposerClipboardTests` pins what it takes, what it skips and the cap.

Two properties are load-bearing there. **Asking what the pasteboard holds is not reading it:**
since iOS 16 reading a *value* raises the system's paste notification, while the `has…` flags and
the type list raise nothing, so availability is answered from metadata and the value is read only
once somebody has chosen the entry — a control that prompted merely by being drawn would teach
people to refuse the prompt. And the item count comes from **whatever another app put there**, so
it is capped at the eight a message carries *before* anything is read, rather than by the tray
refusing the ninth file after its bytes were already copied out of the pasteboard server. A file
copied in another app arrives as a URL rather than as bytes, which is the one case where the size
is knowable in advance; it is refused on `fileSize` without ever being read.

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
An iOS catalogue refresh also carries one trace from `hostRefreshStarted` through every bounded
route preparation/request and its terminal refresh result. Route records name their phase,
configured timeout, monotonic duration, attempt position, cancellation and winning transport.
Hosted preparation adds coarse rendezvous/host-wait/offer/ICE/proxy stages without SDP, ICE
candidates or service addresses. Pairing, sequential mutation failover, notification registration
and local discovery resolution use the same bounded route records. Live session and dashboard
event sockets use separate traces across hello, failure/end and the scheduled exponential
reconnect delay; both own an explicit hello deadline rather than relying on URLSession to end a
silent peer. Public report delivery records each 30-second HTTPS attempt and whether it was
delivered, left idempotently queued, or terminally refused.
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
in that project, with the reviewed screenshot as a real image attachment when included.

**The opening is atomic, and image bytes never become prompt text.** The public intake still uses
base64 as a bounded HTTP wire encoding, but the paired-Mac path places readable report JSON in
`RemoteReportSessionOpeningDTO.prompt` and the JPEG in its separate screenshot field. The Mac
validates and stages that JPEG on the remote-server queue, then the session coordinator takes its
own attachment-store copy and appends only that copy's quoted path before launch. Failure at any
of those gates starts no chat. The legacy `RemoteCreateSessionRequestDTO.prompt` is deliberately
empty for this path: a Mac predating the atomic envelope ignores the new field and refuses the
empty prompt, rather than creating a report chat that lost the picture or received raw base64.
The catalogue advertises `report-session-opening`; a current phone uses the old prompt route only
for a text-only report to an older Mac, and asks for a Mac update when a selected screenshot could
not travel safely.

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

Each remote Native composer owns its draft. A shared iPhone terminal uses an independent local
composer and sends the completed text plus Return as one PTY write. This does not make the
terminal multi-user: it creates a safe atomic boundary at submission so concurrent devices cannot
interleave individual characters. The key bar's controls remain immediate terminal controls.
When the terminal is solo, the same bar can switch between that Compose surface and Direct TUI
input; collaboration temporarily requires Compose and does not overwrite the saved solo choice.

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

A named cap takes its bytes from SwiftTerm's live encoder rather than stopping at that classic
fallback. Codex negotiates kitty keyboard event reporting before `/model`; under that contract a
touch arrow is a press followed by a release, and enhanced functional-key spelling takes
precedence over DECCKM. The bar owns both ends of a touch and sends both events in one ordered PTY
write. Snippets and hand-authored raw sequences remain verbatim by definition.

Modifier caps have two compatible lifetimes. A completed tap still cycles off → armed → locked →
off, but the cap is also active from touch-down to touch-up, so holding ⌃ or ⌥ with one finger and
tapping an arrow with another sends one real xterm chord. Using a modifier in that held chord
consumes its later button activation instead of accidentally arming the following key. One shared
button style owns the immediate pressed travel and theme fill for every cap; retained, prewarmed
feedback generators acknowledge completed key and latch actions instead of constructing a cold
generator after each release.

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
The two trailing SF Symbols also cannot be aligned by their equal frames: the dismissal chevron
and customization badge extend below different keyboard-shaped motifs. Their group aligns on the
symbols' first text baseline, which puts the shared keyboard chassis on one visible ink line.

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
should move the provider key behind a service it operates rather than ship it in either app.

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

Scheduled expiry cleanup keeps each D1 delete to a 1,000-row page, then immediately repeats only
the statements that filled their page. An accumulated assertion, notification, rendezvous, or
refresh-session backlog therefore drains in one scheduled invocation instead of losing ground
behind a fixed daily cap.

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
  for the same reason. While the `lan` door is on, the Mac advertises each bound address, its
  `.local` name and any `remoteAccessAdvertisedHostname` override as `https` `lan` endpoints; while
  the `tailscale` door is on, it advertises each bound tailnet address and this Mac's MagicDNS name
  on the same sticky port as `https` `tailscale` endpoints. Every one of them is marked as
  presenting the Mac's own identity, and **Serve's `*.ts.net:8443` origin is never among them**.
- **A routable door presents a certificate of this Mac's own, and the phone trusts exactly the one
  whose fingerprint it scanned.** There is no certificate authority in the path, which is not a
  downgrade from a public certificate but stronger: no authority can be induced to issue a second
  certificate for the same name, because a name is not what is being trusted. It also means one
  identity serves every address the Mac ever has, so the same pairing keeps working from a VPN, a
  tailnet, or a new DHCP lease. The certificate lists this Mac's addresses and `.local` name as
  subject alternative names for tidiness; **the client checks none of them**, and hostname
  verification is deliberately not performed for a pinned host.
- The private key and its certificate are `0600` files in Threading's own Application Support
  directory, under `RemoteIdentity`, and the identity is rebuilt from them on every launch.
  Deliberately not a Keychain item: an agent's shell can delete a login-keychain item with
  `security delete-generic-password` and no prompt, and this app launches agents with an
  unrestricted shell, so a stray deletion would silently invalidate every pairing. The trade is
  that any process running as this user can read the file, and for a trust root the deletion
  failure is the one that matters. A missing or unreadable identity is a named state, never a
  quiet regenerate: a door with nothing to present binds nothing at all rather than falling back
  to cleartext, and the identity is minted only on first enable and on an explicit reset.
- **Active owner-device and guest-share bearer records prefer the data-protection Keychain.** The
  build probes the entitlement once; a build that cannot use it falls back to the login Keychain
  and the Remote Access page warns that the agent's command line can add or delete entries there.
  On upgrade, a legacy envelope is decoded and fully validated before it is copied. The protected
  write commits before the legacy item is removed, corrupt or future-version data stays untouched,
  and a protected empty sentinel prevents a login-Keychain item planted after the first upgraded
  launch from becoming authority. Once present, the protected item is the only item read for
  authorization.
- The pairing code carries the fingerprint. `SHA-256` over the leaf certificate's DER, truncated
  to 128 bits and written base32 upper case, is 26 characters entirely inside QR's alphanumeric
  mode, and it rides as a second fragment component: `HTTPS://192.168.1.42:8760#<token>.<code>`.
  Neither the pairing token's alphabet nor a bearer's contains `.`, so the split is unambiguous,
  and a client written before this reads the whole fragment as one bearer and is refused with a
  401 rather than connecting unpinned. `/api/me` carries the whole 64-character hex fingerprint to
  an owner, so a phone that scanned 128 bits holds all 256 immediately afterwards.
- **The identity can be replaced without re-pairing.** A phone connected over the pinned channel
  is talking to the holder of the private key, so a successor announced there is authenticated by
  the identity it replaces: the Mac mints the next certificate, advertises it as
  `nextPinnedFingerprint`, and switches to it when asked, on the same port and without touching
  loopback. A device that has read the announcement pins both and does not notice. An announcement
  arriving over an unpinned connection is not one. "Reset identity" therefore becomes the path for
  a *lost* key rather than the only path there is, and it is the one action that does unpair every
  device that did not receive an announcement.
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
- **This network** and **Through a VPN** bind routable addresses, which is a change of exposure:
  Threading becomes an app that accepts incoming connections. Nothing is bound that a way in did
  not ask for, every routable listener presents this Mac's pinned certificate, and loopback stays
  cleartext because the Hosted Direct bridge and Tailscale Serve talk plain HTTP to it. No router
  port is forwarded and no inbound firewall rule is opened on your router; what changes is that
  this Mac answers on a network you are already on.
- **A one-chat guest link opens nothing new.** It points at a way in that is already bound and is
  reached the same way an owner device reaches it, with the same certificate and the same
  authorization path. A guest holds a bearer for one chat, is never sent this Mac's endpoint list,
  and never learns an identity from `/api/me`. Nothing starts on their behalf, and revoking the
  link or the member ends it immediately.
- While **Tailscale** is on, the listener binds the addresses this Mac holds on its tailnet, with
  the same pinned identity and the same sticky port as every other routable door. Tailscale filters
  packets between nodes whatever port they are on, so the tailnet's ACL policy still decides who
  may reach it; **a rule written against Serve's 8443 has to be rewritten against the listener's
  port**, which is migration rather than a capability change. Tailscale still relays encrypted
  WireGuard traffic when peers cannot connect directly.
- While **Open in a browser on your tailnet** is on, Tailscale Serve additionally exposes the
  loopback listener as HTTPS/WSS on dedicated port 8443 under the `*.ts.net` name. Threading
  removes only that exact Serve handler when it stops and never runs `tailscale serve reset`, which
  could erase unrelated services. Before starting, it reads `tailscale serve status --json` and
  refuses to replace an existing HTTPS handler on 8443; remove that handler explicitly and retry.
  Serve runs in acknowledged background mode and every CLI probe has a bounded timeout, so a wedged
  CLI cannot leave the sub-option permanently starting. **Enabling it publishes the
  machine/tailnet DNS name in public certificate-transparency logs**; it does not publish chat
  contents or make the service public, and it is off by default for that reason. No phone uses it:
  the iOS app pins the certificate this Mac holds and reaches the tailnet address directly.
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
  (`RemoteConnectionLink.scannablePayload`), a LAN door with the fingerprint beside the token
  encodes in 33 modules; the 52-character relay host it replaced needed 37 with the token alone,
  and 41 before the token changed. It remains an unguessable online-only bootstrap held in memory, is accepted once (with a
  short same-device retry window for a lost response), and rotates immediately. Invitation and
  durable device bearers remain 256-bit base64url: they travel by copied link or protocol
  exchange, never by camera, so they buy nothing from the QR trade.
- Pairing-link decoding re-enters the same failable initializer as scanned and programmatic links.
  Synthesized `Codable` would otherwise bypass the HTTP(S), host, user-info and non-empty-bearer
  checks and manufacture a value its non-optional endpoint accessors could not safely represent.
  The validated share URL is derived once at construction, while only the normalized origin and
  bearer are persisted.
- **The 128-bit choice was forced by the host, and the host has since shortened.** A 52-character
  `trycloudflare.com` hostname used to be most of the payload; a LAN door is `192.168.1.42:8760`
  and the fingerprint is now the longest thing riding beside the token. At level M the shipping
  payload measures 33 modules (`PairingCodeImageTests` holds the number). Full 256-bit entropy
  would cost versions the code does not need to spend, so the bootstrap stays 128-bit: it is
  online-only, held in memory, and rotated on first use. Upper-casing the origin keeps earning
  either way.
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
  Catalogue event deltas apply the same scope before emitting anything: an out-of-scope row
  change sends neither a summary nor the changed conversation's identifier or activity timing.
  Archiving a live session immediately disconnects any remote viewer already attached to it.
- Authentication failures are rate-limited globally and per device, and slow WebSocket consumers
  are dropped instead of being allowed to back-pressure an agent's terminal. Inbound WebSocket
  reads are decoded with a cursor and compacted once per network receive; a batch of thousands of
  minimal pre-authentication frames therefore remains linear work on the server's shared queue.
  A frame and a complete reassembled message are each capped at 1 MiB. Every continuation is
  compared with the buffer's remaining capacity before `Data.append`, so the transient retained
  message never exceeds the stated cap; the server admits at most 32 connections.
- Native REST mutations carry a request id. The Mac coalesces concurrent duplicates and keeps the
  bounded result for five minutes, while rejecting the same id with a different path or semantic
  JSON body. JSON key order and whitespace are normalized before fingerprinting, and iOS emits
  sorted keys as compatibility with installed hosts that fingerprinted bytes. The iPhone can
  therefore retry a lost response, including over another advertised endpoint, without starting
  two sessions or applying an action twice. Native prompts and atomic terminal
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

### Discovery on the same network

The `lan` door works without discovery: the Mac advertises its addresses through `/api/me` and
the phone remembers them. Discovery answers the question that list cannot, which is where the Mac
is *now* after DHCP moved it. Without it a new lease costs a re-pair; with it the phone
re-resolves and carries on.

- **What is broadcast.** While Remote Access is on, the `lan` door is bound and
  `remoteAccessDiscoveryEnabled` is on, the Mac registers `_threading._tcp` on that door's
  listeners and nowhere else. The instance name is an opaque 16-character token derived from this
  Mac's id, never the computer name: `NWListener.Service(name: nil, …)` advertises under the
  computer name, which usually contains the user's own. The TXT record carries three values and
  the parser on both ends refuses a fourth: the host id, the protocol version, and the full
  64-character certificate fingerprint. No user name, no project names, no chat titles. macOS
  broadcasts this Mac's `.local` hostname regardless of Threading; that one is not ours to hide.
- **One registration, not one per address.** Several LAN interfaces mean several listeners under
  the one door, but Bonjour advertises a host: the SRV record names the `.local` hostname and the
  address records behind it already cover every interface. A second registration of the same name
  and port would only earn a platform rename.
- **The announcement follows what is bound.** A door with no address on it announces nothing, and
  the record names the certificate the door presents, so rotating the identity re-registers with
  the new fingerprint on the same port. Turning discovery off withdraws the registration and
  leaves the door open; the addresses are still advertised through `/api/me`.
- **Match, do not trust. Pairing stays QR-only.** A discovered service is interesting to the phone
  only when its TXT fingerprint is one that phone already accepts for a Mac it has already
  paired with, current or announced successor. Everything else is ignored, including an unpaired
  Mac advertising the same service type and a service claiming a paired Mac's host id with a
  different fingerprint. A match puts the record's *existing* pins in force for the newly learned
  address and changes nothing else: no pairing is created, no pin is learned or widened, and the
  connection that follows still has to be answered by the certificate behind that fingerprint.
  A guest capability never matches at all.
- **The phone browses only in the foreground, and only when it has a Mac to look for.** The
  tracked services and the remembered addresses both have ceilings, one service is resolved at a
  time with a deadline, and the browser is stopped in the background. A discovered address is
  held in memory rather than written into the pairing: it is a fact about the network the phone is
  on right now.
- **Denial degrades.** If iOS Local Network access is refused, browsing finds nothing and the
  advertised endpoint list is the fallback, exactly as it is for a VPN or tailnet address.
- **It does not cross a tunnel.** Multicast rarely crosses WireGuard, so UniFi Teleport, an
  ordinary VPN and the tailnet carry no discovery. They do not need it: those addresses come from
  the advertised list, and `remoteAccessAdvertisedHostname` is the escape hatch for an address the
  Mac cannot enumerate.
- **Two rows on the Remote Access page, inside the "This network" card.** *Announce on this
  network* is `remoteAccessDiscoveryEnabled` and states the payload rather than describing it:
  an opaque name, this Mac's id, its protocol version and its certificate fingerprint, never the
  computer name and never the user's, and pairing still needs the code. Under it, *Announced as
  <name>* prints the instance name currently registered, which is the one part of the payload
  that is safe to show and the only way a person can check by eye that no name of theirs is on
  the network. Both come from `RemoteDiscoveryPresentation`, so the states are rendered from a
  value rather than from a live registration a hosted test must not make.
- **Local network privacy applies to the Mac too.** macOS 15 brought it over from iOS, and Apple's
  TN3179 is explicit that *every* Bonjour operation needs the privilege, registering a service
  included. So Threading's own `Info.plist` carries `NSLocalNetworkUsageDescription` and
  `NSBonjourServices`, and the first announcement is what asks. Listening for and accepting
  incoming TCP needs no privilege, which is why the door itself works whatever the answer is.
  Measured on macOS 26.5: the same registration completed in about 0.7 seconds from a
  Terminal-run binary, which TN3179 exempts along with daemons and root, and completed not at all
  under an app identity whose privilege was undetermined. A hosted test is in the second group, so
  the real round trip is a manual `dns-sd` check written down in `RemoteServiceDiscoveryTests`
  rather than a test that would fail on every machine.

**Wake on Demand comes with the advertisement, under two conditions.** macOS hands a
Bonjour-advertised listener to a Sleep Proxy on the network, which is an Apple TV, a HomePod or a
capable router, and the proxy answers for the sleeping Mac and wakes it when somebody connects.
`RemoteWakeOnDemandFacts` holds the two inputs: whether "Wake for network access" is on, read from
`pmset`, and whether a sleep proxy answered a short `_sleep-proxy._udp` browse. `canWakeThisMac`
is true only when **both** hold, and unknown is never yes. With the setting off macOS never hands
the registration over; with no proxy present there is nothing to answer for a sleeping Mac and it
sleeps through every attempt exactly as before. Nothing may render "can wake this Mac" from
anything but that value.

The settings page states it as a fact line under the announcement, and there are five of them:
*Can wake this Mac from sleep* when both facts hold, *Wake for network access is off in System
Settings ▸ Energy*, *No sleep proxy on this network; an Apple TV or HomePod provides one*, *Not
checked yet* while either fact is unknown, and *Waking needs an announcement on this network*
when nothing is registered. The last one is not redundant: a Sleep Proxy answers for an
*advertised service*, so both facts can hold on a Mac that is announcing nothing, and without it
the page would promise waking through a service it had just withdrawn. The two facts are read
when the page appears and when the `lan` door's state changes, never on a timer: reading them
costs a child process and a multicast browse, and a sleep proxy is a property of the network this
Mac is attached to rather than of the Mac.

### Over a VPN, and over Teleport

A VPN puts the phone on a network this Mac is already listening on, so almost nothing here is
new: the `lan` door answers, the certificate is the same one, and the port is the same sticky
port. What is new is honesty about which door an address arrived on. Every VPN and the tailnet
appear as a `utun`, and the only thing telling them apart is whether the tunnel carries an
address out of `100.64.0.0/10`; anything else on a `utun` is somebody's VPN and is advertised as
kind `vpn`. UniFi Teleport is WireGuard underneath and hands the phone an address inside the home
network, which is the case that looks most like the LAN and is still not it. A rule that read
the address alone would advertise Teleport's endpoint as `lan`, and a phone would try it while
off the Wi-Fi. `RemoteListenerDoorTests` asserts the classification, its range edges, and the kinds
`doorEndpoints` publishes.

**Discovery does not reach here.** Multicast rarely crosses WireGuard, so a tunnel carries no
Bonjour: the advertised endpoint list is what makes a VPN work, and
`remoteAccessAdvertisedHostname` is the escape hatch for an address this Mac cannot enumerate.
Nothing about waking applies either, for the same reason: a Sleep Proxy is a link-local
service.

**Not yet run.** The plan's §7 acceptance is a live check with hardware this repository cannot
stand in for, so it is written down rather than asserted:

- [ ] With Teleport connected on **cellular** (Wi-Fi off on the phone, so nothing can be reached
      the short way), the phone reaches the Mac and the chat list loads.
- [ ] It uses the **same pinned certificate**: the 26-character identity code the phone shows for
      that Mac matches the one on the Mac's Remote Access page, and no
      "This Mac's identity does not match" state appears.
- [ ] It uses the **same port**, the one the `lan` door reports on the Wi-Fi.
- [ ] **No re-pairing and no settings change** on either device: the tunnel goes up, the phone
      connects, and nothing is scanned.
- [ ] The Mac's advertised address list refreshes when the tunnel goes up and down, rather than
      keeping one address for the life of the process.
- [ ] Bonjour is confirmed absent over the tunnel (`dns-sd -B _threading._tcp` from the phone's
      side of it finds nothing), which is expected and is why the address list carries this.
- [ ] Only one packet-tunnel VPN runs on iOS at a time, so Teleport and Tailscale are checked one
      at a time rather than together.

### iPhone trust evaluation

<!-- Owned by the iOS client. Self-contained on purpose: nothing above or below depends on it. -->

The phone trusts one public key, learned by photographing a code on the Mac's own screen. There
is no certificate authority in that path, and therefore no authority that can be induced to issue
a second certificate for the same address.

- **One pinning delegate, both sessions.** `RemoteClient` owns a request session and a WebSocket
  session, and `RemoteCertificatePinningDelegate` is attached to both. A server-trust challenge
  goes to the session-level delegate, so a socket on a session without one silently keeps stock
  evaluation, which refuses a Mac's self-signed leaf outright. `RemoteHostTrustTests` asserts the
  two sessions hold the same object rather than two configured alike.
- **Two sources for a pin, and no third.** The scanned pairing link pins its own host before the
  first request is made over it. An owner `/api/me` response pins the host of every advertised
  endpoint carrying `identity: "pinned"`, which now includes the tailnet address and this Mac's
  MagicDNS name. An endpoint without that flag keeps stock evaluation, because it is terminated by
  somebody else's certificate and pinning that host would refuse the one endpoint that works; no
  build advertises one today, since Serve's origin is never sent. A guest capability never teaches
  a phone a pin.
- **Why a `/api/me` response is trustworthy.** It exists only because the pin matched or because
  the system validated a publicly issued certificate; a refused challenge produces no response to
  read. So the fingerprints in it are the Mac's own word about its identity.
- **Rotation without re-pairing.** `nextPinnedFingerprint` is accepted beside the current one, so
  a Mac can announce its successor over the pinned channel and start presenting it later with no
  device scanning anything. When a later response reports the successor as current, the phone's
  record follows and the retired certificate stops being accepted. Absence never clears a pin: a
  host that says nothing about its identity is an older Mac, not an instruction to stop pinning.
- **Hostname verification is deliberately not performed for a pinned host.** The certificate
  covers no name a certificate authority could vouch for, and one identity serving every address
  the Mac ever has is what makes a VPN address, a tailnet address and a new DHCP lease work with
  the same pin.
- **A mismatch is its own named failure.** A cancelled server-trust challenge surfaces as
  `URLError(-999)` with no underlying error, so the delegate records its own verdict per host and
  the client reads that. The phone says "This Mac's identity does not match the one you paired
  with", offers re-pairing, and never presents it as a generic network error or as a changed
  address. A support report carries the verdict as a token; the fingerprint itself is not a fact
  a report contains.
- **The dashboard stops loading when the attempt has stopped.** An offline phase retains the
  structured failure rather than only its sentence, so an owner with no cached catalogue gets a
  recovery card instead of an indeterminate “Loading sessions…” card. It names only the saved
  doors in compact product language (LAN, Tailscale, VPN or Direct), never an address or port,
  offers the cause-specific next step, and keeps re-scanning available after an ordinary route
  failure. The complete 26-character identity already pinned by the phone is shown for comparison
  with **Settings ▸ Remote Access** on the Mac; a mismatch has no “trust this answer” shortcut.
  **Report a problem** opens the app-owned private-report consent sheet without capturing the
  screen. Its reviewed package is written to the protected iOS outbox before delivery, so neither
  the Mac route nor immediate Internet connectivity is required; the same idempotent package
  retries when connectivity returns in the foreground. Reporting and outbox policy remain
  host-owned alongside connection truth and recovery actions.
  This recovery surface is deliberately host-only under the customization-surface gate: Threading
  retains connection truth, certificate comparison and every recovery action even where other
  presentation is customizable.
- **Persisted with the pairing.** Both fingerprints live on the paired-host Keychain record, so
  the pin is in force on the first request after a relaunch rather than only after the request
  that would have learned it. The 26-character code is shown beside the Mac in Choose Mac for
  comparison against the Mac's own settings page.
- **The port walk is not a trust decision.** A `lan` address on the sticky range is retried on
  the remaining ports of that range, in the listener's own order, and only while nothing has
  answered. An HTTP status, an authentication refusal or a refused certificate ends that door
  immediately.
- **A door is also over when its address definitively cannot be reached.** A name-resolution or
  explicit no-route failure rules out every remaining port at that address, so `RemoteDoorWalk`
  moves to the next door and records one bounded skip decision. A generic request timeout is not
  such a verdict: URLSession does not say whether a port was filtered or a server accepted the
  connection and stalled, and a listener may still occupy another port of the sticky range. The
  read-only catalogue races network families independently, so preserving that port walk does
  not put a viable Tailscale or VPN lane behind repeated LAN timeouts. A refusal also keeps
  walking; finding a listener on another port is the walk's reason to exist.
- **Local Network access.** `NSLocalNetworkUsageDescription` ships with the `lan` door because
  iOS prompts on the first unicast to a same-subnet private address, not only on Bonjour. A
  denial produces an ordinary no-route error, which the phone tells apart from an absent host by
  the address it was aimed at, and reports as its own state with the Settings link.

## Beta limitations

Hosted Direct is implemented but not production-deployed by this repository checkout. The
checked-in Worker configuration contains a deliberately invalid D1 identifier, and the production
hostname, Cloudflare Realtime key, Sign in with Apple server key, rate-limit namespaces and Apple
server-notification registration must be provisioned or confirmed before distributed builds can
use it. A forced TURN-only run and the broader NAT/sleep/handoff matrix remain release gates.

Every advertised route is stable now, which is what lets a pairing survive a restart: a bound
address and the sticky port are the same tomorrow, and a phone that finds neither learns the
current list from the next route that does answer. A phone still paired to a retired Quick Tunnel
address has a dead endpoint and no way to learn a live one, so those pairings have to be scanned
once more. An owner paired over the tailnet reconnects after a Mac or app restart without
rescanning as long as Tailscale is running on both devices.

**Public guest links are gone with the relay.** A guest needs the Threading app and a way onto one
of your networks; a browser-only guest comes back when the bundled client can be served over an ICE
data channel.

On iPhone, Tailscale must be connected before this Mac's tailnet address or MagicDNS name is
reachable. iOS permits only one active packet-tunnel VPN at a time, so another VPN may prevent that
connection; in that situation reach this Mac over the VPN you do have connected, which the network
way in already answers.

An operated release can add account-backed rendezvous and invitations. Without recipient
accounts Threading cannot
push to a friend *before* they accept a share link; their messaging app carries the invitation,
then Threading registers that accepted capability and can notify the device from then on.

Remote access cannot wake a Mac that is offline, and cannot wake a sleeping one except on the
same network, where the sleep proxy path above can: both "Wake for network access" and a proxy on
the network are required, and Threading claims it only when it has observed both. A remotely
resumed session starts in the background and does not activate or bring Threading's Mac window to
the front. While Remote Access is starting or listening, Threading holds a
`userInitiatedAllowingIdleSystemSleep` process activity. This prevents App Nap from suspending the
main-actor work behind an otherwise healthy listener when the app has no visible window, while
deliberately preserving normal system sleep. The activity ends when Remote Access stops or its
listener fails.

Remote session creation intentionally exposes only checkouts the Mac already knows. Git Review,
the read-only repository browser, detected image/PDF previews, and browser follow snapshots have
separate owner-only and size boundaries; file surfaces additionally enforce path containment.
Arbitrary filesystem access, browser control from the phone, and private browser pixels are not
exposed. Composer attachment uploads are — narrowly, and only as described under
[Sending a file from the phone](#sending-a-file-from-the-phone); the phone can put a file in the
attachment store of one session it may already write to, and can do nothing else with the
filesystem.

For the tailnet way in, install and sign in to Tailscale on the Mac and iPhone, and make sure its
ACLs allow the iPhone identity to reach the Mac **on the listener's port** (`8760` by default), not
on Serve's 8443. Enabling HTTPS for the tailnet is needed only for the browser sub-option.
Threading invokes the local `tailscale` CLI to read this Mac's status and, when that sub-option is
on, to publish and remove its own Serve handler; it does not sign in, change tailnet ACLs, or
enable the VPN for you.

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
  (`RemoteListenerSet`, `RemoteAccessDoors`), the pinned identity the routable doors present
  (`RemoteAccessIdentity` and the `RemoteIdentity*` encoders behind it), durable owner-device
  registry, authentication, the Tailscale Serve transport, routing, the application
  command capability, and live session mirrors.
- `Sources/Threading/Resources/RemoteClient`: dependency-free browser client. A browser on the
  LAN or the tailnet meets a certificate interstitial against a pinned self-signed identity;
  **Open in a browser on your tailnet** (`TailscaleServeTransport`) is the opt-in way around that
  on a tailnet, and the iOS app is unaffected because it pins. Its five allowlisted bundle assets
  are loaded lazily once per server lifetime; browser `no-store` remains a privacy and protocol
  requirement, not a reason to repeat synchronous disk reads on the connection queue.
- `ThreadingRemoteKit`: versioned wire DTOs, pairing-link parsing, the fingerprint codec and
  pinning policy (`RemoteHostPinning`), and the discovery vocabulary both ends have to agree on
  (`RemoteServiceDiscovery`: the service type, the TXT keys, and the opaque instance name).
- `Sources/ThreadingMobile`: SwiftUI iOS shell, UIKit Native-conversation timeline and SwiftTerm
  terminal surface.
- `docs/NOTIFICATION_E2E.md`: opt-in real APNs and Claude → MCP → APNs verification.
- `docs/REMOTE_DIAGNOSTICS.md`: privacy boundary, cross-device tracing and support workflow.
