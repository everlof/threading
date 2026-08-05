# Execution Audit

The factual, provider-neutral ledger of what an agent asked a tool to do and what came back.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

Execution Audit is deliberately not another conversation renderer. It records structured execution
events, permission decisions and Threading MCP calls, then shows those values without an AI summary.
Prompts, reasoning, assistant prose, text deltas and transcript replay are outside the boundary.
This is what makes the surface useful as evidence rather than as another interpretation of a run.

## Capture boundaries

Provider-native adapters run before `StreamEvent` presentation normalization:

| Runtime | Native observation | Preserved value |
|---|---|---|
| Claude Chat | `--input-format stream-json` assistant `tool_use` and user `tool_result` blocks | Original tool name/id and decoded `input`/`content` JSON |
| Codex Chat | App Server `item/started` and terminal `item/completed` notifications | The complete decoded notification `params`, including thread, turn and native item fields |
| Grok Chat | ACP `tool_call` and `tool_call_update` session updates | The complete decoded update; intermediate updates remain separate **Updated** records |
| Threading MCP | JSON-RPC `tools/call` immediately before dispatch and the encoded result immediately after it | Raw decoded `params.arguments`, request id, and result/error object |
| Permission broker | Request immediately before the sheet and its returned decision | Tool/input followed by allow or deny reason |

Codex observes supported execution item types on both the root thread and delegated child threads:
commands, file changes, MCP and dynamic tool calls, web searches, image views, collaboration calls and
plans. Claude capture happens before the subagent routing seam for the same reason. Categories are a
deterministic projection of the native operation; they are filters, not a replacement for the native
payload.

A Threading tool can legitimately appear twice. A provider-stream record proves that the provider
requested it; a Threading-MCP record proves that Threading received and executed it. Keeping both is
more useful than collapsing the handoff. The Source chips isolate either side.

Grok Terminal and OpenCode do not expose a structured execution feed through their current terminal
integration, and OpenCode is not registered with Threading's MCP server. Execution Audit therefore
does not guess actions from terminal text. Those surfaces show only independently observed
Threading-owned events if one exists. A blank ledger is more honest than a reconstructed one.

The wire contracts behind these choices are documented by the providers: OpenAI's App Server uses
bidirectional JSON-RPC/JSONL and distinguishes started/delta/completed notifications
([Unlocking the Codex harness](https://openai.com/index/unlocking-the-codex-harness/)); Claude exposes
structured tool lifecycle hooks and stream events ([Claude Code hooks](https://code.claude.com/docs/en/hooks));
and Grok's integration follows ACP's versioned `session/update` schema
([ACP schema](https://agentclientprotocol.com/protocol/v1/schema)). The implementation still tests
the exact envelopes Threading consumes instead of treating documentation as a parser test.

## Record and fidelity

Each JSONL record has a session id, monotonic sequence, timestamp, source, provider, category, phase,
operation, optional native call id, exact input/output values, duration when a request can be paired,
fidelity, explicit redaction paths, the previous digest and its own digest.

- **Exact** means the decoded native JSON value is retained. JSON object key order is made stable on
  disk, but no semantic fields are renamed or summarized inside `input` or `output`.
- **Exact · redacted** means the native shape is retained with specific values replaced. Every
  replacement is listed by JSON path and reason in `redactions`.
- **Canonicalized** exists for an explicitly projected source that cannot provide a native value. It
  must never be used to make a normalized provider tool row look exact.

Requested and terminal records correlate by source and call id. Intermediate ACP updates do not
consume that pending call, so the terminal result still receives a duration and the original
operation/category even if its own update is sparse.

## Privacy and integrity

The ledger can contain source code, command output, URLs and page-derived tool results. It is local,
not harmless. Ordinary `browser_type` text and `browser_fill_form` values are retained because they
are part of the exact tool call. Deterministically credential-shaped keys (passwords, tokens,
authorization/cookie fields and payment verification codes) are replaced, as are image bytes; each
replacement becomes a labelled placeholder with an explicit path and reason. Password values are
already unavailable to browser tools, but the storage boundary does not rely on that upstream fact.

`browser_fill_credentials` is the one tool whose *arguments* are safe by construction rather than
by redaction: it accepts no origin, username or password, only an optional user-authored account
name and a target. Its result is a fresh page snapshot, which reaches the ledger after
`BrowserViewController.scrubFilledSecrets` has removed the filled value — see
[`agent-browser.md`](agent-browser.md) for why that scrub exists and what it cannot reach. The
browser trace records that a credential fill happened and the structural target kind, and
deliberately not which account: it already omits locator names and field values, and an account
name is the user's own words about an account.

Files live under `~/Library/Application Support/Threading/ExecutionAudit/` with a `0700` directory
and `0600` files. Each session is append-only JSONL, capped to a current 4 MiB segment plus three
rotated segments. Records are SHA-256 linked. Verification distinguishes a complete chain from a
verified retained suffix after rotation and from malformed or altered data. This is tamper-evident,
not tamper-proof: an attacker able to rewrite the whole directory can recompute the chain.

Deleting a session or project deletes its current and rotated audit files synchronously before the
model disappears. Reset Everything moves the whole Application Support directory aside under the
existing recoverable reset policy. Provider transcripts remain provider-owned and are unaffected.

## Surface

**Execution Audit** is a normal persistent display-panel tab. Its newest-first list filters by
category and source and searches the visible factual fields. Selecting a row opens its complete
record JSON beside the list, including integrity, fidelity and redaction status.

**Browser split** switches the inspector to a vertical audit/browser workspace, pins the audit to
Browser events and embeds the session's real `BrowserViewController`. It is not a screenshot or a
second browser: routing still targets that live session browser, so actions and page changes can be
reviewed together. The mode and browser URL survive panel restoration.

Rendered tests cover the inspector and browser split at 2560×1520 in System, Cyberpunk and Swiss,
each in light and dark appearance. The browser fixture is loaded into WebKit and captured only after
`takeSnapshot` succeeds; a blank placeholder is not visual verification.
