# Decision records

A decision record is what a feature draft becomes once the answer is *no*, *not yet*, or *only
this much*. [`docs/feature-drafts/`](../feature-drafts/README.md) holds proposals somebody intends
to build; this directory holds ideas that were investigated to the point of a **recommendation**,
including the ones being turned down.

Both directions are worth writing. An idea rejected without a record comes back every six months
and is re-investigated from zero; an idea deferred without a stated trigger is never picked up
again even when the thing that was missing arrives.

A record here:

- states the user problem in concrete cases, not as a feature name;
- says what Threading **already** does that overlaps, because most of these are 60% built;
- records what the prior art actually does, measured rather than assumed;
- specifies the domain/host contract precisely enough to implement without re-deriving it;
- names the security, privacy, destructive-action and scaling analysis;
- gives the smallest shippable slice, the explicit non-goals, and the tests;
- ends with a recommendation and **the evidence that should reopen it**.

Rule of thumb: if a later agent has to redo the investigation to act on the recommendation, the
record failed. If it can implement the approved slice straight from §4 and §7, it worked.

When an approved slice ships, move its durable decisions into the relevant
[`docs/architecture/`](../architecture/) file and leave a short pointer here — the same rule
`feature-drafts` follows. A record whose recommendation is *reject* stays as it is; that is the
artefact.

## Records

All five came out of the third [t3code mining trip](../T3CODE_FINDINGS.md) and were deliberately
kept apart. They are five independent product questions that happen to share a competitor, not one
"advanced workflow" system, and three of them turn out to be mostly answered by machinery
Threading already has.

| Record | Recommendation |
|---|---|
| [Revert to this message](revert-to-message.md) — put the files back to where a turn started, and the separate question of rewinding the provider conversation | **Prototype** the workspace-only half; **reject** the conversation-revert claim |
| [Automatic settling](automatic-settling.md) — an inbox that files a finished chat away by itself | **No-go** on a new lifecycle state; **experiment** with a presentation-only Needs Attention view |
| [Editable file previews](editable-file-previews.md) — edit a file in Threading instead of leaving for an editor | **Reject** on the Mac; **wait for demand** on a narrow remote-only slice |
| [Repository setup hooks](repository-setup-hooks.md) — a checked-in command that runs when Threading creates a worktree | **Reject** automatic execution; **prototype** an offer that still needs a press |
| [DOM source attribution](dom-source-attribution.md) — click an element in the browser, get `Component` and `file:line` | **Reject** a bundled framework provider; **wait for demand** on reading what a page already publishes |

## Measurements these records rest on

Provider contracts were read from the installed runtimes on 2026-08-12 rather than from
documentation, because three of the five decisions turn on exactly what a provider will and will
not do:

| Fact | Source |
|---|---|
| Claude `rewind_conversation` / `rewind_files` control requests, their refusal vocabulary, and the file-history subsystem behind them | CLI 2.1.228 binary (`~/.local/share/claude/versions/2.1.228`) |
| Claude's "File has been modified since read" write precondition, and the `seed_read_state` control request that suppresses it | same |
| Codex `thread/rollback` marked deprecated, counted in turns, explicitly not reverting files | `codex app-server generate-json-schema`, codex-cli 0.147.0 |
| Codex `thread/fork` taking an inclusive `lastTurnId` | same |
| Codex's `fs/*` host-filesystem request family | same |
| t3code's setup-script runner, settling derivation, file-save coordinator and element picker | local clone at `edc503a7a`, which is **newer** than the `5719e8a` the findings document was written against |
| `react-grab@0.1.50` reading `__REACT_DEVTOOLS_GLOBAL_HOOK__`, fiber `_debugSource`/`_debugOwner`/`_debugStack`/`_debugInfo` and `sourceMappingURL` | npm tarball |

Where a record cites one of these it says so inline, so a later reader can tell a measurement from
an inference and re-run the measurement against a newer runtime.
