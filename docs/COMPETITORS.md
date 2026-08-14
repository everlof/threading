# Competitive landscape

Last updated: 2026-08-14

This is the index for products we have researched as competitors or close
substitutes. Each dossier is a point-in-time source review, not a permanent claim
about a fast-moving product. Prefer the dated dossier over recollection when making
a product decision.

## Researched products

| Product | Category | Why it matters | Research |
|---|---|---|---|
| **Threading** | Reference product | Native Mac workspace plus scoped remote collaboration, source review, browser automation, and a capability-governed extension host. | Current repository documentation |
| **[omg.dev](https://github.com/BennyKok/omg.dev)** | Direct | Self-hosted web/PWA control plane for many coding-agent CLIs, with worktrees, delegation, automation, artifacts, and phone access. | [Detailed findings](OMG_DEV_FINDINGS.md), source snapshot `301e29f` on 2026-08-13 |
| **[bb](https://github.com/get-bb/bb)** | Direct/strategic | Programmable agentic IDE with a shipped agent-authored plugin loop, broad backend/frontend extension APIs, durable threads, delegation, remote machines, and Git workflows. | [Detailed findings](BB_FINDINGS.md), source snapshot `5ecdd69` on 2026-08-14 |
| **[t3code](https://github.com/pingdotgg/t3code)** | Direct | Web/Electron/mobile coding-agent client with normalized conversations, PTYs, worktrees, review, and remote access. | [Detailed findings](T3CODE_FINDINGS.md), researched 2026-07-25 |
| **[Herdr](https://github.com/ogulcancelik/herdr)** | Adjacent/direct | Terminal-native multi-agent process manager with durable PTYs, worktrees, SSH access, and an executable plugin marketplace. | [Detailed findings](HERDR_FINDINGS.md), researched 2026-07-28 |

## At-a-glance feature matrix

The cells describe first-party product behavior found in the researched source. An
agent being able to run a shell command is not counted as a first-party product
feature.

| Capability | Threading | omg.dev | bb | t3code | Herdr |
|---|---|---|---|---|---|
| Primary surface | Native macOS; native iOS companion; browser | React PWA backed by a local Bun server | Electron desktop, web app, CLI, and HTTP API | Web, Electron, and mobile clients | Rust terminal UI and CLI |
| Supported interactive agents | Claude Code, Codex, Grok, OpenCode | Claude, Codex, OpenCode, Jcode, Cursor, Grok, Pi, Copilot | Claude Code, Codex, Pi, and ACP agents including Cursor | Claude Code and Codex | Any terminal process; agent presets |
| Native structured conversation | Yes, with terminal fallback | Yes; normalized from SDKs and TUI transcripts | Yes; append-only normalized events plus terminal panels | Yes; normalized provider events | No; PTY output is the interface |
| Simultaneous session view | Sidebar attention model; one focused conversation | Up to four pinned conversations on a wide screen | Split panes and thread panels; multiple live threads | Thread list plus focused workspace | Multiple live panes is the core UI |
| Durable process after client disconnect | Remote host remains active; local agents end when the Mac app quits | Yes, via tmux | Yes; server and host daemon own lifecycle | Server-owned sessions | Yes, via the daemon and PTYs |
| Isolated git worktrees | Opt-in managed workspaces with a finish/merge/disposal handshake | Default for managed sessions in git repositories | Opt-in managed worktree environments | Per-thread option | First-class worktree sessions |
| Read-only diff review | Six scopes, structured and image diffs | Session-branch diff, unified or split | Thread and workspace diffs, including images | Four scopes, unified or split | No dedicated review UI |
| Stage, commit, and PR/MR workflow | Yes | No dedicated workflow | Commit, PR, and squash-merge flow; no staging UI found | Commit, push, and PR flow; no staging UI | No dedicated workflow |
| Mobile and remote | Paired devices, native iOS and browser, APNs | Installable PWA over Tailscale or experimental relay; Web Push | Paired browser access, Tailscale, and enrolled execution machines; no native mobile app | Mobile clients, relay/Tailscale, APNs/Live Activities | SSH from any terminal |
| Scoped collaboration and roles | Per-conversation View, Collaborate, and Approve roles | No; anyone who can reach the server controls it | Account-gated owner access; no comparable per-thread roles found | Pairing and remote access, without comparable per-chat roles | Host/SSH boundary |
| Visible delegation hierarchy | Yes | Yes; MCP-driven, cross-agent children | Yes; manager and child threads, plus Tasks delegation | Subagent activity indicator, not a comparable tree | Agent processes, without a normalized transcript tree |
| Recurring autonomous watchers | No; scheduled messages are narrower | Yes; scheduled auto-agents emit deduplicated findings | Automations, workflows, schedules, and background services through plugins | No first-party equivalent found | No first-party equivalent found |
| Usage and limit visibility | Account limits, history, recovery estimates, tokens, and cost | Provider limits, context, tokens, cost estimates, and process resources | Context and process state; no comparable account-limit dashboard found | Provider diagnostics; no comparable per-turn cost dashboard | No first-party equivalent found |
| Rich artifacts/results | Display panel, attachments, media, charts, scenes | Sandboxed artifacts plus a cross-session **Shipped** feed | Inline visualizations plus plugin-owned panels and records | Attachments and browser previews | Terminal output |
| First-party browser automation | Visible browser, annotation, evidence, audits, and execution ledger | No first-party browser-control surface found | No first-party interactive browser-control surface found | Embedded preview, DOM picking, and Playwright MCP | No |
| Extension boundary | Capability policy plus semantic native rendering | Trusted ESM injection and embeddable React packages | Full-trust in-process TypeScript and same-origin React plugin SDK | Provider integration seams; no comparable app-extension host | Executable plugins; intentionally unsandboxed |

## Watchlist and baselines

These appear in strategy notes but do not yet have a source-level dossier:

- **Conductor** — commercial multi-agent workspace and pricing reference.
- **OpenCode and official agent CLIs** — upstream runtimes and substitution
  baselines, rather than full workspace competitors.

Their monetization context is tracked in [Open-source strategy](OPEN_SOURCE.md).
Add a dossier here before relying on a watchlist product for a feature decision.

## Maintenance rule

When adding a competitor:

1. Record the research date and an immutable source revision when possible.
2. Separate shipped first-party behavior from what an underlying agent can improvise.
3. Include both a feature inventory and the security, trust, and persistence model.
4. Link the dossier in this index and update only the matrix rows supported by evidence.
5. Re-check volatile adoption, pricing, and hosted-service claims before citing them.
