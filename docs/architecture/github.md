# GitHub Connectivity

The credential chain, the GitHub App connection, and the brokered network fetch that lets a
safe extension read from the internet without ever holding a socket or a token.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

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
(View ▸ Inspect Element / Inspect Geometry, then **Submit Issue**) and **Help ▸ Report a
Problem…**. Both compose through `GitHubIssueComposer` — description first, evidence under it,
environment last — and both POST through the credential chain above. The repository is a
constant, not a setting: a field pointing it elsewhere would let one user file this app's
diagnostics into a stranger's tracker.

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
