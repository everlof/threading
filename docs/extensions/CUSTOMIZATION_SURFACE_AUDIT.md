# Customization surface audit

Threading should be deeply customizable without turning its AppKit hierarchy into an API. The
reusable mechanism is semantic component composition:

- a stable, versioned component ID;
- a host-owned behavior and presentation shell;
- optional properties and additive slots;
- exclusive visual replacement when the shell can safely survive it;
- composable around-hooks containing exactly one `.proceed`;
- prepublished values and synchronous in-memory rendering, never IPC during layout or hover.

The component ID remains specific to a durable product concept. The composition engine is
general; a selector such as `NSView > NSStackView:nth-child(2)` is not.

Here **host** means the Threading application rather than an installed extension. **Host-owned**
behavior remains Threading's responsibility even when an extension adds to or replaces the
surface's presentation: for example, a session-row extension may replace visible content while
Threading still owns selection, drag and drop, activity state and row actions. A **host-only**
surface exposes no extension customization seam at all, usually because replacement would weaken
a security boundary, misrepresent an explicit user-owned choice or break an essential interaction.

## Adoption order

| Surface | Proposed contract | First authority | Host must retain | Status |
| --- | --- | --- | --- | --- |
| Main window content | `application.main-window@1` | around-hook | window chrome, input routing | Implemented |
| Sidebar workload analyzer | existing theme `material.chart_style: spectrum` | theme-selected host presentation | workload/intensity truth, exact count, effort judgement, accessibility, bounded motion | Implemented |
| Project row | `sidebar.project-row@1` | properties, slot, replacement | selection, DnD, row actions, count | Implemented |
| Project hover card | `sidebar.project-hover-card@1` | hook, replacement | hover, popover, sizing, dismissal | Implemented |
| Session row | `sidebar.session-row@1` | properties, slot, replacement | selection, DnD, activity, actions | Implemented |
| Session identity | `sidebar.session-identity@1` | replacement | activity precedence and row shell | Implemented |
| Standalone terminal row | — | host-only | selection, shell/foreground-command status, row actions | Host-only |
| Work organization controls | — | host-only | project ownership, chat/terminal type membership, stable within-type order, direction persistence | Host-only |
| Chat checkout move controls (session menu, Tools policy, agent approval) | — | host-only | canonical checkout identity, durable ownership transaction, turn/input fence, authority audit and runtime resume | Host-only |
| Command palette | — | host-only | command identity and availability, focus/dismissal, bounded search, shortcut ownership/conflicts, explicit target collection and last-moment invocation checks | Host-only |
| Mobile terminal key bar | — | host-only | Direct/Compose resolution, collaboration override, PTY encoding, input permission, modifier/press lifecycle, haptics, accessibility, user-authored layout fallback | Host-only |
| Mobile terminal return-to-end control | — | host-only | emulator scroll-end truth, TUI/local ownership, follow-mode transition, motion and accessibility | Host-only |
| Mobile terminal selection quote tray | — | host-only | selected-text snapshot, bracketed-paste decision, insertion/submission path, removal, accessibility | Host-only |
| Mobile connection reuse settings and metrics | — | host-only | authenticated transport lifecycle, mirror detach/resume truth, bounded pool policy, privacy-safe telemetry | Host-only |
| Local iOS diagnostics settings | — | host-only | independent consent, pairing and authorization, request nonces, evidence allowlist, screenshot policy and bounded custody | Host-only |
| Session hover card | `sidebar.session-hover-card@1` | hook, replacement | hover, popover, session lifecycle | Implemented |
| Account usage popover | `toolbar.account-usage-popover@1` | hook, replacement | refresh, account selection, hover survival | Implemented |
| All-account usage fleet | — | host-only | discovery/refresh pacing, current-account identity, migration eligibility/action, bounded scrolling and popover lifecycle | Host-only |
| Usage analytics section switch | — | host-only | selected native analysis, retained chart state, keyboard and accessibility navigation | Host-only |
| Curfew surfaces (draft moon button and chip, chat chip, sidebar Curfew fold, strip source, Settings section) | — | host-only | the deadline and its instance identity, hold admission, the wind-down record, interrupt/stop decisions and their receipts, the watched-turn rule, Lift | Host-only |
| Account setup and reconnect | — | host-only | provider identity, isolated-home routing, child-process lifecycle, login verification, credential non-capture, native failure and installation fallback | Host-only |
| Custom-limit authoring | — | host-only | account/window identity, numeric validation, rule semantics, persistence, bounded history work, keyboard and accessibility contract | Host-only |
| Start composer accessories | `composer.session-start@1` | protected horizontal hook | text input, submission, keyboard, drafts | Implemented |
| Reply composer accessories | `composer.conversation-reply@1` | protected horizontal hook | text input, submission, keyboard, stream/permission state | Implemented |
| User message | `conversation.user-message@1` | protected vertical hook | transcript order, content, turn boundary | Implemented |
| Assistant message | `conversation.assistant-message@1` | protected vertical hook | transcript order, content, streaming lifecycle | Implemented |
| Tool call | `conversation.tool-call@1` | protected vertical hook | result attachment, expansion, transcript order | Implemented |
| Permission card | `conversation.permission-card@1` | display-only protected hook | queue, context, decisions, remote mirroring | Implemented |
| Display-pane header | `display.pane-header@1` | protected command/status hook | tab ownership, close/select/order, overflow, persistence, `+` menu | Implemented |
| Display tab header | `display.tab-header@1` | display-only `after-title` slot | identity, active state, close/select, ordering, overflow | Implemented |
| Session Overview body | — | host-only | Activity attribution and lazy tree, usage/accounting truth, Info polling/process controls/port routing, section lifecycle, persistence and empty-panel fallback | Host-only |
| In-panel iOS Simulator body | — | host-only | CoreSimulator device identity, boot lease and ownership, agent consent/routing, framebuffer/input authority, visibility budget and fallback truth | Host-only |
| Session corner card | `session.corner-card@1` | display-only placement slot, disclosure detail | card navigation, visibility, activity and usage truth, refresh, the whole reveal gesture | Implemented |
| Launch failure surface | — | host-only | the runtime's captured words verbatim, exit classification, retry, the report path's review-before-send rule, repair eligibility and the working-copy boundary | Host-only |
| Attachment preview body | `attachments.preview@1` | exclusive preview-body replacement, offered rather than owned | chronology, filter, selection, Open in, reveal, delete, pruning, the too-large refusal, editable annotation receipt/revisions and the inspector rail | Implemented |
| Background sessions (quit choice, launch band, Advanced list) | — | host-only | which children the daemon holds and their identities, the quit answer and what it stops, registration and its removal rule, the stop's attach-then-kill, bounded survey and viewport | Host-only |
| Command-line tool installation (Advanced row) | — | host-only | which tools are public, the shim directory and its refresh, what in a user's `~/.local/bin` may be written or removed, the login-shell `PATH` reading, the refusal to edit a shell profile | Host-only |
| Command-line tools on launched `PATH` (Advanced switch) | — | host-only | the environment composed for every shell and agent, prepend-never-substitute, the absent-`PATH` refusal | Host-only |
| Update channel picker | — | host-only | which builds the updater accepts, the default a build resolves to, the feed override, the versions Sparkle compares | Host-only |

The background-sessions surfaces remain host-only because each of the three is a **decision about
somebody's running work**, not a presentation of it. The quit choice ends processes or does not;
the list's Stop ends one; the switch beside it registers or removes a launchd agent whose
`unregister()` kills the running helper. None of that is a layout, and a replaceable presentation
of it would be a surface that can misname which agent it is about to stop. The facts behind them
are already published where an extension can reach them honestly — a session's activity and its
runtime — and what is missing for an extension that wants to *act* is a typed background-session
entity with the daemon's identity in it, not the box the rows are in. The launch band is a
`PaneNoticeView`, which is host chrome for the same reason every other band is.

The two command-line-tool surfaces remain host-only for the same reason as the rows above them,
one step sharper: both write outside anything Threading owns. One creates and deletes a symlink in
the user's own `~/.local/bin` and reads what their login shell exports; the other changes the
`PATH` of every process this Mac's agents will run. A replaceable presentation of either is a
surface that can misname the path it is about to write, or say a switch is off while it is on. The
facts behind them are already published where an extension can reach them honestly — the settings
catalogue describes both rows, and neither is remotely mutable by construction.
The update channel picker remains host-only because it decides which software this Mac will
install. Its two levels are exactly the subscriptions Sparkle can honour, its resolved default
comes from the running build's own channel so a directly downloaded beta is not filtered into
silence, and nightly is deliberately absent because a date version outranks every release and
choosing stable again would strand the user. A replaceable presentation of that could offer a
level the updater does not accept, show a level other than the one in force, or name nightly as a
one-click option. An extension that wants to know what somebody receives should ask for a
published typed subscription value, not for the control that sets it.

The launch failure surface remains host-only because its content *is* the evidence. The whole
surface exists because an agent's account of why it would not start was being destroyed, and a
replaceable presentation of that account is one that can paraphrase, truncate or restyle the one
text nobody should be reading second-hand. The repair route compounds it: the offer's eligibility,
the working-copy boundary and the "checked, backed up, then asked" sequence are a safety contract,
not a layout. An extension that wants to act on these failures should ask for a published typed
failure record to observe, not for the box the words are in.

The standalone terminal row remains host-only because no published extension entity or data
capability represents its live shell. Exposing replacement presentation without that authority
would create a visual contract that cannot truthfully describe the process behind it. Threading
therefore keeps its identity, selection, foreground-command spinner and lifecycle actions
host-owned; a future public row starts by publishing the typed terminal context rather than by
leaking the AppKit cell.

The macOS sidebar and iOS dashboard organization controls remain host-only navigation chrome.
They arrange existing public or host-only rows without changing those rows' presentation
contracts. Threading owns persisted project membership, chat-versus-terminal classification,
stable order inside each type, direction persistence and the navigation destination; allowing a
replacement control to contradict any of those facts would make the same terminal appear to have
different ownership across surfaces.

Moving a chat between checkouts is the durable half of that same boundary, so its shared session
menu, Tools policy and approval sheet remain host-only too. Threading owns canonical repository
and worktree identity, the atomic session/project transaction, the active-turn input fence, the
authority classification and audit record, provider transcript custody, and the point at which
the same conversation may resume. A replaceable surface could otherwise display a branch as the
target while committing another checkout, release input before the turn checkpoint, or claim an
agent-initiated move was explicitly requested. Extensions may still customize the surrounding
session row and header through their existing contracts; no new checkout-move component or data
authority is introduced.

The command palette remains host-only even though extensions may contribute semantic commands to
its registry. Threading owns the query and keyboard state, the 100-row presentation cap, shortcut
conflict policy, input prompts, session-target revalidation, overlay dismissal and the one host
invoker. An extension may customize its command's published title, detail, icon, scope and default
shortcut through the command contract; it may not replace the shell and visually claim a disabled
command, stolen shortcut or stale target is executable.

The mobile terminal key bar is host-only even though its key layout and solo Direct/Compose choice
are deliberately customizable by the person using that phone. Its presentation is inseparable
from the collaboration rule that temporarily requires atomic Compose, permission-gated PTY
writes, DECCKM/xterm encoding, latching and live two-finger modifier state, touch cancellation,
haptic and accessibility feedback, attachment upload/custody and path insertion, and the
device-local archive's validated fallback. Letting an extension replace that shell could show a
key, file, input mode or pressed state that the host did not authorize. Threading owns those
behaviors and the complete interactive cap; the built-in keyboard editor remains the one
presentation customization seam.

The mobile terminal return-to-end control is host-only because its presence is an emulator claim,
not decoration. Threading retains the exact reachable scroll end, whether one finger belongs to
the TUI or local history, the action that cancels the current UIKit gesture velocity before it
clears manual scrollback and resumes follow mode, and the control's accessibility and Reduce
Motion behavior. An extension cannot replace the arrow or its visibility without risking a
control that claims local content is below while the program actually owns that gesture.

The mobile terminal selection quote tray is host-only for the same reasons. A chip stands for
text the person selected in the terminal and chose to send; the host owns that snapshot, decides
whether it travels as one bracketed paste from the emulator's seeded mode, writes it to the PTY
or into the atomic line submission, and removes it. An extension drawing the chip could show
lines that are not the ones about to be sent.

Mobile connection reuse settings and metrics are host-only because their presentation states
transport facts that an extension cannot observe or enforce. Threading owns authentication,
subscriber detachment, viewport/presence/input-control release, resume authorization, expiry and
capacity bounds, and the privacy boundary of the aggregate counters. An extension may not replace
or relabel this page and claim a socket is cheap, parked, reused or private when the host lifecycle
does not say so.

Local iOS diagnostics settings are host-only because the switches are the visible consent
boundary for a content-bearing evidence route. Threading must keep each device's opt-in paired
with owner authorization, the selected LAN route, single-use request ids, the fixed structural
allowlist, screenshot provenance and bounded custody. An extension may not replace or relabel
these settings and claim evidence or an error screenshot is disabled when the host would still
accept or collect it.

The sidebar workload analyzer is deliberately not a second extension component around the brand
row. It is one presentation of an existing theme-owned slot: any installed theme may select the
spectrum material, while `SidebarBrandView` keeps the exact operational facts and accessible
wording host-owned. Publishing replacement UI here would either expose no useful data or require
a new brokered app-wide activity capability; theme selection provides the useful customization
without turning runtime state into presentation authority.

Account setup and reconnect remain host-only because the presentation is inseparable from an
authentication boundary. Threading must keep the selected provider paired with the exact
`CLAUDE_CONFIG_DIR`/`CODEX_HOME`, own cancellation and timeout of the child process, verify through
the provider before registering a location, and preserve a native missing-CLI/install-guide
fallback. The provider CLI owns the browser UI and credential. Allowing an extension to replace
this surface could visually claim a different provider, solicit a credential, or report success
without the host's verification; additive decoration has no use worth that ambiguity.

Custom-limit authoring remains host-only because its visible percentages are executable account
policy, not decorative Settings copy. Threading keeps the selected account and provider window
paired with the exact metric, validates whole-number bounds before dismissal, converts a reserved
share to its complementary pace allowance, bounds rolling history to one week, persists the rule,
and retains the keyboard, focus and accessibility contract of the modal. An extension may present
its own settings, but cannot replace this surface and visually claim that Threading will enforce a
different bound from the one the host stored.

The all-account usage fleet remains host-only for its first contract because it is an operational
surface rather than one account's replaceable reading. The host owns enabled-account discovery,
provider refresh pacing, which login is current, the bounded virtual viewport, and the exact
`SessionMigration` eligibility and move action for the conversation under the toolbar. Publishing
its presentation requires a typed, bounded multi-account usage contract; the existing
`toolbar.account-usage-popover@1` remains the customization point for one account's reading.

The Usage analytics section switch remains host-only navigation over Threading's prepared
Consumption and Limit-history truth. Threading owns which retained native column is visible, its
keyboard and accessibility state, and the promise that switching does not rebuild or reset either
chart. Extension-contributed Usage settings remain additive sections outside this switch; a
replacement switch must not gain authority to hide or relabel their content.

Session Overview is host-only because its two sections expose host-owned operational truth rather
than a presentation-only document: exact versus observed work attribution, transcript-accounted
usage and price provenance, live processes, terminate confirmations, listening-port routing,
filesystem hydration and bounded lazy loading.
The host also owns the section lifecycle—only the visible reading may poll or attach—and the
synthetic, non-persisted Overview shown when a person opens an empty panel. Extensions can still
compose into the surrounding `display.pane-header@1` and `display.tab-header@1`; publishing the
body would require separate typed, brokered data contracts rather than access to these controllers.

The in-panel iOS Simulator is host-only because its presentation is also an authority boundary.
The selected UDID, whether Threading may shut it down, which session and agent may control it,
whether a hidden tab consumes framebuffer work, and whether the direct helper or public fallback
is active must remain one host-owned truth. An extension replacement could falsely present a
different device or claim live input while holding neither lease nor consent. Extensions may
still decorate the surrounding `display.pane-header@1` and `display.tab-header@1`; a future safe
device-status component begins with a typed brokered snapshot, not access to CoreSimulator or the
framebuffer controller.

Image annotation persistence and publication remain deliberately host-owned inside the existing
attachment-preview contract. A replacement preview may draw the file body, but it cannot replace
the editable annotation document, claim that a revision was added to chat, or alter the stable
receipt that links a composer/transcript back to that document. Those are user-authored state and
transport truth, not preview presentation.

## Project hover-card precedent

The project-metrics hover proved the complete presentation pattern:

```text
ProjectRowView hover shell
└── NSPopover owned by Threading
    └── fixed-width/inset composition host
        └── extension hook A
            └── extension hook B
                └── selected replacement or native project metrics
```

An extension-only card uses an empty native `.proceed` body. Removing the final contribution
closes that card rather than leaving blank chrome. Native-metrics availability and extension
availability are therefore independent reasons for presentation.

The project-metrics data itself is not part of the visual contract. An extension that only adds CI or
repository information uses existing project snapshots. An extension that needs the exact
language breakdown or repository history aggregates requires a separately reviewed brokered data
capability; UI composition must not become an accidental route to private models. The proposed
bounded contract is recorded in
[`project-insights-extension.md`](../feature-drafts/project-insights-extension.md).

## Named popover gate

Every product popover has a stable `HostPopoverID` in `HostPopoverCatalog.swift`. Its exhaustive
exposure switch must either map the presentation to a public component contract or state why it
remains host-only. Product code creates it through `HostPopoverFactory`; a source-audit test
rejects raw `NSPopover()` construction anywhere else.

The name describes the durable product presentation, not the AppKit object. This prevents a new
popover from being added without making an extension-boundary decision, while still allowing
host-only presentations such as the account icon picker when extensions must not replace an
explicit user-owned choice.

`design.help` is the catalogue's first entry that is not a *place* in the app: `HelpPopoverButton`
is a component, so the same ID names every "?" in the product. That is deliberate. The panel's
body is always the words the surface it stands on already publishes — a remote way in's four
questions, an identity operation's cost — so an extension with something to add about that
surface adds it to *that* surface's contract, and would gain nothing by composing into the
sentence explaining it. What stays host-owned is the affordance: the press, the placement,
Escape, the focus return, and the promise that the same words reach a screen reader from the
button whether or not the panel is ever opened. Moving prose behind a press is only honest while
that promise holds, which is why it is a component rather than a pattern each page repeats.

`extension.node-detail` is host-only for a different reason from the others: its *body* is
already an extension's own tree, so there is nothing in it for a second extension to compose
into, and the surface exists only while a reader holds a row open. What stays host-owned there
is the gesture — the dwell, the placement, the growth limit, the pointer bridge that lets the
pointer cross into it, and the dismissal.

## Composer precedent

Both composers wrap their existing native `PromptView` in the generic composition host. A
project-scoped start-composer hook and a session-scoped reply-composer hook may add compact
controls on either side of `.proceed`. Their contracts permit only a horizontal stack and
require `.proceed` exactly once; replacement and overlay are forbidden.

This is deliberately narrower than a visual slot or full replacement. It preserves the exact
native input instance—and therefore its text, callbacks, focus, keyboard behavior and lifecycle—
while still allowing useful actions such as templates, context attachment or status. Removal of
the contributing generation removes only its controls and leaves that same prompt instance in
place.

## Conversation-row precedent

Conversation rows deliberately do not share one broad contract. User text, assistant markdown,
collapsible tool activity and security decisions have different invariants and therefore
different IDs. Each real native row is retained inside a vertical around-hook with exactly one
`.proceed`; replacement and overlay are unavailable.

Targets may be family-wide or use a session ID from `host.sessions.read`. They do not identify a
specific message and no transcript content enters component context. This keeps UI composition
from silently becoming transcript-read authority. Tool results still attach to the retained
native `ToolCallView`, and permission hooks cannot contain buttons—the native card remains the
only place where Allow or Deny can originate.

Thinking, notices and the streaming placeholder are not public components. They are transient
states whose durable output becomes an assistant-message row.

## Corner-card precedent

The floating card over the session's content pane is the first contract whose **slot IDs are
placements**. `session.corner-card@1` names the surface generically — the card shows the
checkout's branch and counters today, and may show agents or attachments tomorrow, so neither
"git" nor any content kind appears in the ID. `top-trailing` is the only corner with a card;
when a leading card ships, it becomes an additive `top-leading` slot on the same contract
version rather than a rename or a sibling component.

The slot's **row** is display-only. Built-in segments own navigation — Git opens Review, the
session receipt opens Overview ▸ Info, and child-agent status opens Subagents — so an extension
button inside the same compact line would fight the host's hit targets. Threading also owns the
usage values and their provider-reported/estimated wording; customization cannot relabel an
estimate as billed cost. Rows ride the native card's visibility. Git, usage or child-agent state
can keep the Session Status Card present without one another; there is still no extension-only
presentation.

"Extensions with more to say use hover cards or a panel" was the answer to that rule, and for
one version it pointed at a door that did not exist: an extension could compose into a hover
card the host *already* shows, and could not give a card of its own to a row it had
contributed. `ExtensionNode.disclosure` is that door. A row states that it has a second level
and what that level says; Threading owns the reveal — the dwell, the surface, its placement,
how far it grows before it scrolls, and what dismisses it. The revealed level has its own
vocabulary in the contract (`disclosureDetail`), which is where the display-only rule stops:
the corner card's second level may carry `standard` buttons, because a control there fights
nothing. Opening it is what the reader just asked for. A hover reveal is still not where a
destructive or primary action belongs, and the contract says so by allowing neither role.

## Attachment-preview precedent

Every other surface in this table is *published to*: an extension declares a patch and the host
applies it. `attachments.preview@1` is the first that is **asked**, and the difference is the point.

A preview body is exclusive — one row shows one thing — so a published patch would have needed a
conflict rule, and every conflict rule invents a state ("two extensions claim this file") that a
user has to resolve. Instead the host offers the attachment to each candidate in the order the
user's own extension list puts them in, and the first valid acceptance wins. Ordering *is* the
conflict policy.

That shape also gets three properties for free:

- **Declining is ordinary.** An extension that previews Lottie declines every PDF it is offered,
  and the host simply moves on. There is no registration to keep accurate.
- **A failure is a decline.** A timeout, a generation that died mid-offer and an invalid body all
  advance to the next candidate, so a slow or crashing extension costs the user one preview rather
  than the pane.
- **The fallback is always already there.** The native body is drawn first and replaced only when a
  candidate wins, so removing the last contribution never closes the built-in surface or leaves
  blank chrome.

At most eight candidates are consulted for one presentation, because selecting a row must not be
able to turn into unbounded process work as the user installs more extensions. See
[`media-documents.md`](../architecture/media-documents.md).

## Gate for every new surface

Before adding a component:

1. Name the durable semantic surface and its entity context. For a popover, register its stable
   `HostPopoverID` and choose public-component or documented host-only exposure.
2. State which behavior remains host-owned even under full visual replacement.
3. Start with the narrowest useful properties, slots or protected hook.
4. Preserve contribution provenance for every interactive node.
5. Define native, extension-only, invalid, disable, reload and conflict fallback.
6. Exercise the real product shell, not only the semantic renderer.
7. Add the contract to the generated catalogue and authoring tools.
8. Add new host data independently and only when a real extension cannot work without it.
