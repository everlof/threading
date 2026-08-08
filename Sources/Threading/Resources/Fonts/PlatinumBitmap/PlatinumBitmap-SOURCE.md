# Platinum bitmap fallback

The Platinum title and menu renderer contains a compact Swift port of the Jarrah 12 bitmap
artwork from Systemless 0.2.1. Systemless describes the face as independently hand-drawn and
conforms its advances, bearings, x-height, and cap height to the classic Macintosh 12-pixel UI
strike. It is used because Apple's Charcoal is not licensed for redistribution and modern
Geneva rasterization does not preserve the one-bit QuickDraw appearance.

- Upstream author: Ben Letchford
- Upstream package: `systemless` 0.2.1
- Source archive: `https://static.crates.io/crates/systemless/systemless-0.2.1.crate`
- Imported file: `src/quickdraw/fonts/pixel_font/chicago12.rs`
- Archive SHA-256: `07eced336ab0641a30908de47d489d22997d3613927b6fc1b01069ad9056ee14`
- License: SIL Open Font License 1.1
- Copyright: Copyright (c) 2026 Ben Letchford (https://systemless.org)
- Upstream reserved font name: `Systemless`

The glyph records were mechanically converted from readable ASCII-art rows to a compact base64
table and decoded by `PlatinumBitmapFont.swift`. The embedded representation is not exposed as a
font family and does not use the reserved Systemless or Jarrah name as the name of a modified
font. `PlatinumBitmap-OFL.txt` preserves the complete upstream font license.
