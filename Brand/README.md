# Threading brand assets

`ThreadingMark.svg` is the canonical two-orange display mark.
`ThreadingMarkMono.svg` is the canonical single-color small mark.
`ThreadingAvatar.svg` is the social account avatar — the mono mark on the navy
ground, held to 68% of the frame so the circular crop every network applies
cannot reach the hexagon's corners. Upload `ThreadingAvatar-400.png` to X.

The locked provisional palette is:

- navy ground: `#07172B`
- burnt orange: `#C95726`
- middle orange: `#D9692B`
- bright orange: `#FF9A3D`
- mono orange: `#F28A36`

Run `scripts/export_brand_assets.sh` after changing either SVG. It regenerates
the checked-in PNG masters and synchronizes the website and static app-icon
inputs. Runtime themed Dock geometry is drawn in
`Sources/Threading/UI/Design/GeneratedAppIcon.swift` and is pinned against the
iOS generator by `AppIconRenderTests`. Run `scripts/generate_mobile_theme_icons.sh` to rebuild
the manually selectable iOS stock-theme alternates and their Settings previews from that same
Dock renderer.
