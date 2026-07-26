# Design note: "make Skalman do X"

Status: core flow implemented and dogfooded. Updated 2026-07-25.

## The moment this is about

A user is in a session, talking to an agent about their own project, and says one of these:

> Skalman should show me which of these sessions are on a dirty branch.
> Can you make the sidebar show CI status?
> I want a panel that lists my open PRs.

The extension-authoring MCP group now connects that ask to the answer. It tells the agent that
Skalman can be extended, scaffolds a separate self-contained project into the sidebar, exposes
the component catalogue and preview validator, and proposes a reviewed installation. Editing
Skalman's own source remains the plausible wrong move: it needs the repo, a build and a relaunch,
and does nothing for a user who did not clone it.

The answer is an extension. This note is how the user gets from the sentence to a running one
without being handed a tutorial.

## The shape

**The ask becomes a new extension, in its own project, in the sidebar.**

That last part is the insight worth keeping. An extension under development is a software
project — source, a build, a git history, an agent working on it — and holding software projects
is the entire job of the app it is being written for. So the flow does not need a new surface:
it needs to route into the surface that already exists.

```
session in "sonda"  ──  "make Skalman show CI status"
        │
        │  the agent recognises a customization, not a code change
        ▼
scaffold  ~/Developer/Skalman Extensions/com.example.ci/
        │      skalman-extension.json, Package.swift, Sources/main.swift
        ▼
added as a project  ──  its own row in the sidebar, with a session already asking
                        the question the user asked
        │
        │  edit → build → propose install → user approves capabilities
        ▼
running extension  ──  Settings ▸ Extensions, and visible wherever it contributes
```

## Decisions

### 1. Carry the ask, not the chat

The tempting move is to fork the conversation, since forking exists and carries context
(`--fork-session`, see `HANDOFF.md`). Two reasons not to, one practical and one about what is
actually worth carrying.

**A fork cannot cross projects as things stand.** Claude resolves `--resume <id>` inside
`<config>/projects/<slug of cwd>/`, so a fork run from the new extension's folder would look for
the parent transcript under a different slug and not find it. `SessionMigration` proves a
transcript is a portable client-side file — it already copies one between account directories by
swapping a path prefix — so copying it into the new folder's slug directory is *plausible*. It
is also unproven, and it would be the second place in the codebase that rewrites where a
transcript lives.

**And most of that conversation is about the user's own project.** What transfers is the
request, not the history: the new session should start with the ask, the authoring docs, and a
scaffold — not with fifty turns about someone's Rust build. `ProjectStore.addSideChat` is the
wrong primitive here for the same reason it is the right one elsewhere: it deliberately keeps
the child in the parent's project.

So: a **new session in the new project**, seeded through the composer's existing
`pendingPrompt`, carrying the sentence the user actually said. If context turns out to matter,
the transcript-copy path is the thing to measure, and it should be measured rather than
assumed.

### 2. The source lives where the user can see it

Not in Application Support. An extension's source is something the user will open in an editor,
put under git, and eventually publish; a directory nobody can find is a directory nobody
maintains. Default to something like `~/Developer/Skalman Extensions/<identifier>/`, settable,
and **never** inside the installed package — boundary 8 says an installed package is immutable,
and that is exactly what makes source and package two different things.

That distinction is the one most likely to confuse, so the flow has to make it visible rather
than clever: **editing the source does not change the running extension.** Source is built into
a package, the package is installed, the installed copy runs. The loop is edit → build →
reload, and a UI that hid that would produce "I changed it and nothing happened" as the standard
experience.

### 3. Installing is proposed, never performed

An MCP tool that installs an extension is an arbitrary code-execution primitive: it takes a
directory and makes the app run what is in it. The codebase already has the right precedent —
`propose_storage_cleanup` puts named paths to the user and removes only what they approve, and
the gate that makes it safe is that the agent cannot name anything the host has not already
vetted.

The same shape applies: `extension_propose_install` shows the manifest, the
identifier, and — most importantly — **the capabilities it is asking for**, and installs only on
approval. Capabilities are the thing being approved; the packaging item in `HANDOFF.md` already
requires that a capability change be visible before an update is enabled, and a first install is
the same question asked for the first time.

Nothing auto-installs. Nothing auto-enables. An agent that could quietly grant itself
`network.client` and `storage.secrets` by writing a manifest would make every other boundary in
this platform decorative.

### 4. Reload is a development mode, not a free action

After the first approval, the inner loop wants to be fast: change a line, rebuild, see it. But
the code has changed since the user approved it, so an unconditional `reload_extension` re-runs
something nobody looked at.

The honest resolution is a **development install**: an extension the user has explicitly pointed
at a source directory, which Skalman will rebuild-and-reload on request without re-approving
each time, and which is visibly marked as such wherever it appears. That matches
`HANDOFF.md`'s existing line that source-only execution stays a developer workflow, and it keeps
the ordinary install path — where the user approves a package, not a directory — unchanged.

A capability *change* re-prompts even in development mode. That is the one thing the mode
cannot be allowed to smooth over.

### 5. Two views of one thing

The extension appears twice, and the split is not accidental:

- **A project row** — where it is *edited*. Sessions, branches, git review, the shell drawer:
  everything the app already gives a piece of software being worked on.
- **Settings ▸ Extensions** — where it is *run*. Enabled, disabled, reloaded, its status, its
  capabilities, its failures.

They should link to each other, because the question "why is my panel not showing" is answered
in one and asked in the other.

## What must not happen

- **Editing Skalman's own source in response to a customization ask.** If a user genuinely
  wants to change the app, that is a different act and the agent should say so plainly rather
  than quietly doing something that cannot work.
- **Silently doing nothing when the ask does not fit.** If the request cannot be expressed
  through a documented contract, the agent should name the missing surface. `HANDOFF.md` asks
  for exactly this evidence — "treat missing APIs encountered by these extensions as evidence" —
  and this flow is where that evidence will actually be generated, by users rather than by us
  guessing.
- **Scaffolding into the user's current project.** The extension has nothing to do with the
  repository the conversation happened to start in.

## The SDK dependency

The dependency shape is decided: a scaffold receives the exact SDK snapshot Skalman ships,
under `Vendor/SkalmanExtensionKit`, and its `Package.swift` uses that relative path. The
snapshot carries `SDK_VERSION`.

The matching authoring contract is scaffolded beside it at `Vendor/docs/extensions`. The
generated project README points first to `AGENT_AUTHORING.md`, then `API_V1.md`, schemas, and the
generated component catalogue. Because the packager retains the whole project under `Source/`,
a later agent can understand, audit, fork, and rebuild the extension without this repository or
a network fetch.

That keeps a project under `~/Developer/…` buildable without the Skalman repository or a
network fetch, and the project retained under the distributed package's `Source/` records the
API source it actually used. An SDK upgrade is a visible source change and package update.

Every app build now embeds the filtered snapshot under
`Contents/Resources/ExtensionSDK/SkalmanExtensionKit`, and a hosted test verifies its version,
manifest, public source, and absence of `.build`. `extension_scaffold_project` copies it into an
atomic project, adds that project to the sidebar, and writes a visible starter panel plus
`Scripts/package.sh`. That script runs the selected official Swift/Wasm SDK and atomically
assembles `Build/<identifier>.skalmanextension` with the entire editable project under `Source/`.
WebAssembly packages without rebuildable Swift source are refused.

The read-only authoring tools — `extension_list_components`,
`extension_describe_component`, `extension_preview_component_patch`,
`extension_validate_component_patch` — let an agent design against the real contracts before a
single line compiles. `extension_propose_install` then inspects the assembled package, shows its
local/unsigned origin, runtime, and complete capability set, and copies it only after the user
chooses **Install Disabled**. The manual Settings import uses the same proposal.

An opt-in hosted dogfood test executes that exact generated path against the official
Swift 6.3.2 WebAssembly SDK: app-shipped snapshot → scaffold → policy plugin → Wasm compile →
generated package script → source-bundled package → disabled app-owned install with provenance →
signed Wasm runner registration.

## Optional follow-ups, outside safe v1

1. Create and pre-seed a first session in the scaffolded project with the user's exact ask.
   Today the project is added to the sidebar and the calling agent continues the work.
2. Add a visibly marked development-install/watch mode for automatic rebuild and reload.
   Ordinary immutable packages deliberately keep the explicit build → review → update loop.
3. Link the source project and its installed Settings entry in both directions.
