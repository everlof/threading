# WebExtension development

The **Web Extensions** display tab and `web_extension_development` MCP tool share one
`WebExtensionDevelopmentService` worker per chat. This is for browser WebExtensions, separate
from Threading's own extension SDK. The selected chat must have a local checkout. The panel is
host-only: Threading owns process launch, checkout identity, instrumentation, installation,
diagnostic provenance, source navigation and test verdicts. Shared design components supply the
appearance; no extension can replace these authority-bearing controls.

## Development loop

Open the panel from the display-panel **+** menu or command palette. For a new project choose
**Project → Create Starter Extension**. Once per machine, choose **Install Development Tools**
(Python 3 is required; `THREADING_WEBEXT_PYTHON` can select it). Select a target and **Start**.
Edit the original files, **Rebuild & Reload**, then **Run Tests**. Project also opens the browser
extension debugger, popup and options pages. These pages open as tabs; actual toolbar popup
focus/dismissal, browser permission prompts and store installation need browser UI checks.

The helper discovers root/dist/WXT manifests, or reads `.threading/web-extensions.json`:

```json
{
  "version": 1,
  "targets": [{
    "id": "chrome",
    "browser": "chrome",
    "source": ".output/chrome-mv3",
    "build": ["npm", "run", "build", "--", "-b", "chrome"],
    "url": "https://example.test",
    "tests": [
      {"url": "https://example.test", "selector": "#extension-badge", "text": "Ready"},
      {"page": "popup", "selector": "#refresh", "click": true},
      {"selector": "#result", "text": "Updated"}
    ]
  }]
}
```

Build is an argv array executed in the checkout, never a shell string. Source must be the built,
loadable extension directory. Use one browser-specific build target per output when API or
manifest differences require it. `page` supports popup, options and side-panel content. `url`
supports HTTP(S), or `fixture` for the bundled local test page. Assertions require exactly one
CSS match; `text`, `click` and `fill` are supported. Test screenshots are written to the run's
state directory (one success and one failure image, overwritten on subsequent runs).

## Browser adapters and their limits

| Target | Launch and reload | Test level |
| --- | --- | --- |
| `chromium` | Pinned Chrome for Testing from Playwright, separate persistent profile, direct CDP pipe installation | Real Chromium extension and page assertions |
| `chrome`, `edge`, `brave`, `vivaldi`, `opera`, `arc` | Installed Mac application, separate profile, `Extensions.loadUnpacked` | Same engine adapter; each product/version still needs its own smoke run |
| `firefox` | Installed Firefox, Selenium temporary add-on installation; reinstallation on reload | Real Firefox extension and page assertions |
| `safari` | Instrumented folder; activate through Safari's temporary-extension UI | Manual real Safari checks, live diagnostics after connection |
| `safari-ios` | **Package Safari** generates the Xcode wrapper; run it on a simulator/device and enable it | Manual Safari checks; no claim that Playwright WebKit runs Safari extensions |
| `firefox-android` | `web-ext`, `adb`, exact `device` serial; loopback port forwarding and restart on reload | Dedicated Android test device; manual UI, captured diagnostics |
| `manual` | Load the staged folder using the target's own developer workflow | Manual UI, captured diagnostics if WebExtension APIs permit it |

For another desktop Chromium product, duplicate a target and change both `id` and `browser`
(for example `edge`), keeping that product's build output and test URL. For Android, add a target
such as `{"id":"android","browser":"firefox-android","source":"dist/firefox","device":"YOUR_ADB_SERIAL","application":"org.mozilla.firefox"}`.
Install `adb` and Mozilla's `web-ext` on the Mac and enable USB/Firefox debugging on the dedicated
test device first. The launcher forwards only its loopback collector port for that exact serial,
removes the route at Stop, and restarts the temporary add-on on Rebuild & Reload.

Chromium variants must implement CDP `Extensions.loadUnpacked` and allow developer extensions.
Managed-browser policy or a removed API can refuse launch. Chromium MV2 removal cannot be
worked around by this adapter. Firefox's background manifest is adapted in the disposable copy;
this does not translate unsupported browser APIs. Safari converter warnings belong in the build
log and must be addressed in the project's original sources before distribution. A physical iOS
device cannot reach the Mac through its own `127.0.0.1`; automatic telemetry is therefore limited
to the Mac/iOS Simulator. Physical-device debugging uses Safari's developer tools.

The Chromium adapter deliberately attaches only to page targets. In real-browser probes, broad
worker inspection stalled extension messaging; the direct pipe keeps the worker lifecycle owned
by the browser. A Chromium test requires real background → content and popup round trips, not
merely a visible service-worker target. `Extensions.loadUnpacked` also performs rebuild reloads;
tests cover storage retention rather than assuming reinstallation preserves it.

Compatibility evidence on this Mac: Chrome for Testing 156 and Firefox 158 pass the full fixture.
Chromium also passes with a visible browser (`--headed`), matching the panel’s launch mode.
The installed Chrome 155.0.8059.80 loads its background but stalls content messaging through this
installation path, including in an uninstrumented minimal reproduction. It is not marked E2E
verified. Use the Chromium target for the reliable development loop and test the installed
browser separately; do not substitute one product's passing result for another. Safari Mac and
iOS wrappers are generated separately from live Safari activation checks. The generated Mac
wrapper compiles with signing disabled. The iOS Simulator build stalled in Xcode’s storyboard
compiler and was stopped; it is not verified. Physical Android/iOS and the other installed-browser
brands still require device/product smoke runs.

## Diagnostics and custody

`stage` copies a bounded, symlink-free extension tree and instruments only that copy. Source JS
files are unchanged so stack line numbers survive. A new build hash identifies each copy.
Background workers/pages, isolated static content scripts and extension HTML pages report
console calls, exceptions, rejected promises, failed `fetch` calls and message send/reply/failure operations (without message payloads). Events retain browser
target, build, context ID, URL, tab/frame, stack and arrival order. Source Map v3 resolution reads
local maps and resolves only existing files inside the checkout. Older-build events cannot open
source against a newer build. Remote, virtual and indexed source maps are not resolved.

The development manifest adds loopback host access. Each live target has a random bearer route
on a loopback-only collector; stopping revokes it. These are development artifacts and must not
be published. No request bodies, headers or cookies are deliberately collected. Console values
can contain secrets; redaction is best effort. Diagnostic text is untrusted data, never an agent
instruction. MAIN-world scripts, dynamically injected scripts, XHR and browser-internal errors
are outside the injected hook. Use the native debugger for breakpoints, startup/manifest errors,
permissions and anything the hook cannot execute or capture. CSP can prevent connection;
`running` means launched, while `connected` requires telemetry from the current build.

## Ownership and bounds

Swift sends typed NDJSON requests over a serial utility queue. Both pipe ends are nonblocking;
short replies use single POSIX reads. The bundled-worker test exposed Foundation’s
`read(upToCount:)` waiting for more bytes on a still-open pipe, so a partial-response cancellation
regression now covers that exact failure. Unused parent pipe ends are closed and writes suppress
SIGPIPE, have a deadline and refuse requests above 64 KiB. Filesystem work, JSON codecs,
source maps, subprocesses and browser protocols never run on the main actor. Each chat owns one
helper; moving its tab does not duplicate it. One command may wait behind an in-flight
operation, so event polling cannot refuse a Start/Reload click. Further commands are refused;
checkout release invalidates both the worker and its queued reservation. Hiding the panel stops UI polling but retains the
worker journal. Closing it, archiving/removing its chat, or moving the chat's checkout cancels the
helper. Closing the application closes stdin; the helper tears down its browsers. Profiles and
development artifacts live in a per-session temporary directory with a fresh worker generation;
a quick close/reopen cannot reuse a profile still shutting down. They never use personal browser
profiles. Firefox preserves extension storage across reload within one browser run, but starts
with a fresh Selenium profile after Stop/Start.

Scaling gate: at most four chat helpers and three live targets per helper; sixteen configured
targets; 4,096 entries/32 MiB per source bundle; 2,000 retained events; 500 accepted events/second; 128 queued native browser events;
16 concurrent HTTP readers with two-second socket deadlines; 64 KiB input; 200 events per page;
2 MiB event pages within 4 MiB transport responses; 100 events/second per instrumented context. The visible panel polls
twice per second and reuses table rows; selection survives journal eviction by event ID. Its
edge-to-edge table explicitly uses `.plain`: the first real-shell render caught a layout feedback
loop when AppKit’s automatic inset gutters competed with exact column fitting. Filtered journal reads use bounded field text rather than re-serializing every row. A local
10,000-event probe retained 2,000 rows; a missing-text scan fell from 76.69 ms to 11.15 ms after
removing repeated JSON encoding (20 scans, under substantial machine load). All of this runs
outside the UI process. Build
output is capped at 1 MiB. Commands have deadlines and terminate their owned process groups.
The ordinary operation deadline is 150 seconds, setup 330 seconds. Test screenshots replace a
fixed pair of files. Browser profile storage is browser-managed and should be cleared by stopping
the session and removing its temporary state when large downloaded site data is no longer useful.

## Verification

Local verification on 2026-10-15 passed all 11 helper contracts and 14 selected XCTest tests,
including the bundled-worker Chromium loop and the real panel's Start → Test → edit → Reload →
Test → Stop journey. The four real-shell captures were inspected at 420-point panel width;
controls, event selection and source details fit in every theme. These are new evidence images,
not accepted regression baselines. The browser-specific compatibility limits above still apply.

- `python3 scripts/test_web_extensions.py`: staging, source-map confinement, scaffold safety and bounded journal/Unicode page contracts, collector authorization and route revocation.
- `python3 scripts/test_web_extensions.py --e2e chromium chrome firefox`: real-browser installation, content/background messaging, deliberate cross-context failures, source lookup, storage-preserving reload and failed-build recovery. Requires the setup dependencies and installed target browsers. Add `--headed` for a visible browser.
- `scripts/test.sh fast -only-testing:ThreadingTests/WebExtensionDevelopmentTests`: bundled worker resource and real Swift-to-Python pipe, refusal recovery, stale-checkout rejection and cancellation. Set `THREADING_WEBEXT_E2E=1`
  and `THREADING_WEBEXT_PYTHON=/path/to/python` to also run a real Chromium loop through the bundled Swift transport.
- With the same E2E environment, `scripts/test.sh fast -only-testing:ThreadingTests/SimulatorPaneRenderTests/testWebExtensionPanelRunsRealBrowserDevelopmentLoop` clicks the real panel’s Start, Run Tests, Rebuild & Reload and Stop against Chromium.
- `scripts/ui-evidence.sh --only web-extension-workbench`: shipping panel shell at 420 points in System light/dark, Cyberpunk and Swiss, including dispatch of Rebuild. Its transport fixture is separate from the real-browser tests above.

Primary adapter references: [Playwright extension testing](https://playwright.dev/docs/chrome-extensions),
[Chrome CDP Extensions](https://chromedevtools.github.io/devtools-protocol/tot/Extensions/),
[Firefox web-ext](https://extensionworkshop.com/documentation/develop/getting-started-with-web-ext/),
[Safari web extensions](https://developer.apple.com/documentation/safariservices/safari-web-extensions).
