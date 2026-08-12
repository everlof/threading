# Cursor CLI over ACP — Provider Findings

Researched 2026-08-12 to answer one question: **can `cursor-agent` honestly back a native
conversation in Threading** — launch, initialize, session create/load, prompt streaming,
permissions, cancellation, MCP, durable session identity — the way the Claude and Codex
transports already do.

Everything in §1–§6 was **measured against a CLI installed on this machine for this
investigation**: `cursor-agent` **2026.08.11-e8db854**. Every command and every JSON-RPC pair is
reproduced verbatim, redacted only where a value was token-shaped or contained the user's home
path. Where a fact comes from reading the shipped JavaScript bundle rather than from the wire it
is labelled **(static)**; where it could not be reached without a Cursor account it is labelled
**BLOCKED-ON-AUTH** and says exactly which byte stopped it.

**§1–§6 were recorded before any login**, which is what bounds them: the handshake, the routing
table, the refusal shapes, and the session-identity mechanism are measured there; the streaming
turn is not. **§10 is the authenticated pass**, recorded later the same day against a real Cursor
account on this machine, and it supersedes every "BLOCKED-ON-AUTH" row it reaches. Where §10
contradicts a static reading in §1–§6, §10 wins — it says so explicitly at each point.

The short version: **the protocol surface is real and unusually complete — and the entire
session half of it is behind one auth gate that an API key opens.** `initialize` answers
unauthenticated and advertises `loadSession: true` plus session listing. Every session method
refuses with one uniform error until credentials exist. The decisive finding is §5.3: setting
`CURSOR_API_KEY` changes that refusal from "Authentication required" to a downstream service
error, which means **Threading does not have to drive a browser flow** to support Cursor.

---

## 1. Install provenance and how to remove it

`cursor-agent` was not present before this research: `which cursor-agent` found nothing, and
`/usr/local/bin/cursor` was (and remains) a dangling 2024-era symlink into a non-existent
`/Applications/Cursor.app`.

The official installer was downloaded **without executing it** and read first:

```
curl -fsSL https://cursor.com/install -o <scratch>/cursor-install.sh
sha256: b1af27b9556c5f1c58d166742dbb33425ebd90a4bbd7e5453d66b920bf1f9f6b   (203 lines)
```

It is entirely user-local — no `sudo`, no system path, and **it does not edit shell rc files**;
it only *prints* the `export PATH=…` line for the detected shell. Verified afterwards by hash:

```
shasum -a 256 ~/.zshrc ~/.bashrc ~/.bash_profile ~/.profile   # identical before and after
```

What it created, measured by diffing the tree:

| Path | What |
|---|---|
| `~/.local/share/cursor-agent/versions/2026.08.11-e8db854/` | the whole payload, **225 MB** — a webpack'd Node bundle plus native `pty.node`, `node_sqlite3.node`, `spawn-helper`, `cursorsandbox` |
| `~/.local/bin/agent` → that dir's `cursor-agent` | primary name |
| `~/.local/bin/cursor-agent` → same target | legacy name; **this is the name to spawn** |

The version is pinned into the installer itself (`DOWNLOAD_URL` names
`lab/2026.08.11-e8db854`), so the script is not a floating "latest" — re-running it later
installs a different, hard-coded build beside this one under `versions/`.

**Uninstall** (complete, no residue):

```bash
rm -f  ~/.local/bin/agent ~/.local/bin/cursor-agent
rm -rf ~/.local/share/cursor-agent
rm -f  ~/.cursor/cli-config.json ~/.cursor/agent-cli-state.json ~/.cursor/statsig-cache.json
rm -rf ~/.cursor/projects ~/.cursor/acp-sessions ~/.cursor/plans
```

(`acp-sessions` and `plans` appeared only during the authenticated pass — see §10.4 and §10.8.
`acp-sessions/<uuid>/store.db` holds conversation content, so removing it is deleting chats.)

The last two lines are the state the CLI wrote during these probes (§6, §10); `~/.cursor/argv.json`
and `~/.cursor/extensions/` predate this work by years and belong to the Cursor **editor** — do
not delete those.

Two things were deliberately **not** run: `cursor-agent install-shell-integration` (its help says
it writes to `~/.zshrc`) and `cursor-agent login`.

---

## 2. The command surface

```
$ cursor-agent --version
2026.08.11-e8db854
```

`cursor-agent --help` presents itself as `agent`, and its commands are:

```
install-shell-integration    Install shell integration to ~/.zshrc
uninstall-shell-integration  Remove shell integration from ~/.zshrc
login                        Authenticate with Cursor. Set NO_OPEN_BROWSER to disable browser opening.
logout                       Sign out and clear stored authentication
mcp                          Manage MCP servers
plugin                       Manage plugins and plugin marketplaces
worker [options]             Start a private cloud worker …
status|whoami [options]      View authentication status
models                       List available models for this account
bedrock                      Configure AWS Bedrock usage for CLI
about [options]              Display version, system, and account information
update                       Update Cursor Agent to the latest version
create-chat                  Create a new empty chat and return its ID
generate-rule|rule           Generate a new Cursor rule with interactive prompts
agent [prompt...]            Start the Cursor Agent
ls                           Resume a chat session
resume                       Resume the latest chat session
help [command]               Display help for command
```

**`acp` is not in that list.** It exists anyway — a hidden subcommand:

```
$ cursor-agent acp --help
Usage: agent acp [options]

Start the Cursor Agent as an ACP (Agent Client Protocol) server

Options:
  -h, --help  Display help for command
```

It takes **no options of its own**. Everything configurable is a *global* option placed before
the subcommand, which was verified rather than assumed — `cursor-agent -e https://127.0.0.1:9/nowhere acp`
starts and completes an `initialize` handshake normally (§3), confirming the
`cursor-agent [-e <endpoint>] acp` spawn shape.

Global options that bear on a host embedding it: `--api-key <key>` (and `CURSOR_API_KEY`),
`-e/--endpoint` (and `CURSOR_API_ENDPOINT`, default `https://api2.cursor.sh`), `-H/--header`,
`--model`, `--force`/`--yolo`, `--auto-review`, `--sandbox enabled|disabled`, `--approve-mcps`,
`--trust`, `--workspace <path>`, `--add-dir <path>`, `-w/--worktree`, `--mode plan|ask`.

Whether any of those are honoured **in the `acp` path** is untested; the ACP session carries its
own `cwd`, `mcpServers`, modes and model config over the wire (§4, §5), so most of them are
likely the interactive TUI's concern.

---

## 3. `initialize` — answers unauthenticated, and says a lot

All ACP probing used a bounded stdio harness (`acp_probe.py`, in scratch): it spawns the child,
writes newline-delimited JSON-RPC on a schedule, reads both pipes with timestamps, and
**always** kills the child at the budget. Every probe below terminated with `SIGTERM` at its
deadline (`final rc=143`); no probe process survived.

Request:

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false},"clientInfo":{"name":"threading","version":"probe-0"}}}
```

Response, at **0.64 s** from spawn, verbatim:

```json
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"mcpCapabilities":{"http":true,"sse":true},"promptCapabilities":{"audio":false,"embeddedContext":false,"image":true},"sessionCapabilities":{"list":{}}},"authMethods":[{"id":"cursor_login","name":"Cursor Login","description":"Authenticate using existing Cursor login credentials. Run 'agent login' first if not logged in."}]}}
```

Reading it:

- **`protocolVersion: 1`.** Sending `{"protocolVersion":99}` returns the *same* response with
  `protocolVersion: 1` — it negotiates down silently rather than erroring. `initialize` is also
  re-callable; a second one is answered, not rejected.
- **`loadSession: true`** — the resume half of the lifecycle is advertised, not merely hoped for.
- **`sessionCapabilities: {"list": {}}`** — session enumeration is advertised. This is the
  `unstable_listSessions` slot in the ACP library, and Cursor fills it (proved in §4).
- **`promptCapabilities`**: `image: true`, but **`embeddedContext: false`** and `audio: false`.
  Embedded context being off matters for us: file mentions must be sent as text or resource
  links the agent resolves itself, not as inlined `resource` blocks.
- **`mcpCapabilities: {http: true, sse: true}`** — HTTP and SSE MCP transports are declared.
  Note stdio is *not* listed; in ACP stdio is the unconditional baseline and only the extra
  transports are advertised, so this reads as "http and sse **as well**".
- **`authMethods`**: exactly one, id **`cursor_login`**. This matches the comparative evidence
  in the appendix.
- **No `_meta`** anywhere in the response.

Sending `clientCapabilities._meta.parameterizedModelPicker: true` (the T3 gate) changed nothing
observable in the response — but it is read. **(static)** The bundle contains:

```js
clientSupportsParameterizedModelPicker(){ … this.clientCapabilities?._meta?.parameterizedModelPicker === true }
getModelPickerMode(){ return this.clientSupportsParameterizedModelPicker() ? "parameterized" : "variants" }
```

So the flag selects the *shape of the model list handed back later*, at session creation — which
is why an unauthenticated `initialize` cannot show its effect. This build is 2026-08-11, well past
the 2026-04-08 date gate T3 uses, and the capability is present.

---

## 4. The routing table, measured without an account

The refusal codes discriminate cleanly, which makes the whole method table measurable
unauthenticated:

- **`-32601 Method not found`** — the method is not registered at all.
- **`-32000 Authentication required`** — registered, reached the handler, refused on credentials.
- **`-32602` / `-32603` with "Session … not found"** — registered, past auth routing, failed on
  the fake session id.

Fired against a fresh `cursor-agent acp` (ids and params elided for width):

| Method | Response | Verdict |
|---|---|---|
| `session/new` | `-32000 Authentication required` | registered |
| `session/load` | `-32000 Authentication required` | registered |
| `session/list` | `-32000 Authentication required` | registered |
| `session/prompt` | `-32603 Internal error` · `{"details":"Session s-probe not found"}` | registered, **past the auth gate** |
| `session/set_mode` | `-32603` · `Session s-probe not found` | registered |
| `session/set_model` | `-32602 Invalid params` · `Session s-probe not found` | registered |
| `session/set_config_option` | `-32602 Invalid params` · `Session s-probe not found` | registered |
| `cursor/list_available_models` | `-32000 Authentication required` | registered |
| `session/cancel` (as a **request**) | `-32601 Method not found` | see below |
| `session/fork` | `-32601 Method not found` | **absent** |
| `session/resume` | `-32601 Method not found` | **absent** |
| `session/select_model` | `-32601` | wrong name; it is `set_model` |
| `session/request_permission` | `-32601` | client-side method, correctly not on the agent |
| `session/update` | `-32601` | client-side |
| `fs/read_text_file` | `-32601` | client-side |
| `terminal/create` | `-32601` | client-side |
| `cursor/ask_question` | `-32601` | client-side (see §4.2) |
| `cursor/create_plan` | `-32601` | client-side |
| `cursor/update_todos` | `-32601` | client-side |
| `cursor/task` | `-32601` | client-side |
| `cursor/generate_image` | `-32601` | client-side |
| `totally/bogus` | `-32601` | control |

Two of those need care.

### 4.1 `session/cancel` is a notification, not a request

The `-32601` above is an artifact of how it was sent. **(static)** the dispatcher has two arms,
and cancel lives in the second:

```js
… case "session/set_config_option": { … } default: if(n.extMethod) return n.extMethod(e,t); throw xt.methodNotFound(e) }),
(async (e,t) => { if("session/cancel"===e){ const e=le.parse(t); return n.cancel(e) }
                  if(n.extNotification) return n.extNotification(e,t); throw xt.methodNotFound(e) })
```

Re-sent **without an `id`**, `{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s-probe"}}`
produced no response and no error, and the process stayed alive — consistent with a notification
handled for a session that does not exist. Cancellation is therefore present and correctly
ACP-shaped. What it *settles to* is unmeasured (see §7).

### 4.2 Cursor's extension methods are real, and their names are not the documented ones

The comparative note names `askQuestion`, `createPlan`, `updateTodos`, `listAvailableModels`.
**On this build the wire names are snake_case under a `cursor/` prefix** — the only such strings
in the bundle:

```
"cursor/ask_question"   "cursor/create_plan"   "cursor/generate_image"
"cursor/list_available_models"   "cursor/task"   "cursor/update_todos"
```

And the direction matters. Only **`cursor/list_available_models` is served by the agent**; the
other five returned `-32601`, i.e. the agent does not implement them — **the agent calls them on
the client**. **(static)** the agent's extension arm handles exactly one name:

```js
extMethod(e,t){ … if(e===y.Hn) return yield this.listAvailableModels(); throw i.GI.methodNotFound(e) }
```

So Cursor's plan / todo-list / interactive-question UX is **something a client must implement**,
not something it receives for free on `session/update`. A Threading transport that ignores them
gets a conversation that silently loses Cursor's planning and question surfaces; one that answers
them owns new UI.

### 4.3 Model selection is a config option, not a first-class method

**(static)** `session/set_model` is a thin alias:

```js
unstable_setSessionModel(e){ return yield this.setSessionConfigOption({sessionId:e.sessionId, configId: S.ACP_MODEL_CONFIG_ID, value:e.modelId}), {} }
```
with `ACP_MODEL_CONFIG_ID = "model"`. This is the `setModel` + `setConfigOption` pairing the
comparative evidence describes, confirmed in this build: one generic config channel, with
`"model"` as a reserved id.

### 4.4 Malformed input is swallowed silently

Three deliberate insults, each on its own line:

```
this is not json at all
{"jsonrpc":"2.0","id":99,
{"jsonrpc":"2.0","id":101,"method":"session/new","params":{}}
```

The first two produced **no output at all** on stdout or stderr, and the process kept serving
subsequent valid requests. Only the third — well-formed JSON-RPC with bad params — answered:

```json
{"jsonrpc":"2.0","id":101,"error":{"code":-32603,"message":"Internal error","data":[{"expected":"string","code":"invalid_type","path":["cwd"],"message":"Invalid input"},{"expected":"array","code":"invalid_type","path":["mcpServers"],"message":"Invalid input"}]}}
```

Two consequences for a transport. **A framing desync is undetectable** — a dropped or corrupted
line yields silence, not an error, so a client must rely on its own request timeouts rather than
expecting the agent to complain. And **`data` is sometimes an array, not an object**: the Zod
issue list is passed straight through, so a decoder that assumes `error.data.message` will fail
to decode exactly the errors that explain a bug. Note also that `session/new`'s required params
are confirmed here: `cwd` (string) and `mcpServers` (array) are both mandatory.

Across every probe in this document, **stderr never produced a single line.** `cursor-agent acp`
is silent on stderr even when insulted.

---

## 5. The auth gate

### 5.1 The refusal is uniform

Unauthenticated, `session/new`, `session/load` and `session/list` all returned byte-identical
errors apart from the id:

```json
{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Authentication required","data":{"message":"Authentication required. Please run 'agent login' first, then call authenticate() with methodId 'cursor_login'."}}}
```

Baseline confirmed out of band:

```
$ cursor-agent status --format json
{"status":"unauthenticated","isAuthenticated":false,"hasAccessToken":false,"hasRefreshToken":false,"message":"Not logged in"}

$ cursor-agent about --format json
{"cliVersion":"2026.08.11-e8db854","model":"Auto","subscriptionTier":null,"osPlatform":"darwin",
 "osArch":"arm64","userEmail":null,"terminalProgram":"threading","shell":"bash","lastRequestId":null}
```

(`terminalProgram: "threading"` is the CLI reading `TERM_PROGRAM` from the surrounding Threading
session — worth knowing that it fingerprints its host.)

### 5.2 `authenticate` drives a browser, and reports the URL as an *error*

Called with the advertised method id. **The flow was not completed and the URL was not visited.**
The harness pinned `BROWSER=/usr/bin/true` and `NO_OPEN_BROWSER=1` before spawning, precisely so
this probe could not hijack a browser.

```json
{"jsonrpc":"2.0","id":2,"method":"authenticate","params":{"methodId":"cursor_login"}}
```
```json
{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"Invalid params","data":{"message":"Failed to open browser for login. Please visit: https://cursor.com/loginDeepControl?challenge=<REDACTED>&uuid=<REDACTED>&mode=login&redirectTarget=cli"}}}
```

No browser was launched. Three things follow.

1. **`authenticate` is not a credential handshake — it starts an interactive device flow.**
   Despite the `authMethods` description saying "Authenticate using existing Cursor login
   credentials", it does not merely adopt them; with no stored login it goes for the browser.
2. **A host must neutralise the browser before spawning.** If Threading called `authenticate` on
   a plain environment, the CLI would open the user's browser from under a native app. Setting
   `BROWSER` to a no-op is what made this probe safe, and is the shape any embedding needs.
3. **The login URL arrives inside `error.data.message` as prose**, under `-32602 Invalid params`
   — not as a structured field, and not under a code that means "action required". Harvesting it
   means substring-matching an error string, which is brittle and would break silently.

A wrong id is at least clean:

```json
{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"Invalid params","data":{"message":"Unknown authentication method: nonexistent_method. Supported method: cursor_login"}}}
```

### 5.3 The gate opens on an API key — this is the important one

`cursor-agent models` refuses with a message the help never mentions:

```
Error: Authentication required. Run 'agent login', pass --api-key/--auth-token, or set CURSOR_API_KEY/CURSOR_AUTH_TOKEN.
```

So there are **four** credential paths, of which only one is the browser. Testing whether the ACP
gate honours them — same probe, one deliberately invalid key in the child's environment
(`CURSOR_API_KEY=key_INVALID_PROBE_…`):

```json
{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"<scratch>/proj","mcpServers":[]}}
```
```json
{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"Internal error","data":{"message":"Failed to initialize session services"}}}
```
```json
{"jsonrpc":"2.0","id":3,"error":{"code":-32603,"message":"Internal error","data":{"message":"Failed to initialize ACP services"}}}
```

**The refusal changed.** Without a key: `-32000 Authentication required`, returned in **0.00 s**.
With an invalid key: `-32603` "Failed to initialize session services", returned in **0.69 s** — a
network round trip. **(static)** this is exactly the boundary in the source:

```js
newSession(e){ … if(!this.isAuthenticated) throw authRequired({message:`… run 'agent login' …`});
  if(!this.sharedServices) try{ this.sharedServices = yield this.authConfig.initSharedServices() }
  catch(e){ throw internalError({message:"Failed to initialize session services"}) } …
```

The `isAuthenticated` check passed on the strength of the env var alone; only the subsequent
service init failed, because the key was fake. **A valid `CURSOR_API_KEY` therefore takes ACP
session creation all the way through, with no browser and no `authenticate` call at all.**

For Threading this reframes the whole provider: Cursor support does not require embedding a
device-code flow. It requires a key field. Everything marked BLOCKED-ON-AUTH below is blocked on
*this machine having no account*, not on a protocol limitation.

`CURSOR_API_KEY` does **not** change `cursor-agent status` (still `unauthenticated`, since that
command reports stored login tokens only), so status is not a usable readiness probe for a
key-configured session.

---

## 6. Session identity, state on disk, and the non-ACP surfaces

### 6.1 The session id is a UUID, and it is the chat id

**(static)** — this is the answer to durable identity, and it is unusually clean:

```js
newSession(e){ … const n = crypto.randomUUID(), r = resolve(e.cwd ?? process.cwd()); …
  const b = { sessionId:n, modes:this.buildModesState(l), models:w, configOptions:y };
  return setTimeout(()=>{ m.sendAvailableCommands …
```

```js
loadSession(e){ … const {sessionId:t} = e; debugLog("ACP loadSession called for sessionId:", t);
  const o = Object.assign({}, this.options, { resumeChatId: t }); const n = resolve(e.cwd); …
```

Three facts fall out. The ACP `sessionId` is a plain **UUIDv4 minted by the CLI**, so it is
opaque and safe to store. `session/load` feeds that same id back in as **`resumeChatId`** — it is
not a separate ACP-only handle but *the Cursor chat id*, which is why `loadSession: true` is
honest. And `session/new`'s result carries **`modes`, `models` and `configOptions`** alongside the
id, so model and mode discovery happen at session creation rather than needing
`cursor/list_available_models` first.

That the chat id is a client-visible UUID is corroborated on the CLI side — and this one runs
**unauthenticated**:

```
$ cursor-agent create-chat
8c1d1cbf-615d-4df3-8391-a9e70e5be32c
```

**(static)** it is `randomUUID()` written into a per-chat SQLite `store.db`. No such file
survived the probe (and `cursor-agent resume` still reports "No previous chats found."), so
unauthenticated chat creation does not durably register anything — but it confirms the id space.

### 6.2 Where it writes

Diffed `~/.cursor` against a pre-install marker. Paths only; no contents are reproduced here
because the auth files in this tree can hold tokens.

| Path | When it appeared |
|---|---|
| `~/.cursor/cli-config.json` | first CLI run — settings (`permissions`, `approvalMode`, `sandbox`, `network`, `attribution`, …) |
| `~/.cursor/statsig-cache.json` | first CLI run — feature-flag/telemetry cache |
| `~/.cursor/agent-cli-state.json` | after `ls` / `resume` |
| `~/.cursor/projects/<slugified-cwd>-<hash>/` | after running in a project cwd — **per-project** state dir, left empty here |

The installer itself touched **none** of these; `~/.cursor` was byte-identical immediately after
install and only changed once the CLI was *run*. Nothing was written outside `~/.cursor` and
`~/.local`, and no rc file was modified.

Note the per-project directory keyed by cwd: Cursor scopes chat history to a project path, which
lines up with Threading's own project→session model but means **cwd is load-bearing for resume**,
not merely a working directory.

### 6.3 The non-ACP commands, measured

```
$ cursor-agent ls
  ERROR Raw mode is not supported on the current process.stdin, which Ink uses
        as input stream by default.
```

`ls` is an **Ink TUI** and dies without a TTY — it is not a scriptable session lister. The
scriptable path is ACP `session/list`, which is auth-gated. `cursor-agent resume` answers
`No previous chats found.` unauthenticated.

```
$ cursor-agent models          → Error: Authentication required. …
$ cursor-agent --list-models   → Error: Authentication required. …
$ cursor-agent mcp list        → No MCP servers configured (expected in .cursor/mcp.json or ~/.cursor/mcp.json)
```

`mcp list` works unauthenticated and names the two config locations. Note that MCP has **two
independent injection routes**: this on-disk config, and the `mcpServers` array passed per
session over ACP. A host that injects its own MCP server over the wire should expect the user's
`~/.cursor/mcp.json` servers to be present too.

All of `ls`, `create-chat`, `models`, `mcp list`, `resume` exited **0 even when refusing** — exit
status is not a usable success signal.

---

## 7. Capability table

What Threading needs for an honest native Cursor conversation, against what was measured.
"BLOCKED-ON-AUTH" meant the method is registered and reachable and stopped on credentials; **§10
settled almost all of those on the wire**, and each such row now carries its §10 evidence. Only two
rows are still unreached, and they say why.

| What the app needs | Verdict | Evidence |
|---|---|---|
| Spawn + stdio JSON-RPC | **MEASURED** | `cursor-agent acp`; hidden subcommand, `--help` confirms "ACP (Agent Client Protocol) server" |
| Custom endpoint | **MEASURED** | `cursor-agent -e <url> acp` handshakes normally |
| `initialize` + version negotiation | **MEASURED** | response in 0.64 s; `protocolVersion: 1`; `99` negotiates down to `1` |
| Auth-method discovery | **MEASURED** | `authMethods:[{id:"cursor_login", …}]` |
| Non-browser credentials | **MEASURED** (gate only) | `--api-key`/`--auth-token`/`CURSOR_API_KEY`/`CURSOR_AUTH_TOKEN` pass `isAuthenticated` (§5.3); that a key sustains a *turn* is still inference — §10.11 |
| `session/new` (+cwd, mcpServers) | **MEASURED** (§10.1) | result is exactly `{sessionId, modes, models, configOptions}`; 2.5 s; 3 modes, 34 models, 2 config ids (`mode`, `model`) |
| Session id durability | **MEASURED** (§10.4) | UUIDv4 survives process death; `~/.cursor/acp-sessions/<uuid>/{meta.json,store.db}` |
| `session/load` — resume | **MEASURED** (§10.4) | replays prior turns as `session/update` notifications *before* the result; result = `{modes, models, configOptions}` |
| `session/list` — enumeration | **MEASURED** (§10.10) | `{sessionId, cwd, title, updatedAt}`, newest first, global across cwds, durable; omits sessions that never took a turn |
| `session/prompt` — streaming turn | **MEASURED** (§10.3) | `stopReason:"end_turn"`; token-level chunks; no `messageId`, no message boundary of any kind |
| `session/update` stream kinds | **MEASURED** (§10.3) | seen live: `session_info_update` (**not in the static list**), `agent_thought_chunk`, `agent_message_chunk`, `tool_call`, `tool_call_update`, `plan`, `available_commands_update`, `current_mode_update`; `user_message_chunk` only on replay |
| Session auto-title | **MEASURED** (§10.3) | `session_info_update {"title":…}` ~0.9 s into the first turn; also in `session/list` |
| Tool calls + updates | **MEASURED** (§10.6) | `kind` ∈ `execute`/`edit`/`search`/`other`; shell gives `rawInput.command` + `rawOutput{exitCode,stdout,stderr}`; output is in `rawOutput`, **not** ACP `content` |
| Diff payload for an edit | **BROKEN** (§10.6) | `content[].type:"diff"` carries unified-diff *header fragments* in the content fields — `oldText` is the literal `-- /dev/null`, `newText` is `++ b/<path>` plus the real content — not renderable as a diff without heuristics |
| Tool-call id is single-line | **ABSENT** (§10.6) | `toolCallId` is `call-<uuid>-0\nfc_<hex>_0` — contains a literal newline |
| Failed/rejected tool status | **ABSENT** (§10.5, §10.9) | a rejected tool and an MCP error both report `status:"completed"`; ACP's `failed` is never used |
| Permissions with option kinds | **MEASURED — contradicts the static row** (§10.5) | **three** options, always: `allow_once`, `allow_always`, `reject_once`. **No `reject_always` on the wire.** `optionId`s hyphenated, `kind`s underscored; reason in `toolCall.content` |
| Permission covers edits | **ABSENT** (§10.5) | under `approvalMode:"allowlist"` a file write raised no `session/request_permission` at all; only shell commands are gated |
| `allow_always` persistence | **MEASURED** (§10.5) | writes a `Shell(<argv0>)` rule into `~/.cursor/cli-config.json` `permissions.allow` — global, shared with the TUI, not per-session |
| Cancellation | **MEASURED** (§10.7) | `session/cancel` notification → pending `session/prompt` resolves `{"stopReason":"cancelled"}` in **4 ms**; stream stops; session stays loadable |
| MCP injection over the wire | **MEASURED** (§10.9) | contacted at `session/new` as `Cursor/1.0.0`, MCP `2025-11-25`, `elicitation.form`; `tools/list` → `tools/call`; tools surface as permission-gated `kind:"other"` calls |
| MCP from disk | **MEASURED** | `mcp list` names `.cursor/mcp.json`, `~/.cursor/mcp.json`; disk↔wire merge still unmeasured (§10.11) |
| cwd handling | **MEASURED, with a hazard** (§10.4) | required string, `resolve`d; **`session/load` accepts any cwd and silently rebinds the live session to it** while `meta.json` keeps the original |
| Per-turn usage / token telemetry | **ABSENT** (§10.10) | no `usage`-shaped notification in any probe; cost and limits are not on this protocol |
| Model discovery | **MEASURED** (§10.1) | 34 models in the `session/new` result; `cursor/list_available_models` adds the per-model knobs (`effort`, `thinking`, `context`, `reasoning`, `fast`) |
| Model selection | **MEASURED** (§10.2) | `session/set_model` and `session/set_config_option{configId:"model"}`; ids from the wrong picker mode are refused `-32602 "Invalid model value: …"` |
| Parameterized model picker | **MEASURED — effect now observed** (§10.1) | flag `true` → bare ids + marketing names (`claude-opus-5`, "Opus 5"); flag absent → bracketed variant ids (`claude-opus-5[thinking=true,…]`). The two id spaces are **disjoint** |
| Modes (plan / ask / agent) | **MEASURED** (§10.2) | real ids `agent`/`plan`/`ask`; `set_mode` emits `current_mode_update` then `{}`; bad id → `-32603` with `data.details` (a third `error.data` shape) |
| Image prompts | **MEASURED** (advertised) | `promptCapabilities.image: true` |
| Embedded context blocks | **ABSENT** | `promptCapabilities.embeddedContext: false` |
| Audio prompts | **ABSENT** | `promptCapabilities.audio: false` |
| `session/fork` | **ABSENT** | `-32601` — ACP library supports it, Cursor does not implement `unstable_forkSession` |
| `session/resume` (distinct from load) | **ABSENT** | `-32601` — `unstable_resumeSession` not implemented; resume is `session/load` only |
| Cursor plan / todo / question UX | **MEASURED — optional** (§10.8) | `cursor/create_plan` fires with a rich payload; answering `-32601` costs the turn **nothing** (same content, `end_turn`), because the plan also arrives as a standard `plan` update. `ask_question`/`update_todos`/`task`/`generate_image` never fired |
| Scriptable session list off-protocol | **ABSENT** | `cursor-agent ls` is an Ink TUI, fails without a TTY — but ACP `session/list` covers it (§10.10) |
| Framing-error detection | **ABSENT** | garbage and truncated JSON produce *no* response and no stderr; unchanged under auth |

### The sharp edges

1. **Session methods are all-or-nothing behind auth** — but the API-key path (§5.3) means this is
   a configuration problem, not a protocol wall.
2. **`authenticate` will open the user's browser.** Any spawn must neutralise `BROWSER` first,
   and the login URL is only recoverable by substring-matching an `-32602` error message.
3. **Silent framing failures.** No stderr, ever; malformed input vanishes. Client-side timeouts
   are mandatory.
4. **`error.data` is polymorphic** — object with `message`, a raw Zod issue *array*, or an object
   with `details` instead of `message` (§10.2). Three shapes, one field.
5. ~~**Five `cursor/*` methods are the client's job.**~~ **Corrected by §10.8:** they are optional.
   Refusing `cursor/create_plan` with `-32601` did not disturb the turn, and the plan arrived on
   the standard `plan` update anyway. Implementing them buys a richer plan document, nothing more.
6. **No fork.** Threading's side-chat/fork capability has no Cursor equivalent — `session/fork`
   is not implemented.
7. **No embedded context**, so workspace file mentions cannot be inlined as resource blocks.
8. ~~**Resume is cwd-scoped.**~~ **Corrected by §10.4 — it is worse than scoped: it is unchecked.**
   `session/load` accepts the id from any directory, replays it, and rebinds the live session to
   whatever cwd it was handed. The host owns cwd correctness; the agent will not object.
9. **The edit diff is malformed** (§10.6) — diff-header fragments in `oldText`/`newText`. A Cursor
   profile cannot feed Threading's diff cards without cleaning it up first.
10. **A rejected or failed tool reports `completed`** (§10.5, §10.9), so the transport must
    remember its own permission answer to render the row honestly.
11. **`toolCallId` contains a literal newline** (§10.6). Opaque, stable, and unsafe in anything
    line-oriented.
12. **Edits are not permission-gated** under the default `allowlist` mode (§10.5) — only shell
    commands are. Do not describe Cursor's approvals as covering file changes.
13. **`allow_always` edits the user's global `~/.cursor/cli-config.json`** (§10.5), shared with the
    interactive CLI. That button has blast radius beyond the session offering it.
14. **No usage or token telemetry exists on this protocol** (§10.10).

---

## 8. What authenticated measurement must still cover

Every item here needs a Cursor account or a valid `CURSOR_API_KEY`. None of it is inferable from
what is above. **Checked items were measured on 2026-08-12 — see the §10 subsection named after
each.**

- [x] `session/new` success: full result shape — `sessionId`, `modes`, `models`, `configOptions`
      — and whether `models` differs with `parameterizedModelPicker` on vs. off. → **§10.1**
- [x] `session/prompt`: the actual `session/update` sequence, chunk granularity, whether
      `agent_thought_chunk` is emitted, and the terminal `stopReason` for a clean turn. → **§10.3**
- [x] `session/cancel` mid-turn: how long it takes to settle, and that the in-flight
      `session/prompt` resolves with `stopReason: "cancelled"` rather than erroring or hanging.
      → **§10.7**
- [x] `session/request_permission`: real payload, which `optionId`s arrive, and whether
      `allow_always` persists into `~/.cursor/cli-config.json`'s `permissions`/`approvalMode`.
      → **§10.5**
- [x] Tool-call fidelity: `tool_call` / `tool_call_update` content, diffs, and whether they carry
      enough to render Threading's tool rows. → **§10.6** (shells yes, diffs no)
- [x] **Durability across processes**: create a session in process A, record the id, kill A,
      `session/load` the same id in process B, and confirm history replays. → **§10.4**
- [x] Whether `session/load` replays prior turns as `session/update` events (ACP's contract) or
      returns silently. → **§10.4** (it replays, coalesced, before the result)
- [x] Same id from a *different* cwd — does the per-project directory make resume fail? → **§10.4**
      (no: it succeeds and silently rebinds)
- [x] MCP injection: pass a real `mcpServers` entry, confirm tools appear, and see whether disk
      config merges with wire config. → **§10.9** (injection measured; the disk↔wire merge is not —
      no `mcp.json` existed on this machine)
- [x] `cursor/ask_question` / `create_plan` / `update_todos` / `task` / `generate_image`: real
      payloads and what a client must answer. → **§10.8** (`create_plan` only; the other four never
      fired, and refusing them is harmless)
- [x] `available_commands_update`: the slash-command list Cursor pushes after `session/new`.
      → **§10.2**
- [x] `session/set_mode` against real mode ids, and `session/set_model` round-tripping. → **§10.2**
- [ ] **BLOCKED** — whether `CURSOR_API_KEY` alone (no `agent login`) sustains a full turn, or
      degrades. This account authenticated through the browser; no key exists to test with, and one
      must be minted from the Cursor dashboard. → **§10.11**
- [ ] Rate-limit / quota refusal shape, for `limit-recovery.md` parity. Not encountered in ten
      turns; not worth chasing deliberately. → **§10.11**
- [x] `session/list` result shape — enough for Threading's import-outside-conversations flow?
      → **§10.10** (yes: id, cwd, title, updatedAt, durable and global)

---

## 9. Decision — deferred, with the gates named

> **Re-decided 2026-08-12, on §10's evidence: GO.** The rule below keys on the load-bearing
> lifecycle, and all of it measured as working — `session/load` replays history in order,
> permissions round-trip with the standard `kind`s, a cancel settles as `cancelled` in 4 ms, and
> the session id is durable across processes. What did not clear becomes implementation scope,
> not deferral: gate 5's bounded-response hardening lands first as provider-neutral core work
> (now also covering opaque ids); edit tool calls render without diff cards until Cursor's diff
> payload carries real old/new text (§10.6); a tool the client itself denied is presented as
> denied even though Cursor reports it `completed` (§10.5); resume always launches with the
> session's own checkout as cwd, because `session/load` rebinds silently (§10.4); and the
> capability rows claim no forking, no permission modes, no embedded context, and no usage meter.
> The original deferral text is kept below as the record of why the measurement was made.
>
> **Shipped 2026-08-12.** `AgentKind.cursor` is `ACPStreamSession(.cursor)` on
> `cursor-agent acp`, with `ACPProviderProfile+Cursor.swift` as its whole provider surface. Two
> things the plan did not anticipate came out of §11 and changed the shape: Cursor's TUI and its
> ACP server keep **disjoint conversation stores**, so a Cursor session is native-only
> (`AgentCapabilities.terminalUI` is the new row, and the terminal launch path refuses); and its
> login is in the keychain rather than a config directory, so `accountEnvironmentKey` became
> optional. Gate 5's hardening landed first as provider-neutral core work — a bounded handshake,
> opaque tool-call ids, and a denied call presented as denied — in `ACPStreamSession` with its
> own transport tests.

**Cursor does not ship as a provider yet.** The rule this record was made under: a capability the
app advertises must be measured, and resume, permissions, tool fidelity, and cancellation settling
are all BLOCKED-ON-AUTH above — statically corroborated by the bundle, observed on the wire by
nobody. A `AgentKind.cursor` that launches but cannot keep those promises is the named anti-goal,
so none lands.

What is already in place: the shared `ACPStreamSession` runtime is extracted, Grok-parity is held
by `GrokACPProfileTests`, and the transport itself is held by `ACPStreamSessionTests` against
deterministic fakes. When the gates below are cleared, Cursor is one `ACPProviderProfile` value,
one `AgentLauncher` launch line (`cursor-agent acp`, `BROWSER` neutralised), and its own honest
capability rows — no new transport.

The gates, in order:

1. **An authenticated wire pass over §8**, which needs a Cursor account or `CURSOR_API_KEY` only
   the user can supply. The harness rules at the end of this document apply unchanged. The
   load-bearing items are the `session/load` replay shape, the `session/request_permission`
   round-trip, the mid-turn `session/cancel` settle, and tool-call fidelity; the rest of §8 is
   completeness.

   > **CLEARED on 2026-08-12 evidence (§10).** All four load-bearing items were measured on the
   > wire over ten prompt turns; only the `CURSOR_API_KEY`-alone question and the quota-refusal
   > shape remain unreached, and neither is load-bearing.

2. **Wire confirmation of the two vocabularies the shared runtime assumes.** The bundle carries
   the underscored option kinds (`allow_once`, …) and the standard stop reasons (`cancelled`,
   `refusal`) — if the wire agrees, the core needs no change; if it deviates, that is the profile
   member the core's comment already reserves.

   > **PARTIALLY CLEARED (§10.5, §10.7).** Stop reasons agree: `end_turn` and `cancelled` arrived
   > exactly as assumed. Option kinds agree in spelling but **not in cardinality** — only three
   > arrive (`allow_once`, `allow_always`, `reject_once`); `reject_always` never appears, and the
   > `optionId`s are hyphenated (`allow-once`) while the `kind`s are underscored. A client must
   > key off `kind` and render whatever arrives, not a fixed four.

3. **A product decision on the five client-side `cursor/*` methods.** Measure what degrades when
   they are unregistered; if `ask_question` turns out to be part of an ordinary turn, Cursor needs
   a question surface in Threading before it can ship, not after.

   > **CLEARED (§10.8).** Answering `-32601` to `cursor/create_plan` cost the turn nothing: it ran
   > to `end_turn`, and the plan arrived in full through the standard `plan` `session/update`
   > anyway. `cursor/ask_question` never fired in any measured turn. They are enrichment, not a
   > ship blocker.

4. **Honest capability rows, written from this table**: no `.forking` (`session/fork` is absent),
   resume via `session/load` only and cwd-scoped, no permission-mode surface until Cursor's
   plan/ask/agent modes are measured against Threading's six-mode vocabulary (they are a different
   axis), no embedded-context claims (`embeddedContext: false`).

   > **PARTIALLY CLEARED (§10.2, §10.4).** The three modes are now measured with real ids
   > (`agent`/`plan`/`ask`) and a live `current_mode_update`; they remain a different axis from
   > Threading's six. One row needs rewriting rather than confirming: resume is **not** cwd-scoped
   > — `session/load` accepts the id from *any* cwd and silently rebinds the live session to the
   > cwd it was handed (§10.4), which is a correctness hazard, not a restriction.

5. **A bounded-response hardening decision for `ACPStreamSession`** — Cursor swallows malformed
   input with no response and no stderr, so a client-side timeout is the only detector of a
   framing desync. That hardening is provider-neutral and should land as core work with its own
   transport test, not as a Cursor conditional.

   > **NOT CLEARED — unchanged, and now with a second reason.** Nothing in §10 softens it: stderr
   > stayed silent across every authenticated probe too. §10.6 adds a decoding hazard in the
   > same family — `toolCallId` contains a literal newline — so the hardening should cover opaque
   > id handling as well as timeouts.

Re-run §3–§4 before acting on any of this if `cursor-agent update` has moved the pinned build.

---

## 10. Authenticated measurement (2026-08-12, build 2026.08.11-e8db854)

The user logged in through the browser flow. Same machine, same pinned build, same harness rules —
`BROWSER=/usr/bin/true` and `NO_OPEN_BROWSER=1` in every child environment, a wall-clock budget
with `terminate()` then `kill()`, and no `login`/`logout`/`update` at any point. Every probe below
ended `rc=143` at its deadline.

```
$ cursor-agent status --format json
{"status":"authenticated","isAuthenticated":true,"hasAccessToken":true,"hasRefreshToken":true,
 "userInfo":{"email":"<account>","userId":<redacted>,"createdAt":"2026-08-12T18:41:00.697Z"}}
```

**Cost of this section: ten prompt turns**, every one a throwaway sentence against a scratch
directory (`<scratch>/projA`, `<scratch>/projB`), never the repository. **No quota or rate-limit
refusal was encountered**, so §8's refusal-shape item stays open. Absolute paths below are
redacted to `<scratch>` and `~`; nothing else is edited.

Two things the unauthenticated pass could not have known frame everything that follows: the wire
carries a **`session_info_update`** kind that appears in no static list in §7, and the whole
session lifecycle works — creation, streaming, permissions, cancellation, cross-process resume —
on an ordinary browser login with no API key and no `authenticate` call over ACP.

### 10.1 `session/new` succeeds, and hands back the entire configuration surface

```json
{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"<scratch>/projA","mcpServers":[]}}
```

Answered at **2.5 s** after the request (0.6 s `initialize` + a network round trip). The result has
exactly four keys — `sessionId`, `modes`, `models`, `configOptions` — confirming the static
reading in §6.1 verbatim:

```json
{"jsonrpc":"2.0","id":2,"result":{"sessionId":"512ff973-0b9d-4679-a33c-9bfd6f020f1e","modes":{"currentModeId":"agent","availableModes":[{"id":"agent","name":"Agent","description":"Full agent capabilities with tool access"},{"id":"plan","name":"Plan","description":"Read-only mode for planning and designing before implementation"},{"id":"ask","name":"Ask","description":"Q&A mode - no edits or command execution"}]},"models":{"currentModelId":"default[]","availableModels":[{"modelId":"default[]","name":"Auto"},{"modelId":"grok-4.6[effort=high,fast=true]","name":"grok-4.6"}, … 34 entries … ]},"configOptions":[ … ]}}
```

- **`sessionId` is a UUIDv4**, as §6.1 predicted from the bundle.
- **`modes`**: three, `currentModeId: "agent"`. These are Cursor's execution modes, a different
  axis from Threading's six permission modes — `plan` is read-only, `ask` forbids edits and
  commands, `agent` is the default.
- **`models`**: 34 entries.
- **`configOptions`**: exactly two ids, `mode` and `model`, both `type: "select"`, categories
  `mode` and `model`. There is no third knob. `configOptions[1]` is a duplicate of `models` in
  `{value,name}` clothing, so a client can drive everything through the generic config channel.

**The `parameterizedModelPicker` `_meta` flag changes the model list, exactly as §3 predicted.**
Same command, `clientCapabilities._meta.parameterizedModelPicker: true`:

| | `models.currentModelId` | first entries |
|---|---|---|
| flag **absent** ("variants") | `default[]` | `{"modelId":"default[]","name":"Auto"}`, `{"modelId":"grok-4.6[effort=high,fast=true]","name":"grok-4.6"}` |
| flag **`true`** ("parameterized") | `default` | `{"modelId":"default","name":"Auto"}`, `{"modelId":"grok-4.6","name":"Cursor Grok 4.6"}`, `{"modelId":"claude-opus-5","name":"Opus 5"}` |

So the flag is not cosmetic: it decides **whether variant parameters are baked into the id**
(`claude-opus-5[thinking=true,context=300k,effort=high,fast=false]`) or stripped out, and it also
switches `name` from the raw slug to the marketing name ("Opus 5", "Cursor Grok 4.6"). The two id
spaces are **not interchangeable** — see the `set_model` failure in §10.2. A host must pick one
mode at `initialize` and stay in it.

Only under the flag does `cursor/list_available_models` line up with the session's own list; it
answers in 0.5 s with 34 entries of the shape

```json
{"value":"grok-4.6","name":"Cursor Grok 4.6","configOptions":[{"id":"effort","name":"Effort","description":"Effort the model uses to generate its response.","category":"thought_level","type":"select","currentValue":"high","options":[{"value":"low","name":"Low"},{"value":"medium","name":"Medium"},{"value":"high","name":"High"},{"value":"xhigh","name":"Extra High"}]},{"id":"fast","name":"Fast","description":"Significantly faster but consumes more usage","category":"model_config","type":"select","currentValue":"true","options":[{"value":"false","name":"Off"},{"value":"true","name":"Fast"}]}]}
```

— i.e. the per-model knobs (`effort`, `thinking`, `context`, `reasoning`, `fast`) that the variants
form squashes into the bracketed suffix. This is the only method that exposes them structurally.

### 10.2 `available_commands_update`, modes and models round-tripped

**`available_commands_update` arrives as an unsolicited notification ~0.7 s *after* the
`session/new` result**, matching the `setTimeout` in §6.1. On this account it carried **23
commands**, and each entry has exactly two keys:

```json
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"…","update":{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"copy-request-id","description":"Copy the last request ID to clipboard"},{"name":"create-rule","description":"Create Cursor rules for persistent AI guidance. … (builtin skill)"},{"name":"loop","description":"Run a prompt or skill in this session on a recurring or variable interval (e.g. /loop 5m /foo). (builtin skill)"}, … ]}}}
```

No `input` schema, no argument hints — just `name` and `description`. Note the list is **the
user's own**: builtin skills, user commands (`/outsource (user)`) and global ones are mixed
together, so it is account state, not a protocol constant. It is pushed once per session and was
never re-sent.

`session/set_mode` works against the advertised ids and **emits the notification before the
result**:

```json
{"jsonrpc":"2.0","id":3,"method":"session/set_mode","params":{"sessionId":"…","modeId":"plan"}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"…","update":{"sessionUpdate":"current_mode_update","currentModeId":"plan"}}}
{"jsonrpc":"2.0","id":3,"result":{}}
```

Both in the same millisecond, locally — no network round trip. A bad id is refused with a *third*
`error.data` shape, neither `{message}` nor a Zod array but `{details}`:

```json
{"jsonrpc":"2.0","id":6,"error":{"code":-32603,"message":"Internal error","data":{"details":"Invalid mode ID: bogus_mode. Valid modes: agent, plan, ask"}}}
```

`session/set_config_option` with `configId:"mode"` does the same thing and additionally **returns
the full refreshed `configOptions` array** (0.6 s — it does round-trip), where `set_mode` returns
`{}`. Two spellings of one operation with different result shapes.

`session/set_model` **rejects an id from the other picker mode**, which is how the two id spaces
were proved disjoint:

```json
{"jsonrpc":"2.0","id":4,"method":"session/set_model","params":{"sessionId":"…","modelId":"claude-haiku-4-5[thinking=true]"}}
{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"Invalid params","data":{"message":"Invalid model value: claude-haiku-4-5[thinking=true]"}}}
```

(that session had been initialized *with* `parameterizedModelPicker`, so it wanted the bare
`claude-haiku-4-5`.)

### 10.3 One clean turn, end to end

```json
{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"512ff973-…","prompt":[{"type":"text","text":"Reply with exactly: ok"}]}}
```

The complete sequence, timestamps relative to spawn (prompt sent at 8.006):

```
 8.940  session_info_update   {"title":"Okay"}
11.097  agent_thought_chunk   {"type":"text","text":"The user requested a"}
11.097  agent_thought_chunk   {"type":"text","text":" reply containing exactly"}
11.098  agent_thought_chunk   {"type":"text","text":" \"ok\"."}
11.098  agent_message_chunk   {"type":"text","text":"ok"}
11.185  → {"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}
```

Reading it:

- **`session_info_update` is a real wire kind and is in none of §7's static vocabulary.** It
  carries `{"title": "…"}` — Cursor auto-names the chat from the first prompt, ~0.9 s in, before
  any content. Threading gets a free session name from it, and must expect it mid-stream.
- **`agent_thought_chunk` is emitted**, and it precedes the message. Reasoning is on by default on
  the `Auto` model.
- **Granularity is token-level**, word-ish fragments arriving in bursts within the same
  millisecond (237 chunks in 2.0 s on the counting turn in §10.7). A client that lays out per
  chunk will do 100+ layouts a second; coalescing is mandatory, not an optimization.
- **There is no `messageId` and no message-boundary event of any kind.** Neither chunk kind
  carries an id, an index, or a "final" marker. The only boundaries a client gets are (a) the
  change of `sessionUpdate` kind, (b) an interleaved `tool_call`, and (c) the `session/prompt`
  result. Threading's timeline must synthesize message identity itself; nothing on the wire
  supports patching an earlier message.
- **`user_message_chunk` is not echoed live.** The client's own prompt never comes back during the
  turn — only on replay (§10.4). A transport that renders both will double-render after a resume.
- **`stopReason: "end_turn"`** for a clean turn, arriving 87 ms after the last chunk.

### 10.4 Durability across processes — replay works, cwd scoping does not

Process A created `512ff973-…` in `<scratch>/projA` and ran the turn above; it was then killed at
its budget. A **fresh process** in the same cwd:

```json
{"jsonrpc":"2.0","id":3,"method":"session/load","params":{"sessionId":"512ff973-0b9d-4679-a33c-9bfd6f020f1e","cwd":"<scratch>/projA","mcpServers":[]}}
```

**History replays as `session/update` notifications, in order, before the result** — 2.9 s after
the request:

```json
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"512ff973-…","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Reply with exactly: ok"}}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"512ff973-…","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"The user requested a reply containing exactly \"ok\"."}}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"512ff973-…","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ok"}}}}
{"jsonrpc":"2.0","id":3,"result":{"modes":{…},"models":{…},"configOptions":[…]}}
```

Four facts a transport depends on:

1. **The replay is coalesced, not re-streamed.** The three thought fragments of §10.3 come back as
   **one** chunk. So chunk count is not stable across a resume, and any client-side identity keyed
   to chunk arrival will not survive one.
2. **The user turn *is* included** (`user_message_chunk`), unlike the live stream.
3. **The result carries `modes`, `models` and `configOptions` but not `sessionId`** — the caller
   already knows it.
4. **All replay notifications precede the result**, so a client can treat the result as
   "replay complete" without a sentinel.

An unknown id is refused cleanly: `-32602` · `{"message":"Session \"00000000-…\" not found"}`.

**The cwd question has a worse answer than "it refuses".** Loading the *same* id from
`<scratch>/projB` — a completely different directory — **succeeded**, replayed identically, and
then the live `session/list` reported the session as belonging to `projB`:

```json
{"jsonrpc":"2.0","id":2,"result":{"sessions":[{"sessionId":"512ff973-…","cwd":"<scratch>/projA","title":"Okay","updatedAt":"…"}]}}   ← before the cross-cwd load
{"jsonrpc":"2.0","id":4,"result":{"sessions":[{"sessionId":"512ff973-…","cwd":"<scratch>/projB","title":"Okay","updatedAt":"…"}]}}   ← after it, same process
```

There is no refusal and no warning. On disk the record is unchanged — `~/.cursor/acp-sessions/<uuid>/meta.json`
still reads `{"schemaVersion":1,"cwd":"<scratch>/projA","title":"Okay"}` after the fact — so the
rebinding is in-memory only, which means `session/list` answers from **two different sources**
(live session state for loaded sessions, `meta.json` for the rest) and can disagree with itself
within one process. **§7's "resume is cwd-scoped" row was wrong**: cwd is load-bearing for where
tools will run, and Cursor will happily run a resumed conversation's tools against a directory it
never saw. A host must pass the cwd it stored, because nothing on the agent side will catch a
mismatch.

Where the state lives (paths only — `store.db` holds conversation content):

| Path | What |
|---|---|
| `~/.cursor/acp-sessions/<uuid>/meta.json` | `{schemaVersion, cwd, title}` — what `session/list` reads |
| `~/.cursor/acp-sessions/<uuid>/store.db` (+`-wal`, `-shm`) | the conversation; **created only once a session takes a turn** |
| `~/.cursor/plans/<name>-<sessionprefix>.plan.md` | plan documents (§10.8) |

A session created and never prompted leaves a `meta.json` with no `title` and no `store.db`, and
**does not appear in `session/list`**. Threading cannot rely on `session/new` alone registering
anything durable.

### 10.5 Permissions: three options, not four

Default state on this machine was `approvalMode: "allowlist"` with
`permissions.allow: ["Shell(ls)"]`. Prompting `Run the shell command: echo hello` produced, 2.5 s
after the tool went `in_progress`, an agent→client **request**:

```json
{"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"sessionId":"0a993b58-…","toolCall":{"toolCallId":"call-aaaa9a3f-33b2-441e-87e9-6afeb6eccde2-0\nfc_1d06cbc2-409c-933a-ab58-55ccbae321a8_0","title":"`echo hello`","kind":"execute","status":"pending","content":[{"type":"content","content":{"type":"text","text":"Not in allowlist: echo"}}]},"options":[{"optionId":"allow-once","name":"Allow once","kind":"allow_once"},{"optionId":"allow-always","name":"Allow always","kind":"allow_always"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}}
```

This is the decisive payload, so read it closely.

- **Three options arrive, not four.** `allow_once`, `allow_always`, `reject_once`. **There is no
  `reject_always` on the wire** — in any of the four permission requests captured (shell ×3, MCP
  tool ×1) the array was byte-identical. §7's static row listed all four kinds because all four
  *strings* are in the bundle; the wire contradicts it. A client must render from `options[]`,
  never from a fixed set.
- **`optionId` and `kind` use different spellings** — hyphens in the id (`allow-once`), underscores
  in the kind (`allow_once`). Answering echoes the `optionId`.
- **The reason is in `toolCall.content`**, as a doubly-nested `{"type":"content","content":{"type":"text",…}}`
  block: `"Not in allowlist: echo"`. That, not the title, is what a permission sheet should show.
- **The agent's request ids start at 0** and are its own counter — independent of the client's.
- **`toolCall.status` is `"pending"` in the permission payload** even though a `tool_call_update`
  had already moved that same id to `in_progress` a moment earlier. The two disagree; the update
  stream is the newer one.

Answering is unremarkable:

```json
{"jsonrpc":"2.0","id":0,"result":{"outcome":{"outcome":"selected","optionId":"allow-once"}}}
```

**Allow once** → the tool runs, 2.6 s later `tool_call_update` `status:"completed"` with output,
turn ends `end_turn`.

**Reject once** (a separate turn, `whoami`) → **`tool_call_update` with `status:"completed"`**, 30 ms
later, *with no `rawOutput` and no content*:

```json
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"e60ae83c-…","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-807c6aad-…","status":"completed"}}}
```

The model then narrates the rejection in prose ("The `whoami` command was rejected (not run).") and
the turn ends `end_turn`. **A rejected tool is indistinguishable from a successful one by status
alone** — ACP has `failed` and Cursor does not use it here. Threading must remember its own answer
to render a rejected row honestly; the wire will not tell it twice.

**`allow_always` persists globally and immediately.** A third turn (`date`) answered
`allow-always` rewrote `~/.cursor/cli-config.json` before the turn finished:

```
permissions.allow: ["Shell(ls)"]                  ← before
permissions.allow: ["Shell(ls)", "Shell(date)"]   ← after
```

It is a `Shell(<argv0>)` rule in the **user's global CLI config** — not per-session, not
per-project, and shared with the interactive `cursor-agent` TUI and any other embedding. A host
offering that button is editing global state on the user's behalf. (This probe's entry was removed
afterwards; the file is otherwise untouched.)

**The gate is narrower than it looks: file writes are not gated at all.** The edit turn in §10.6
wrote a new file into the scratch directory with **no `session/request_permission` whatsoever**
under the same `allowlist` mode. On this build the allowlist governs *shell commands*; edits go
through on the mode alone. Any Threading surface that presents Cursor's approval flow as "you will
be asked before it changes anything" would be lying.

### 10.6 Tool-call fidelity — good for shells, broken for diffs

**Shell (`kind: "execute"`).** Two updates plus a completion:

```json
{"sessionUpdate":"tool_call","toolCallId":"call-aaaa9a3f-33b2-441e-87e9-6afeb6eccde2-0\nfc_1d06cbc2-409c-933a-ab58-55ccbae321a8_0","title":"`echo hello`","kind":"execute","status":"pending","rawInput":{"command":"echo hello"}}
{"sessionUpdate":"tool_call_update","toolCallId":"…","status":"in_progress"}
{"sessionUpdate":"tool_call_update","toolCallId":"…","status":"completed","rawOutput":{"exitCode":0,"stdout":"hello\n","stderr":""}}
```

That is enough for a Threading tool row: a title, the command in `rawInput`, and a structured
`{exitCode, stdout, stderr}` result. Note the output arrives in **`rawOutput`, not ACP's
`content`** — a renderer keyed to `content` will show a completed shell tool with nothing in it.

**`toolCallId` contains a literal newline.** Verbatim: `call-<uuid>-0\nfc_<hex>_0`. It is a Cursor
call id and a provider function-call id joined by `\n`. It is stable across the `tool_call` and its
updates, so it works as a key — but it must never be logged unescaped, put in a filename, used in
a single-line diagnostic, or round-tripped through anything line-oriented. This is the same family
of hazard as the silent framing failures in §4.4 and belongs in the same hardening.

**Edit (`kind: "edit"`) — the diff payload is malformed.** Prompt: `Create a file named probe.txt
containing: probe`. The file was created correctly on disk. The wire said:

```json
{"sessionUpdate":"tool_call","toolCallId":"call-4fc20aed-…","title":"Edit File","kind":"edit","status":"pending","rawInput":{}}
{"sessionUpdate":"tool_call_update","toolCallId":"call-4fc20aed-…","status":"in_progress"}
{"sessionUpdate":"tool_call_update","toolCallId":"call-4fc20aed-…","status":"completed","content":[{"type":"diff","path":"<scratch>/projB/probe.txt","oldText":"-- /dev/null","newText":"++ b/<scratch>/projB/probe.txt\nprobe"}]}
```

`path` is right. `oldText` and `newText` are supposed to be **file contents**; what arrived is
**unified-diff header text**. `oldText` is the literal string `"-- /dev/null"` and `newText` is
`"++ b/<path>\nprobe"` — Cursor has spliced the `---`/`+++` header lines (minus one character each)
into the content fields, so the actual new content `probe` is prefixed with a path line. Rendering
`oldText → newText` as a diff produces a one-line deletion of `-- /dev/null` and a two-line
addition. **Threading's diff cards cannot honestly render this**; a Cursor profile would have to
either strip the header fragments heuristically or refuse to draw a diff card at all. This is a
provider defect, not a modelling gap — and it is exactly the kind of thing §9's "must be measured"
rule exists to catch.

Also: **`rawInput` is `{}` on the edit call**, so at `pending` time there is no filename to show —
only the generic title `"Edit File"`. The path arrives only with the completion. Other kinds seen:
`kind:"search"` (title `"Find"`, `rawInput:{}`), `kind:"other"` for plans and MCP tools.

### 10.7 Cancellation settles in 4 ms

Prompt `Count from 1 to 400, one number per line, no other text.`, then a `session/cancel`
**notification** 2.0 s after the first `agent_message_chunk`:

```
 9.948  first agent_message_chunk        (237 chunks follow over 2.0 s)
11.944  last agent_message_chunk
11.954  → {"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"8d67e523-…"}}
11.958  ← {"jsonrpc":"2.0","id":3,"result":{"stopReason":"cancelled"}}
```

**4 ms** from notification to the pending `session/prompt` resolving, streaming stopped, no error,
no orphaned request, and the session stayed listable and loadable afterwards. `stopReason` is
exactly `"cancelled"` — the vocabulary the shared runtime already assumes. This is the cleanest
result in the whole document.

### 10.8 `cursor/*` — real, optional, and duplicated by the standard `plan` update

Prompt `Make a 3-step plan to rename a function, then stop.` in `plan` mode, with the five
`cursor/*` methods registered as client handlers. `cursor/create_plan` fired, verbatim:

```json
{"jsonrpc":"2.0","id":0,"method":"cursor/create_plan","params":{"toolCallId":"call-88eae32e-…","name":"Rename a function","overview":"A minimal three-step process to rename a function safely across the codebase, then stop.","plan":"# Rename a function\n\n1. **Find all usages** — …\n2. **Rename the definition** — …\n3. **Update all references** — …\n","todos":[{"id":"find-usages","content":"Search for definition and all references of the function","status":"pending"},{"id":"rename-def","content":"Rename the function at its definition","status":"pending"},{"id":"update-refs","content":"Update all call sites, imports, and tests","status":"pending"}],"isProject":false,"phases":[]}}
```

It expects a response; `{}` was accepted without complaint. Around it, the same content came
through **ordinary ACP channels** in the same millisecond:

```json
{"sessionUpdate":"tool_call","toolCallId":"call-88eae32e-…","title":"Create Plan: Rename a function","kind":"other","status":"pending"}
{"sessionUpdate":"plan","entries":[{"content":"Search for definition and all references of the function","priority":"medium","status":"pending"},{"content":"Rename the function at its definition","priority":"medium","status":"pending"},{"content":"Update all call sites, imports, and tests","priority":"medium","status":"pending"}]}
{"sessionUpdate":"tool_call_update","toolCallId":"…","status":"in_progress","content":[{"type":"content","content":{"type":"text","text":"Plan saved to file:///~/.cursor/plans/Rename%20a%20function-3403e5f6.plan.md"}}]}
{"sessionUpdate":"tool_call_update","toolCallId":"…","status":"completed"}
```

**The degradation test settles gate 3.** The identical prompt, with **no** `cursor/*` handlers
registered — the client answering the standard JSON-RPC way:

```json
{"jsonrpc":"2.0","id":0,"method":"cursor/create_plan","params":{ … same shape … }}
{"jsonrpc":"2.0","id":0,"error":{"code":-32601,"message":"Method not found","data":{"message":"client has no handler for cursor/create_plan"}}}
```

The agent **ignored the error entirely**: 1 ms later the tool call continued to
`"Creating plan file…"`, the plan file was written, the tool completed, and the turn ended
`{"stopReason":"end_turn"}` — same content, same duration. The only observable difference between
the two runs was the `tool_call`'s `rawInput`: `{"_toolName":"createPlan"}` when unhandled versus
absent when handled.

So **`cursor/*` is enrichment, not a contract.** A Threading transport that registers nothing loses
nothing except Cursor's own richer plan document (`overview`, markdown `plan`, ids on the todos) —
the plan itself still arrives as an ACP `plan` update that Threading's existing timeline can
render. `cursor/ask_question`, `cursor/update_todos`, `cursor/task` and `cursor/generate_image`
**never fired in any of the ten turns**, including the plan-shaped ones, so their payloads remain
unmeasured and no measured turn depended on them.

### 10.9 MCP injection over the wire works

A localhost-only dummy MCP endpoint (a small Python HTTP server that logs every request, bound to
`127.0.0.1`, never reachable off-host) was passed in `session/new`:

```json
{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"<scratch>/projA","mcpServers":[{"name":"threading_probe","type":"http","url":"http://127.0.0.1:8766/mcp","headers":[]}]}}
```

`session/new` succeeded normally, and **Cursor connected during session creation**, before any
prompt. What the dummy server logged, verbatim:

```
POST /mcp   User-Agent: Cursor/1.0.0   accept: application/json, text/event-stream
  {"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"elicitation":{"form":{}}},"clientInfo":{"name":"Cursor","version":"1.0.0"}},"jsonrpc":"2.0","id":0}
POST /mcp   mcp-protocol-version: 2025-06-18
  {"method":"notifications/initialized","jsonrpc":"2.0"}
GET  /mcp   Accept: text/event-stream            ← opens the server→client stream
```

It negotiates **MCP 2025-11-25**, accepts the server's `2025-06-18` downgrade, advertises
`elicitation.form`, identifies as `Cursor/1.0.0` (not as the ACP client), and opens the SSE
back-channel. With an empty tool list it stopped there. With one tool advertised it went on to
`tools/list` and then, when asked, `tools/call`:

```
{"method":"tools/list","params":{},"jsonrpc":"2.0","id":1}
{"method":"tools/call","params":{"name":"probe_ping","arguments":{}},"jsonrpc":"2.0","id":2}
```

**Injected MCP tools surface as ordinary tool calls and are permission-gated**, with the server
name folded into the title:

```json
{"sessionUpdate":"tool_call","toolCallId":"call-9b55b2d9-…","title":"MCP: tool","kind":"other","status":"pending","rawInput":{}}
{"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"sessionId":"f6138263-…","toolCall":{"toolCallId":"call-9b55b2d9-…","title":"threading_probe-probe_ping: probe_ping","kind":"other","status":"pending","content":[{"type":"content","content":{"type":"text","text":"```json\n{}\n```"}}]},"options":[{"optionId":"allow-once","name":"Allow once","kind":"allow_once"},{"optionId":"allow-always","name":"Allow always","kind":"allow_always"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}}
```

Note the `tool_call` title is the useless `"MCP: tool"` while the *permission* payload has the good
one (`threading_probe-probe_ping: probe_ping`) and the arguments as a fenced JSON block. An MCP
error comes back as `rawOutput.error`, prefixed and code-preserving:

```json
{"sessionUpdate":"tool_call_update","toolCallId":"…","status":"completed","rawOutput":{"error":"MCP error -32601: Method not found"}}
```

— again `status:"completed"` for a failure. Whether wire-injected servers merge with the user's
`~/.cursor/mcp.json` was not separately measured (no disk servers were configured on this machine).

### 10.10 `session/list` is durable, global, and ordered

```json
{"jsonrpc":"2.0","id":2,"result":{"sessions":[{"sessionId":"f6138263-…","cwd":"<scratch>/projA","title":"Probe Ping Tool","updatedAt":"2026-08-12T19:08:13.126Z"},{"sessionId":"437722ed-…","cwd":"<scratch>/projB","title":"Rename Function Plan","updatedAt":"2026-08-12T19:04:34.613Z"}, … ]}}
```

Ten entries after ten turns, one per prompted session. Exactly four keys —
`sessionId`, `cwd`, `title`, `updatedAt` — **newest first**, **across all cwds** (a process running
in `projA` lists `projB`'s sessions), and **surviving process death**. It is enough for Threading's
import-outside-conversations flow: a stable id to `session/load`, a human-readable title, a project
path to match against, and a timestamp to sort by. What it does not offer is any content preview,
message count, model, or paging — and it silently omits sessions that never took a turn (§10.4).

No `usage`-, token- or context-window-shaped notification arrived in any probe: **there is no
per-turn telemetry on this protocol.** Cost and limit reporting for a Cursor session would have to
come from somewhere else entirely.

### 10.11 What is still unmeasured

- **`CURSOR_API_KEY` alone sustaining a turn — BLOCKED.** This account authenticated through the
  browser flow; no API key exists to test with, and one can only be minted from the Cursor
  dashboard. §5.3 remains the strongest evidence: the key passes the `isAuthenticated` gate. That
  it also carries a full turn is *inference*, not measurement, and gate 1 should say so.
- **Quota / rate-limit refusal shape** — never encountered in ten turns. §8's item stays open.
- **`cursor/ask_question`, `update_todos`, `task`, `generate_image`** — never fired; payloads
  unknown.
- **Disk/wire MCP merge** — no `~/.cursor/mcp.json` on this machine.
- **A second concurrent `session/prompt`** on one session, and `session/prompt` while a permission
  request is outstanding.

---

## 11. The terminal contract (measured 2026-08-12)

Measured because the launcher's exhaustive switch demands a terminal line for every runtime, and
because §10 had said nothing about the interactive CLI. Same rules as every probe above:
`BROWSER=/usr/bin/true` and `NO_OPEN_BROWSER=1` in the child environment, a wall-clock budget with
`SIGTERM` then `SIGKILL`, no `login`/`logout`/`update`, and every chat in a scratch directory.
The TUI needs a pty, so it ran under a small Python `pty.fork` harness. **Cost: one prompt turn.**

**The answer is that Cursor's two interfaces are not two views of one conversation.** They keep
separate stores and neither can read the other's identifier. That is the whole of §11, and
everything below is how it was established.

### 11.1 The command surface a terminal launch would use

`cursor-agent --help` — the globals that would matter, verbatim:

```
-p, --print                  Print responses to console (for scripts or non-interactive use).
--output-format <format>     text | json | stream-json      (only with --print)
--mode <mode>                plan | ask
--resume [chatId]            Select a session to resume     (default: false)
--continue                   Continue previous session
--model <model>              Model to use (e.g. gpt-5, sonnet-4-thinking). Parameterized models
                             accept quoted bracket overrides
--workspace <path-or-name>   Workspace directory or saved workspace name (defaults to cwd)
--trust                      Trust the current workspace without prompting
-w, --worktree [name]        Start in an isolated git worktree at ~/.cursor/worktrees/…
```

The prompt is an **operand**: `agent [options] [command] [prompt...]`, and the `agent` subcommand
repeats it. So the leading-dash hazard `sessions.md` records for Claude and Codex applies here
too, and it was confirmed rather than assumed — with a dead endpoint so no turn could start:

```
$ cursor-agent -e http://127.0.0.1:9 "- item one"
error: unknown option '- item one'

$ cursor-agent -e http://127.0.0.1:9 -- "- item one"
⚠ Workspace Trust Required …                       ← parsed as the prompt; got as far as the gate
```

`--` fixes it, exactly as `ShellCommand.append(operand:)` already emits for the other two.

### 11.2 A fresh interactive launch stops on workspace trust

The first launch in a directory Cursor has not seen draws a modal and waits for a keypress:

```
╭──────────────────────────────────────────────╮
│  ⚠ Workspace Trust Required                  │
│  Do you trust the contents of this directory?│
│    ▶ [a] Trust this workspace                │
│      [q] Quit                                │
╰──────────────────────────────────────────────╯
```

Nothing else happens until it is answered — not the prompt, not the model. `--trust` skips it and
records the answer as an empty `.workspace-trusted` file in the project's state directory. **ACP
raises no such gate**: every `session/new` in §10 ran in a scratch directory with no trust prompt
and no `--trust`.

With the gate answered, `cursor-agent --trust "Reply with exactly: ok"` ran the turn and drew the
reply. So the TUI can launch fresh with an opening prompt. What it creates is the problem.

### 11.3 The two stores, and the two identifiers that cannot cross

| Interface | Where the chat is written | Listed by ACP `session/list`? |
|---|---|---|
| `cursor-agent acp` | `~/.cursor/acp-sessions/<uuid>/{meta.json,store.db}` | yes (§10.10) |
| `cursor-agent` (TUI) | `~/.cursor/projects/<slugified-cwd>/agent-transcripts/<uuid>/<uuid>.jsonl` | **no** |

Both identifiers are UUIDv4. Neither store knows the other's.

The TUI turn above created `a0ec7d3d-…`. Immediately afterwards, `~/.cursor/acp-sessions` still
held exactly the 13 directories it had before, and ACP `session/list` returned the same 10 entries
with the new id absent. Loading it over ACP from the same cwd:

```json
{"jsonrpc":"2.0","id":3,"method":"session/load","params":{"sessionId":"a0ec7d3d-…","cwd":"<scratch>/projT","mcpServers":[]}}
{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"Invalid params","data":{"message":"Session \"a0ec7d3d-…\" not found"}}}
```

The other direction is worse, because it does not refuse. `cursor-agent --trust --resume <an ACP
session id>`, run in the very directory that session was created in, printed the ordinary empty
banner — no `Loading conversation`, no history, no error, no exit code — and sat there as a blank
chat. The positive control rules out a harness artefact: `cursor-agent --resume <a TUI chat id>`
in the same harness printed `⠀⠞ Loading conversation` and then replayed
`Reply with exactly: ok` / `ok`. (A pty *window size* must be set for either to render; the first
attempt at this measurement produced one character per line and no visible history at all.)

**So a Cursor session cannot be moved between the two surfaces.** Threading's surface switch is
defined as showing *the same conversation* another way, and here it would silently show a
different, empty one.

### 11.4 The scope this forces: Cursor is native-only

`AgentCapabilities.terminalUI` exists because of §11.3, and Cursor is the one runtime without it.
`AgentSession.resolvedNativeSurface` clamps such a session to the native surface — a correction
rather than a refusal, since the surface is Threading's own choice about how to draw a
conversation — and `AgentLauncher.plan(for:in:)` throws
`unsupportedTerminalConversation(.cursor)` rather than running a command line that would open the
wrong chat. The Original UI / Native Chat choice is not offered for Cursor.

### 11.5 The login is not in a directory

Threading routes an alternate account by pointing one environment variable at a config directory
(`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, …). Cursor has no such variable, measured against the two
candidates its own bundle names:

| Probe | Result |
|---|---|
| `CURSOR_DATA_DIR=<empty dir> cursor-agent status --format json` | `authenticated` — and the directory stayed empty |
| `XDG_CONFIG_HOME=<empty dir> cursor-agent status --format json` | `authenticated`, having written `<dir>/cursor/cli-config.json` |

So `XDG_CONFIG_HOME` moves the *settings* file and `CURSOR_DATA_DIR` the *data* root
(`projects/` resolves through it in the bundle), but the credential follows neither: it is in the
system keychain. `AgentKind.accountEnvironmentKey` is therefore `String?`, and Cursor's is `nil` —
there is no name a launch could set, and inventing one would put an inert lie in the single place
`AgentEnvironment` reads to decide what *not* to strip.

Note also what the bundle does contain: `CURSOR_CONVERSATION_ID`, `CURSOR_AGENT_CHAT_ID`,
`CURSOR_SANDBOX` — run identity of exactly the kind `AgentEnvironment.inheritedIdentityPrefixes`
exists to drop. A `CURSOR_` family is **not** added there in this change, deliberately: the same
prefix covers `CURSOR_API_KEY`, `CURSOR_AUTH_TOKEN` and `CURSOR_API_ENDPOINT`, and the current
mechanism holds one keep-exception per runtime, so adding the family today would strip the
credentials §5.3 identified as the non-browser way in. It needs a keep-*list* first.

### 11.6 The command catalog, as one account actually receives it

The 23 entries §10.2 counted, read off the wire again for the catalog policy. Cursor's builtins:

```
copy-request-id   create-hook     create-rule      create-skill    create-subagent
loop              migrate-to-skills                rename-chat     sdk
shell             split-to-prs    statusline       update-cli-config
```

The remaining ten were this account's own commands and its projects' skills, and are **not
reproduced here**: they are user data, and more to the point they prove the list is account state
rather than a protocol constant. A host policy can therefore only name builtins, and everything it
does not name must stay usable — which is how `CursorACPComposerCatalog` is written.

Four are refused in native Chat, each because its *effect* has nowhere to land here:
`copy-request-id` (clipboard from a TUI that is not running), `statusline` (configures that TUI's
status line), `update-cli-config` (edits the user's global `~/.cursor/cli-config.json`, shared
with every other Cursor client), and `loop` (installs recurring work in the session that Threading
can neither see nor stop, beside scheduled messages that it can). `rename-chat` is presented as a
session action rather than a turn; its result arrives as the ordinary `session_info_update`
Threading already routes into the protected agent-title slot.

---

## Appendix — comparative evidence (unverified against this install)

Carried over from the sibling TypeScript project **T3** (a local clone at `~/repo/t3code`; see
[`T3CODE_FINDINGS.md`](T3CODE_FINDINGS.md)), which
drives Cursor over ACP. **This is comparative material, not ground truth for this build**, and it
was recorded against a different, unnamed CLI version. Where §1–§6 measured the same thing, the
measurement wins.

| T3 claim | Status against this install (2026.08.11-e8db854) |
|---|---|
| Spawn is `cursor-agent [-e <endpoint>] acp` | **Confirmed.** Hidden subcommand; `-e` parses as a global before it. |
| Auth method id is `cursor_login` | **Confirmed** verbatim in `authMethods`. |
| Client sends `clientCapabilities._meta.parameterizedModelPicker: true` | **Confirmed, and its effect now measured** (§10.1): it strips variant parameters out of every `modelId` and swaps slugs for marketing names. The two id spaces are disjoint, so a host must pick one and stay in it. |
| Gated on CLI version date ≥ 2026-04-08 | **Not verified.** This build is 2026-08-11, comfortably past it, so the gate could not be exercised in either direction. |
| Cursor `_ext` methods: `askQuestion`, `createPlan`, `updateTodos`, `listAvailableModels` | **Partly contradicted.** The concepts exist; the wire names on this build are `cursor/ask_question`, `cursor/create_plan`, `cursor/update_todos`, `cursor/list_available_models` — plus two T3 does not mention, `cursor/task` and `cursor/generate_image`. Only `list_available_models` is agent-served; the rest are client-side. |
| Model selection is `setModel` + `setConfigOption` replay | **Confirmed in shape and on the wire** (§10.2). Both methods work; `set_config_option` additionally returns the refreshed `configOptions` array where `set_model` returns `{}`. |
| Documented at `cursor.com/docs/cli/acp#cursor-extension-methods` | Not fetched during this research; the bundle was read instead. |

The installed version may differ from whatever T3 targets, and Cursor pins exact builds in its
installer rather than shipping a floating latest — so **any of these can drift with a single
`cursor-agent update`.** Re-measure §3 and §4 against the installed build before relying on them.

---

## Reproducing this

The probe harness and every raw transcript are in the scratch directory used for this
investigation, not in the repo. The harness is ~90 lines of Python: spawn, timestamped
schedule of newline-delimited JSON-RPC writes, threaded readers on both pipes, hard kill at a
budget. Three rules made it safe to run against an auth-gated CLI, and should be kept by anything
that repeats it:

- `BROWSER=/usr/bin/true` and `NO_OPEN_BROWSER=1` in the child environment, always.
- A wall-clock budget with `terminate()` then `kill()`, so no probe can outlive the run.
- Never `cursor-agent login`, `logout` or `update` from a probe. §10 was recorded against a login
  the *user* performed; the harness never touched credentials and never printed a token.

The §10 pass added three rules of its own, and they are the ones that keep an authenticated
re-run cheap and safe:

- **Every session and prompt runs in a scratch directory**, never the repository — Cursor writes
  files, runs shell commands and rebinds cwd on load.
- **Budget the account.** Ten trivial prompts covered the whole of §8; prompts were one sentence
  each ("Reply with exactly: ok") because the object of study is the wire, not the answer.
- **Restore anything the probe persisted.** `allow_always` writes a global rule into
  `~/.cursor/cli-config.json`; that entry was removed afterwards, and the file is otherwise
  untouched.

To repeat §10, the harness needs one addition over the §3 version: **auto-responders for
agent→client requests**, keyed by method, so `session/request_permission` can be answered by
option *kind* and `cursor/*` can be answered — or deliberately refused with `-32601` — to measure
degradation. A trigger that fires a `session/cancel` notification N seconds after the first
matching `session/update` line is what measures cancellation.
