# README images

The images the root `README.md` shows. They are the same files threading.codes serves under
`/product/`, copied unchanged, and every one is a capture of the real macOS or iOS app over
synthetic fixture data — never a developer's own projects or chats.

| File | Source |
| --- | --- |
| `mac-threading-claude-review.png` | `Tests/ThreadingTests/MarketingWindowRenderTests.swift` (`THREADING_RENDER_OUT`), a recorded Claude Code TUI replayed through SwiftTerm |
| `mac-git-review.png` | The Git Review pane render test, Threading theme, dark |
| `theme-tui-swiss.png`, `theme-tui-cyberpunk.png` | The shared theme capture fixture, Swiss Minimalist (light) and Cyberpunk (dark) |
| `ios-session-list.png`, `ios-claude-tui.png`, `ios-codex-tui.png` | `scripts/capture_marketing_ios.sh` App Store captures (`fastlane/marketeer`), scaled to half size |

`docs/marketing/SCREENSHOT_PLAN.md` defines the capture pipeline and its privacy rules. Replace
these with fresh captures from that pipeline rather than with screenshots of a working setup.
