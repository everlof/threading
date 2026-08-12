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

**No login was performed.** The machine has no Cursor account, and none was created. That bounds
this document: the handshake, the routing table, the refusal shapes, and the session-identity
mechanism are measured; the streaming turn is not.

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
rm -rf ~/.cursor/projects
```

The last two lines are the state the CLI wrote during these probes (§6); `~/.cursor/argv.json`
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
"BLOCKED-ON-AUTH" means the method is registered and reachable and stopped on credentials — per
§5.3, a valid `CURSOR_API_KEY` is expected to clear every one of them.

| What the app needs | Verdict | Evidence |
|---|---|---|
| Spawn + stdio JSON-RPC | **MEASURED** | `cursor-agent acp`; hidden subcommand, `--help` confirms "ACP (Agent Client Protocol) server" |
| Custom endpoint | **MEASURED** | `cursor-agent -e <url> acp` handshakes normally |
| `initialize` + version negotiation | **MEASURED** | response in 0.64 s; `protocolVersion: 1`; `99` negotiates down to `1` |
| Auth-method discovery | **MEASURED** | `authMethods:[{id:"cursor_login", …}]` |
| Non-browser credentials | **MEASURED** | `--api-key`/`--auth-token`/`CURSOR_API_KEY`/`CURSOR_AUTH_TOKEN`; gate provably passed in §5.3 |
| `session/new` (+cwd, mcpServers) | **BLOCKED-ON-AUTH** | `-32000`; params validated as `cwd:string`, `mcpServers:array` |
| Session id durability | **MEASURED (static)** | `crypto.randomUUID()`; same id replayed to `loadSession` as `resumeChatId` |
| `session/load` — resume | **BLOCKED-ON-AUTH**, structurally confirmed | `loadSession:true` advertised; body maps id → `resumeChatId` |
| `session/list` — enumeration | **BLOCKED-ON-AUTH** | `sessionCapabilities:{list:{}}`; `-32000`, so implemented |
| `session/prompt` — streaming turn | **BLOCKED-ON-AUTH** | reached handler: `-32603 "Session s-probe not found"` |
| `session/update` stream kinds | **BLOCKED-ON-AUTH**, vocabulary present (static) | bundle carries `agent_message_chunk`, `agent_thought_chunk`, `user_message_chunk`, `tool_call`, `tool_call_update`, `plan`, `available_commands_update`, `current_mode_update` |
| Tool calls + updates | **BLOCKED-ON-AUTH**, vocabulary present (static) | as above |
| Permissions with option kinds | **BLOCKED-ON-AUTH**, vocabulary present (static) | `session/request_permission` is agent→client (`-32601` on the agent, as expected); all four kinds present: `allow_once`, `allow_always`, `reject_once`, `reject_always` |
| Cancellation | **MEASURED** as a notification; settling **BLOCKED-ON-AUTH** | request form `-32601`; notification form accepted silently; `stopReason` vocabulary in bundle incl. `cancelled`, `end_turn`, `max_tokens`, `max_turn_requests`, `refusal` |
| MCP injection over the wire | **BLOCKED-ON-AUTH**; transports **MEASURED** | `mcpCapabilities:{http:true,sse:true}`; `mcpServers` required in `session/new` |
| MCP from disk | **MEASURED** | `mcp list` names `.cursor/mcp.json`, `~/.cursor/mcp.json` |
| cwd handling | **MEASURED** | required string, `resolve`d; per-project dir `~/.cursor/projects/<slug>-<hash>/` created |
| Model discovery | **BLOCKED-ON-AUTH** | `cursor/list_available_models` → `-32000`; `session/new` result also carries `models` + `configOptions` (static) |
| Model selection | **BLOCKED-ON-AUTH**, wiring confirmed (static) | `session/set_model` → `setSessionConfigOption(configId:"model")`; `session/set_config_option` registered |
| Parameterized model picker | **MEASURED** (flag is read) | `clientCapabilities._meta.parameterizedModelPicker` → `getModelPickerMode()`; build 2026-08-11 |
| Modes (plan / ask / agent) | **BLOCKED-ON-AUTH**, registered | `session/set_mode` reached handler; `buildModesState` in `session/new` result |
| Image prompts | **MEASURED** (advertised) | `promptCapabilities.image: true` |
| Embedded context blocks | **ABSENT** | `promptCapabilities.embeddedContext: false` |
| Audio prompts | **ABSENT** | `promptCapabilities.audio: false` |
| `session/fork` | **ABSENT** | `-32601` — ACP library supports it, Cursor does not implement `unstable_forkSession` |
| `session/resume` (distinct from load) | **ABSENT** | `-32601` — `unstable_resumeSession` not implemented; resume is `session/load` only |
| Cursor plan / todo / question UX | **ABSENT unless the client implements it** | `cursor/create_plan`, `cursor/update_todos`, `cursor/ask_question`, `cursor/task`, `cursor/generate_image` are **client-side**: `-32601` on the agent |
| Scriptable session list off-protocol | **ABSENT** | `cursor-agent ls` is an Ink TUI, fails without a TTY |
| Framing-error detection | **ABSENT** | garbage and truncated JSON produce *no* response and no stderr |

### The sharp edges

1. **Session methods are all-or-nothing behind auth** — but the API-key path (§5.3) means this is
   a configuration problem, not a protocol wall.
2. **`authenticate` will open the user's browser.** Any spawn must neutralise `BROWSER` first,
   and the login URL is only recoverable by substring-matching an `-32602` error message.
3. **Silent framing failures.** No stderr, ever; malformed input vanishes. Client-side timeouts
   are mandatory.
4. **`error.data` is polymorphic** — object with `message`, or a raw Zod issue *array*.
5. **Five `cursor/*` methods are the client's job.** Ignoring them costs Cursor's planning,
   todo and question surfaces; supporting them is net-new UI.
6. **No fork.** Threading's side-chat/fork capability has no Cursor equivalent — `session/fork`
   is not implemented.
7. **No embedded context**, so workspace file mentions cannot be inlined as resource blocks.
8. **Resume is cwd-scoped**, because chat state lives under a per-project directory.

---

## 8. What authenticated measurement must still cover

Every item here needs a Cursor account or a valid `CURSOR_API_KEY`. None of it is inferable from
what is above.

- [ ] `session/new` success: full result shape — `sessionId`, `modes`, `models`, `configOptions`
      — and whether `models` differs with `parameterizedModelPicker` on vs. off.
- [ ] `session/prompt`: the actual `session/update` sequence, chunk granularity, whether
      `agent_thought_chunk` is emitted, and the terminal `stopReason` for a clean turn.
- [ ] `session/cancel` mid-turn: how long it takes to settle, and that the in-flight
      `session/prompt` resolves with `stopReason: "cancelled"` rather than erroring or hanging.
- [ ] `session/request_permission`: real payload, which `optionId`s arrive, and whether
      `allow_always` persists into `~/.cursor/cli-config.json`'s `permissions`/`approvalMode`.
- [ ] Tool-call fidelity: `tool_call` / `tool_call_update` content, diffs, and whether they carry
      enough to render Threading's tool rows.
- [ ] **Durability across processes**: create a session in process A, record the id, kill A,
      `session/load` the same id in process B, and confirm history replays.
- [ ] Whether `session/load` replays prior turns as `session/update` events (ACP's contract) or
      returns silently.
- [ ] Same id from a *different* cwd — does the per-project directory make resume fail?
- [ ] MCP injection: pass a real `mcpServers` entry, confirm tools appear, and see whether disk
      config merges with wire config.
- [ ] `cursor/ask_question` / `create_plan` / `update_todos` / `task` / `generate_image`: real
      payloads and what a client must answer.
- [ ] `available_commands_update`: the slash-command list Cursor pushes after `session/new`.
- [ ] `session/set_mode` against real mode ids, and `session/set_model` round-tripping.
- [ ] Whether `CURSOR_API_KEY` alone (no `agent login`) sustains a full turn, or degrades.
- [ ] Rate-limit / quota refusal shape, for `limit-recovery.md` parity.
- [ ] `session/list` result shape — enough for Threading's import-outside-conversations flow?

---

## 9. Decision — deferred, with the gates named

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
2. **Wire confirmation of the two vocabularies the shared runtime assumes.** The bundle carries
   the underscored option kinds (`allow_once`, …) and the standard stop reasons (`cancelled`,
   `refusal`) — if the wire agrees, the core needs no change; if it deviates, that is the profile
   member the core's comment already reserves.
3. **A product decision on the five client-side `cursor/*` methods.** Measure what degrades when
   they are unregistered; if `ask_question` turns out to be part of an ordinary turn, Cursor needs
   a question surface in Threading before it can ship, not after.
4. **Honest capability rows, written from this table**: no `.forking` (`session/fork` is absent),
   resume via `session/load` only and cwd-scoped, no permission-mode surface until Cursor's
   plan/ask/agent modes are measured against Threading's six-mode vocabulary (they are a different
   axis), no embedded-context claims (`embeddedContext: false`).
5. **A bounded-response hardening decision for `ACPStreamSession`** — Cursor swallows malformed
   input with no response and no stderr, so a client-side timeout is the only detector of a
   framing desync. That hardening is provider-neutral and should land as core work with its own
   transport test, not as a Cursor conditional.

Re-run §3–§4 before acting on any of this if `cursor-agent update` has moved the pinned build.

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
| Client sends `clientCapabilities._meta.parameterizedModelPicker: true` | **Confirmed as read** by `clientSupportsParameterizedModelPicker()`; effect not observable unauthenticated. |
| Gated on CLI version date ≥ 2026-04-08 | **Not verified.** This build is 2026-08-11, comfortably past it, so the gate could not be exercised in either direction. |
| Cursor `_ext` methods: `askQuestion`, `createPlan`, `updateTodos`, `listAvailableModels` | **Partly contradicted.** The concepts exist; the wire names on this build are `cursor/ask_question`, `cursor/create_plan`, `cursor/update_todos`, `cursor/list_available_models` — plus two T3 does not mention, `cursor/task` and `cursor/generate_image`. Only `list_available_models` is agent-served; the rest are client-side. |
| Model selection is `setModel` + `setConfigOption` replay | **Confirmed in shape.** `session/set_model` delegates to `session/set_config_option` with `configId:"model"`. The "replay" half is unverified. |
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
- Never `cursor-agent login`.
