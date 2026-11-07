# Linked Workrooms

Agents put structured questions to named people outside this Mac — domain experts, not
programmers — and get typed answers back as mail. The product direction is
[`linked-workrooms.md`](../feature-drafts/linked-workrooms.md); the slice described here was
planned in [`linked-workrooms-expert-portal.md`](../feature-drafts/linked-workrooms-expert-portal.md).
The controller's older, work-bound questions (schema v11) are in
[`autonomous-controller.md`](autonomous-controller.md#linked-workrooms-schema-v11-local-trial).

## Shape

```
agent session ──MCP "Workrooms"──▶ WorkroomAgentCommandService ──▶ ControllerStore (mailbox.db, v12)
                                    │ git context captured by host        ▲
owner ──native approval / Settings──┘                                     │ participant ops only
person ──https──▶ tunnel (ngrok | cloudflared) ──▶ WorkroomPortalServer (127.0.0.1, in-app)
answer ──▶ mail reply person→session (same txn) ──▶ MacMailDelivery.arrived ──▶ notice / wake
```

| Piece | Where |
|---|---|
| Records, forms, access tokens, person mailbox | `Packages/ThreadingController/Sources/ThreadingController/Workroom*.swift`, `ControllerMail.swift` |
| Portal: routes, policy, rendering, Swedish and English | `Packages/ThreadingController/Sources/ThreadingWorkroomPortal/` (Foundation only, no sockets) |
| Loopback socket, tunnel, start/stop, delivery | `Sources/Threading/Core/Workrooms/` |
| Agent tools | `Core/MCP/MCPWorkroomTools.swift`, `Core/Workrooms/WorkroomAgentCommandService.swift` |
| Owner surfaces | `UI/Windows/WorkroomOpeningSheet.swift`, `UI/Preferences/WorkroomsPreferencesViewController.swift` |

## Decisions

**Questions live in the Mac's own controller store.** `MacMailbox`'s `mailbox.db` already holds
every Mac session's mailbox; a workroom question is a record beside them, so the question, its mail
and later the answer's mail commit in one transaction. The portal runs inside the app and reads the
store through the same actor, so there is no second writer and no schema skew between processes.

**An answer is mail.** `MailboxKind.person` is a third mailbox kind. A question is mail from the
asking session to the person's mailbox (admitted by the workroom, not a grant); an answer, a
clarification request or a decline is a reply from it, which `isReplyToOwnMail` admits and marks
`wake`. So a busy agent hears through its hooks, an idle terminal gets the notice typed, a dormant
native chat is woken — every surface `MacMailDelivery` already handles — and nothing new delivers
words into a session. The mail text is a summary Threading writes; the typed answer is in the
record (`workroom_questions`). The header says the message was written by a person outside this
Mac and is information, never instructions or permission. Rejected: a host notice through
`SessionMessageDelivery`, which reaches no dormant session and would duplicate the notice,
stop-continuation and wake machinery.

**Person mail never leaves this host.** `send` refuses a person sender or recipient unless it comes
from the workroom operations and stays local; `accept(peer:)` refuses person envelopes; no grant can
name a person; no forward or `mail-move` carries a person's reply. Older peers never see the new
kind, so they never fail to decode it. A question starts a fresh mail chain: a person answering
ends an unattended exchange the way a person's own prompt does (`MailHumanTurn`).

**The portal is in the app, behind its own listener.** `WorkroomPortalServer` binds 127.0.0.1,
shares no port, router or handler with `MCPServer` or `RemoteAccessServer`, and serves only
`WorkroomPortal`, whose route table (`WorkroomPortal.routes`, pinned by a test) has no owner route.
Rejected for now: a `threading-workroomd` helper. Autoinstall restarts the app often enough that a
helper would gain little availability, sleep stops both, and it would cost a target, a launchd
registration, retire-on-upgrade, Keychain access lists and a cross-process mail signal. The core is
Foundation-only, so it can move to a helper or a Linux host if answers while the app is quit turn
out to matter.

**Approval is native.** Agents can drive Threading's own browser, so any owner action on a web
page would be one they could click. Opening a room is `ConfirmationPrompt.approveWorkroomOpening`
(`.alwaysAsks(.securityGrant)`), whose message names the room and project, the person (and whether
the agent proposed them), the questions waiting, the tunnel and that its provider can read the
traffic, the duration and — labelled — the agent's reason. `WorkroomOpeningLedger` allows one sheet
per room and person and refuses a repeat for 15 minutes after a no.

**Rooms are created by agents but private.** `workroom_create` exists only while Settings ▸
Workrooms is on, and its wording says to use it only when asked; that is a request, not a guard,
which is acceptable because a room is invisible outside this Mac until the user approves an
opening. A room records the session that created it.

**A room belongs to a repository, not a checkout.** Each checkout and worktree is its own
`Project`, and a chat moves between them (`set_session_checkout`, a managed workspace's own
worktree). Rooms were first scoped to the creating project, so a chat that moved lost the rooms it
created and asked in — `workroom_questions` refused the very question whose answer had just arrived
by mail — and agents in sibling checkouts of one repository could not share a decisions room.
The scope is now `repository:<git common dir>` (`Project.lastKnownRepositoryIdentity`); a folder
Git never verified keeps `project:<id>`. `WorkroomScopeMigration` moves each older project-scoped
room to its repository's scope once, when the host refreshes and the project's repository is
known (`rescopeWorkroom`, idempotent; questions, access and publication are keyed by the room and
move with it). An answer that arrives while a chat is moving is not lost either way: it is mail
in the session's durable inbox, delivered by the new process's hooks.

**A pluggable tunnel, and its address problem.** `WorkroomTunnel` supervises one child through
`ChildProcessSpawn` and `AgentChildLedger` and reads the public address from its output. ngrok uses
the user's own configuration merged with a private overlay (`agent: web_addr: false`, 0600 file in
a 0700 directory, deleted on stop): with the local agent API on, any process of this user could ask
the running agent to open more tunnels on the account. Configuration files are passed as repeated
`--config` flags. A Cloudflare Quick Tunnel needs no account but its address changes every start,
which kills sent links — the incident behind [`named-cloudflare-tunnel.md`](../decisions/named-cloudflare-tunnel.md)
— so Settings says so and ngrok with a reserved domain is the default. Why a tunnel is acceptable
here at all: [`workroom-participant-tunnel.md`](../decisions/workroom-participant-tunnel.md).

**The portal runs only while it has something to serve.** `WorkroomHost.refresh()` starts the
listener and the tunnel when Workrooms is on and at least one room is open, and stops both
otherwise — at launch, on a Workrooms setting change, after an opening or a close, and every five
minutes so an expired room stops the tunnel unattended. It never starts in a hosted test.

The Settings page keeps its header, switch and address controls mounted while status changes or
people and rooms reload. A full page replacement detached the switch during its flip and discarded
keyboard focus. The page links its controls in visual Tab order, including the Add a person fields
and any room actions; a data refresh replaces only the bounded people and room cards.

**The git context is the host's.** `WorkroomGitContextReader` reads the asking session's working
directory (`ProjectStore.workingDirectory(forSessionID:)`) off the main actor through
`GitProcess`: head, base (the agent's `base_ref` or the default branch), merge-base, the first 50
changed paths and their total, up to 20 commit subjects, and whether the checkout is dirty. The
model never types it, so an answer is pinned to the code it was about. Agents and the owner read it;
the person's page does not show it.

**Language follows the person.** Each person has a BCP-47 language and who set it. An agent may
change it (`workroom_set_language`) when answers show another preference; a choice the person made
in the portal sticks against agents. A question records its own language; the portal's words
(Swedish, English) follow the person's language, then `Accept-Language`, then English.

## A tied chat does not wait in its terminal

A session is **tied** while it created, or asked in, a workroom that is not closed
(`workroomTie` records, written by `createWorkroom` and `askWorkroom`; `workroomTies` reads at most
100). For a tied session, `WorkroomQuestionGuard` answers two hooks through
`/question-guard/<token>?event=…`, an answering endpoint like `/mail-notice/`:

- **`PreToolUse` on `AskUserQuestion`** (Claude terminals): denied, with a reason that says to ask
  with `workroom_ask` and keep working. This is enforcement; the tool does not run.
- **`Stop`** (Claude terminals, and Codex through the shared `hooks.json`): blocked **once per
  turn** when the last message's closing paragraph ends on a question (a `?` in a URL does not
  count). `stop_hook_active` and the remembered `turn_id` (or the message's tail when a runtime
  sends none) mean a turn that ends on a question again is let through, so a question only the
  person at the terminal can answer still reaches them and nothing loops. A block goes through
  `MailStopContinuationLedger` like a mail notice's, so the chat is not shown idle while it
  continues.

Questions for the owner go to the person chosen in **Settings ▸ Workrooms ▸ Questions for you go
to**, who is granted beside anyone a room is opened to. Without one, the reason tells the agent to
state its assumption instead. Every untied session gets an empty answer. The entries are written
for every session with lifecycle hooks and decide at request time, because a chat becomes tied
mid-session; changing Codex's `hooks.json` costs one renewal of the user's hook trust. Native
chats are not guarded yet: their questions reach the app's own permission card.

## A question is a conversation

An agent rarely gets everything from one form. The person needs to ask what a term means, add a
fact the form had no field for, or answer a follow-up about their own answer, and the agent needs
to ask that follow-up. So every question page is a chat between the person and the asking session,
and a person's inbox is ordered like one.

- **Either side may write while the question is open or answered.** The person posts
  `POST /q/<id>/clarify`, which mails the asking session (`wake`, like an answer); the agent calls
  `workroom_respond` with `action: message` (`clarify` is kept as its earlier name). The stored
  note kinds stay the v12 `clarification` (person) and `response` (agent), which every build
  decodes; the portal shows both as messages. A conversation holds 60 messages
  (`WorkroomLimits.notes`); a closing decline or withdrawal is always admitted beyond that.
- **An agent's message must reach a person who is not looking.** Without that, a follow-up on an
  answered question sat in a section nobody reopens. A `workroomReply` record (key: the question,
  `parent`: the person, a 280-byte preview) marks it. It is written again on each agent message, so
  the newest sorts first through `record_parent`, and removed when the person opens the question,
  answers, writes or declines, or the agent withdraws. Opening a page is a write only when a mark
  exists. No schema change: it is a new record kind beside the others.
- **Each question is in exactly one inbox section:** New messages (marked, newest reply first),
  Waiting for your answer (open), Answered and closed. The open and recent scans read the mark as an
  `EXISTS` column of the same indexed row, so the 500-row examination bound covers it.
- **Order is the store's, not the clock's.** Stored times have whole seconds, so a quick exchange
  ties. `detail` reads answers and notes in one query ordered by `sequence` and hands the portal
  `timeline`, which is not encoded into the agents' JSON; they have both lists and their times.
- **Next question.** The page links the person's next open question after this one in a room open
  to them, wrapping to the first (`participantNextQuestion`, at most 100 rows examined). After a
  saved answer it is the notice's button, so a 211-question review is answer, next, answer.
- **Phone first.** One column, 44-point targets, 16-pixel inputs (iOS Safari zooms on smaller),
  `format-detection` off so values like `0,5` are not phone links, language and privacy in the
  footer. Not a home-screen web app: on iOS a standalone page has its own cookie jar, so it would
  open signed out with an already-spent single-use link.

### The page refreshes itself, without trusting the script

The portal was script-free. A chat that needs a reload to show the reply is not a chat, so it now
serves one static, same-origin file, `GET /assets/portal.js`, under `script-src 'self';
connect-src 'self'` and nothing else. It polls `GET /state` (inbox) or `GET /q/<id>/state` (one
question) every 4 s while the tab is visible, backing off to 60 s on errors and stopping on 401 or
404. The answer is `{"v": fingerprint}`; when it differs from the page's `data-version` the page
reloads to its own path (and `#latest` for a question), unless the person has focus in a field or
has typed or chosen something — then it un-hides a server-rendered banner instead. Typed text is
never thrown away.

What keeps this safe: the script inserts no markup and reads nothing but the fingerprint; every
word on the page is still server-rendered and escaped; there is no inline script; and every page
works without it (times stay in UTC, the person reloads). It also shows times in the reader's
zone and disables a form's buttons after one submit. A device polling from three visible tabs uses
45 of its 120 requests a minute. The fingerprints are bounded counts: a question's is
`state.revision.notes` (`WorkroomQuestion.pageVersion`, the same property the page renders, so they
cannot drift into a reload loop); the inbox's combines the newest question, the open count, the
reply marks and the person's room grants (`participantInboxVersion`), each read through an index
with a 500-row limit. Assets carry `?v=` and a hash of their content, so a cached copy never
outlives an upgrade.

## In the Threading app

A person can answer in the iPhone app instead of the browser. It is the same person, the same
questions and the same participant operations, reached through the remote door rather than the
portal's tunnel — so they get native notifications and an icon badge, and the owner can comment
from their own phone.

- **A workroom membership is a guest share whose scope is one person.** `RemoteScope.workroomPerson`
  sits beside `.session` and `.projectTerminal` and covers no chat and no terminal; its `/api/me`
  catalogue is empty and advertises `workrooms`. Settings ▸ Workrooms ▸ **Invite to App** mints it
  through `RemoteAccessCoordinator.prepareWorkroomShare`, the chat-share machinery: Hosted Direct
  when the service is ready, so a person far from this network can accept it, a private door
  otherwise; single use for 24 hours, then a device-bound membership in the guest-share Keychain
  record (`targetKind: workroomPerson`) until **Sign Out**, which ends app devices and browsers
  together. Remote Access must be on; the portal's tunnel is not involved.
- **`/api/workroom/…` routes** (`RemoteWorkroomPath`, DTOs in `RemoteWorkroomDTO.swift`): `inbox`,
  `state`, `question/<id>` and its `answer`, `message` and `decline`. The route is parsed and the
  body bounded (64 KiB) before anything is read; the viewer is decided on the main actor against
  the current authorization and the Workrooms switch (`WorkroomRemoteViewer`), and the store checks
  the person, the room and the question on every operation as it does for the portal. A participant
  acts only as their person, through `WorkroomPortalBackend`, so mail delivery is identical.
- **The owner reads every question and comments; they never answer or decline for a person.** A
  paired owner device sees one `latest` section, newest question first (`ownerWorkroomQuestions`,
  the record page index, 20 a page). A comment is a note with author `owner`, kind `comment` and
  the owner's name (the person chosen for the owner's own questions, else the macOS full name). The
  person sees it as a new message; the asking session hears it as a reply on the question's mail,
  sent from the person's mailbox because that is the reply the question's chain admits, with words
  that say the owner wrote it. A view-only owner device reads but does not comment.
- **Notifications.** `WorkroomAppNotifier` announces a question asked in an open room, the agent's
  message, the owner's comment, and a room opened with questions waiting, only to that person's
  memberships and only for a question they can see. Titles come from the portal's vocabulary in the
  person's language (`WorkroomNotificationText`); the body is the question's title or the message's
  first 300 bytes, which pass through Apple. The kind is `workroom`, its session slot the question
  id, and the request carries `badge`: the person's open questions plus unread messages in rooms open
  to them (`participantWaitingCount`, each counted once, 500 rows of each examined). The hosted
  broker learned the kind and the badge in notification protocol 6; a Mac sends neither to an older
  broker, so the phone then hears only while the app is open.
- **One vocabulary.** The wire spells field kinds, states and fixed answers exactly as the form
  stores them (`RemoteWorkroomYesNo` beside `WorkroomYesNo`, and so on); a test pins each pair.

## Records (schema v12)

### Extending an invitation

Settings' **Extend Link…** and the `workroom.extendLink` command share
`WorkroomLinkExtension` and a native `extendWorkroomInvitation` security-grant confirmation.
The owner adds seven days to the later of the existing expiry and now. The store updates the
same digest-keyed record, retaining its public ID, issue time and single-use state. No plaintext
token is recovered, stored or copied. Pending expired invitations may be renewed; redeemed,
replaced, revoked and removed-person invitations cannot. An exact invitation ID and expected
expiry are revalidated inside the write transaction, preventing stale screens and duplicate
approvals from extending a different link or adding time twice.

This extends the existing host-only Workrooms Settings surface. Themes style its existing
controls; identity, token custody, expiry changes and confirmation remain host-owned. Room
publication and browser session expiry are independent and unchanged. A rotating tunnel address
cannot be repaired by extending the token; a reserved domain is still needed across restarts.

The owner action is infrequent and O(1) indexed reads/writes even with a long invitation history.
The command examines at most the same 50 people as Settings, with one indexed latest-invitation
lookup each; the expected set is a handful. It creates no unbounded views or timer, and database
work stays on `ControllerStore`'s actor. Settings retains its existing bounded page refresh.

| Record (`record.kind`) | Key | Notes |
|---|---|---|
| `workroomPerson` | person UUID; `key` = handle | owner-added, or added on an approved opening; `removed` revokes every device and invitation |
| `workroomPublication` | room id | private (absent) → open (expiry) → closed |
| `workroomAsk` | question id; `parent` room; `scope` asker | immutable draft and git context; state, answer revision and note count |
| `workroomAnswer` | `<question>/<revision>` | immutable; validated against the form |
| `workroomNote` | UUID; `parent` question | clarification (person), response (agent), comment (owner, with `name`), decline, withdrawal |
| `workroomInvitation` | SHA-256 of the token; `parent` person | single use, 7 days; a new one revokes the pending one |
| `workroomDevice` | SHA-256 of the session token; `parent` person | 30 days; at most 20 live per person |
| `workroomTie` | `<mailbox>|<room>`; `parent` mailbox | the session works in that room; see the question guard |
| `workroomReply` | question id; `parent` person | an agent message the person has not opened; see the conversation |

Tables: `workroom_ask(question, room, asker, person, state, sequence)` with indexes by room, room
and state, asker, person and state, and person alone; `workroom_access(room, person, state,
revision)` with an index by person. A state string this build does not know is unreadable data
(`unsupportedSchema`), never a grant or a revocation.

## Portal

Routes: `GET /assets/portal.{css,js}`, `GET|POST /join/<token>`, `GET /`, `GET /state`,
`GET /q/<id>`, `GET /q/<id>/state`, `POST /q/<id>/{answer,clarify,decline}`, `POST /language`.

- `GET /join/<token>` only shows a Continue button; `POST` redeems. Link previews and mail scanners
  fetch URLs, and a single-use link must survive them.
- `Host` must be the published host (or the loopback listener's, which a rebinding page cannot
  produce). A `POST` must come from exactly the published `Origin`, as a url-encoded form of at most
  64 KiB carrying the form token, which is derived from the session token and needs no storage.
- Cookie `__Host-wr`, `Secure; HttpOnly; SameSite=Lax` (Lax so a link opened from mail redirects).
- Every response, errors included: CSP `default-src 'none'; script-src 'self'; connect-src 'self';
  style-src 'self'; img-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'`,
  `nosniff`, `no-referrer`, `no-store`, `noindex`, HSTS, COOP/CORP.
- Missing, foreign and revoked answer with the same 404. Every request re-resolves the device,
  the person, the room grant and the room's openness.
- Rate limits per device (120/min), for joins (20/min) and globally (600/min); never per client
  address, which is always loopback and whose forwarding headers can be forged.
- The socket refuses a repeated `Host`, `Origin`, `Cookie`, `Content-Type` or `Content-Length`
  (the shared parser would keep the last), caps headers at 16 KiB, waits 10 s for them, answers
  one request per connection and keeps at most 32 open.
- Every agent- or person-written string is escaped and rendered as text; directional overrides
  are replaced. The one script only polls (see the conversation section above). A print
  stylesheet stands in for the trial's PDF.

## Review batches

Questions have no per-session hourly quota. A review with 211 independent decisions must be
publishable in one run without combining unrelated decisions or waiting for a clock window.
The capacity bound is 500 open questions per room, checked in the same transaction as the
question and its mail. Answered, declined and withdrawn questions release capacity; an exact
idempotent retry still succeeds when the room is full. Existing `workroomAskRate` records are
ignored, so an already-exhausted counter does not require a reset or a schema migration.
The opening approval, room summary and tool context use an indexed count of the bounded open
set, so they include the full batch even beyond the context's 200-question history sample.
`workroom_context` keeps its history scan bounded and reports `question_history_complete`;
its open count is exact even when older closed-state counts are partial.

Workroom question and reply mail bypasses the agent-to-agent send-rate counter. Otherwise the
ordinary 20-per-minute mail fuse would replace the removed hourly block. This exception is only
the internal `viaWorkroom` route: ordinary agent mail retains its rate fuse, and person mail is
still refused through public send and peer paths. Inbox capacity, chain limits, room access,
form sizes and the portal's device/join/global rate limits still apply.

## Scaling contract

| Quantity | Expected | Bound |
|---|---|---|
| People | a handful | Settings shows 50; `workroom_find` lists up to 200 |
| Rooms per project | tens | `workroom_find` examines 4 pages of 50; Settings shows the newest 20 of 200 read |
| Open questions per room | 1–211 in a review batch | 500, enforced at `ask`; the indexed capacity scan examines at most 500 rows |
| Asks per session | a complete review batch | no timed quota; room and mailbox capacity bound outstanding work |
| Answer revisions / messages per question | 1–3 / 1–10 | 20 / 60, plus one closing note |
| Reply marks per person | a few | one per question; the New messages scan examines at most 500 |
| App badge count | a few | open questions and marked replies, at most 500 rows of each examined per count |
| Owner's question list | tens to hundreds | 20 a page through `record_page`; the poll fingerprints the first page only |
| Page polls | one per visible tab every 4 s | each a bounded count; the device limit is 120 a minute |
| Inbox page | 20 shown per section | at most 500 index rows examined per section per request; `more` says it stopped there |

No layout, scroll or stream callback reaches the store. The portal decodes a payload only for a
row it shows. Tool JSON is encoded on a worker. A batch remains a sequence of bounded atomic
asks; no call constructs every question's UI. The 500-question regression checks capacity,
idempotence and released slots; the 211-question portal regression follows every 20-row page
and answers the last question through the real participant route.

## Threat model

Native approval guards the tool path, not the user account. An agent shell running as the user
could write `mailbox.db`, start its own tunnel or read the clipboard after Copy Link; if Threading
has the Accessibility permission, scripted clicks could reach a sheet. These are the same limits
every same-user secret in Threading has (`permissions.md`). What the design does guarantee: no tool
result ever contains a link or token, the web side has no owner capability, tokens are stored only
as digests, and nothing is reachable from outside until a room is opened to a named person.

An app membership is a Remote Access guest capability: its bearer lives in the guest-share Keychain
record and is bound to the device that accepted it, like a shared chat's. It reaches only the
`workroom/…` routes as its person; every other route sees a guest with no chat and no terminal. A
notification's title and first lines leave the Mac through the hosted broker and Apple.

## Verification

`swift test` in `Packages/ThreadingController` (`WorkroomQuestionTests`, `WorkroomPortalTests`)
covers the records, forms, mail containment, the v11 upgrade, single-use redemption under
concurrency, digests on disk, bounded inbox scans, reply marks and their sections, the next
question, the fingerprints, conversation order within one second and the whole portal policy.
`THREADING_RENDER_OUT=<dir> swift test --filter rendersTheInbox` writes a signed-in inbox, a
conversation and an unanswered question with their assets, for review at phone width.
`WorkroomRemoteBridgeTests` (app) covers who is a viewer, route parsing, the participant/owner
permissions, the conversation projection in the person's words and the vocabulary pins; the broker's
`apns.test.ts` covers the `workroom` kind and the badge bounds. `ThreadingTests`
covers the git capture against a real repository, tunnel recipes and fake tunnel processes, the
socket against a real listener, the sheet's words, the opening ledger, the tool group's absence
while off, and the Settings page (`WorkroomsSettingsRenderTests`, light and dark). A pilot over a
real tunnel should check that a form post arrives with `Content-Length` and which `Host` the
provider forwards.
