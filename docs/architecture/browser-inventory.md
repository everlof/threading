# Browser inventory

This is the implementation inventory for Skalman's visible browser and its agent surface. It
records the product boundary behind each browser-like control so future work does not accidentally
promise Chrome parity where WebKit or the trust model differs.

Part of the [CLAUDE.md](../../CLAUDE.md) index and the
[agent-browser architecture](agent-browser.md).

| Area | Visible browser | Agent surface | Status and boundary |
| --- | --- | --- | --- |
| Navigation | Back, forward, reload/stop, address/search, reload from origin | Navigate, history, stop, tabs, bounded pop-ups | Complete |
| Responsive testing | Device toolbar, editable width/height, rotate, reset, 12 named presets | `browser_resize`; isolated browser for fuller emulation | Complete for CSS viewport; presets do not claim touch, DPR, mobile identity, or hardware emulation |
| Test conditions | Theme-owned color scheme, CSS media, and User-Agent controls | `browser_emulate`, `browser_capabilities`, `browser_run_isolated` | Complete with unsupported WebKit conditions reported honestly |
| Annotation | Native annotation mode, numbered pins, edit/delete | Read-only `browser_annotations` | Complete; user-authored runtime state stays outside the DOM and is returned separately from untrusted page data |
| Page discovery | Find bar with live next/previous search | Semantic snapshots, strict query, waits | Complete |
| Interaction | Normal WebKit pointer/keyboard behavior and inspector | Ref, selector, semantic locator, coordinate, form-fill, key, hover, drag, scroll | Complete within the documented semantic and safety bounds |
| Visual inspection | Visible-page screenshot save | Viewport/full-page/element screenshot and visual compare | Complete; native annotation pins remain a separate trusted layer rather than being baked into page pixels |
| Print and zoom | Native print panel; 50–200% per-tab zoom | Page state and screenshot reflect zoom | Complete |
| Diagnostics | Web Inspector | Console, network metadata, performance, trace, accessibility audit | Complete; no bodies, headers, cookies, or credentials |
| Authentication | WebKit/macOS passkeys and AutoFill when offered; private-field refocus | Password field triggers user takeover | Complete safe boundary; Skalman never reads a vault or password |
| Uploads | Native open panel | Agent may suggest existing paths, user approves | Complete |
| Downloads | Native save panel and current-runtime recent download list | One action bound to a user-approved destination | Complete for active runtime; this is not a persistent browser-wide download manager |
| Website data | Clear current site's data with native destructive confirmation | `browser_storage clear_site_data` | Complete at the safe per-site boundary; no global time-range cleaner |
| Permissions/settings | Tools settings shortcut and per-origin Website Access grants | Origin authorization on every browser read/action result | Complete |
| Isolation | Shared persistent or per-tab private WebKit data store | Fresh Playwright Chromium, Firefox, or WebKit context | Complete; isolated runs never import live cookies, credentials, history, or storage |
| Cookie/password import | Not exposed | Not exposed | Intentionally absent: importing secrets would cross the agent and credential boundary |

## Deliberate non-goals

- Chrome DevTools device identity emulation inside `WKWebView`.
- A password-vault API, 1Password CLI integration, or plaintext credential handoff.
- Browser-wide cookie/password import.
- Treating a current-runtime download list as durable download history.
- Mixing trusted user annotations into the page's untrusted DOM snapshot or screenshot pixels.
