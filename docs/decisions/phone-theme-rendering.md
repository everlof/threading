# Phone theme fonts, glow, shaders, sounds and widget accent

Date: 2026-10-04. Decision: implement the remaining theme brief items on the paired phone.

Fonts supplied with a theme may travel to the owner's paired devices. They are private theme
assets, registered in the receiving process with CoreText, and affect titles and chrome only.
Message bodies and terminal fonts retain their own typography. This copies the person's supplied
font to their device rather than distributing it publicly or installing it system-wide.
Missing, unsupported or corrupt fonts fall back to the native typeface hint. Font files remain
bounded to four at 16 MiB each; transfers use requests of at most 1 MiB and verified SHA-256.

Terminal glow belongs to SwiftTerm's shared renderer. Metal paints foreground ink into a
bounded offscreen texture, blurs on the GPU and composites beneath explicit cell backgrounds.
It does not glow images, decorations or the caret. No glow means no extra texture or passes.
The phone disables it in Low Power Mode. A dense full-screen redraw must meet the 60 fps
device budget before accepting the shipping path; simulator timing is not that measurement.
The Core Graphics path retains pixel-equivalent partial redraws and a bounded dirty-span
underlay cache (64 entries / 16 MiB). Live Metal uses a half-resolution halo when support is at
least four device pixels, while preserving the full-resolution foreground.

The Mac may project one currently enabled, reviewed backdrop Metal surface. It sends only
the admitted source, scalar bindings and optional texture through authenticated theme assets;
no extension executable, token, host capability or process runs on the phone. Appearance packs
remain Mac-owned: activating or releasing one changes the projected surface. The phone owns
one passive surface per visible screen, at most 24 fps and 1,290 pixels on its long side.
It freezes for Reduce Motion and stops for hidden/background/Low Power states. Audio is
unavailable, and phone-local workload, theme and moment values obey local reaction controls.
Repeated GPU frames above a four-millisecond budget withdraw the surface until it is replaced.

Theme attention and turn-finished sounds may be installed into the phone's private
`Library/Sounds` after bounded conversion to CAF, under 30 seconds and 1 MiB. A push names a
custom sound only after that device confirms the matching digest is installed, while its
current sound preference and preview consent still permit it. Missing, retired or unconfirmed
sounds use the ordinary default or silence. Theme selection cannot grant notification consent.

Usage widgets carry only the pinned Mac's resolved accent. Account identity, freshness,
readings, backgrounds and semantic foregrounds remain host/system-owned. WidgetKit's tinted
and vibrant presentation wins over the authored accent. No images, fonts, shaders, credentials
or additional theme palette enter the App Group.

Preparation, font parsing/registration, sound conversion and asset I/O are bounded worker
operations. Hot layout and frame callbacks read prepared values only. The new presentations
reuse existing theme/extension contracts; no new extension execution authority is introduced.
