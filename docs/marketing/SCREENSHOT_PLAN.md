# Product screenshot plan

The website must use captures from real macOS and iOS builds. CSS facsimiles can
remain useful for diagrams and theme previews, but they are not product
screenshots.

## Capture principles

- Use deterministic synthetic projects, diffs, and account names. A provider TUI fixture is
  initially rendered by the installed provider from a synthetic saved session, privacy-reviewed,
  and stored as its PTY bytes. Ordinary recaptures replay that recording through SwiftTerm; they
  never spend a provider turn or read a developer's provider history. Hand-authored ANSI that only
  resembles a provider is not acceptable. Never capture a developer's real repository content.
- Capture the shipping interface from DEBUG-only fixtures. Do not maintain a
  second marketing implementation of the app.
- Freeze time, elapsed durations, rate limits, file paths, and process state so
  recaptures do not drift.
- Keep uncompressed PNG masters in the repository. The website may generate
  AVIF or WebP derivatives.
- Use the Threading theme for ordinary product workflows on both macOS and
  iOS. Use other themes only when the page is explicitly comparing themes.
- Keep the app-drawn Threading title bar, window controls, command band, and
  frame in ordinary macOS captures. A loose controller render is theme
  comparison evidence, not a full product window.
- Keep fixture copy independent of the working product name.

## Required scenes

| ID | Platform | Scene | What it proves |
| --- | --- | --- | --- |
| `mac-attention` | macOS | Several active sessions with working, needs-you, and review states | The app turns concurrent work into an attention model |
| `mac-conversation` | macOS | Experimental native conversation with tool activity and an inline permission | The structured preview keeps decisions attached to their cause |
| `mac-subagents` | macOS | Parent session with a visible child tree and results | Delegation does not disappear into a flat log |
| `mac-git-review` | macOS | File list, text diff, and staging boundary | Conversation connects to reviewable changes |
| `mac-theme-showcase` | macOS | The same full Threading workspace — project sidebar, selected session, provider TUI, display pane, and Git Review — under each compared theme | Theme masks change the app dress without changing the underlying story |
| `ios-sessions` | iOS | Paired session list with attention states | Important work follows away from the desk |
| `ios-permission` | iOS | Shared conversation and scoped approval | Remote decisions remain explicit |
| `ios-review` | iOS | Compact Git review | The companion supports review without pretending to be the Mac |
| `ios-tui` | iOS | Provider TUI with the remote composer | The established terminal session follows you from the Mac |

## Master sizes

- macOS: 1440 × 900 points at 2×, producing 2880 × 1800 PNG masters.
- iOS: capture at the simulator's native scale. The current iPhone 17 fixture
  produces 1206 × 2622 PNG masters; keep one device model for a whole sequence.
- Preserve full-frame masters. Marketing crops are derived assets, not new
  source captures.

## Current real-build seed captures

The first checked-in assets prove the real capture path before the full harness
is built:

- `docs/assets/screenshots/macos/mac-editorial-conversation.png`
- `docs/assets/screenshots/macos/mac-git-review-detail.png`
- `docs/assets/screenshots/ios/ios-permission.png`
- `docs/assets/screenshots/ios/ios-pairing.png`

The macOS files come from the real AppKit render tests. The iOS files come from
the installed DEBUG app on an iPhone 17 simulator. They are source captures,
not website-ready marketing selections. The review demo currently opens
without its synthetic host data and must be fixed before `ios-review` is
accepted.

## iOS marketing flow

The five current iOS checkpoints are one entry in the canonical evidence manifest:

1. one connected Mac, one Threading project, and four mixed Claude/Codex chats;
2. the installed Claude Code TUI recording with its structured task strip;
3. the installed Codex TUI recording;
4. Claude with the real software keyboard and complete shipping session menu open;
5. the shipping Settings root.

Run the complete story with one theme input:

```bash
scripts/capture_marketing_ios.sh --theme threading
scripts/capture_marketing_ios.sh --theme editorial
```

The checked-in PTY resources are refreshed independently, only when their synthetic story or the
installed provider version changes:

```bash
python3 scripts/record_marketing_terminal_fixtures.py
```

Claude resumes one temporary synthetic saved session under its built-in ANSI theme, including a
real `Edit` tool record and structured patch result that its installed TUI renders as the native
Update diff; the recorder deletes that exact session as soon as the terminal settles. Codex talks only to the recorder's
loopback Responses server in an ephemeral, MCP-disabled run and applies one patch inside a
disposable synthetic workspace, which makes its provider-owned Edited-files block and diff part of
the recording. Both fixtures are rendered at 62 columns. Marketing launches pin the iPhone terminal
preference to 10 points, close to the density of a real compact phone session, without changing the
shipping 13-point default. The recorder rejects private home paths, missing diff colours,
missing native file-change output and provider-startup failures before replacing a fixture.
The DEBUG marketing terminal installs the fixture's declared grid before it feeds those PTY bytes,
even though the scene retains interactive keyboard chrome. This prevents a phone-local resize from
reinterpreting provider cursor addressing and stranding incremental status updates in the prompt.

The script writes five semantically named full-display PNGs, the evidence report, and an MP4. All
five declare standard Dynamic Type and the Simulator's fixed 9:41 status treatment. Static scenes
first prove that their app-owned pixels have stabilized, then capture the composed display. The
menu capture uses accessibility labels to press the shipping toolbar control and to prove the
Usage account, Workspace, Interface, and Archive rows exist before capture. It has no coordinate
or animation delay in its contract.

The MP4 is a continuous Simulator screen recording of shipping interactions, not an assembly of
still frames. It starts in New Session, opens the real model-and-effort matrix, selects GPT-5.6 Sol
at Extra High, types the deterministic prompt and lets that draft become the fixture-backed Codex
chat. The terminal gesture then moves toward older scrollback instead of pushing past the bottom.
The flow visits Claude's task plan and finishes by changing Usage from Accounts to Totals and
scrolling the real daily-provider chart into view; Settings is deliberately absent from the movie.

The manifest fixes the run at 30 fps and 900 frames. Every action is scheduled on that absolute
frame clock, accessibility postconditions must settle before their next deadline, and a take is
rejected when any action starts more than 150 ms late. The recorder normalizes the result to the
App Store portrait size only after the live run has passed that clock, so theme variants keep the
same gestures and timestamps without adding editorial fades.

## Capture harness

The repository already has deterministic AppKit render tests controlled by
`THREADING_RENDER_OUT`, including conversation, Git review, theme settings, and
full theme renders. iOS already has `THREADING_MOBILE_DEMO` fixtures for pairing,
permissions, new sessions, review, and themed dialogs.

Build on those foundations:

1. Add a DEBUG-only `THREADING_MARKETING_SCENE` router to the macOS app.
2. Extend `THREADING_MOBILE_DEMO` only through the canonical evidence catalogue.
3. Seed both platforms from one small marketing-fixture package so names,
   messages, session state, and diffs agree.
4. Add a `ThreadingMarketingUITests` target that launches each scene at its
   canonical size and writes a named PNG.
5. Keep `scripts/capture_marketing_ios.sh` as the single iOS marketing entry point.
6. Validate dimensions, expected scene count, and accidental sensitive strings
   before assets can be synced into `web/public/product/`.

## Website asset contract

The website should reference stable semantic names such as
`/product/mac-attention.webp`, never simulator-generated filenames. A manifest
records the source PNG digest, crop, output dimensions, and generated formats.
This lets CI detect stale derivatives after a new capture.

The first version of this contract now lives in:

- `web/product-screenshot-references.json`, which names each journey checkpoint
  or evidence scene by a stable identifier;
- `web/scripts/sync-product-screenshots.mjs`, which resolves those identifiers
  from selected test reports;
- `web/public/product/manifest.json`, which records the resolved source, pixel
  size, and SHA-256 digest for each public copy.

`GitReviewRenderTests.testRendersFullThreadingShellWithTUIAndGitReview` owns the
named macOS theme-showcase captures. It drives the shipping `MainWindowController`
through its real sidebar selection, attaches the shipping provider terminal,
opens the display pane's Git Review against a temporary Git repository, and
renders the complete three-pane Threading workspace. The repository contents
are deterministic fixture data. The provider transcript is produced by one
real, read-only Codex terminal session and the same live terminal is repainted
under every theme.

Run `scripts/capture_website_tui.sh` to create those seven captures. The render
test is skipped unless that script's explicit live-capture flag is present, so
an ordinary test run never spends a provider turn. The disposable repository's
trust setting is scoped to that one command; provider-owned live-session history
keeps following the provider's normal behavior.

All images under `web/public/product/` are generated copies. Do not edit them by
hand. After capturing new macOS journey evidence, macOS surface evidence, and
iOS surface evidence, run the website's `screenshots:check` command against the
three selected reports. A changed referenced capture makes the check fail.
Review the new source image, then run `screenshots:sync` with the same paths to
update the website copies and their hashes.

The website test also rejects a product image that has no named reference, a
missing referenced image, an unexpected size, or bytes that differ from the
generated manifest. This keeps test output as the source of truth while leaving
the final update as an explicit review decision.
