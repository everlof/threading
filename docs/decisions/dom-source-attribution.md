# React/DOM source attribution

> Status: **decision record** (2026-08-12). **Reject** bundling a framework-specific attribution
> provider — React internals, source maps and all. **Wait for demand** on a thin alternative:
> reading attribution a page *already publishes* through one small versioned contract, passed
> through with `page_reported` provenance and containment-proved paths, degrading to the semantic
> answer Threading already gives. Not implementation work.

Part of the [decisions index](README.md). Read alongside
[`agent-browser.md`](../architecture/agent-browser.md) — the snapshot and ref model, the annotation
overlay's component probe, the untrusted-page-data boundary, `browser_capabilities` as the honest
boundary, and the three backends — plus
[`mcp-and-display.md`](../architecture/mcp-and-display.md),
[`execution-audit.md`](../architecture/execution-audit.md) and
[`dependencies.md`](../architecture/dependencies.md).

**The one-sentence version.** Threading's picker already hands an agent a role, an accessible name,
a test id, a stable ref and a screenshot; the delta a source-attribution provider adds is
`Component` and `file:line`, which is a *shortcut for a grep the agent can already do* — and buying
it means vendoring React's private, development-build-only fiber internals plus a source-map
consumer into a WKWebView page world, which is the largest framework-coupling this codebase would
have ever taken on for the smallest capability increment in this document set.

---

## 1. User problem and concrete use cases

1. **"This button is wrong."** The user is looking at their own dev server in Threading's browser.
   They want to tell the agent *which* button without describing it in prose.
2. **The generic label.** The element says "Save". There are nine of them. The accessible name does
   not disambiguate, and neither does the CSS selector once the class names are hashed.
3. **The design-system indirection.** The visible element is a `<button class="ui-btn">` rendered by
   `<Button>` rendered by `<PrimaryAction>`. What the user wants changed lives in the call site, not
   in the component that emitted the DOM node.
4. **The agent's search cost.** Told "the Save button in the settings dialog", the agent greps,
   finds four candidates, reads three files, and asks. A `file:line` would have skipped that.

Case 3 is the one that genuinely resists every non-framework answer. Cases 1, 2 and 4 have partial
answers today.

---

## 2. Existing Threading behaviour and overlap

**The general capability exists and is deliberate.** `BrowserAgentBridge` reads a page into a
compact accessibility-oriented snapshot, minting stable `eN` refs in WebKit's isolated client world.
Actions prefer refs over guessed CSS; selectors are strict across the composed tree (zero or
multiple matches fail rather than picking the first); and mutating, wait and element-screenshot
tools also accept a **rerender-safe semantic locator** — an exact accessibility role plus optional
name, an associated form label, or a test id — resolved immediately before the action and staying
strict. `browser_snapshot` can be scoped to a ref or deep selector and walks open shadow roots and
same-origin frames.

**A component picker already exists, for the user.** While annotation mode is on, the overlay
outlines and names the component under the pointer. Its design is directly relevant here: it
**climbs from the deepest hit element to the nearest ancestor the agent could already address** — an
existing ref, an ARIA or implicit role, or a test id — within six levels, so pointing at the word
inside a button highlights the button. The probe **mints no refs** (it reads `elementToRef` and
never writes it, so hovering cannot renumber the page under an agent mid-task), returns a box in
top-level viewport CSS pixels plus role and accessible name, runs one probe at a time with only the
newest pointer position queued, and is re-asked on scroll.

So the *interaction* — hover, outline, name, click to attach — is built. What it reports is semantic,
not source.

**The composer can already carry it.** `ConversationContextAttachment` generalized composer context
beyond image paths, with message/file/attachment entry points, transcript reconstruction and a
RemoteKit wire shape. A picked element would be one more attachment kind, not new plumbing.

**Page-controlled data already has a boundary, and it is strict.** Page text is labelled untrusted
in every snapshot and in the MCP instructions; the warning comes *before* the page title and URL
because those are page-controlled too; titles are collapsed and bounded; credential-shaped URL parts
are redacted. `browser_annotations` returns user notes with explicit `user_authored` provenance,
kept separate from the DOM snapshot — and the component probe's output is deliberately *never* added
to an annotation or a tool result, precisely so that provenance stays exactly true.

**Attribution of a different kind is already built, and its rules transfer.**
`BrowserAttributionState` is a bounded tree of visible nodes with a curated fixed list of visual
computed properties; `BrowserStructuralDiff` matches two captures on test id, then role and
accessible name, then structural position, and **never on ref equality** — because the bridge
restarts `nextRef` at 1 per document, so `e12` in two captures is not evidence of anything. A key
appearing twice produces an `ambiguous` finding rather than an invented pairing, and findings are
worded as *"associated with"* because sharing a rectangle is evidence and not proof of cause. That
vocabulary — bounded, ambiguity-preserving, evidence-not-proof — is exactly what a source
attribution needs.

**`browser_capabilities` is the precedent for saying no honestly.** It returns a versioned
machine-readable matrix and explicitly reports locale, time zone, geolocation, permissions, offline,
network conditions, touch, device scale, reduced motion, forced colors, interception, engine
selection and per-tab cache disabling as **unsupported** in the WKWebView backend, so an agent can
choose `browser_run_isolated` instead. A framework attribution provider would be one more row in
that matrix, whatever the answer.

**Page-world injection at document start is established.** `consoleCapture` and `networkCapture` are
installed as `WKUserScript`s at `.atDocumentStart` in all frames with no `in:` world argument — i.e.
the **page world** — on the stated reasoning that isolated-world wrappers cannot see calls made
through the page's own `console`, `fetch` or XHR. Everything else (`navigationReadiness`,
`passwordFocusObservation`, `annotationViewportObservation`) is `.defaultClient`. So the mechanism a
React hook would need exists and has a precedent; what does not exist is a precedent for injecting
*third-party* code into it.

**Dependency posture.** [`dependencies.md`](../architecture/dependencies.md) covers four local Swift
packages, all forks Threading owns. The only vendored JavaScript is
`Sources/Threading/Resources/RemoteClient/xterm.js` (277 KB) and the hand-written `app.js` beside
it — served to the remote client, not injected into the user's own pages. Worth noting while it is
in view: `xterm.js` does not currently appear in `Legal/THIRD_PARTY_NOTICES.md`, which
`scripts/check_bundled_licenses.sh` gates on for the components that *are* listed. Adding a second
vendored JS bundle should not happen before that is resolved either way.

---

## 3. Lessons from t3code

Read from the local clone at `edc503a7a`.

**They do not implement it. They depend on it.** `apps/desktop/src/preview/PickPreload.ts` imports
`getElementContext` from **`react-grab/primitives`** (`"react-grab": "^0.1.32"` in
`apps/desktop/package.json`) and calls it inside an Electron preload with Node integration. The
preload's own contribution is the overlay, the hit testing and the IPC.

`PickedElementPayload` is what crosses: `pageUrl`, `pageTitle`, `tagName`, `selector`,
`htmlPreview`, `styles`, `componentName`, `source` (one stack frame) and `stack` (all of them), each
frame being `{ functionName, fileName, lineNumber, columnNumber }`, every field nullable.

Two things they got right and both should be copied:

- **A strict structural validator in its own Electron-free module**, with the reason written down:
  a malformed payload — "preload bug, future schema mismatch, malicious page that intercepts the
  preload's IPC channel via prototype pollution" — would otherwise throw deep in the renderer and
  the chip would silently never appear. They treat their own picker's output as untrusted input.
- **Clamping on the way into the draft.** `normalizeElementContextSelection` trims and truncates
  every string (`htmlPreview` and `styles` at 4,000 characters each) so a 5 MB `outerHTML` never
  reaches persistence.

What they do **not** do: prove the returned `fileName` is inside the project; distinguish confidence
levels; degrade to a stated semantic answer when attribution is absent (`componentName` and
`source` are simply `null`); or say anything about production builds.

**What `react-grab` actually reads.** Measured from the published tarball
(`react-grab@0.1.50`, MIT, depends on `bippy@^0.6.1`): the distribution references
`__REACT_DEVTOOLS_GLOBAL_HOOK__` (32 occurrences), fiber `_debugStack` (26), `_debugOwner` (13),
`_debugSource` (10), `_debugInfo` (5), and `sourceMappingURL` (6). Its `getElementContext` returns
`{ element, snippet, htmlPreview, stackString, stack, componentName, filePath, lineNumber,
columnNumber, fiber, selector, styles }` — with `filePath` documented as e.g.
`"/src/components/Button.tsx"`.

So the mechanism is: install React's DevTools global hook **before React initializes**, walk the
fiber tree from the DOM node, read the debug fields React attaches **in development builds only**,
and resolve bundled positions back to source through source maps. Its own README installs it under
`process.env.NODE_ENV === "development"` for every framework it documents (Next.js App Router,
Pages Router, Vite). The IIFE build is 386 KB. It is at `0.1.50` while t3code pins `^0.1.32` — a
0.x package moving fast enough that the caret range spans eighteen releases.

---

## 4. Proposed domain and host contract

Two designs are specified: the one being rejected, so the rejection is arguable, and the thin one
being deferred.

### 4.1 The rejected design: a bundled framework provider

What it would take in Threading, and why each line is a cost rather than a task.

- **Injection.** A `WKUserScript` at `.atDocumentStart` in the **page world** — the world
  `consoleCapture` already uses — installing the DevTools global hook before the page's own scripts
  run. Isolated worlds cannot do it: they have a separate global object, so a hook set there is
  invisible to React. This means Threading executes third-party code in the page's own world on
  every page the user browses, including signed-in ones, because injection must happen before it is
  known whether the page is React.
- **Vendoring.** 386 KB of minified third-party JavaScript, at a 0.x version, reading React private
  fields, as a build resource with a legal notice — see §2 on the existing gap.
- **Source maps.** Turning a bundled position into a repository path requires consuming
  `sourceMappingURL`, which for a dev server means fetching the map. That is a network read
  performed by Threading's browser on the user's behalf, against an origin the grant covers for
  *page* content — and a decision about whether an inline `data:` map, an external map on another
  host, or a map behind auth is fetched at all.
- **Path resolution.** The library returns a path the *page* asserts. Turning `/src/components/Button.tsx`
  into a repository file requires knowing the project root, and proving containment, and deciding
  what to do when the page names `/Users/someone-else/...` or `../../../etc/passwd`.
- **Framework coupling.** `_debugSource` is React ≤18; `_debugStack`/`_debugOwner` are React 19's
  shape; both are private and both are absent from production builds. Vue, Svelte, Solid, Angular
  and every other framework need their own provider or get nothing. The provider's correctness is a
  function of a version matrix Threading does not control and cannot test against.

### 4.2 The deferred alternative: read what the page publishes

The insight is that `react-grab` **exposes `window.__REACT_GRAB__`** in its global build, and a
developer who wants this already installs it (or a Vite/Next plugin like it) in their own dev
build. Threading does not need to *be* the instrumentation; it needs a contract for *reading* one.

**The contract**, if it is ever built:

1. **One versioned page contract, framework-neutral.** Threading looks for a single well-known
   global exposing `{ version, describeElementAtPoint(x, y) }` or equivalent, returning
   `{ componentName?, filePath?, line?, column?, framework?, confidence }`. Threading publishes the
   shape; adapters — including a two-line shim over `__REACT_GRAB__` — are the page's business, and
   can live in this repository's docs as an example rather than in the app as a dependency.
2. **Threading vendors nothing and injects no third-party code.** The probe is a few lines in the
   isolated client world calling a page-world global through the existing bridge, exactly as bounded
   as the component probe already is.
3. **Absent contract ⇒ absent field.** No detection heuristics, no "looks like React", no fallback
   to reading fibers ourselves. `browser_capabilities` reports
   `source_attribution: unavailable | page_provided`.
4. **Provenance is `page_reported`, always.** It rides beside — never inside — the semantic answer,
   and never inside `browser_annotations`, whose `user_authored` claim must stay exactly true. This
   is the same separation the component probe already maintains.
5. **The path is untrusted input and is resolved, not trusted.** Before it is shown or returned:
   reject absolute paths outside the session's execution checkout; reject any `..` component; resolve
   symlinks and prove the root prefix; require the file to exist and be a regular file. A path that
   fails any of these is **dropped**, and the attachment says attribution was unavailable — it is
   never shown as a path the agent might then read. This reuses `repositoryFile`'s discipline
   including its `ls-files` membership check, because the path came from the least trustworthy
   source in the app.
6. **Confidence is stated, not implied.** Three levels are enough: `exact` (a contained path and a
   line), `component-only` (a name, no usable path), `none`. The wording follows
   `BrowserStructuralDiff`'s: *associated with*, not *defined at*.
7. **Everything is bounded and clamped at the boundary**, t3code's rule: component name, path,
   `htmlPreview` and `styles` all truncated before they reach a draft, a tool result or a
   transcript.
8. **Iframes.** Same-origin frames are walked as the bridge already does, with coordinates
   translated into the top surface; cross-origin frames are **counted and opaque**, the answer
   `browser_accessibility_audit` already gives.
9. **Minified production pages** return `none` and say so. No guessing from class names, no
   heuristic component naming.
10. **The other two backends are out of scope.** `browser_run_isolated`'s checkable promise is that
    nothing authenticated is reachable, and `browser_attach_chrome` is a one-shot batch subprocess
    with no callback into the app — adding a flag to either is how a promise like that gets broken.

**Degradation is the product**, not an error path: with no page contract, the picker returns exactly
what it returns today — role, accessible name, test id, ref, bounded HTML preview, styles and a
screenshot. That is a good attachment. The source line is a bonus that is either present and proved,
or absent and stated.

---

## 5. Security, privacy, destructive-action and scaling analysis

**The page is hostile until proved otherwise, and this feature's whole input comes from it.**

- **A page-supplied path is an attack surface.** Its purpose is to make an agent open a file. A page
  that returns `/Users/x/.ssh/id_rsa` or `../../.env` is asking Threading to hand the agent a
  location to read, in a session where the agent has an unrestricted shell. §4.2(5) is therefore the
  load-bearing clause, and dropping rather than reporting is deliberate: reporting a rejected path
  still tells the agent the path.
- **A page-supplied component name is prompt-injection carrier text.** It is page-authored prose
  reaching the model. It gets the same treatment page titles do: collapsed to one line, bounded,
  and delivered under the untrusted-data label that already precedes snapshot content.
- **Page-world injection is the risk the rejected design adds.** Isolated-world scripts cannot be
  observed or replaced by the page; a page-world script can be. Injecting a 386 KB third-party
  bundle into the page's own global on every navigation — including on signed-in origins the user
  granted for *reading* — is a materially larger surface than the two small capture shims that are
  there today, and it would be running before the origin grant is even evaluated, since it installs
  at document start. The deferred design injects nothing.
- **Source-map fetching is a network request Threading makes.** It must not happen implicitly; if it
  is ever needed it is a separate, stated capability with its own origin rule, not a side effect of
  hovering.
- **The execution audit already covers the output.** A picked-element attachment reaching the
  composer is a tool result and is recorded exactly, so a page-reported path is preserved as
  evidence of what the page claimed.

**Privacy.** Nothing new leaves the machine in the deferred design. In the rejected one, a source-map
fetch could reach a third-party host named by the page.

**Destructive.** Nothing here writes. The harm model is entirely *misdirection*: an agent confidently
editing the wrong file because attribution named it. That is why confidence is a field and why the
wording is "associated with".

**Scaling.** Apply the [scaling gate](../../CLAUDE.md#scaling-gate):

- One probe at a time with only the newest pointer position queued — the rule the component probe
  already follows, and pointer movement is the highest-frequency callback in the app.
- No walk proportional to the document: the probe asks about one element.
- No fiber-tree traversal on the main actor; the page world does its own work and the result crosses
  bounded.
- The rejected design fails this gate at injection time rather than at probe time: a 386 KB script
  parsed and executed at document start on **every** navigation is a cost paid by every page,
  including the ones with no React in them.

---

## 6. Dependencies on earlier roadmap goals

Shipped and sufficient for the deferred design: `BrowserAgentBridge`'s isolated-world evaluation and
snapshot bounds, the annotation overlay's component probe and its ancestor-climbing rule,
`ConversationContextAttachment`, `browser_capabilities`' matrix, the untrusted-page-data labelling,
`repositoryFile`'s containment discipline, and the execution audit.

Owed for the deferred design: one published page-contract shape, one bounded probe, one attachment
kind carrying provenance and confidence, one capability row, one containment check, and a documented
example shim.

Owed for the rejected design: all of the above, plus a vendored bundle, a legal notice, a
page-world injection policy, a source-map consumer, a project-root resolver, and a per-framework
version matrix.

---

## 7. Smallest shippable slice

Only if §12's trigger fires: the deferred design, **read-only, React-agnostic, one framework
example**.

- The published contract in §4.2(1), documented rather than implemented.
- The picker attaches `componentName` and a contained `filePath:line` when the page provides them,
  with `page_reported` provenance and a confidence level.
- `browser_capabilities` grows one row.
- Everything else — degradation, bounds, containment, iframes, minified pages — per §4.2.

Explicitly **not** part of the slice: any code that knows what a React fiber is.

---

## 8. Explicit non-goals

- Vendoring `react-grab`, `bippy`, or any framework-internals library.
- Reading `__REACT_DEVTOOLS_GLOBAL_HOOK__`, `_debugSource`, `_debugOwner`, `_debugStack` or
  `_debugInfo` from Threading's own code.
- Injecting third-party JavaScript into the page world.
- Consuming source maps, or fetching a `sourceMappingURL`.
- Detecting the framework, or guessing a component name from class names, `data-*` conventions or
  file naming.
- Returning any path Threading has not proved is a regular file inside the session's execution
  checkout.
- Adding attribution to `browser_run_isolated` or `browser_attach_chrome`.
- Letting attribution enter `browser_annotations`, or letting the probe mint refs.
- Replacing or de-emphasising the semantic picker. It is the general capability; this would be an
  optional annotation on it.
- Claiming a component *defines* an element. Attribution is association.

---

## 9. Acceptance and failure tests

Acceptance (deferred design):

1. A page exposing the contract returns component name and a contained path; the attachment carries
   both, `page_reported` provenance and `exact` confidence.
2. A page not exposing it returns the semantic answer unchanged, with attribution stated as
   unavailable — and the picker's existing role/name/box output is byte-identical to today's.
3. `browser_capabilities` reports the state without prompting for an origin grant and without
   reading page content, which is its existing contract.
4. The component name is collapsed to one line and bounded before it is drawn or returned.
5. An element inside a same-origin iframe resolves with coordinates translated to the top surface;
   a cross-origin iframe is counted and opaque.
6. The probe mints no refs: `elementToRef` is unchanged across a hundred hover probes.

Failure, each degrading to the semantic answer with attribution absent and **nothing** page-supplied
reaching the agent:

7. The page returns a path containing `..`.
8. The page returns an absolute path outside the execution checkout.
9. The page returns a path inside the checkout that does not exist, or is a directory, or is a
   symlink pointing outside.
10. The page returns a 200 KB component name.
11. The page returns a malformed object, a Promise that never settles, or throws — the probe times
    out and the picker still works.
12. The page redefines the global between probes, or defines it as a getter with side effects.
13. A minified production build: `none`, stated, with no guess.
14. Two elements report the same path and line — allowed, reported as-is; the feature does not
    dedupe or infer.

---

## 10. Estimated complexity and maintenance burden

**Deferred design: small to implement, low to maintain.** One probe, one attachment field, one
capability row, one containment check. The contract is Threading's own, so nothing upstream can
break it; a page that stops providing attribution degrades to today's behaviour.

**Rejected design: moderate to implement, and the maintenance is unbounded and not ours.** The
correctness surface is `{React version} × {bundler} × {dev/prod} × {source-map style} × {library
version}`, none of which this project controls or can test in CI. `react-grab` is `0.1.x`; React's
debug fields are private and have already changed shape once between 18 and 19. This is precisely
the coupling [`dependencies.md`](../architecture/dependencies.md) avoids by owning forks of
everything it depends on — and a fork of a React-internals library is a fork of React's release
schedule.

---

## 11. Recommendation

**Reject the bundled framework provider.** The value is real but small — it saves the agent a grep —
and the cost is the largest external coupling in the codebase, injected into the page world of every
site the user visits, for a capability that evaporates in production builds and outside React.

**Keep the semantic picker as the general capability**, unchanged. It already answers cases 1 and 2
well, works on every page including production ones, and costs nothing.

**Wait for demand on the page-published contract.** It is the version of this feature that fits: the
developer who cares about case 3 opts in on their own dev build, Threading reads it under the
provenance and containment rules it already has for everything else the page says, and a page that
says nothing costs nothing.

**And name the cheaper answer to case 4 out loud**, because it may be the whole answer: the agent has
a shell and a repository. Given a role, an accessible name and a bounded HTML preview, "find where
this is rendered" is a two-minute grep it does well. The `file:line` is a convenience, not a
capability, and the feature's value should be judged against an agent that greps competently rather
than against one that guesses.

---

## 12. What should reopen this

**Build the page-published contract** when a user working on a React or Vue app reports that the
picker's semantic answer is not enough to disambiguate — specifically case 3, where the element the
agent finds is the design-system component rather than the call site the user meant. One clear
report is enough; the slice is small.

**Reopen the bundled provider** only if all of these change:

- browsers or frameworks expose element→source attribution through a **public, stable** API, so it
  stops being private-internals archaeology (a standardised `data-source` convention emitted by
  bundlers in dev would do it, and would also make §4.2 the right implementation of it); and
- the attribution survives production builds, which today it structurally cannot; and
- it is framework-neutral, so it is a browser capability rather than a React feature.

**Watch, separately and for a different reason:** `react-grab`'s own trajectory. If it becomes the
de facto thing developers already have running in their dev builds, the page-published contract gets
cheaper — the shim is two lines over `window.__REACT_GRAB__` — and demand for it will show up as
users asking why Threading's picker does not see what their other tools see. That question is the
trigger for §7, not for the rejected design.

**Housekeeping, unrelated to whether this ships:** resolve `xterm.js`'s absence from
`Legal/THIRD_PARTY_NOTICES.md` before any second vendored JavaScript asset is considered.
