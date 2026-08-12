# Scoped sound overrides

> Status: feature draft — nothing here is implemented or scheduled. It extends the shipped
> notification-sound and terminal-bell work (`388ce721`) rather than replacing it. Two claims
> need verifying in code before implementation and are marked **[verify]** where they appear:
> whether a bell can be reliably attributed to the agent versus another foreground program, and
> whether `ProjectTerminal` should carry overrides at all.

## Summary

Let a sound answer two questions at once: **which conversation is making it** and **why**.

Today Threading has exactly two sound settings, both app-wide: one sound for every notification
that sounds, and one for every terminal bell. This draft scopes both to the chat, the project, or
the app — the same three scopes terminal themes already resolve through — and splits each into
the events that actually differ, so a blocked approval in the repo you are shipping today can
sound unlike a background turn finishing in the one you are not.

Two tiers, because most people want one thing and some want nine:

- **One sound for this chat / this project.** A context-menu submenu on the row, one click, no
  sheet. This is the case the design optimizes for.
- **A sound per event.** A sheet behind a *Customize…* item, listing the nine events below.

Everything is opt-in and inherits by default: a chat follows its project, a project follows the
app, and nothing acquires a sound because a scope above it changed shape.

## User problem

The shipped settings answer "what does Threading sound like". They cannot answer the questions
people actually have once more than one agent is running:

- *Which of these six chats just pinged me?* Right now every one of them sounds identical, so the
  sound tells you only that something happened, and you switch to the app to find out what. The
  sidebar already distinguishes them visually; the audio channel carries no information at all.
- *Is that worth interrupting for?* A turn ending in the background and an approval that is
  holding work up are the same ping today. The settings already treat these as separate **kinds**
  — they have separate switches — but the switches are all-or-nothing per kind, app-wide.
- *Why did the terminal just beep?* A bell from an agent asking for input, a bell from a test
  runner finishing, and a bell during an unattended launch are three different events that the
  activity tracker already tells apart internally, and that are indistinguishable to the ear.

There is also a narrower, concrete problem this solves, recorded as the open finding in
`IMPROVEMENTS.md`: **a bell from a background session can make two sounds**, its own and the
attention alert the same edge posts. Today the only remedy is switching one of them off globally.
With per-event scoping, `bell.agentAsking` can be set to Off while every other bell keeps
ringing, which is a proportionate answer rather than a global one. This draft does not *fix* that
finding — the ordering problem it describes is untouched — but it turns it from "silence one of
two features" into "silence one of nine events".

## What Threading can honestly distinguish

The event list is not a wish list. Each entry below is something the code already computes for
another purpose, which is what makes this a routing problem rather than new instrumentation.

### Bell events

`SessionActivityTracker.recordBell()` already branches on the state that separates these; see
[`session-activity.md`](../architecture/session-activity.md).

| Event | How it is known | Confidence |
|---|---|---|
| `bell.agentAsking` | not visible, not `launchedUnattended` — the case that sets `awaitsUser` and raises the sidebar's hand | certain; this is the existing branch |
| `bell.agentVisible` | `isVisible` — you are looking at the session that rang | certain |
| `bell.launch` | `launchedUnattended` — already treated as boot noise rather than an ask | certain |
| `bell.otherProgram` | the PTY's foreground process group is not the agent | **[verify]** heuristic |

`bell.otherProgram` is the one that needs proving. `ProcessUtility.foregroundProcessGroup(ofPTY:shellPid:)`
already exists and `TerminalSession` calls it to attribute terminal titles, but a bell arrives
asynchronously with respect to that snapshot, so the answer can be stale for a program that just
exited. **Design rule that makes a wrong guess inaudible:** `bell.otherProgram` must inherit from
the same place `bell.agentAsking` does unless the user deliberately gives it its own sound. A
misattribution then costs nothing until someone has opted into hearing the difference, at which
point they have also opted into the occasional wrong answer. If the check proves unreliable
enough to be misleading, ship the other three and drop this row; the model does not depend on it.

Note that a bell rung in a **standalone terminal** is not the same record as a chat's bell —
`ProjectTerminal` is its own type. See *Data model* below.

### Notification events

Three exist as `AttentionAlert` cases with their own settings rows. Two more post notifications
today through separate paths and are currently unreachable from any sound setting:

| Event | Source |
|---|---|
| `alert.blocked` | `AttentionAlert.blocked` — a turn stopped on an approval |
| `alert.unread` | `AttentionAlert.unread` — finished or asked while you were elsewhere |
| `alert.finished` | `AttentionAlert.finished` — a turn ended in the background |
| `alert.requestedUpdate` | `AttentionAlertCenter.postRequestedUpdate` — the agent called `notify_user` |
| `alert.scheduledMessage` | `ScheduledMessageNotifier` — a scheduled message was sent, or failed |

`alert.scheduledMessage` posts **silently** today (it never sets `content.sound`). Including it
here is a small behaviour change and should ship defaulting to silent, so the default install
sounds exactly as it does now.

## Product contract

### The choice

The same three-case choice the bell already uses, for every event:

```
inherit          — no entry at this scope (the default, and not a stored value)
silent           — post/ring without a sound
systemDefault    — the macOS notification tone for alerts, the system alert sound for bells
named(fileName)  — any sound in the shared picker, including one the user added
```

`silent` per event subsumes what `playsAttentionAlertSound` does globally. The toggle stays as the
master switch — it is the control people reach for meaning "not right now" — and per-event
`silent` refines it, the same relationship the alert-kind switches already have with
`notifiesOnAttention`.

### Resolution

Three scopes, narrowest first, matching `ThemeResolution.resolve` and `AttentionAlertScope`:

```
session (or standalone terminal)  →  project  →  app  →  built-in default
```

and **two levels within each scope**, so that "this project sounds like Submarine" survives the
addition of a tenth event later:

```
scope[event]  →  scope[all]  →  next scope out
```

Full order for one bell in a chat:

```
session[bell.agentAsking] → session[all]
  → project[bell.agentAsking] → project[all]
    → app[bell.agentAsking] → app[all]
      → built-in default
```

`scope[all]` is what the one-click submenu writes. `scope[event]` is what the Customize sheet
writes. A scope with neither is absent from storage entirely, which is what makes this opt-in
rather than a table of inherited values copied into every record.

**Nil means follow, and the writer keeps it that way.** The mute item already does this and the
reasoning transfers exactly: when the chosen value equals what the scope would have inherited,
store nothing rather than storing the matching value, so a later change to the project still
reaches the chat. `ProjectSidebarSessionActions.toggleMutedClicked` is the pattern to copy.

### Where it is set

**Context menu — the one-click tier.** On a project row and on a chat row, beside the existing
Mute item:

```
Sounds ▸
    ✓ Follow Project (Glass)          ← names what it inherits, as the theme menus do
      ─────────
      Off
      macOS Alert Sound
      Submarine
      Glass
      Purr
      …
      ─────────
      Add a Sound…
      Customize…                       ← opens the per-event sheet
```

The checked row is the current effective answer, and its parenthetical names the inherited sound
so the menu explains the inheritance without a second click — the rule
[`themes.md`](../architecture/themes.md) already states for its Inherit items. Selecting a sound
plays it, exactly as the settings pickers do.

When a scope has per-event overrides, the first item reads **Customized (3 events)** and remains
selectable to clear them.

**Customize sheet — the per-event tier.** One row per event, grouped *Bell* and *Notifications*,
each row a picker whose first item is *Follow …* naming the inherited sound. A **Reset all to
inherited** button. Reachable from the context menu and from Settings.

**Settings.** The app scope keeps its current home (General ▸ Notifications and ▸ Terminal Bell),
extended from one picker each to the same nine-row table behind a *Customize…* button, so the app
scope and the other two are configured by the same sheet.

### Finding what is overriding

A per-chat sound that someone set two weeks ago and forgot is a mystery noise, and the same is
true of the mute feature today. The design owes an answer:

- Settings gains a **Custom sounds** section listing every project and chat that carries an
  override, what it resolves to, and a Reset control per row and for all of them. The list is
  built from the store, so it cannot drift from the records.
- The sidebar row's tooltip or its existing hover affordance names a non-inherited sound. Exact
  surface to be decided against `ProjectRowView`; the requirement is that an overridden row is
  identifiable without opening a menu.

Neither surface should add a persistent badge to the row. A quiet app does not decorate rows with
configuration state, and an override is not a status.

## Architecture this extends

| Piece | File | What changes |
|---|---|---|
| Sound library, picker menu, install, preview | `NotificationSound.swift`, `SoundPickerMenu.swift` | nothing — already shared by two callers, this adds more |
| Bell choice and playback | `TerminalBell.swift` | `ring()` takes the resolved choice instead of reading `AppSettings` |
| Alert sound choice | `AttentionAlertSound.swift` | folds into one `SoundChoice` shared with the bell |
| Which sound plays | `AttentionAlerts.swift` (`chosenSound`) | resolves per event and per session instead of app-wide |
| Bell cause | `SessionActivity.swift` (`recordBell`) | reports the cause alongside the edge |
| Scope resolution | new `SoundResolution` beside `AttentionAlertScope` | the four-step lookup above, pure and testable |
| Records | `Models/Project.swift` | one optional field on `AgentSession`, `Project`, `ProjectTerminal` **[verify]** |
| Row menus | `ProjectSidebarSessionActions.swift`, `ProjectSidebarViewController.swift` | the Sounds submenu beside Mute |
| Settings | `GeneralPreferencesViewController.swift` | Customize button, plus the Custom sounds section |

`AttentionAlertSound` and `TerminalBellSound` should collapse into one `SoundChoice` with a
`silent` case as part of this work. They are the same three-case shape today and were kept apart
only because the alert had no need for silence; once every event can be silenced, two types
carrying one idea is the thing that will drift.

## Data model and persistence

One additive, optional field per record:

```swift
/// Sounds this scope overrides. Absent — the common case — inherits everything.
/// Keys are `SoundEvent` raw values plus the reserved `all`; values are `SoundChoice`
/// stored strings.
var soundOverrides: [String: String]?
```

Three constraints, all of them learned the hard way in this codebase:

1. **Additive and `decodeIfPresent`, with no format-version bump.** A stored `formatVersion`
   raised for a new field has already cost this project the whole store once: one v2 panel row
   made an older build quarantine `threading.db`, and quarantine deletes the WAL holding the rows.
   See [`persistence.md`](../architecture/persistence.md). A new optional dictionary needs none of
   that.
2. **Unknown keys round-trip.** A dictionary typed `[String: String]` rather than
   `[SoundEvent: SoundChoice]` at the storage boundary means a record written by a later build,
   naming an event this build does not know, survives being read and written by it. Decode to the
   typed form for use; keep the raw map for persistence.
3. **A name is not a file.** `SoundChoice.named` stores a file name that macOS resolves later, and
   a name that resolves nowhere plays silence with no fallback. Resolution already falls back to
   the default for exactly this reason; scoping must not introduce a second path that skips it.

## Playing it: the scaling gate

A bell is driven by a PTY and can arrive as fast as a program can write a byte, so resolution sits
on a hot path and must be O(1). It is:

- `ProjectStore.locate(sessionID:)` is a dictionary lookup into `sessionLocationsByID`, then two
  array indexes — not a scan.
- Each scope is a dictionary lookup, at most six for the full chain.
- No filesystem work. `NotificationSoundLibrary.resolve` does up to three `stat`s and already runs
  per notification; for the bell it runs behind the rate limiter, so a storm cannot multiply it.

**One rate limiter, not one per event.** A bell is a sound in a room. If four events fire in the
same 200 ms the user should hear one thing, not four different custom sounds overlapping, so the
existing shared `SoundPlayer` window stays global rather than becoming per-event.

## Rejected alternatives

- **Named sound sets, assigned like themes.** Fits the app's existing three-scope vocabulary
  exactly, and was the first design. Rejected because it puts a creation step in front of the
  common case: "make this project's bell quieter" would mean naming and saving a set before you
  can apply it. Sparse per-event overrides give the same expressiveness with nothing to create.
  Worth revisiting if people end up applying the same nine-event table to many projects.
- **A sound per agent kind (Claude sounds different from Codex).** Cheap to add and genuinely
  requested elsewhere, but it answers "what is running" rather than "what needs me", and the
  project/chat scope already separates the sessions you care about. Can be layered later as
  another scope between project and app if it earns its place.
- **Letting agents choose the sound over MCP.** `notify_user` already takes a title, body and
  destination, and a `sound` parameter is one line. Rejected: an agent picking what noise your
  machine makes is a capability with no ceiling and an obvious failure mode. The user's
  `alert.requestedUpdate` setting decides how agent-requested updates sound, and the agent decides
  only whether to send one.
- **Per-event rate limiters.** Would let two causes ring simultaneously. Rejected above.
- **A badge on overridden rows.** Rejected under the design vocabulary's "quiet until relevant":
  configuration is not status.

## Scope boundaries

Out of scope for a first implementation:

- **The iOS companion.** `RemoteNotifications.swift` uses `.default` and APNs sounds must be
  bundled in the iOS app, so per-event custom sounds do not cross the wire. The remote client's
  existing per-kind sound switches are the analogue and stay as they are.
- **Volume, ducking, output device.** macOS owns these.
- **A visual bell.** Terminal.app and iTerm2 both have one and it is the right answer for "silent
  but noticeable"; it is a terminal-rendering change with its own motion-preference and
  reduced-motion obligations, and it does not belong in a routing draft.
- **Fixing the double-sound finding.** Mitigated, not fixed. See `IMPROVEMENTS.md`.

## Risks

- **Cacophony.** Nine events × three scopes is enough rope to make an app that sounds broken. The
  one-click tier being the default path is the mitigation; the Customize sheet should be reachable
  but not the first thing offered.
- **Sound is not an accessible channel.** Everything distinguished by sound here is already
  distinguished visually in the sidebar and Notification Center, and must stay that way. No event
  may become audio-only.
- **`~/Library/Sounds` is shared with macOS.** Per-project sounds will encourage adding more
  files, all of which appear in System Settings' alert-sound list. The Custom sounds section
  should say where they live.
- **Override rot.** A chat is a short-lived record; a per-chat sound outlives its usefulness fast.
  Consider whether archiving a chat should drop its overrides.

## Tests

- `SoundResolution` is pure: the full four-step chain, every scope combination, `all` versus a
  specific event, and an unresolvable name falling back rather than going silent.
- Bell-cause classification against a `SessionActivityTracker` driven through visible /
  not-visible / unattended-launch, asserting the cause the existing branches already imply.
- Round-tripping a record whose `soundOverrides` names an unknown event, proving forward
  compatibility, alongside the existing `ProjectDatabase` tests.
- The writer stores `nil` where the value matches the inherited one, so a chat keeps following its
  project — the mute tests are the template.
- A rendered-state test of the Customize sheet and the context submenu, light and dark, since the
  inherited-value parentheticals are the part that will silently go wrong.
- The rate limiter still collapses a storm when the events differ.

## Rollout

1. Collapse `AttentionAlertSound` and `TerminalBellSound` into `SoundChoice`, no behaviour change,
   existing preferences becoming the app scope's `all` entry.
2. Add `SoundEvent`, classify the bell cause in `recordBell`, and route both players through
   `SoundResolution` at the app scope only. Still no behaviour change; everything resolves to
   today's answers.
3. Add the record field, the resolution chain, and the context submenu (one-click tier).
4. Add the Customize sheet and the Settings Custom sounds section.
5. Move the durable decisions into [`session-activity.md`](../architecture/session-activity.md)
   and delete this draft, per the directory's own rule.

Steps 1 and 2 are worth landing on their own: they remove a duplicated type and make the bell's
cause explicit, both of which are improvements whether or not the scoping ships.
