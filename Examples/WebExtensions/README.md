# WebExtension development fixtures

Open this directory as a project in Threading, create a chat, then open **Web Extensions** from
the display panel's **+** menu. Choose **Install Development Tools** once, select a target, and
click **Start → Run Tests**. Edit a source file, use **Rebuild & Reload**, and run the tests again.
Firefox must be installed separately. Chromium uses the development browser installed by setup.

The hidden `.threading/web-extensions.json` declares the targets and tests. No npm build or
external website is required. These are development fixtures with deliberate errors, not store
packages. Their loopback host access exists to exercise the local test page.

| Target | What its passing test establishes |
| --- | --- |
| `chromium-contexts` | MV3 classic worker, top/child content scripts, static and dynamic MAIN, file/function injections, callbacks and Promises, isolated registration, ports, missing native-host errors, DNR blocking, XHR failure, sandbox and offscreen diagnostics, popup/options/sidebar/new-tab page content, worker wake-up, reload and restart storage retention |
| `chromium-modules` | Nested module worker, relative imports, content/background round trips after reload |
| `firefox-contexts` | MV3 background scripts, frames, static/dynamic MAIN, dynamic isolated scripts, registration, ports, missing native-host errors, DNR, XHR, extension-page content, reload storage retention and fresh storage after browser restart |
| `firefox-modules` | Module background scripts and relative imports after reload |
| `firefox-legacy` | MV2 nonpersistent background HTML and content/background round trips after reload |

Expected deliberate failures include `coverage-main-error`, `coverage-sandbox-error`,
`coverage-offscreen-error`, a missing native host and a 404 XHR. Tests assert selected diagnostic
events as well as page behavior. An error row does not by itself mean the test failed. MAIN and
sandbox events are labelled untrusted because scripts in those public worlds can forge them.
Port and native-message payloads must never appear in the event journal.

For native-browser checks, use **Project → Open Browser Debugger**. Open the actual toolbar
popup and sidebar to check focus and dismissal; open DevTools to activate the fixture's
`ThreadingCoverage` panel and look for `coverage-devtools-error`. DevTools creation and popup
chrome are not exercised by opening their HTML in a tab. Permission prompts, optional grants,
incognito/private browsing, installed native hosts, store signing/install/update, offline behavior,
and platform-specific APIs still need their own scenarios. The fixture does not install a native
host or change your personal browser profile.

Registered MAIN scripts, legacy `tabs.executeScript`, browser-internal failures and native-host
process internals remain native-debugger cases. Safari, Safari iOS, Android and each installed
Chromium product need real product/device checks; passing Chromium does not certify them.
See the [adapter matrix and capture limits](../../docs/architecture/web-extension-development.md).

From the Threading repository root, using a Python with the development dependencies installed:

```sh
python3 scripts/test_web_extension_contexts.py --e2e
python3 scripts/test_web_extension_contexts.py --e2e chromium-contexts --headed
node scripts/test_web_extension_hooks.js
```

The scripts copy this project into disposable directories and use the same worker as the panel.
