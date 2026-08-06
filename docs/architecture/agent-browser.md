# Agent Browser

The live browser an agent drives, kept separate from the rendered-document web view.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

The live browser and the rendered-document web view are deliberately separate. Each live
`BrowserViewController` uses the persistent website data store and can carry authenticated state;
agent access therefore goes through an app-level origin grant even though Threading's MCP server
itself is pre-approved. Localhost is admitted for development, other origins offer once,
persistent-host, or deny choices. After an action navigates, the new origin is checked before
any resulting page state is returned.

Browser traces remain bounded diagnostics returned to the agent. They are not the user's execution
history. The [Execution Audit](execution-audit.md) records the exact structured browser tool calls,
results and permission decisions instead; its Browser split embeds this same live controller and
filters the ledger to Browser events.

**"Localhost" has to mean the loopback and nothing wider**, because `BrowserOrigin.isLocal` is
the one answer that skips the prompt outright — `hasBrowserAccess` returns true on it alone. It
was `host.hasPrefix("127.")`, and `127.` is a legal subdomain label: `127.evil.com` is an
ordinary domain anyone can register, and it read as this machine and was handed the browser's
signed-in state with no prompt at all. The octets are parsed now — four dotted, all plain ASCII
digits, all 0–255, the first exactly 127 — so a hostname cannot pass by looking like an address.
`.localhost` stays a *suffix* test on purpose: RFC 6761 reserves the whole TLD for the loopback,
so `sub.localhost` genuinely is this machine.

## What the grant prompt guarantees

The prompt is the whole of the security this feature offers: an agent reaching a signed-in
browser is stopped by one alert, and everything downstream trusts the answer. So the promises it
makes are listed here, each one enforced by something that fails rather than by care at the call
site. A change that cannot keep one of these is a change to the contract, not an implementation
detail.

**1. Nothing is guessed into existence.** An input that cannot be resolved to a page this browser
opens is refused; it is never rewritten until it looks like one. This is the rule that broke:
`normalizedURL` prefixed `https://` onto anything containing a dot, so an agent asking for
`file:///notes.html` produced `https://file:///notes.html` — whose *host* is the word `file` — and
the alert read "Allow the agent to use file?", about a host that does not exist. A scheme with no
host is now honoured or refused, never prefixed, which also keeps a local path out of the search
fallback. The port form still gets its prefix, because `example.com:8080/x` parses its own host as
a scheme — the test is on what follows the colon, not on the colon. A foreign scheme that *does*
carry a host (`ftp://files.example.com/x`) stays as written and dies at `BrowserOrigin`, so no
prompt is raised for it at all.

**2. The prompt names the exact page.** The title carries the host, because the host is what the
grant is keyed on; the body carries the URL that will load. A host alone cannot answer the
question — one host serves both an article and an account page. `BrowserOrigin.displayURL` cuts
from the tail at 120 characters so padding cannot push the origin off screen, drops Cc/Cf scalars
so a bidi override cannot visually reorder a host, and removes credentials: this is the one place
the shown string deliberately differs from the loaded string, because `https://example.com:pw@evil.example/`
is a page on evil.example that reads as example.com, and a password does not belong in an alert.
The true host is stated separately for exactly that reason.

**3. What was approved is what loads.** `authorizeBrowserTarget` hands back an
`ApprovedBrowserTarget` — a value whose initializer is private to the file that raises the prompt
— and `BrowserViewController.navigate(to:)` starts an agent navigation from nothing else. Before
that, the command authorized `normalizedURL(from: input)` and then navigated from `input`,
normalizing a second time on the far side of the user's answer: the same function ran twice, so
prompt and load agreed by coincidence. `check_architecture_boundaries.sh` fails the build on an
agent handler that navigates to anything but the approved value.

**4. The page cannot change under an open prompt.** Every command that acts on the current page
re-checks its lease (`browserPageLeaseIsCurrent`) or its document identity (`agentPageIdentity`)
after the decision returns, and fails with "retry against the page now on screen" rather than
acting on a page the user did not see. The browser is shared with the user, who can navigate it
while the sheet is up.

**5. A redirect is a new decision.** `finishBrowserNavigation` re-authorizes the *final* URL
before any page content is returned, so a granted origin that bounces to another one prompts
again instead of leaking the destination's content.

**6. Only two things skip the prompt, and both are pinned by parse.** Loopback (see above) and
`about:blank` — the whole `about:` scheme used to qualify while the prompt described it as "this
blank page"; only the blank document does now.

**7. Every undecidable state is a refusal.** No origin, no lease, no page URL, a display string
that cannot be rebuilt without credentials, a decision provider that never answers — each ends in
denial or an error, never in an unprompted load.

**8. The prompt is raised over the window showing the page.** An alert about a page the user
cannot see is one they answer about something else, which is the same as not asking. So the
browser prompts — the origin grant, the sensitive-action confirmation, the site-data clear — take
their window from `SessionBrowserResolver.window(for:)` rather than from the app's main window,
and that answer comes from the **host** holding the browser (`SessionBrowserHosting.hostWindow`),
not from the browser's own `view.window`: a host installs only its active tab, so a browser
sitting behind another tab is in no window at all and would otherwise have sent its prompt
wherever the app considered primary. The main window remains the fallback when no host can be
named, and `ConfirmationAlert` runs app-modal rather than as a sheet when there is no window at
all — a prompt with nowhere to attach is still answerable, never skipped. The host is asked only
when its view is already loaded, so answering "which window" never builds a pane for a session
nobody has opened.

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
certificate state; downloads, password fills, arbitrary JavaScript, a persistent profile of its
own, and network interception are deliberately absent from *this* backend, which is what makes
its "nothing authenticated is reachable" promise checkable. The app bundles only its small audited
bridge, not Playwright's hundreds of megabytes of version-coupled browsers. If the local package
or matching browser binary is absent the tool returns the exact install command and does not
download anything implicitly. Optional final screenshots are size-bounded, cached with the
existing rolling browser artifacts, and can be returned as an MCP image.

## Attached Chrome

`browser_attach_chrome` is the third backend, for the one job neither of the others can do: work
that genuinely needs the user's own signed-in session, a browser extension, or a passkey. It
launches a persistent Playwright context, headful, against **a Chrome profile of Threading's own**
under `~/Library/Application Support/Threading/ChromeAutomationProfile` — set up from Settings ▸
Tools, where the user signs in once and installs their password manager's extension.

Not the user's everyday profile, and not by choice. Since Chrome 136 (May 2025) Chrome refuses
`--remote-debugging-port` and `--remote-debugging-pipe` against the default user-data directory,
precisely to stop tools — and infostealers — driving the profile that holds a person's sessions.
Playwright's persistent-context launch speaks CDP too, so no transport reaches the everyday
profile on current Chrome. "Signed into what Chrome is signed into" therefore softens honestly to
"signed in once, kept". What it buys is exactly what a `WKWebView` cannot have: the 1Password
extension's ⌘\ recognises the domain, fills both fields, and the whole sign-in reduces to one
Touch ID — with no plaintext ever crossing into Threading, because Threading is not in that path
at all.

Threading still reads no cookie, no Keychain item, and no credential. Chrome's own "Chrome Safe
Storage" key never leaves Chrome; device-bound tokens and passkeys keep working because this is
real Chrome. Password fields are refused here as everywhere, so the intended shape of a run is:
navigate to the sign-in page, then `wait_for` a post-sign-in element while the user fills it
themselves.

The fence is an **origin allowlist granted before the browser launches**. The bridge is a one-shot
batch subprocess — it executes up to fifty steps and exits, with nothing to call back into the app
mid-run — so it cannot ask the way the live browser asks per read. Every origin in
`allowed_origins` therefore goes through the same `authorizeBrowserAccess` once/always/deny sheet
the WKWebView browser uses, one at a time, before Chrome opens; a single deny refuses the whole
run rather than quietly running a shorter one. A step-at-a-time grant bridge, which would match
the live browser's per-read semantics exactly, is the documented upgrade path.

Inside the bridge the same list is enforced three ways: before every step, on every main-frame
navigation, and on every new page through `context.on("page")`, which closes an out-of-allowlist
pop-up and reports it identically. A `goto` is checked against its *target* before the request is
sent, so a disallowed host never receives one; a redirect into a disallowed origin is caught by
the navigation watcher, which is the only moment it can be known. A violation stops the run,
closes the context, and returns a structured result naming the origin and the step index — and
the violating step's own result is never appended, so nothing about that page reaches the agent.
Origins compare as exact `BrowserOrigin.key` strings on both sides, which is why two loopback
servers on the same host are two different origins rather than one.

The isolated and attached paths are deliberately two functions in the bridge and two argument
types in Swift. Their promises are opposites, and the way to keep a promise like "nothing
authenticated is reachable" is to not add a flag to the function that makes it. `browser_capabilities`
lists all three backends, and reports the attached one as `chrome_missing`, `profile_not_set_up`,
`runtime_missing`, or `available`, so an agent can find out before it asks. One profile directory
is one Chrome, so a run while the setup window is open fails on Chrome's `SingletonLock`; that is
detected and said in plain words rather than fought. The profile lives under Threading's own
Application Support directory, so Reset Everything moves it aside with the rest of the app's
state.
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

The mode itself is stated on the browser surface rather than only on the control that started it:
an accent frame around the viewport and an accent badge in its bottom-left corner, both drawn by
the overlay and both gone the moment the mode ends. Deliberately a frame and not a wash — a tint
over the whole page would recolour the very thing the user opened annotation mode to look at.

While that mode is on, the overlay also outlines and names the component under the pointer, because
a crosshair over live content says where a pin will land and nothing about *what* it will be read
as. The overlay resolves nothing itself: it reports pointer movement, and the browser answers with
one bounded read of the page — the box in top-level viewport CSS pixels plus a role and accessible
name. It answers with a **component**, climbing from the deepest hit element to the nearest ancestor
the agent could already address (an existing ref, an ARIA or implicit role, a test id) within six
levels, so pointing at the word inside a button highlights the button. The probe mints no refs: it
reads `elementToRef` and never writes it, so hovering cannot renumber the page underneath an agent
mid-task. Everything it returns is page-authored and stays page-authored — collapsed to one line
and cut to a bounded length before it is drawn, and never added to an annotation, a tool result, or
`browser_annotations`, whose `user_authored` provenance therefore remains exactly true. One probe
runs at a time with only the newest pointer position queued behind it, and the highlight is re-asked
on scroll, which moves the page under a stationary pointer without generating a mouse event.

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

Every password refusal goes through one coordinator helper, `beginPasswordTakeover`, in a fixed
order: **activate, select, reveal, focus**. The order is the substance. Universal autofill and
system AutoFill fill the focused field of the *frontmost application*, and `revealDisplayPane`
returns `false` and does nothing at all when the asking session is not the one on screen — so
before this, a takeover in a background session unhid nothing while the user's own fill shortcut
landed in whatever they happened to be reading. The app is brought forward and the session
selected the same way a clicked notification does it (`NSApp.activate` behind an injectable seam,
then `SessionNotificationOpened`, which the sidebar already observes), and only once the selection
has landed is the pane revealed. `browser_fill_form` shares the helper too; it used to reveal the
pane and then leave the field unfocused for no reason. Beside the affordance, while a password
field has focus and the strip is wide enough to hold it, a quiet hint names the one-touch paths.
It is copy, not capability: Threading invokes no vault and still never sees the value.

This distinction is load-bearing. Public Authentication Services password requests return an
`ASPasswordCredential` containing plaintext user and password strings to the app, while the
AutoFill-assisted request API is unavailable on macOS. Threading therefore never calls a password
provider. Any system Password AutoFill that WebKit offers, plus WebAuthn and passkey challenges,
remains WebKit- and system-owned. Ordinary password values remain redacted from snapshots,
unavailable to browser actions and waits, omitted from traces and diagnostics, and protected by
the existing form-submission confirmation after the user fills them.

## Test credentials

The takeover above is what the app does **by default and unless the user changes it**. It is also
the wrong shape for the case it kept hitting: a throwaway login on `localhost:3000`, typed by hand
forty times a week, where a human touch per fill protects nothing. So Settings ▸ Tools ▸ Browser
Sign-In offers three sources, and `browser_fill_credentials` behaves according to which is chosen.

| Provider | Threading sees plaintext | Human touch per fill |
|---|---|---|
| **macOS AutoFill and password managers** (default) | never | yes — the takeover above |
| **Threading test credentials** | transiently, per fill | no |
| **1Password** | transiently, per fill | no — 1Password authorizes the read |

The tool takes **no origin, username, or password**. The origin comes from the live authorized
page, the values from the user's own vault. It may name an `account` when one origin holds several
test logins, because choosing between "admin" and "read-only" is part of a real task — the origin
fence still holds, so the worst a prompt-injected page buys is the wrong test account on a page the
user already granted. Every path that is not a fill — the default provider, no entry for this
origin, a provider that is not ready — ends in `beginPasswordTakeover`, so the agent's code path is
the same whatever the user chose, and the tool is honest in every configuration.

**The consent chain is new and has to be said outright.** "Always Allow This Host" never mentioned
credential injection, and loopback origins skip the prompt entirely. So the grant is *not* what
authorizes a fill: **authoring the entry in Settings is**, per origin, and the fill asks for its
origin grant with its own purpose — "sign in to" — rather than the generic "interact with", so a
first grant names the stakes.

**The origin is verified inside the fill script, not before it.** This is the one place a
Swift-side check would have been theatre: `callAsyncJavaScript` is given `in: nil`, so WebKit runs
against whichever main-frame document exists when it *delivers* the script. Every other action
tolerates that race because the worst case is a click landing on a fresh page and the final origin
is authorized again afterwards; here the secret has already crossed by then. A `<meta
http-equiv="refresh">` moves the document with no script at all, and the user can navigate the
shared browser themselves. The expected scheme/host/port therefore arrive as arguments and the
isolated-world script compares them against its own `location`, which page JavaScript cannot shadow
because it does not share that world's global object. Both the origin and `type === "password"` are
re-checked after the actionability await, which is a yield a page can navigate inside. Values reach
JavaScript only through the arguments dictionary, never interpolated into script source, which
surfaces in error strings.

**A filled value is retained per tab so it can be scrubbed back out.** Snapshot redaction keys off
the field's live `type` attribute, so a page that flips its own password input to `type=text`, or
copies the value into a `div`, would hand the plaintext to the next `browser_snapshot`. That is
worse here than an ordinary XSS: a page whose CSP blocks its own exfiltration can use the *agent*
as the channel, and the agent has a shell no CSP touches. Threading is the only party that knows
the string, so it removes it from snapshots, query output, and the console and network buffers.
This is a deliberate retention trade rather than "held for the duration of one fill": the value
lives as long as the tab holds it, never reaches disk, and is dropped when the document leaves that
origin. **Screenshots cannot be scrubbed and remain a residual channel.** Values under six
characters are not scrubbed either — replacing a short string everywhere it appears would both
ruin the snapshot and advertise the secret's shape.

The vault prefers `kSecUseDataProtectionKeychain`, **and probes rather than assumes it**. That
keychain is unreachable from `security add-generic-password` and `security
delete-generic-password`, which the file-based login keychain is not — and this app hands agents an
unrestricted shell. But it needs a `keychain-access-groups` entitlement backed by a real team
identity, so an ad-hoc-signed Debug build gets `errSecMissingEntitlement` on every write. This was
found by the store's own suite failing eight tests while the feature "worked": the writes had been
silently going nowhere. `BrowserCredentialStore.usesDataProtectionKeychain` therefore runs one
throwaway write at startup and falls back to the login keychain, and
`isShellReachable` reports which vault the build actually got — surfaced in the Settings row and in
`browser_capabilities` as `vault_reachable_from_shell`. Reads prompt in either keychain, so an
agent cannot *learn* a stored password either way; what the weaker one allows is planting or
deleting an entry. The point is that the weaker build says so rather than inheriting the stronger
build's promise.

There is deliberately **no biometric gate**: unattended filling is the whole point, and a vault
that asks for Touch ID per fill is the takeover flow with extra steps. That is the "less secure"
this feature is named for, which is also why the UI calls it *test credentials* and never a
password manager, warns on well-known identity providers, and requires an explicit throwaway
acknowledgement for any origin that is not loopback.

### The 1Password provider

`OnePasswordCLI` reads the item through `op read`, under the user's login shell for the reason
`AgentLauncher.loginShellPath` gives — a GUI app does not inherit the interactive `PATH`. Worth
stating plainly so nobody later mistakes the indirection for a boundary: **`op read` is exactly as
available from the agent's own shell as it is from Threading**, so this provider buys convenience
and a no-plaintext-at-rest story, not a new fence. The fence is 1Password's own per-process
authorization. The login shell also puts the user's rc files and any `op` alias on the value's path,
which is inherent to needing their `PATH`.

Threading stores only the `op://vault/item` reference, in `PreferenceStore` beside the provider
choice rather than in the Keychain, because a reference is a name and not a credential. The field
names are appended by Threading, and a reference that already names a field is refused at the point
it is typed — otherwise one entry could read `.../password` for its username. Two `op read` calls
rather than one `op item get --format json`: the JSON form returns every field on the item, and this
wants exactly two.

Availability is probed with `op --version` and deliberately **not** `op account list`, which can
raise 1Password's own authorization prompt — a settings page the user is merely looking at must not
make a window appear. An unauthorized `op` fails at fill time instead, which is the moment the user
expects to be asked. The read runs off the main actor, because it can sit on a Touch ID prompt that
a person has to physically answer.

**One known limit, written down rather than claimed away.** The provider choice and
`BrowserAccessStore`'s persistent grants live in `UserDefaults`, so an agent with shell access can
`defaults write` both. Neither hole is new and neither yields a password — the vault itself is out
of the shell's reach, and an entry must exist before a provider choice means anything. It matters
because it set the bar for what could be built on top, which is the next section.

### Submitting without being asked every time

Filling a sign-in and then still asking before the submit is about half the value the vault exists
for, so `BrowserSubmissionExemptions` is the other half — and the piece that most deserved to be
built last, because it relaxes a different guarantee than the fill does.

It is **process memory, deliberately not a preference.** The provider choice and the persistent
origin grants live in `UserDefaults`, which an agent's shell can rewrite with `defaults write`; that
is tolerable there because neither yields a password. It is not tolerable here — a persisted
exemption plus a stored credential plus one prompt injection is fill-and-submit with nobody
watching, which is unattended takeover of whatever that origin is. A store the shell cannot reach at
all is the only version worth having, so quitting Threading is a complete revocation. That property
is worth keeping even when someone later asks for it to be remembered across launches.

**Only an origin that already holds a credential may be exempted**, because the exemption extends a
decision the user already made in Settings for that exact origin. Everywhere else the prompt stays
the two-answer question it has always been: a "stop asking" that any page could earn is not a
narrower prompt, it is a disabled one. The second affirmative is offered through `choose`, not a
suppression box, for the reason the origin grant gives — a remembered answer scoped to one host is
this prompt's own answer, while a checkbox would remember something about every host at once. The
prompt stays `.alwaysAsks` in the register. Exemptions are listed and revocable in Settings ▸ Tools,
and membership is re-checked at each submission rather than captured when granted, so revoking takes
effect on the next submit.

`browser_fill_credentials` never submits; submission keeps its own confirmation.
`browser_run_isolated` does not get this tool at all — its checkable promise is that nothing
authenticated is reachable, and the way to keep a promise like that is to not add a flag to the
function that makes it. `browser_attach_chrome` is untouched: it has the real 1Password extension.

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

## Visual baselines

A baseline is an approved picture of a page: what somebody decided correct looks like. The whole
subsystem exists to make one claim durable and one comparison honest, and every decision below
follows from that.

**The judgment is the user's.** If the agent both captures the baseline and decides whether the new
render matches it, the loop is circular and asserts nothing — which is why Percy, Chromatic and
Applitools all put a human in the approve step. `BrowserBaselineUI` puts **Save as Baseline…** in
Browser Options, gives it a command id (`view.saveBaseline`, no default chord) so it can be bound,
and **Accept New Revision** lives only on the comparison surface. Some states are also structurally
user-only: a password field refuses agent typing by design, so anything behind a sign-in, a passkey
or a 2FA prompt can only be captured by a person.

**Symmetry, though.** `browser_baselines` gives the agent `list`, `capture` and `delete` through the
same contract, at the same project scope, because the panel's `+` already creates shared and private
browser tabs for both parties and a baseline should not be the one browser resource only one side can
make. What the agent cannot do is replace, approve or delete a **user-captured** record.

### One capture path

`BrowserViewController.captureBaseline` is the only way a baseline is made. The visible-page
screenshot exporter still uses a bare `WKWebView.takeSnapshot`; a baseline must not, because that
produces backing-store pixels rather than the CSS-pixel-normalized ones `browser_screenshot` and
`browser_click` agree about. Two capture paths would mean a user baseline and an agent comparison
quietly disagreeing about what a pixel is.

Conditions are recorded beside the pixels, not derived later: fragment-stripped URL and origin,
capture kind, viewport, document size, scroll offset, page zoom, **resolved** colour scheme (what the
page's own media query answered, not the `auto` emulation setting), CSS media, user-agent override,
browser context, pixel dimensions, clipping, capture time, schema version and content hash. A
comparison whose conditions differ from the baseline's says so, because that alone can change every
pixel on the page.

The screenshot, the page metrics and the attribution state are three WebKit calls and cannot be made
atomic through the public API. They are taken back to back against one `BrowserPageIdentity` and the
capture is refused if the document was replaced in between. A page animating through the sequence can
still drift; attribution is therefore described as best-effort wherever it is returned.

### The store

`BrowserBaselineStore` is per **project**, under
`~/Library/Application Support/Threading/BrowserBaselines/<project>/<baseline>/<revision>/`, holding
`manifest.json`, `baseline.png` and optionally `state.json`. It is deliberately **not** the rolling
browser-artifact cache: that ring evicts by count, which is right for evidence and wrong for a claim.

- **Immutable revisions.** Approval adds one and moves the active pointer. The image it replaced keeps
  its directory, so the last approved copy is always recoverable.
- **Atomic writes.** A revision is assembled in a sibling `staging-<uuid>` directory, re-read,
  re-hashed and re-measured there, and only then moved into place. The active pointer never advances
  onto a revision that has not proven itself.
- **Damage is set aside.** A record that will not decode is moved under `Quarantine/`. If that move
  fails, **writes are blocked** rather than continuing over data nobody has looked at.
- **A newer schema is not corruption.** A record from a later build is left exactly as found and
  counted, not quarantined: downgrading and losing a colleague's baselines is not a recovery.
- **Quotas refuse visibly.** Per-image bytes, baselines per project, revisions per baseline, project
  bytes and attribution bytes are all bounded, and exceeding one is a typed error with a route to the
  baseline browser. An approved baseline is never silently evicted.

Deleting a session leaves the library alone. Removing a **project** takes its baselines, which is why
the removal confirmation says so and why the sweep in `projectSidebarDidRemoveSessions` is by project
id. Reset Everything already moves the whole support directory aside recoverably.

The numbers in `BrowserBaselineDefaults` are provisional. What is not provisional is that every
dimension has a bound. Real capture sizes across viewport, full-page and element captures are the
measurement still owed before they are fixed.

### Two origins

Returning a comparison discloses pixels from the live page **and** from the baseline, which may be a
different site. The current document's origin is authorized as it always was; the baseline's stored
origin is authorized separately before its bytes leave. A `list` withholds URLs for origins with no
grant rather than prompting once per row — the same thing `browser_tabs` already does with page
metadata.

Private-context captures are **user-only**, whoever made them, and the context wins over whatever
the record already said. Provenance is not permission: an agent that captured authenticated pixels in
a private tab has not thereby earned the right to read them back later. Making one agent-readable is
a separate, explicit choice in the baseline browser.

The record's existing answer is deliberately *not* inherited by a new revision. Adding a private-tab
revision to an already-readable baseline would publish authenticated pixels under a permission the
user granted about entirely different ones — and the first version did exactly that, while printing
"this record is user-only" beside it.

### The comparator

`BrowserVisualComparator` was a max-per-channel absolute delta, which weights a blue shift the eye
barely sees exactly as heavily as a luminance shift it cannot miss, and reported every line of
re-rasterized text as a change.

- **YIQ perceptual distance**, pixelmatch's, normalized to 0…1. The legacy `channel_threshold` is
  still accepted and *translated*: a grey step of Δ moves luminance by exactly Δ, so the mapping is a
  computation rather than a constant somebody picked.
- **Anti-aliasing suppression**, pixelmatch's detector ported: a pixel with both a distinctly darker
  and a distinctly lighter neighbour, at least one of which has three or more identical siblings in
  *both* images. The "in both" half is what stops a genuinely new edge being written off. Suppressed
  pixels are counted and reported, never silently dropped.
- **Alpha is composited, not compared.** The decode is premultiplied (`CGBitmapContext` offers no
  straight-alpha 8-bit RGBA), so compositing onto white is `channel + 255·(1 − α)`. Both sides get
  the same ground. Getting this backwards is silent: opaque pixels agree under either formula.
- **A size change fails, and still answers.** The common region is compared, signed width and height
  deltas are returned, and the diff is drawn at the union of both extents with the uncompared band in
  a flat tint. Images are never scaled into a pass.
- **Ignore rectangles** leave both halves of the ratio, so a large ignore cannot make a small change
  look smaller than it is. Semantic ignores wait on attribution state, because a PNG baseline has no
  old element geometry to resolve them against.

SSIM is deliberately absent from pass/fail: two independent oracles must not silently disagree about
whether one comparison passed.

### Regions and structure

`browser_visual_compare` takes a bounded `detail` level rather than splitting into a second tool: the
question is the same visual question either way, and an agent should not have to choose a tool before
it knows whether the page changed.

- `summary` — numbers only.
- `regions` — `BrowserRegionLabeller` dilates the changed-pixel mask (separably, so the cost is linear
  in the radius), floods it, recomputes each box from the **original** mask so no region claims the
  dilation's padding, merges near neighbours, ranks by changed pixels and caps. Raw connected-component
  labelling would turn one changed sentence into dozens of letter rectangles. `BrowserRegionAttributor`
  then names what each region sits on, preferring the **deepest** element rather than the largest —
  `html` and `body` overlap everything and explain nothing. A region over no element says exactly that:
  canvas, images, background painting and pseudo content are all real answers.
- `structure` — `BrowserStructuralDiff` matches the two captured trees on bounded semantic evidence:
  test id, then role and accessible name, then structural position. **Never on ref equality** — the
  bridge restarts `nextRef` at 1 for each document and assigns as it walks, so `e12` in two captures
  is not evidence of anything. A key that appears more than once on either side produces an
  `ambiguous` finding instead of an invented pairing. Findings are ordered by the pixels they overlap
  and worded as "associated with", because sharing a rectangle is evidence and not proof of cause.

`BrowserAttributionState` is a **visual-attribution snapshot**, not a Percy-style reproducible archive:
a bounded tree of visible nodes with a curated, fixed list of visual computed properties, plus visible
`::before`/`::after`. It mints no refs — a capture must not renumber the page the agent is working
against. Coordinate space is explicit per capture kind and lives in `BrowserCaptureSpace`; getting it
wrong does not fail, it silently attributes every region to whatever is near the top of the page.

### What a captured pixel is

Two contracts the whole attribution stack rests on. Both were assumed, both were wrong, and neither
shows up at scroll 0 and zoom 1 — which is the state anybody testing by hand is in.
`BrowserCaptureGeometryTests` asks WebKit rather than reasoning about it, and is in the fast plan's
skip list with the other live-WebKit suites.

- **A full-page capture starts at the document origin.** `WKSnapshotConfiguration.rect` is in the
  *view's* coordinates, where (0, 0) is the current scroll position, so a capture taken at scroll
  1000 covered document 1000–4000: the wrong band, running past the end of the document, while three
  consumers read it as starting at the top — the attribution space adds the scroll back, the overlay
  anchors at `-scroll`, and `clipped` compares against the document height. `screenshot(fullPage:)`
  now scrolls to the top and restores afterwards, because a capture is not a navigation and the
  reader was looking at something.
- **One captured pixel is `pageZoom` CSS pixels.** The capture is sized from `webView.bounds`, which
  is points, while every box, offset and scroll attribution reads is CSS pixels. At 200% the two
  disagree by exactly two, so `BrowserCaptureSpace.scale` is the zoom the capture was taken at and
  not 1. The overlay carries the same number rather than reading today's zoom: a baseline is a
  picture of a past moment, so the zoom that matters is the one it was taken at.

### The two surfaces

`BrowserComparisonViewController` shows baseline against current on `ImageCompareView`, with the diff
map available as a second view and **Accept New Revision** in the header. Its bytes live in the
controller and **the tab is deliberately not persisted**: a persisted tab pointing at the rolling
artifact ring would come back after a relaunch naming files that had been swept. A comparison is a
moment rather than a document, and re-running it is one tool call. The baseline itself is durable;
only the comparison is ephemeral.

`BrowserBaselineOverlay` holds an approved picture over the live page. It is a **sibling** of
`BrowserAnnotationOverlay`, sharing its scroll observation, mode frame and badge, and deliberately not
its hit testing: annotation mode takes page clicks because a click places a pin, while this overlay
must pass every click through except on its own handle. It is native, so `browser_screenshot` never
bakes it into page pixels. A full-page baseline tracks document scroll over its captured extent; a
viewport baseline is valid only at its recorded offset, and scrolling away is **stated in the badge**
rather than silently misaligned — an overlay that slid a viewport capture around would present pixels
at positions they were never captured at.

### More things to diff against

A baseline is one right-hand side. Three others are worth having, and each needed a boundary rather
than just a byte array.

**The page's own past.** `BrowserAutoCaptureRing` keeps a small in-memory history of what the page
looked like immediately *before* each agent mutation, and `baseline_previous` compares against the
most recent one. Three rules hold it in place. It is **opt-in and off by default**, because otherwise
every page-changing tool call pays for a screenshot on the main actor for an answer nobody may want.
It is **not the baseline library**: these are automatic and unapproved, and letting an agent's own
before-shot sit among approved pictures would blur the one distinction the whole subsystem rests on.
And it covers **agent-originated changes only** — the entry names the tool it was taken in front of,
so "what did my click change?" is answerable while a user's own click, a timer, or a late network
response is honestly outside what it saw. Navigation is deliberately not in `mutatingTools`: a new
document is not a change to the old one.

**Another tab.** `baseline_tab_id` captures a second live tab in the same session, now, and compares
the two. Both origins are authorized separately, because a comparison discloses pixels from each.
The report says both sides are live, since a difference may be a change in either of them.

**A git ref.** Captures record the checkout's commit in their conditions, comparisons report when
the two commits differ, and `browser_baselines list` filters by commit prefix. Nothing here ever
checks anything out: reproducing a baseline's commit would mean stashing and restoring the user's
working tree behind them, which is ruled out explicitly.

**Across viewports.** `browser_baselines capture` takes `viewport_width`/`viewport_height` and puts
the browser back afterwards (in a `defer`, so a failed capture cannot strand the user at a phone
size); `browser_visual_compare` takes `match_baseline_viewport` to re-render at the baseline's own
recorded viewport before capturing. So N presets means N baselines, each compared at its own size.
One viewport's baseline is never scaled to stand in for another — that is the same rule the
dimension handling already enforces, reached from the other direction.

### Diffs that are not pixels

The same product shape pointed at what the page says about itself. None of it was free once images
worked: each needed its own bounded, versioned snapshot, and each has one rule that keeps it honest.

`BrowserDiagnosticsSnapshot` records timings, console, network and accessibility findings, stored as
`diagnostics.json` in the revision bundle beside `baseline.png` and `state.json`, and compared when
`browser_visual_compare` is asked for `diagnostics`.

- **Timings are measured against a noise floor and never called a regression on one run.** Two runs
  of an unchanged page differ anyway; a report that presents a three-millisecond move as a
  regression teaches everybody to ignore it. Layout shift gets its own floor because it is unitless
  rather than milliseconds, and long-task counts get theirs because they are integers.
- **Console and network carry the window they were collected over.** The live buffers clear on their
  own schedule, so "this 404 is new" is meaningless without an interval. Two windows more than three
  times apart in length are declared not comparable rather than normalised into a rate the page
  never reported.
- **Everything is fingerprinted, and identity excludes the count.** A line carrying a timestamp or a
  request id is otherwise new on every capture, and a URL carrying a record id makes one resource
  look like a hundred. Digits are masked and identifier-shaped path segments collapse to `*`. The
  count is shown but is deliberately *not* part of identity: a warning that happened forty times
  instead of once is the same warning, and folding the count in would report it as added and
  removed at once. That bug existed until the test for it was written.
- **Accessibility findings drop their refs.** Keeping one would invite matching on it, which is the
  mistake the structural diff already refuses.

The layout-shift overlay draws where the page moved under the reader, on the same surface as a held
baseline and under the same two contracts: it passes clicks through, and it never reaches the DOM.
It draws each shift's **previous** rectangle, because that is where the reader was looking when the
page pulled it away, and it weights opacity by the shift's own score so a jolt and a hairline do not
shout equally. A page WebKit records no layout-shift entries for is reported as unavailable, which
is a different answer from a page that stayed still.

**Support is asked for directly, not inferred from a thrown error.** `PerformanceObserver.observe`
does *not* throw on an entry type the engine has never heard of — the spec has it warn and return —
so the first version's try/catch reported every engine as supporting layout shift and every page as
perfectly steady. Since WebKit implements no `layout-shift` entries at all, that was the answer for
every page Threading can show, and the overlay silently did nothing while the docs claimed it would
say so. `supportedEntryTypes` is the question that actually has an answer.

### Deliberately not built

CPU and network throttling stay unsupported in `WKWebView` and `browser_capabilities` keeps saying so;
the honest path is Playwright through `browser_run_isolated`. No cloud baselines, approval service or
review dashboard: the compare surface and the panel are the review surface. No reproducible DOM
archive. No baking overlays or annotations into page pixels. Imported design images would need their
own `imported_reference` provenance, alignment offset and scale contract — the provenance case exists,
and nothing feeds it yet, precisely so a Figma export cannot wander into a pass/fail comparison.
