# Agent Browser

The live browser an agent drives, kept separate from the rendered-document web view.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

The live browser and the rendered-document web view are deliberately separate. Each live
`BrowserViewController` uses the persistent website data store and can carry authenticated state;
agent access therefore goes through an app-level origin grant even though Threading's MCP server
itself is pre-approved. Localhost is admitted for development, other origins offer once,
persistent-host, or deny choices. After an action navigates, the new origin is checked before
any resulting page state is returned.

`BrowserAgentBridge` reads the page into a compact accessibility-oriented snapshot. Interactive
elements receive stable `eN` refs kept in WebKit's isolated client world; click, hover, type,
drag, select, key and scroll tools prefer those refs over guessed CSS. Hover sends DOM
pointer/mouse events and mirrors page-readable `:hover` rules onto an isolated bridge attribute.
Snapshots are bounded, but a truncated result is recoverable: `browser_snapshot` accepts a stable
ref or deep selector as its scope and walks that subtree, including open shadow roots and
same-origin frames, instead of forcing every read to restart at the top of a large document.
Selectors used for a single target are strict across that same composed tree: zero or multiple
matches fail instead of silently choosing the first element. Mutating, wait, and element-screenshot
tools also accept a rerender-safe semantic locator using an exact accessibility role plus optional
name, an associated form label, or a test id. Semantic locators are resolved immediately before the
action, stay strict, and may opt into a case-insensitive name/label substring only when the result is
still unique.
Drag sends both pointer/mouse gestures and the HTML drag/drop sequence, covering application
drag handles and standard drop zones without moving the user's cursor. WKWebView derives genuine
hover from the physical pointer even when given a synthetic AppKit event, and moving the user's
cursor is not an acceptable agent side effect. Native select controls expose a bounded option
list so the agent can choose an exact label or submitted value instead of synthesizing arrow keys.
`browser_fill_form` batches up to twenty-five editable, select, checkbox, radio, or switch targets
from one current snapshot. It resolves the complete ref/selector set and validates every requested
value kind before dispatching the first page event, including targets inside open shadow roots and
same-origin frames. Duplicate fields, read-only or disabled controls, invalid or disabled options,
file inputs, and password fields reject the batch without changing earlier fields. A rerender can
still detach a prevalidated target while the batch is running; that stops at the affected field and
reports how many earlier fields completed, since replaying page events to simulate rollback would be
less safe than reporting the partial result. The batch never opts into form submission, and its one
browser-level navigation guard blocks indirect `requestSubmit()` calls from input or change handlers.
Click sends pointer-down/up and mouse-down/up around activation, with bounded single/double and
left/right/middle variants; right clicks reach page context-menu handlers without opening native
browser chrome. For canvas, WebGL, maps, and similarly visual content without a semantic target,
`browser_click` also accepts one viewport-relative CSS-pixel x/y pair. Hit-testing descends through
open shadow roots and same-origin frames without moving the user's cursor; refs remain preferred
because they survive layout changes. Double submission and double file-input activation are
refused, and coordinate clicks cannot activate file selection. Screenshots are normalized to
CSS-pixel resolution, so their PNG coordinates map one-to-one to coordinate clicks even on Retina
displays. `browser_screenshot` can also isolate one current ref or deep selector. It scrolls that
target into view, waits for stable geometry, translates same-origin frame coordinates into the top
surface, and captures only the target's visible rectangle; if a frame or viewport clips an
oversized element, the result says so rather than implying the hidden pixels were captured.
Key presses focus an explicit target and send cancellable keydown/keypress/keyup events before
supplying the native defaults synthetic WebKit events lack: Tab and Shift-Tab traversal, Enter and
Space activation, select/radio movement, and stepped number/range changes. Page `preventDefault`
wins, Command/Control/Option combinations stay page-owned rather than invoking fallback actions,
and sequential focus crosses accessible same-origin frame boundaries in document order.
Browser waits poll bounded page text, exact/partial/regex URLs, document titles, captured network
responses, selector counts, or element conditions instead of relying on arbitrary sleeps. Element
waits use the same strict ref/selector/semantic-locator resolution and can check state, exact
non-password value or text, attribute presence/value, and focus. Every document-bound poll is tied
to one page identity and origin-authorized before its result is inspected; navigation during the
grant or evaluation retries against the replacement document, and the final snapshot is authorized
again before it is returned.
Checkable controls expose `checked`, `unchecked`, or `checked=mixed`; `browser_set_checked` is
idempotent and uses the page's own click behavior, so an already-correct control is never inverted.
Every mutating action returns a fresh snapshot.
`browser_history` gives the agent the same back, forward, reload, and reload-from-origin
affordances as the native chrome. The last uses public `WKWebView.reloadFromOrigin()` to perform
end-to-end revalidation with cache-validating conditionals when WebKit can, matching the current
page's navigation semantics without clearing the shared website data store or reconstructing a
possibly non-GET request. It is deliberately named `reload_from_origin`, not “ignore cache”:
Chrome DevTools can disable its page cache, but WebKit exposes no honest per-tab equivalent.
Every history action resolves and authorizes the destination before moving, refuses if the shared
history changed while a grant sheet was open, and authorizes the final URL again after redirects.
`browser_navigate` and document-changing `browser_history` actions accept `wait_until=commit`,
`domcontentloaded`, or `load`, with full load as the backward-compatible default. Commit comes
from WebKit's main-frame navigation delegate; DOMContentLoaded comes from a main-frame-only user
script and message handler in WebKit's isolated client world, so page JavaScript cannot forge or
suppress it. Earlier readiness still passes through the same final-origin authorization before
returning partial page state. There is deliberately no `networkidle`: pages commonly keep useful
background connections open, and agents can express the actual condition with `browser_wait`.
`browser_stop` uses public `WKWebView.stopLoading()` to cancel every outstanding resource for the
active page while keeping its committed document, history, cookies, and tab alive. It is
idempotent and returns a fresh snapshot even when the page was already idle, so an agent can
recover from a streaming or hung load without guessing whether cancellation raced completion.
The current URL is captured before the origin grant and compared again before stopping; the final
origin is authorized once more before partially rendered page data is returned. The native reload
button mirrors ordinary browser chrome by becoming a visible Stop control while WebKit is loading.
`target=_blank` and `window.open` use a bounded in-surface `WKWebView` stack rather than being
rebuilt as a GET in the opener. That preserves the original request plus `window.opener`,
`postMessage`, and `window.close` for OAuth and account-linking flows. The visible pop-up has an
explicit close control; Back closes it and returns to its live opener when it has no own history.
Only the active page may add another pop-up, so a hidden opener cannot take the surface back.
`browser_tabs` manages up to eight independent `BrowserViewController`s per session. Each keeps
its own page, history, pop-up stack, responsive viewport, color scheme, CSS media type, User-Agent,
console, and network buffers. A shared context uses the default website data store so signing in
does not create cookie islands; a private context owns one unique non-persistent store and shares
no cookies with the signed-in browser or another private tab. Private tabs and even their URLs are
runtime-only and excluded from panel persistence. The agent addresses tabs by browser-local index
or stable tab id. The most recently selected browser remains the browser-tool target when an image
or document temporarily takes the panel, which matters because showing a browser screenshot itself
creates an image tab. A blank shared browser is not persisted, and live browsers are never silently
evicted at the cap. Listing tabs never prompts and withholds a browser's page-controlled title and
URL until that origin has already been allowed; the generic panel-tab list applies the same
boundary. The panel's `+` menu creates shared and private browser tabs at the same cap, so control is
symmetric for the user and agent.
Remote Access treats the Mac browser as the sole navigation and interaction owner. A successful
agent `browser_navigate`, history move, or new-tab action emits an owner-only Workspace activity
with a stable id; the paired iPhone records whether that id has been seen on that device and shows
one ambient Workspace badge instead of navigating. Lower-level interaction mutations emit an
invalidation without a new activity id, so a visible read-only follow view refreshes without
animating the badge for every click or scroll. The follow route fetches bounded metadata and a PNG
of only the currently visible shared tab on demand. It does not construct a second `WKWebView`,
send input back to WebKit, or run a continuous pixel stream. Page titles are bounded, URLs use the
same redactor as other remote diagnostics, and private tabs expose only a generic placeholder
with no preview. Both REST reads and WebSocket activity require paired owner scope.
`browser_storage clear_site_data` removes the active site's WebKit-owned cookies, caches, storage,
IndexedDB, and service-worker data only after a separate app-owned confirmation. An origin grant,
including an "always allow" grant, never implies permission to delete signed-in state. The
confirmation is bound to the exact tab and document; a page or tab switch cancels before removal.
A private tab clears its entire unique store. A shared tab filters WebKit's site-level data records
to the active host or the parent record WebKit grouped it under, and tells the user that related
subdomains may therefore be signed out. Clearing does not implicitly reload or reconstruct the
current request.
`browser_resize` gives the active browser an exact per-tab CSS-pixel viewport for responsive
testing. It does not resize Threading's window: the fixed-size `WKWebView` sits in a pannable outer
scroll view, so media queries, viewport units, semantic geometry, interactions, and screenshots
all agree while the user can still inspect a desktop viewport inside a narrow panel. The native
device toolbar and `browser_resize` update this same state; neither keeps a second visual-only
size. The toolbar offers editable dimensions, rotation, and named desktop, tablet, foldable, and
phone viewport presets. It folds its label and preset picker into the browser overflow as space
shrinks. Closing the toolbar resets the page to the panel, omitting both tool dimensions does the
same, and navigation and pop-ups inherit the active size. Presets describe CSS viewport dimensions
only: they do not imply touch, device scale, mobile identity, or a different browser engine. The
override is deliberately runtime-only testing state.
`browser_emulate` applies public per-view WebKit conditions to the active tab. `NSAppearance`
makes `prefers-color-scheme`, matchMedia, rendered pixels, and screenshots agree without changing
Threading's window or global appearance; `WKWebView.customUserAgent` changes JavaScript identity and
future HTTP requests without rewriting request headers in app code; and `WKWebView.mediaType`
switches CSS, matchMedia, rendered pixels, and screenshots between screen and print. Dark, light,
screen, print, auto, and the bounded custom User-Agent are per-tab runtime-only conditions;
navigation and pop-ups inherit them. Separate visible controls return appearance, CSS media, and
User-Agent to WebKit defaults, while an empty `user_agent` resets it through the tool. A User-Agent
change deliberately does not reload: the agent uses `browser_history reload` when server-rendered
branching must be fetched again, avoiding an implicit repeat of the current request. Resize and
emulation changes run under the browser-level navigation guard because page handlers, including
matchMedia listeners, can indirectly submit a form, then reuse the normal final-origin
authorization before page state is returned.

`browser_capabilities` is the honest boundary around those features. It returns a versioned,
machine-readable backend matrix without reading page-controlled content or asking for an origin
grant. The in-app WebKit backend explicitly reports locale, time zone, geolocation, permission,
offline, network-condition, touch/mobile, device-scale, reduced-motion, forced-colors,
request/response interception, engine selection, and per-tab cache disabling as unsupported.
Those conditions remain the host's real conditions; they are never approximated with page scripts,
request-header rewriting, or misleading names. Agents can therefore choose a separate isolated
automation backend when a test actually depends on one of them.

`browser_run_isolated` is that separate backend, not a replacement for the visible browser. One
call launches a locally installed Python Playwright runtime, creates a fresh non-persistent
Chromium, Firefox, or Playwright-WebKit context, runs at most fifty strict semantic/CSS steps, and
closes both context and browser. It can honestly emulate viewport, locale, time zone, geolocation,
permissions, offline state, touch/mobile behavior, scale factor, colour/media preferences, and
User-Agent. It never imports the in-app browser's cookies, credentials, storage, history, or
certificate state; downloads, password fills, arbitrary JavaScript, persistent profiles, and
network interception are deliberately absent. The app bundles only its small audited bridge, not
Playwright's hundreds of megabytes of version-coupled browsers. If the local package or matching
browser binary is absent the tool returns the exact install command and does not download anything
implicitly. Optional final screenshots are size-bounded, cached with the existing rolling browser
artifacts, and can be returned as an MCP image.
Page-world user scripts capture console/error output and network metadata, because isolated-world
wrappers cannot see calls made through the page's own `console`, `fetch`, or XHR. Network capture
never records request or response bodies, headers, cookies, or credentials, and sensitive query
values are redacted before they can leave the browser controller. A capture-phase resource-error
listener supplies metadata-only failures for images, scripts, stylesheets, and media that never
produce a usable Performance Resource Timing entry.
`browser_performance` complements those event buffers with a bounded, current-document Web
Performance summary: navigation milestones, paint timing, buffered LCP/layout-shift/long-task
observations when WebKit exposes them, aggregate resource sizes, and only the slowest requested
resources. Resource URLs cross the bridge only to be redacted before agent output; raw traces,
headers, bodies, credentials, and external field-data lookups remain outside the browser boundary.
Because buffered observers complete asynchronously, the tool authorizes the final origin again and
rejects the result if navigation changed the document while it was being measured.
`browser_trace` provides a separate, opt-in per-tab diagnostic timeline. It records only bounded
tool names, structural target kinds, success/error, duration, navigation phases, and
method/status/kind network metadata. It deliberately omits URLs, selectors, locator names, page
text, field values, console text, screenshots, bodies, headers, cookies, and credentials. The
oldest entry is dropped beyond 500 events; traces are runtime-only until explicitly exported as
one of four rolling JSON artifacts in the session cache.
`browser_visual_compare` captures the same CSS-pixel viewport, bounded full page, or strict element
scope as `browser_screenshot`, then compares it with a caller-supplied PNG baseline using a bounded
per-channel threshold and changed-pixel ratio. It saves rolling actual and diff PNG artifacts;
pixel mismatch is a successful comparison result, while invalid baselines, over-limit images,
stale documents, or denied final-origin access are tool errors. Dimensions must match—images are
never silently stretched into a pass—and a mismatch can be displayed in the panel and returned as
an MCP image block.
`browser_accessibility_audit` gives the agent a bounded development-time semantic check without
pretending WebKit contains Lighthouse. It walks visible content in the document, open shadow roots,
and same-origin frames, reporting stable refs for missing accessible names and image alternatives,
untitled frames, broken label references, duplicate ids, positive tab order, and heading jumps.
Both issue count and visited element count are capped; cross-origin frames are counted but remain
opaque. It returns no field values or browser state, labels its result as untrusted page data,
reauthorizes the final origin, and refuses a report if the page navigated during inspection.

Page text is labelled as untrusted external data in every snapshot and in the MCP instructions.
That warning comes before the page title and URL, which are themselves page-controlled; titles
are collapsed to one bounded line and credential-shaped URL parts are redacted. Console, network,
and CSS-query output carry the same boundary in their own results.

User annotations take the opposite trust path. A themed native overlay above the active WebKit
surface owns numbered pins and note text keyed to the page URL without its fragment. It declines
all hit testing outside annotation mode, so visible pins cannot block the page or agent actions.
Only a scroll-coordinate observer runs in WebKit's isolated client world; no note text is injected
into the DOM or exposed to page JavaScript. `browser_annotations` returns the current authorized
page's notes separately from the untrusted DOM snapshot, with explicit `user_authored` provenance
and document-space CSS-pixel coordinates. The agent cannot create, edit, or delete them. Annotation
mode ends on navigation, while notes remain runtime-only for a later visit to the same page URL.

Password fields refuse agent typing and reveal the browser for user takeover. Form submissions,
including Enter on a focused form control, require an app-owned confirmation whose description
is derived from the live target rather than from agent prose. A short-lived, one-shot navigation
guard also enforces that boundary in `WKNavigationDelegate`; target inspection alone is not trusted,
because an ordinary button, change handler, or drop target can call `requestSubmit()` indirectly.

The takeover is an exact-field handoff, not a credential API. When an agent reaches a password
target, Threading reveals the browser, scrolls that field into view, focuses it in WebKit's isolated
client world, and shows a themed **Private Input** affordance while a password field has focus.
A user can then accept WebKit/macOS AutoFill when the current site and platform offer it, use a
third-party password manager's macOS integration, copy from Apple Passwords, or type privately.
The observation bridge sends native code one opaque per-frame document token plus a boolean —
focused or not — and never a field name, account, or value. Native state keeps a set of focused
frame tokens so a late message from an unrelated iframe cannot hide the active handoff.

This distinction is load-bearing. Public Authentication Services password requests return an
`ASPasswordCredential` containing plaintext user and password strings to the app, while the
AutoFill-assisted request API is unavailable on macOS. Threading therefore does not call a password
provider, read a vault, or inject credentials. Any system Password AutoFill that WebKit offers,
plus WebAuthn and passkey challenges, remains WebKit- and system-owned. Ordinary password values
remain redacted from snapshots, unavailable to browser actions and waits, omitted from traces
and diagnostics, and protected by the existing form-submission confirmation after the user fills
them.

Files remain user-controlled boundaries. A plain file-input click reveals the browser and uses a
native open panel. `browser_upload` can seed that same panel with up to ten existing absolute paths,
but the user sees the suggestions, may change them, and must click Open; user-chosen paths are never
returned to the agent. The browser-level navigation guard remains active through the panel and file
input change events, so an indirect `requestSubmit()` is still blocked. `browser_download` binds one
semantic action to the next WebKit download and waits through a native save panel whose copy says
the chosen destination will be returned to the agent; cancellation and targets that do not start a
download are explicit failures. Ordinary downloads still use the same native save panel and visible
completion alert. JavaScript alert, confirm, and prompt dialogs are also native sheets tied to the
browser window. Persistent website grants can be reviewed individually or revoked together on the
Tools settings page.

Do not wait on `requestAnimationFrame` in an agent action: WebKit pauses it in an occluded
display-panel tab. Browser waits use bounded timers, navigation and snapshots have timeouts, and
full-page captures are capped to keep one tool call from pinning the app.
