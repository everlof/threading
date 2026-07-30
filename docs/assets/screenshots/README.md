# Product screenshot sources

These files are captured from the real macOS and iOS implementations. They are
not CSS recreations of the product.

## Current captures

| File | Source | Status |
| --- | --- | --- |
| `macos/mac-editorial-conversation.png` | AppKit conversation render test with the Editorial theme | Valid source capture; needs a marketing crop |
| `macos/mac-git-review-detail.png` | AppKit Git review render test | Valid source capture; needs neutral fixture copy after the product rename |
| `ios/ios-permission.png` | Installed DEBUG app, `THREADING_MOBILE_DEMO=permission` | Valid full-screen source capture |
| `ios/ios-pairing.png` | Installed DEBUG app, `THREADING_MOBILE_DEMO=pairing` | Valid full-screen source capture; recapture after the product rename |

Do not copy these directly into the website and rename them by hand. The
capture and derivative pipeline in `docs/marketing/SCREENSHOT_PLAN.md` defines
the stable scene names, sanitization checks, crops, and web formats.
