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
