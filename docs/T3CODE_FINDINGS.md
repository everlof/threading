# t3code — Competitive Findings

Researched 2026-07-25 against a clone of https://github.com/pingdotgg/t3code at commit
`5719e8a` (v0.0.28, Jul 24 2026), plus an OSINT sweep of their issue tracker, Hacker News,
and press. File paths below are relative to their repo root. t3code is MIT and its landing
page says "Steal our code (legally)" — everything here is ideas and measurements, but the
codebase itself is TypeScript/React/Electron, so nothing ports literally to AppKit.

Skalman has borrowed from t3code twice before this pass (the `MessagesTimeline` minimap and
its logic/view split — both credited in CLAUDE.md). This document is the third mining trip.

---

## 1. What it is

**"The open-source control plane for coding agents."** Created 2026-02-08; 14,776 stars,
3,245 forks, 753 open issues as of research date. Alpha, contributions closed, nightly
releases several times a day. Growth came from Theo's YouTube/X audience, not HN (launch
threads got 6, 4, 2 and 1 points).

Structurally the opposite of Skalman: a Node **server** (`t3` on npm, `npx t3code`) is the
only execution boundary, with five thin clients over it:

| Piece | Path | Role |
|---|---|---|
| server (`t3`) | `apps/server` | Providers, orchestration, git/VCS, PTY terminals, SQLite, MCP, auth, port scanning. The whole product. |
| web | `apps/web` | React 19 SPA — the entire UI (602 TS/TSX files). Served locally, loaded by Electron, also hosted static at app.t3.codes. |
| desktop | `apps/desktop` | Electron 41 shell: supervises a local `t3`, adds browser preview, SSH/WSL/Tailscale, auto-update, native menus. |
| mobile | `apps/mobile` | Expo/React Native, unshipped. Threads, native terminal, review, push + iOS Live Activities, widgets. |
| relay | `infra/relay` | Cloudflare Worker + PlanetScale + Clerk: the hosted "T3 Connect" tunnel + APNs push pipeline. |

**Providers** (five drivers, `apps/server/src/provider/builtInDrivers.ts`): Codex via
`codex app-server` JSON-RPC; **Claude via the Agent SDK in-process** (`query()`,
`canUseTool`, hooks — `Layers/ClaudeAdapter.ts` is 3,948 lines); Cursor and Grok via ACP;
OpenCode via its SDK against a spawned `opencode serve`. All normalized into one canonical
~46-event `ProviderRuntimeEvent` union (`packages/contracts/src/providerRuntime.ts`) with a
written doctrine forbidding `if provider === "codex"` in shared code — the same idea as
Skalman's `ToolIdentity` / `TranscriptReplay.normalised`, at larger scale. **Provider
*instances*, not kinds**: "Codex Work" and "Codex Personal" side by side with separate
homes, env vars, model lists, accent colors.

**Persistence** is a real event store, not aspirational: append-only `orchestration_events`
(global sequence, stream version, command idempotency) + projection tables rebuilt by a pure
decider/projector split; 34 migrations (`apps/server/src/persistence/`). Thin rows + JSON
payloads — the same opencode-derived shape as Skalman's `skalman.db`.

**Multi-device is not cloud sync.** Sessions live in SQLite on the machine running `t3`;
other devices connect to that server (QR pairing, Tailscale, SSH, or the optional hosted
relay). The hosted app at app.t3.codes is a static page that talks to *your* backend. One HN
commenter's framing of why this matters: "The computer I'm working on is not the computer
where the AI has agency" — remote access as a *safety* posture.

**Their distinctive category we don't play in:** an embedded browser preview with
DOM-element picking (click an element → component name + file:line + styles attached to the
prompt) and agent-driven browser automation over MCP (`preview_click`, `preview_snapshot`,
…) backed by Playwright inside Electron.

---

## 2. Feature inventory

Everything with evidence in the code, grouped. (★ = detailed mechanics in §3.)

**Sidebar / threads** — Sidebar V2 inbox model ★; thread snoozing ★; auto-settling ★;
archive + archived view; multi-select with bulk actions; status indicators (working timer,
pending-approval/input badges, terminal-process dot); thread search; AI-generated thread
titles; jump hints (⌘1–9); per-project favicons; project grouping by repository /
repository-path / separate.

**Command palette** (`mod+k`, 2,094 lines) — actions, recents, project switcher, directory
browser with path autocomplete, clone-from-URL (GitHub/GitLab/Bitbucket/Azure), publish
local repo. **User-configurable keybindings** from `~/.t3/keybindings.json` with a `when`
expression language (`terminalFocus && !previewOpen`).

**Conversation** — virtualized timeline with turn folds ★, work-group collapsing ★,
minimap with hover preview ★, three-mode auto-scroll ★, per-turn changed-files card ★,
long-user-message collapse ★, revert-to-this-message, copy-per-message, self-ticking
duration labels ★, context-window donut meter (red > 90%). No reasoning-block UI (thinking
is a one-line row); no per-turn token/cost display; no subagent threads (a hammer icon).

**Composer** (~2,500 lines + Lexical editor) — `@` file mentions (fuzzy), `/` slash
commands (line-start only; `/plan`, `/default` parsed as mode switches), `$` Claude skills
picker; image attachments (max 8 × 10 MB); banner stack (branch mismatch, version skew,
provider status); context chips: terminal output, picked DOM element, preview annotations,
review comments ★; per-thread draft persistence + standalone draft routes; queueing is
absent but **steering** works (Enter during a running turn adds a user message to it).

**Runtime modes / approvals** ★ — four modes: Supervised / Auto-accept edits / Auto ("an
AI reviewer approves routine actions") / Full access; orthogonal Build ⇄ Plan toggle
(Shift+Tab); approvals render *in the composer* with Cancel turn / Decline / Always allow
this session / Approve once; structured multi-question user-input wizard with number-key
shortcuts and 200 ms auto-advance.

**Checkpoints** — a hidden git ref captured per turn (`apps/server/src/checkpointing/`);
powers revert-to-any-user-message (provider history rewinds too via `rollbackThread`) and
per-turn diff ranges.

**Diff / review** ★ — four scopes (Working tree / Branch / Latest turn / Turn N); Pierre
diff renderer themed via `color-mix` ladders; split/unified, word wrap, ignore whitespace,
collapse-all; auto-collapse of large diffs; **inline comments on diff lines that round-trip
into the composer** ★; no staging at all; refresh is 5 s stale-time polling, no watcher.

**Git / PRs** — branch toolbar (Local vs New worktree, locked after first message);
worktree-per-thread with setup scripts (`runOnWorktreeCreate`); **one adaptive button**:
Commit → Commit & push → Commit, push & PR → View PR, with named progress stages and
AI-generated commit messages / PR bodies (policy presets incl. conventional commits); PR
state (open/merged/closed) as a thread badge, colored on hover; checkout-a-PR-into-a-thread;
four forges (GitHub `gh`, GitLab `glab`, Bitbucket, Azure DevOps) behind provider-neutral
"change request" vocabulary; background `git fetch` every 30 s; a `VcsDriver` abstraction
designed for Jujutsu/Sapling ("a Jujutsu driver does not have to pretend to be Git").

**Terminal** — xterm.js PTYs per thread: split, reattach with buffer replay, drag output
into the composer as context.

**Files** — browser + editable preview; workspace fuzzy search index; open-in-editor
matrix covering VS Code/Cursor/Zed/JetBrains suite.

**Project scripts** — `t3.json` per repo: named scripts with icons, `previewUrl`,
worktree-create hooks; each script gets a keybinding.

**Notifications** — an agent-awareness state machine feeding mobile push + Live Activities
via the relay; in-app toasts; provider-CLI update prompts. **No native OS notifications on
desktop** despite a 42-vote issue.

**Settings** — providers (schema-generated forms, secret env vars), connections/pairing,
source control, keybindings editor, diagnostics (incl. process resource history), beta
flags, `glassOpacity` for the "glass" design language.

---

## 3. Implementation deep-dive (the mechanics worth studying)

### 3.1 Turn folding — "Worked for 42s"

`apps/web/src/components/chat/MessagesTimeline.logic.ts` (`deriveTurnFolds`). Once a turn
settles, everything except the **final** assistant message collapses behind a one-line fold.

- Never folds: the running turn, a turn with a streaming message, or (crucially) the
  previous turn during the window right after a send, before the server has created the new
  turn — "folding must not flicker through that window."
- **An interrupted turn stays expanded** ("so the user keeps their place; the next turn
  folds it") and labels itself "You stopped after 42s".
- Duration is measured from the **user message** that started the turn, not the first
  provider entry — entry timestamps undercount (nothing appears until the provider starts
  emitting).
- Duration format ladder: `347ms` → `4.2s` (9.95 s rounds to `10s`, never `10.0s`) →
  `37s` → `3m 12s`.

This is the finished form of a problem CLAUDE.md already names: "twenty filled slabs read as
the conversation's content." Skalman quieted the tool rows; t3code folds the settled turn.

### 3.2 Auto-scroll — a three-mode state machine

`apps/web/src/components/chat/timelineScrollAnchoring.ts`. Modes:

- **`following-end`** — pin to bottom, but only when real content actually overflows
  (reserved anchor blank space doesn't count as content).
- **`anchoring-new-turn`** — entered on every send: the sent user message anchors 16 px
  from the top with blank space reserved below, and the response streams into that space.
  Data changes reveal the growing tail without yanking the anchor.
- **`free-scrolling`** — entered **only by real gestures**: raw `wheel`/`touchmove`/
  `pointerdown` listeners bump a monotonic generation counter; live-follow is on iff the
  counters match. Programmatic scrolls can therefore never break the pin — the failure mode
  behind their own auto-scroll bug (#3925).

Details: near-end tolerance rather than exact bottom; the "Scroll to end" pill is debounced
150 ms to *show* but hides instantly; anchor placement retries up to 12 rAF frames with a
750 ms fallback, then kills momentum by re-pinning; a ≤ 2 px jitter guard restores offset
after layout thrash.

### 3.3 Tool rows

- **Grouping**: consecutive tool entries merge into a work group; only the **last** is
  visible (`MAX_VISIBLE_WORK_LOG_ENTRIES = 1`) behind "+N previous tool calls". Expanding
  uses flushSync + measured-delta **scroll compensation** so history opening above you
  doesn't move what you're reading. Expansion is modeled as *list data* (rows inserted into
  the array), not component state, so the virtualizer's bookkeeping stays true.
- **Lifecycle collapsing**: started/updated×N/completed for one `toolCallId` merge into one
  row that mutates in place, before the timeline ever sees them.
- **Status glyphs**: ✓ / ✗ / − per row. Providers lie about status, so failure is detected
  by **sniffing output text**: `ENOENT`, "command not found", "no such file or directory",
  `/exit(?:ed)? with exit code\s+[1-9]/i`, PowerShell's cmdlet errors, etc. A "neutral" dash
  is promoted to ✓ once the turn settles — ambiguity is temporary, not permanent.
- **Icons**: a priority cascade (approval kind → item type → has-command → tone), with
  `runtime.warning` overriding to a destructive ✗.

### 3.4 Per-turn changed-files card

Each assistant turn ends with a summary card (`ChangedFilesTree.tsx`,
`changedFilesPresentation.ts`):

- Auto-expands only when it is the **latest** turn AND ≤ 5 files AND ≤ 200 changed lines;
  computed once, user toggles persist per (thread, turn).
- Otherwise a compact preview: a scope line ("web 4 files · server 2 files", top-4 scopes)
  plus up to 3 file chips chosen one-per-scope first.
- The tree does single-child directory compression and rolls ±stats up ancestors; the
  header is sticky only while expanded.

### 3.5 Long user messages

Collapse past 8 lines / 600 chars behind a real CSS gradient mask (not an overlay), with
"Show full message" and a copy button that works while collapsed.

### 3.6 Sidebar V2 — the inbox model

`apps/web/src/components/SidebarV2.tsx` + `packages/client-runtime/src/state/threadSettled.ts`.

- **No project groups in the list** — project is a *filter* dropdown. Three sections:
  Active (cards) → Snoozed shelf → Settled shelf (slim rows, dimmed grayscale favicons
  restored on hover).
- **Static sort**: creation order, newest first; "activity NEVER reorders the list — a row
  holds its position from open until settled." Settled rows sort by when work *ended*, and
  the label uses the same function "so label and order can't disagree."
- **Five states, three colors**: approval (amber) / input (indigo) / working (sky) /
  failed (red) / ready (unlabeled). **The recede rule**: working rows recede *with*
  read-ready ones ("inbox-zero: working threads aren't your problem yet"); prominence is
  reserved for done-unread ✓, woke ⏰, and failed.
- **Settling** is a pure derivation, evaluated in order: blockers first (pending
  approval/input/running never settle, even explicitly); a 2-minute queued-turn grace
  window (two-sided `Math.abs` clock-skew check); explicit settle/pin override; **PR
  merged/closed auto-settles only after 1 h idle** (otherwise the permanent merge signal
  snaps a revived thread straight back); inactivity auto-settle after N days (default 3,
  range 1–90). Settled ≠ archived.
- **Snoozing** is an overlay on active, never touches the agent. Presets skew short on
  purpose — "agent-thread rhythms are hours, not days": In 1 hour / This evening (18:00,
  suppressed if < 1 h away) / Tomorrow 09:00 / Next Monday 09:00; day math via `setDate`
  for DST. **Early wake = "raising a hand"**: pending approval/input, a *fresh* failure
  (`session.updatedAt > snoozedAt` — a thread snoozed while already failed stays snoozed),
  or a turn completing after snooze. Timer wakes are derived, no server event. Snooze
  outranks settled. Wake timer re-arms at the earliest wake + 50 ms, clamped to signed
  32-bit (an overflowing `setTimeout` fires immediately → tight loop).
- **Parking navigation**: settling/snoozing the open thread moves you forward to the next
  non-parked row (plan snapshotted before the mutation, re-validated after the await so an
  in-flight command can't yank the user elsewhere). Settle is silent; snooze always toasts
  with Undo ("the toast is the only confirmation").
- Rows are keyed per variant (`threadKey:rowVariant`) so a settling card cross-fades in
  place instead of FLIP-sliding through the list. The routed thread is *always* rendered,
  even inside collapsed shelves.

### 3.7 Diff panel

- Scopes: Working tree / Branch (base-ref picker with local+remote merge and a "use remote
  version" switch) / Latest turn / Turn N submenu. Turn diffs are checkpoint ranges, not
  refs. Selection persists per thread.
- **Scope-keyed ephemeral state**: collapse state stores `{scopeKey, fileKeys}`; a
  mismatched scope key reads as empty — stale state is invisible, no cleanup effects.
- Third-party renderer themed by generating CSS `color-mix` ladders from the app's design
  tokens (92/88/85/80% mixes for addition/deletion backgrounds) — a diff renderer that
  inherits the host theme exactly.
- **Diff comments → composer round trip**: select lines → inline comment draft → chip in
  the composer → serialized as a `<review_comment filePath= rangeLabel=>` XML block with
  the captured hunk → re-rendered as a card in the transcript → re-anchored back into the
  diff by flat line index on re-parse. The same machinery serves plain-file comments.
- No staging. Refresh is polling (5 s stale time), no FS watcher — Skalman's
  `GitCheckoutWatcher` + `--no-optional-locks` design is ahead here.

### 3.8 Minimap (current state vs what Skalman took)

Still one mark per user turn, evenly spaced (8 px; Skalman deliberately chose 20), fisheye
taper by distance from the hovered mark, hidden when the gutter < 48 px, never rendered on
touch. New since the original borrow: a **hover preview card** showing the question plus
the turn's final assistant reply (Skalman's `ConversationTurnPreview` already does this),
selectable text in the preview (events targeting it don't jump), and in-view highlighting
written **directly to DOM nodes** from the scroll handler — zero React commits per frame
(spiritually what AppKit drawing does anyway). No marker kinds for errors/permissions, no
section labels. Nothing to chase.

### 3.9 Perf patterns

Self-ticking labels write `textContent` directly on a 1 s interval so elapsed-time display
creates no React commit while streaming; per-row structural sharing returns the previous
array identity when nothing changed; `content-visibility: auto` on every sidebar row.

---

## 4. OSINT — public feedback

### Praise (consistent across sources)
- Free + MIT + bring-your-own-subscription; resells no tokens.
- The review-before-it-lands workflow: per-turn diffs, approval gates, worktree isolation,
  one-click commit-push-PR.
- Easiest onboarding in the category (`npx t3code`, ~2 min).
- Responsive UI despite Electron; Linux from day one.
- The remote split as a safety posture (HN: "the computer I'm working on is not the
  computer where the AI has agency").
- Theo's own comparison: "T3 Code works better with Codex and has better performance;
  **Conductor has better UX, especially around worktrees**; T3 Code is open-source."

### Complaints (top pain, by heat)
1. **Telemetry trust burn** (#1397): PostHog on by default, persistent pseudonymous ID,
   opt-out only via an undocumented env var; maintainer refused to soften it ("crucial for
   us to know how many users we have"); alleged unsalted hashed account IDs cross-linking
   devices; GDPR thread.
2. **The wrapper tax** (#695, open): same read-only task — Codex CLI ~4m35s vs t3code
   15–20+ min. Users benchmark any harness against the raw CLI.
3. **Idle resource burn** (#3143): 136× the idle power of comparable Electron apps;
   attributed partly to detached Codex subprocesses.
4. **Session-layer reliability**: context silently lost after idle (#2256) and on restart
   (#2140); threads stuck "working…" forever (#2644, #1048); unstoppable threads (#2234).
5. **The server/connection layer is the top bug generator**: pairing failures, remote auth
   failures, OAuth verification failures, broken upgrades, CLI discovery failures.
6. **Fidelity gaps vs the CLIs**: skills/CLAUDE.md not loaded (fixed), no raw tool output
   view (#216), auto-scroll fighting the reader (#3925), wrong context-window math (#2034).

### Most-requested features (by +1 votes)
Dominant theme: **provider breadth** — Pi (#402, 133), Copilot CLI (#193, 118), WSL
(#192, 122, shipped), OpenCode (#539, 109, shipped), Gemini (shipped), ACP layer (#315).
Then:
- Steer/queue follow-ups while working — #231, **47**
- Notifications for completed/approval-needed turns — #780, **42** (still unbuilt)
- Slash commands / skills in the composer — #2491, 33 (shipped)
- **Usage/quota visibility per account — #228, 27** → validates Skalman's usage pill
- Subagents as nested threads — #538, 25
- Themes — #418, 22
- **Import existing CLI sessions — #330, 20** → validates SessionImporter
- **Conversation branching/fork — #1404, 19** → validates side chats
- GitLab/Forgejo, devcontainers, multi-repo projects, message editing, Linux packaging.

### Strategic observations
- Distribution was creator-audience, not organic HN; 14.8k stars in five months.
- Monetization confusion even for a free tool — Theo had to publicly restate "we CAN NOT
  MAKE MONEY ON T3 CODE RN" and rework the landing page (see docs/OPEN_SOURCE.md).
- **Platform risk hit them directly**: Anthropic's (paused) move to meter third-party
  harnesses would have cut subscription usage "by 25×" in Theo's words. Any harness on
  `claude -p` economics shares this exposure — Skalman's CLAUDE.md already records the
  same June 2026 pause.
- Their conceded weaknesses map to openings: worktree UX, session durability, quota
  visibility, notification hygiene, reading ergonomics.

---

## 5. What this validates in Skalman

| Skalman feature | Their state | Evidence |
|---|---|---|
| Usage pill (`AccountUsageItemView`) | Requested, 27 votes; event plumbing exists, no UI | #228, #673, #880 |
| `SessionImporter` | Requested, 20 votes | #330, #207, #2206 |
| Side chats / `--fork-session` | Requested, 19 votes | #1404 |
| Git Review staging (`GitIndexWriter`) | **Absent entirely** — no stage/unstage UI | DiffPanel.tsx |
| FS-watched review (`GitCheckoutWatcher`) | Polling, 5 s stale time | client-runtime/state/review.ts |
| PTY-hosted real CLI (zero overhead) | 3–5× task-time overhead vs raw CLI | #695 |
| Local, no account, no telemetry | Default-on PostHog, trust wound | #1397 |
| Transcript-file grounding | Context loss is their top bug class | #2256, #2140 |

## 6. Lessons — what not to do

1. **Never default-on telemetry.** State the no-bytes-leave-the-machine posture loudly and
   user-facing (only opt-in avatar probes leave Skalman's machine).
2. **The wrapper is judged against the raw CLI's speed.** Keep the native surface at zero
   overhead; being free doesn't excuse a tax.
3. **Session durability is the product.** Their own design docs warn "resumeCursor must
   never be synthesized" — the class of bug transcript-file grounding avoids.
4. **The connection/server layer generated most of their bugs** — don't rush multi-device.
5. **God components** (ChatView.tsx is 6,053 lines) — Skalman's model/view split
   discipline is the countermeasure; keep it.

---

## 7. Borrowables — full ranked list, then the shortlist

Ranked by leverage for Skalman's shape (native conversation surface + Git Review + sidebar):

1. **Turn folding** ("Worked for 42s") — §3.1. Finishes the tool-row-quieting work; the
   interrupt-stays-expanded and user-message-start-boundary rules come free.
2. **macOS notifications on `needsAttention`** — their 42-vote gap, still unbuilt on their
   desktop; `UNUserNotificationCenter` + the existing activity tracker makes this nearly
   free for a native app. Cheapest proven-demand win in the whole document.
3. **Diff-comment → composer round trip** — §3.7. Connects two systems Skalman already has
   (Git Review's `DiffView` + the composer) into "tell the agent what to fix, anchored to
   the lines it wrote."
4. **The three-mode auto-scroll machine with gesture-generation counter** — §3.2. The
   native surface needs exactly this; their #3925 shows the naive version fails.
5. **Tool-row outcome glyphs + failure-text sniffing** — §3.3. Our rows show a size but
   not an outcome; "neutral promotes to success at settle" avoids permanent ambiguity.
6. **Settle/snooze + the recede rule** — §3.6. The biggest *idea* here, but it deserves its
   own design pass: Skalman's grouping (repo → checkout → branch → session) carries
   information their flat inbox discards; the semantics (derived settling, raising a hand,
   PR-merge + 1 h idle) could layer onto the tree without flattening it.
7. **Per-turn checkpoints as hidden git refs** — generalizes `GitTurnBaselineStore` (refs
   solve the gc-prunability that forced ours in-memory and single-turn) → Turn-N diff
   history + revert-to-message. Interacts with Claude's `--resume-session-at` /
   `rollbackThread` question — needs measurement.
8. **Per-turn changed-files card** — §3.4, with the ≤5-files/≤200-lines auto-expand rule.
9. **AI-generated commit messages** in Git Review's commit composer — one headless one-shot
   run, the `ProjectIconResearch` pattern; their policy presets (conventional commits) are
   a nice touch.
10. **Steering/queueing a message while the agent works** — their 47-vote demand, half-built
    (steering works, no queue UI). For our native surface `--input-format stream-json`
    likely permits it; needs a probe.
11. **Long-user-message collapse** — §3.5.
12. **Composer triggers** — `@` file mentions first; `/` commands and `$` skills later.
13. **Context-window meter** — distinct from the account usage pill; Claude's stream
    carries the numbers already.
14. **Scope-keyed ephemeral state** — §3.7; a pattern, not a feature: state carries its
    scope key and reads as empty on mismatch. No cleanup, no staleness.
15. **Subagents as nested rows** — their 25-vote gap; we currently skip `isSidechain`
    records in replay entirely. Both products under-serve this.
16. Snooze preset arithmetic (evening-suppression, DST-safe `setDate`, ceil'd minutes so a
    snooze never reads "0m") — if #6 happens, take these rules verbatim.

### The shortlist (adopt first)

1. Turn folding
2. macOS notifications on `needsAttention`
3. Diff-comment → composer loop
4. Auto-scroll state machine for the native surface
5. Tool-row outcome glyphs

Settle/snooze is deliberately *not* on the shortlist despite being the biggest idea — it
changes the sidebar's philosophy and must be designed against our grouping model, not
copied.

---

## 8. Sources

- Repo: https://github.com/pingdotgg/t3code (clone at `5719e8a`, 2026-07-24)
- Issues cited: #1397 (telemetry), #695 (speed), #3143 (idle power), #2256/#2140 (context
  loss), #3925 (auto-scroll), #231 (steering), #780 (notifications), #228 (usage), #330
  (import), #1404 (forking), #538 (subagents), #216 (raw output)
- https://t3.codes · https://betterstack.com/community/guides/ai/t3-code/
- https://github.com/AgentWrapper/agent-orchestrator/discussions/526 (competitive matrix)
- https://medium.com/@springmusk/t3-code-vs-codex-is-the-free-gui-actually-better-352df1c23932
- Theo: https://x.com/theo/status/2036875737266000048 (Conductor comparison),
  https://x.com/theo/status/2054737293186126056 (monetization)
- https://venturebeat.com/technology/anthropic-reinstates-openclaw-and-third-party-agent-usage-on-claude-subscriptions-with-a-catch
- HN via hn.algolia.com: items 47283489/47283655/47308694/47284441 (launch), 48892468
  (remote-agency quote), 48827402, 47460525, 47633568
