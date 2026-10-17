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

## Records (schema v12)

| Record (`record.kind`) | Key | Notes |
|---|---|---|
| `workroomPerson` | person UUID; `key` = handle | owner-added, or added on an approved opening; `removed` revokes every device and invitation |
| `workroomPublication` | room id | private (absent) → open (expiry) → closed |
| `workroomAsk` | question id; `parent` room; `scope` asker | immutable draft and git context; state, answer revision and note count |
| `workroomAnswer` | `<question>/<revision>` | immutable; validated against the form |
| `workroomNote` | UUID; `parent` question | clarification, response, decline, withdrawal |
| `workroomInvitation` | SHA-256 of the token; `parent` person | single use, 7 days; a new one revokes the pending one |
| `workroomDevice` | SHA-256 of the session token; `parent` person | 30 days; at most 20 live per person |
| `workroomTie` | `<mailbox>|<room>`; `parent` mailbox | the session works in that room; see the question guard |

Tables: `workroom_ask(question, room, asker, person, state, sequence)` with indexes by room, room
and state, asker, person and state, and person alone; `workroom_access(room, person, state,
revision)` with an index by person. A state string this build does not know is unreadable data
(`unsupportedSchema`), never a grant or a revocation.

## Portal

Routes: `GET /assets/portal.css`, `GET|POST /join/<token>`, `GET /`, `GET /q/<id>`,
`POST /q/<id>/{answer,clarify,decline}`, `POST /language`.

- `GET /join/<token>` only shows a Continue button; `POST` redeems. Link previews and mail scanners
  fetch URLs, and a single-use link must survive them.
- `Host` must be the published host (or the loopback listener's, which a rebinding page cannot
  produce). A `POST` must come from exactly the published `Origin`, as a url-encoded form of at most
  64 KiB carrying the form token, which is derived from the session token and needs no storage.
- Cookie `__Host-wr`, `Secure; HttpOnly; SameSite=Lax` (Lax so a link opened from mail redirects).
- Every response, errors included: CSP `default-src 'none'; style-src 'self'; img-src 'self';
  form-action 'self'; base-uri 'none'; frame-ancestors 'none'`, `nosniff`, `no-referrer`,
  `no-store`, `noindex`, HSTS, COOP/CORP.
- Missing, foreign and revoked answer with the same 404. Every request re-resolves the device,
  the person, the room grant and the room's openness.
- Rate limits per device (120/min), for joins (20/min) and globally (600/min); never per client
  address, which is always loopback and whose forwarding headers can be forged.
- The socket refuses a repeated `Host`, `Origin`, `Cookie`, `Content-Type` or `Content-Length`
  (the shared parser would keep the last), caps headers at 16 KiB, waits 10 s for them, answers
  one request per connection and keeps at most 32 open.
- Every agent- or person-written string is escaped and rendered as text; directional overrides
  are replaced. There is no JavaScript. A print stylesheet stands in for the trial's PDF.

## Scaling contract

| Quantity | Expected | Bound |
|---|---|---|
| People | a handful | Settings shows 50; `workroom_find` lists up to 200 |
| Rooms per project | tens | `workroom_find` examines 4 pages of 50; Settings shows the newest 20 of 200 read |
| Open questions per room | a few | 50, enforced at `ask` |
| Asks per session | a burst | 10 per hour |
| Answer revisions / notes per question | 1–3 | 20 / 20 |
| Inbox page | 20 shown | at most 500 index rows examined per request; `more` says it stopped there |

No layout, scroll or stream callback reaches the store. The portal decodes a payload only for a
row it shows. Tool JSON is encoded on a worker.

## Threat model

Native approval guards the tool path, not the user account. An agent shell running as the user
could write `mailbox.db`, start its own tunnel or read the clipboard after Copy Link; if Threading
has the Accessibility permission, scripted clicks could reach a sheet. These are the same limits
every same-user secret in Threading has (`permissions.md`). What the design does guarantee: no tool
result ever contains a link or token, the web side has no owner capability, tokens are stored only
as digests, and nothing is reachable from outside until a room is opened to a named person.

## Verification

`swift test` in `Packages/ThreadingController` (`WorkroomQuestionTests`, `WorkroomPortalTests`)
covers the records, forms, mail containment, the v11 upgrade, single-use redemption under
concurrency, digests on disk, bounded inbox scans and the whole portal policy. `ThreadingTests`
covers the git capture against a real repository, tunnel recipes and fake tunnel processes, the
socket against a real listener, the sheet's words, the opening ledger, the tool group's absence
while off, and the Settings page (`WorkroomsSettingsRenderTests`, light and dark). A pilot over a
real tunnel should check that a form post arrives with `Content-Length` and which `Host` the
provider forwards.
