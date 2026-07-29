# Customization surface audit

Skalman should be deeply customizable without turning its AppKit hierarchy into an API. The
reusable mechanism is semantic component composition:

- a stable, versioned component ID;
- a host-owned behavior and presentation shell;
- optional properties and additive slots;
- exclusive visual replacement when the shell can safely survive it;
- composable around-hooks containing exactly one `.proceed`;
- prepublished values and synchronous in-memory rendering, never IPC during layout or hover.

The component ID remains specific to a durable product concept. The composition engine is
general; a selector such as `NSView > NSStackView:nth-child(2)` is not.

## Adoption order

| Surface | Proposed contract | First authority | Host must retain | Status |
| --- | --- | --- | --- | --- |
| Main window content | `application.main-window@1` | around-hook | window chrome, input routing | Implemented |
| Project row | `sidebar.project-row@1` | properties, slot, replacement | selection, DnD, row actions, count | Implemented |
| Project hover card | `sidebar.project-hover-card@1` | hook, replacement | hover, popover, sizing, dismissal | Implemented |
| Session row | `sidebar.session-row@1` | properties, slot, replacement | selection, DnD, activity, actions | Implemented |
| Session identity | `sidebar.session-identity@1` | replacement | activity precedence and row shell | Implemented |
| Session hover card | `sidebar.session-hover-card@1` | hook, replacement | hover, popover, session lifecycle | Implemented |
| Account usage popover | `toolbar.account-usage-popover@1` | hook, replacement | refresh, account selection, hover survival | Implemented |
| Start composer accessories | `composer.session-start@1` | protected horizontal hook | text input, submission, keyboard, drafts | Implemented |
| Reply composer accessories | `composer.conversation-reply@1` | protected horizontal hook | text input, submission, keyboard, stream/permission state | Implemented |
| User message | `conversation.user-message@1` | protected vertical hook | transcript order, content, turn boundary | Implemented |
| Assistant message | `conversation.assistant-message@1` | protected vertical hook | transcript order, content, streaming lifecycle | Implemented |
| Tool call | `conversation.tool-call@1` | protected vertical hook | result attachment, expansion, transcript order | Implemented |
| Permission card | `conversation.permission-card@1` | display-only protected hook | queue, context, decisions, remote mirroring | Implemented |
| Display-pane header | `display.pane-header@1` | protected command/status hook | tab ownership, close/select/order, overflow, persistence, `+` menu | Implemented |
| Display tab header | `display.tab-header@1` | display-only `after-title` slot | identity, active state, close/select, ordering, overflow | Implemented |
| Session corner card | `session.corner-card@1` | display-only placement slot | card navigation, visibility, activity presentation, refresh | Implemented |

## Project hover-card precedent

The SCC hover proved the complete presentation pattern:

```text
ProjectRowView hover shell
└── NSPopover owned by Skalman
    └── fixed-width/inset composition host
        └── extension hook A
            └── extension hook B
                └── selected replacement or native SCC content
```

An extension-only card uses an empty native `.proceed` body. Removing the final contribution
closes that card rather than leaving blank chrome. Native SCC availability and extension
availability are therefore independent reasons for presentation.

The SCC data itself is not part of the visual contract. An extension that only adds CI or
repository information uses existing project snapshots. An extension that needs the exact
language breakdown requires a separately reviewed brokered data capability; UI composition must
not become an accidental route to private models.

## Named popover gate

Every product popover has a stable `HostPopoverID` in `HostPopoverCatalog.swift`. Its exhaustive
exposure switch must either map the presentation to a public component contract or state why it
remains host-only. Product code creates it through `HostPopoverFactory`; a source-audit test
rejects raw `NSPopover()` construction anywhere else.

The name describes the durable product presentation, not the AppKit object. This prevents a new
popover from being added without making an extension-boundary decision, while still allowing
host-only presentations such as the account icon picker when extensions must not replace an
explicit user-owned choice.

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

The slot is display-only. Built-in segments own navigation — Git opens Review and child-agent
status opens Subagents — so an extension button inside the same compact line would fight the
host's hit targets; extensions with more to say use hover cards or a panel. Rows ride the native
card's visibility. Git state usually supplies that visibility, while child-agent state can keep
the session card present without a Git sentence; there is still no extension-only presentation.

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
