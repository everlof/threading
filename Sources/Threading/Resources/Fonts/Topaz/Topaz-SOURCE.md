# Topaz Workbench fallback

`Topaz_a1200_v1.0.ttf` is dMG of TrueSchool's faithful multi-platform recreation of the
Kickstart 2.x Topaz face used by Workbench 2.x and 3.1. Threading ships it as a separate font
resource so the Workbench theme no longer falls through to Monaco when a proprietary Amiga
installation is absent.

- Upstream author: dMG of TrueSchool / Divine Stylers
- Upstream package: Multi Platform Amiga Fonts 1.02
- Repository: `https://github.com/rewtnull/amigafonts`
- Pinned revision: `d42987535d94ebbfb51e64fee76f9974c6ae145a`
- Imported file: `ttf/Topaz_a1200_v1.0.ttf`
- TTF SHA-256: `da95bfdd6d16ac3602f64ae01699808efede94665fa2a7ac5f33e61641a67e14`
- Embedded CoreText family: `Topaz a600a1200a400`
- License: GNU GPL with the GNU font exception (upstream calls this GPL-FE)
- Copyright notice: Topaz © AmigaInc.; TTF conversion © 2009 dMG/t!s^dS!

`Topaz-UPSTREAM-README.txt` is the complete upstream package readme and copyright/license
notice. `Topaz-GPL-2.0.txt` preserves the full GNU GPL v2 text, and
`Topaz-FONT-EXCEPTION.txt` preserves the exception wording linked by upstream. The face is not
modified. Its source/download location and exact checksum are also pinned in
`docs/references/chrome/implementation-sources.json`.

The upstream prose names the target machines A600/A1200/A4000, but the TTF's family name table
contains `Topaz a600a1200a400`. Production must request that embedded spelling; requesting the
human-readable spelling silently resolves the next fallback instead.
