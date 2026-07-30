# Product screenshot plan

The website must use captures from real macOS and iOS builds. CSS facsimiles can
remain useful for diagrams and theme previews, but they are not product
screenshots.

## Capture principles

- Use deterministic synthetic projects, conversations, diffs, and account
  names. Never capture a developer's real repository or provider history.
- Capture the shipping interface from DEBUG-only fixtures. Do not maintain a
  second marketing implementation of the app.
- Freeze time, elapsed durations, rate limits, file paths, and process state so
  recaptures do not drift.
- Keep uncompressed PNG masters in the repository. The website may generate
  AVIF or WebP derivatives.
- Capture both System and Editorial where the visual story benefits, but use
  one theme consistently inside a single sequence.
- Keep fixture copy independent of the working product name.

## Required scenes

| ID | Platform | Scene | What it proves |
| --- | --- | --- | --- |
| `mac-attention` | macOS | Several active sessions with working, needs-you, and review states | The app turns concurrent work into an attention model |
| `mac-conversation` | macOS | Native conversation with tool activity and an inline permission | Decisions stay attached to their cause |
| `mac-subagents` | macOS | Parent session with a visible child tree and results | Delegation does not disappear into a flat log |
| `mac-git-review` | macOS | File list, text diff, and staging boundary | Conversation connects to reviewable changes |
| `ios-sessions` | iOS | Paired session list with attention states | Important work follows away from the desk |
| `ios-permission` | iOS | Shared conversation and scoped approval | Remote decisions remain explicit |
| `ios-review` | iOS | Compact Git review | The companion supports review without pretending to be the Mac |

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

## Capture harness

The repository already has deterministic AppKit render tests controlled by
`THREADING_RENDER_OUT`, including conversation, Git review, theme settings, and
full theme renders. iOS already has `THREADING_MOBILE_DEMO` fixtures for pairing,
permissions, new sessions, review, and themed dialogs.

Build on those foundations:

1. Add a DEBUG-only `THREADING_MARKETING_SCENE` router to the macOS app.
2. Extend `THREADING_MOBILE_DEMO` with the seven named scenes above.
3. Seed both platforms from one small marketing-fixture package so names,
   messages, session state, and diffs agree.
4. Add a `ThreadingMarketingUITests` target that launches each scene at its
   canonical size and writes a named PNG.
5. Add `scripts/capture_marketing_screenshots.sh` as the single local entry
   point.
6. Validate dimensions, expected scene count, and accidental sensitive strings
   before assets can be synced into `web/public/product/`.

## Website asset contract

The website should reference stable semantic names such as
`/product/mac-attention.webp`, never simulator-generated filenames. A manifest
records the source PNG digest, crop, output dimensions, and generated formats.
This lets CI detect stale derivatives after a new capture.
