# GitHub Connectivity

The credential chain, the GitHub App connection, native pull requests, and the brokered network
fetch that lets a safe extension read from the internet without ever holding a socket or a token.

Part of the [CLAUDE.md](../../CLAUDE.md) index. The provider-neutral review workflow and GitLab
adapter are in [source-control.md](source-control.md).

## Why this exists

The GitHub Checks dogfood extension could read public repositories only: its sandboxed
companion fetched `api.github.com` anonymously, so the moment this repo's remote went private
the card showed a truncated 502. The obvious fix — hand the extension a token — was rejected
outright: `network.client` grants unrestricted outbound (`ExtensionSandboxPolicy` has no
per-host allowlist), so a token in a companion is a push-capable credential one `curl` from
exfiltration. Everything below follows from keeping the credential on the host's side of the
boundary.

## The credential chain (`Core/GitHub/`)

`GitHubCredentialResolver` resolves the best GitHub credential, most authoritative first:

1. **App connection** — Threading's own GitHub App login (below).
2. **`gh` CLI** — `gh auth token --hostname github.com`, asked through the user's **login
   shell** (`AgentLauncher.loginShellPath`, the same reasoning as agent launches: a GUI app
   does not inherit the interactive `PATH`). Asking gh is the supported door — modern gh keeps
   the token in the system Keychain, so reading `~/.config/gh/hosts.yml` finds nothing.
3. **git credential helper** — `git credential fill` for `https/github.com`, with
   `GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false GCM_INTERACTIVE=never` so a background
   probe can never summon an askpass dialog. Catches users who authenticated git without gh.
4. **Anonymous** — always present, public repositories only.

Sources cache: each probe is a subprocess, and the answer changes only when the user acts. A
failed probe retries after five minutes (installing gh must not need an app restart); a 401
from GitHub *invalidates* the tier's cache, because it is proof the cached token died — the
one escape hatch, and the only one needed.

## The app connection (`GitHubAppConnection`)

The "most correct" tier: the user registers a GitHub App (client ID in Settings — it
identifies, it grants nothing, so `UserDefaults` not Keychain), signs in with the **device
flow** (no client secret, native-friendly), and picks repositories at install time on GitHub.
User-to-server tokens expire in hours, so the refresh token is stored beside the access token
— in Threading's own Keychain service (`codes.threading.github.v1`), separate from extension
secrets — and renewal is silent inside `freshAccessToken()`. A refresh must present the same
`client_id` that authorized, so the connection records it; this was nearly missed.

The device-flow steps are static functions over an injected transport, so the state machine
(pending → slow_down → grant/declined/expired) is tested without a Keychain, the singleton, or
real GitHub. Settings ▸ GitHub drives the whole journey and shows the chain's fallbacks with
live probes, so "why did that read work" is answerable from one screen.

## Filing an issue (`GitHubIssueSubmitter`)

Two places raise a ticket against this app's own repository: the inspector's report sheet
(View ▸ Inspect…, then **Submit Issue**) and **Help ▸ Report a
Problem…**. Both compose through `GitHubIssueComposer` — description first, evidence under it,
environment last — and both POST through the credential chain above. The repository is a
constant, not a setting: a field pointing it elsewhere would let one user file this app's
diagnostics into a stranger's tracker.

### What the environment carries

`GitHubIssueEnvironment` is the floor: version, build, macOS, and nothing else. A capture from
the inspector closes with `InspectorEnvironment` instead, which *opens* with that same line and
adds what a picture cannot say — the app theme and the appearance it resolved to, whether the
window is wearing the theme's own frame or AppKit's, the window's size, backing scale and
fullscreen state, the terminal in view with the scope that chose its palette and the font it is
set in, the text size, and any chrome font, display accommodation or interface language that is
not the default. Most
visual complaints are conditional on exactly these: the row clipped under one theme, the overlap
that appears only at the largest text size, the frame numbers that are half what an agent
measuring the PNG counts because the window is retina.

The safety rule is unchanged and is what bounds the list: a ticket outlives the conversation, so
every value must be safe **by construction** rather than by review. Each one is a choice from a
fixed catalogue — a stock theme's name, a named text size, a font family installed on the
machine. A theme the user made and named is reported as `custom`, and a terminal palette that
follows the app theme is reported as following it rather than by the name it borrowed, which
would have leaked the same string by the back door.

The sheet holds that block **apart from** the report text, because it is said in three places
and must be said once in each: the details box, Copy Report, and the ticket, whose composer
appends an environment under a rule of its own. A report string carrying its own environment
arrived on GitHub with the build line printed twice.

A write is not a read, and three rules are the POST's own:

- **Anonymous never posts.** It cannot create an issue under any circumstance, so sending it
  buys a guaranteed 401. Its presence in the chain is instead the signal that there is nobody to
  post *as*, which is what selects the prefilled `issues/new` form — the path that keeps working
  when the repository is public and the user is signed into a browser rather than to `gh`.
- **A transport failure ends the attempt.** A GET that times out is retried under the next tier
  for free; a POST that times out may have created the issue already, and the one thing worse
  than a failed report is two of them. The user retries deliberately or not at all.
- **401/403/404 walk to the next tier; 422 does not.** The first three say "this token may not
  write here", which says nothing about the next token. 422 is GitHub reading the body and
  objecting to it, and every credential hears the same objection.

Every tier refusing ends at the form rather than at an error, because "no credential here may
write to that repository" is a permission answer with somewhere to go.

The REST request and response are fixed wire contracts, so they use small `Codable` envelopes
rather than `[String: Any]`. The generated API body is capped at 60,000 characters, the browser
fallback at 6,000, and labels have explicit count and length budgets. Truncation includes its
marker inside the budget. An accepted POST with an unreadable response still counts as created:
retrying would risk filing a duplicate.

## The development build's third button: **Send to Chat** (`DeveloperReportChat`)

Debug builds only. The same reviewed report, opened as a chat in the repository the running
binary was compiled from, instead of being posted to the private intake.

The reason is not convenience. It is that a chat is a *reader*, and for a long time the private
route had none: `MacIssueReportOutbox` retried a service that was still a checklist rather than a
deployment (see [`issue-reporting-setup.md`](../operations/issue-reporting-setup.md)), so two
reports sat in `~/Library/Application Support/Threading/IssueReports/Outbox/` for two days,
exactly as specified, and told nobody anything.

The outbox now says which of those two things it is doing (see **Where a private report goes**
below), so the sheet no longer promises a retry nothing can perform. This button remains the
fastest way to be *read*: it takes, in one press, the path a developer takes by hand — Copy
Report, new chat, paste, Return.

Four decisions are worth their words:

- **The report keeps its screenshot path.** The private route strips it deliberately — a
  temporary file on this machine means nothing to an intake service — and this one carries
  `details` rather than `publicDetails`, because a path is the one form of an image the agent
  CLIs can act on. That difference is the whole value of the route, and a test holds both
  readings of the same sheet together.
- **The project is the build's own source root** (`#filePath`), matched **exactly** against the
  sidebar, with the on-screen project as the fallback. Exact rather than "somewhere under",
  because one repository holds several projects here and a report about this window belongs to
  the tree that drew it. A build run from a copy — an rsync'd tree, a second checkout — resolves
  to that copy, and falls back when Threading has never been pointed at it.
- **The chat is configured like the last one used in that project**, not from app defaults: the
  person filing the report was working there a moment ago, and a chat that comes up on a
  different agent, login or permission mode is one they must reconfigure before it is useful.
  `lastUsedAt`, not `lastActiveAt` — a background relaunch touches every session at once.
  Archived rows are skipped; a managed workspace and a branch are never chosen, because a UI
  report is read against the tree the build came from.
- **One line of frame, and it is Threading speaking.** Deliberately not the
  `[Cross-session message …]` header from [`control-plane.md`](control-plane.md): nothing here
  was written by another session's agent, and this is the opening prompt of a chat the user
  started by pressing a button. The line exists to keep the trailing view chain from reading as
  something the person typed, and to say the screenshot is a file worth opening.

Starting the chat goes through `startSessionUnattended` + `launchInBackground` — the scheduled
new-session path, which is already the one shape that creates and launches a session with an
opening prompt. It differs in one respect, and on purpose: this one **selects** the new row. A
schedule firing at 09:00 must not reach across whatever the user is reading; a button pressed a
moment ago is being waited on, and the chat coming up is the receipt.

## Where a private report goes (`MacIssueReportOutbox`)

Every report is written to disk before anything is sent, and delivery never consumes it. Two
directories under `~/Library/Application Support/Threading/IssueReports/`:

- **`Outbox/<id>/`** — the record. `report.md` is the report as it reads to someone standing on
  this machine, `screenshot.png` is the capture at the size it was taken, and `submission.json`
  and `receipt.json` join it once a package has actually been delivered. Unbounded on purpose:
  filing a hundred of these and having an agent triage the folder is a supported way to work, and
  no code path reads the folder as a whole beyond a bounded count for a status line.
- **`Pending/<id>.json`** — the delivery queue. The bounded wire package, present only while
  there is an endpoint to send to and it has not arrived, retried on launch and on every
  `didBecomeActive`. Same UUID on every attempt, so a lost response returns the first receipt.

**The record and the package are two documents, not one truncated twice.** The package is bounded
(64 KB, a 12 KB JPEG preview, the capture's path stripped) because an intake service is entitled
to an opinion about size and a temporary path here means nothing to it. The record keeps the
full-resolution PNG and the path, because it is read by a person in Finder or an agent with
`cat`, and a UI defect is often a few pixels that a 480-point preview has already thrown away.
A report too large to send is therefore still a report that was kept.

**Delivery is attempted only against a configured endpoint.** There is no compiled-in fallback
URL: `THREADING_REPORT_INTAKE_URL` (Debug only, what `./dev` sets) or `ThreadingReportIntakeURL`
in Info.plist, or nowhere. A build that states neither writes the record, reports **saved** rather
than queued, and does not post — which is the everyday state of a developer build, and was
previously indistinguishable from a delivery that had failed. Because the queue only exists when
somewhere to send exists, its bound is never what stops a report being filed.

## The sheet's one action (`DeveloperReportSubmitControl`)

Copy Report, Send to Chat and Send to Developer were three buttons in a row, ranked by a layout
rather than by what the person filing the report does with it. They are one control now: the press
is whichever was taken last (`PreferenceStore`, re-resolved against what this build actually
offers, so a remembered Chat is not a Release build's press to nowhere), and the chevron holds the
rest. A sheet with one action draws no chevron, which is the rule the attachments pane's scope
band already follows.

The press is the sheet's accent action *and* welded to its chevron, which was not possible until
the plate learned to carry an emphasis — see `SplitButtonView` and
[`design-system.md`](design-system.md). Its title is the outbox rule above, said in a word:
**Send to Developer** with an endpoint configured, **Send to Outbox** without one.

## A picture taken outside Threading (`DroppedScreenshotReport`)

The inspector photographs the window, which is the wrong evidence for a **hover**: the capture is
taken from a menu the pointer had to travel to, so the highlight, the tooltip, or the open menu is
the one thing missing from the picture. macOS's own ⌘⇧4 has no such problem.

So the report sheet accepts a file, through two doors that are both "the app icon" in the sense
that matters: the Dock's icon (`application(_:open:)`, which already turned dropped folders into
projects and now tells the two apart by declared type), and the titlebar strip beside the traffic
lights (`TitlebarActionWindow.onScreenshotDropped`). Neither advertises itself at rest — the strip
is ordinary window chrome until a drag reaches it — and both are where a Mac user already drops a
file. Launch Services sees `public.image` and `public.folder` in the app's document declarations
with `LSHandlerRank = None`: Apple's drop-only rank lets the Dock deliver those URLs without
offering Threading as an app that opens images or folders.

The strip is narrow on purpose: one file, an image, and only while the pointer is above
`contentLayoutRect` — the same geometry that restores the window's double-click. Everything else
falls through to whatever the content below does with it, because an invisible target that claims
a drag a pane wanted is worse than no target. Once that exact drag is accepted,
`ScreenshotReportDropTargetView` lays a quiet accent wash behind the native strip and says **Drop
screenshot to report** beside the traffic lights. The view never hit-tests, appears only for the
accepted state, and clears on exit, refusal, cancellation and drop; Reduce Motion skips its short
arrival but keeps the complete feedback.

What such a report loses is the geometry the inspector knows by construction. What it keeps is the
picture and the marks put on it, which is what the sheet was worth opening for.

## GitHub pull-request adapter (`GitHubPullRequestClient`)

Git Review remains the authoritative pull-request workflow. Its controller joins local
branch/upstream state with a provider-neutral `ChangeRequestRepositoryStatus`: the open pull
request, draft state, latest decision from each reviewer, requested reviewers, and check runs for
the remote head. The session status card may project only the connected request's number, title
and check summary; both rows navigate back to Git Review and expose no write. GitHub and GitLab
both implement `ChangeRequestProviderClient`; the UI and durable policy do not use either
provider's wire types. The shared boundary, GitLab adapter, capability flags and managed-ref
safety are documented in
[source-control.md](source-control.md).

The publish policy is **repository scoped** and keyed by `git rev-parse --git-common-dir`, so all
linked worktrees share one answer. It is exposed from each project's sidebar menu because that is
where its effect is legible. The default opens an editable native composer. Codex may fill the
title and body, but the composer owns no credential and the text-composition type has no publish
method. The user must still press Publish. The compact chooser keeps the bar quiet; opening it
shows one explanatory line under every choice, and each line names Git Review so the policy cannot
be mistaken for an instruction to the coding agent.

Every primary-button press advances exactly one external transition:

- an unpublished branch is pushed;
- a pushed branch opens the composer or, under an explicit repository policy, creates a draft or
  ready pull request;
- an existing pull request is opened, or a newer local head is pushed.

"Create draft" and "create ready" are therefore shortcuts after an explicit click, never inferred
background automation. The one other authorization surface is a managed-workspace draft: its
separate, nested publication checkbox explicitly grants Threading permission to publish after the
agent's finish handshake. It is still off by default, and enabling isolation alone never grants
it. Uncommitted work is called out and remains local. Pushes and creations get bounded durable
receipts naming the repository, branch, resulting URL, and credential tier where one was used.
Repository policy and those receipts are versioned recoverable preferences: unreadable or
oversized bytes are preserved before replacement, policy is capped by repository count and key
size, and a receipt accepts only a bounded repository/branch plus an authority-safe HTTPS result
URL. A mutation becomes visible in memory only after the encoded candidate has been written and
read back successfully.
receipts naming the repository, branch, resulting URL, and provider credential source where one
was used.

Reads use the normal credential-tier walk because they are idempotent. Creation may walk after an
explicit 401/403/404 refusal, but it **never retries after a transport failure**: GitHub may have
accepted the POST before the connection failed. A 2xx response that cannot be decoded is treated
the same way. With no usable API credential, the client opens GitHub's prefilled compare form and
does not issue an anonymous POST.

Managed-workspace publication is unattended, so it narrows that policy further. It preflights a
native token before pushing and never uses the browser fallback: a compare page cannot complete
the promised archive-and-dispose transaction. The session UUID deterministically names an opaque
remote-only branch, discovery precedes creation so a retry can reuse the review, and the review
receipt is durable before the local worktree is removed. GitHub wire details stop at the adapter;
the managed-workspace record speaks only in provider, repository, remote branch, review number,
URL, and draft state.

That receipt also closes the remote-ref lifecycle. A background reconciler reads the pull request
by number because the branch discovery endpoint intentionally returns only open reviews. Open
means no Git write. Closed or merged permits one comparison against the recorded branch and head
commit; an exact match is deleted with a force-with-lease compare-and-swap, while a moved ref is
never treated as Threading's property merely because its name still begins with `threading/`.
GitHub's own auto-delete is accepted as `alreadyAbsent`. Launch, app activation and a low-frequency
heartbeat cover reviews completed while Threading was quit, elsewhere, or still in the foreground.

### The screenshot is not in the issue, and cannot be

`POST /repos/{owner}/{repo}/issues` takes markdown. Image attachments in the web UI go through
`github.com/upload/policies/assets`, which requires a `user_session` cookie and answers 422 to
token auth; as of 2026 there is no REST or GraphQL surface for it, and the `gh` CLI has an open
request for exactly this with no token-authenticated path to implement it against
([cli/cli#13256](https://github.com/cli/cli/issues/13256)).

The obvious workaround does not survive contact with a private repository: an image committed to
the repo and referenced by its raw URL is fetched by GitHub's **camo** proxy, which has no
session and cannot authenticate, so the ticket would carry a broken image today and a working one
only after the repo goes public. Driving a signed-in browser session is the only thing that
actually works, and it is a Playwright hack.

So the capture goes to the **clipboard** as the issue opens in the browser, and the sheet says
so. One ⌘V in the comment box, no repository writes, and nothing that breaks when the repo
changes visibility. The report's markdown still carries the screenshot's local *path*, which is
the form an agent CLI can open — that is what Copy Report was always for.

## The brokered fetch (`network.brokered`)

The first shape was a bespoke `github.checks.read` capability with a check-runs endpoint. It
was rejected mid-build for the right reason: **a capability per site per operation does not
scale** — the next extension would need `gitlab.pipelines.read`, and the one after that a
fourth bespoke endpoint. What scales is the browser-extension shape: one generic fetch, with
**declarative per-origin grants** in the manifest:

```json
"capabilities": ["network.brokered"],
"networkGrants": [{ "host": "api.github.com", "methods": ["GET"], "credential": "github" }]
```

Rules, each load-bearing:

- **The grant list is the security boundary**, so it is exact: https-only DNS hosts (no
  wildcards, ports, or paths), `GET`/`HEAD` only in v1, at most 8, shown verbatim in the
  install dialog. "Exactly api.github.com" is approvable in a way patterns are not.
- **Every fetch runs host-side** (`ExtensionNetworkBroker`), checked against the authorized
  generation's grants in `ExtensionHostService.routeBrokeredFetch`. The guest gains no socket;
  `Authorization`/`Cookie`/`Host` request headers are refused as broker-owned, `Set-Cookie`
  never travels back, responses cap at 4 MiB.
- **`credential` names a host-known provider** (registry in `ExtensionNetworkBroker.live()`;
  v1 knows `github`). The broker attaches the resolved token itself and reports which tier
  answered — that tier is what lets a card say "connect GitHub in Settings" only when the read
  was actually anonymous.
- **The tiers are walked on 401/403/404 GETs**, because a miss under one tier says nothing
  about the next: a GitHub App sees only the repositories it was installed on, while a `gh`
  token sees everything the user sees. On total failure the *most authoritative* answer is
  reported — the credential the user set up is the one whose answer they should read.
- **An HTTP status is data, not a broker error.** GitHub's 404 returns as a 404 for the
  extension to interpret; only transport failure (DNS, timeout) becomes the envelope's
  `failure`. The 0.1.0 card's unreadable error — "Threading rejected the extension-host request
  (502): Git…" — was three layers each wrapping the previous one's message; the envelope split
  is what unwinds it.
- **A credentialed grant beside a companion holding `network.client` is refused at manifest
  validation.** Brokered responses land only inside the sandboxed guest, which has no way to
  send them anywhere — unless the same extension also owns a raw socket. That pairing is the
  exfiltration channel, so it is the one combination that cannot be declared.

## Rendering failure

The node renderer wraps `.text(.detail)` and deliberately truncates `.status` to one line. An
error therefore renders as a short status ("Couldn't read checks") plus a wrapping detail with
the full message — never as a long `.status`, which is exactly how the truncated 502 happened.
Recorded in the extension's `SDK_FINDINGS.md` as a vocabulary rule.
