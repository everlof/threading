#!/usr/bin/env python3
"""Build the field index from AppThemeSchemaReferenceTests' theme-schema.json export.

Usage: python3 scripts/generate_theme_reference.py <render-dir>/theme-schema.json
The fast test checks every field against the resulting checked-in page.
"""
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parents[1]
entries = json.loads(pathlib.Path(sys.argv[1]).read_text())
layers = {"Palette": [], "Material": [], "Chrome": [], "Character": []}
for path, schema in sorted(entries.items()):
    head = path.split(".")[0]
    layer = ("Palette" if head in ("roles", "terminal_colors") else
             "Material" if head == "material" else "Chrome" if head == "chrome" else "Character")
    layers[layer].append((path, schema))

intro = """# Theme reference

The field index for `variants.light` and `variants.dark` in `create_app_theme` and
`update_app_theme`. Omitted values inherit; explicit `remove_*` flags clear inherited blocks.
Built-in themes must be duplicated before editing. The host owns validation, asset loading,
motion gates and persistence. Themes and extensions only supply presentation.

Call `get_app_theme(section: "schema")` for the block index, then request a dotted path such as
`material.backdrop`, `sidebar.mascot`, `title_morph` or `terminal_colors.glow` for complete
authoring documentation. Array members use dotted paths too (`sprites.source.path`).
Without `section`, `get_app_theme` still returns the theme document.

The **meaning and limits** column is generated from the same schema the describe path returns;
validators remain authoritative, and range prose is generated from their limit constants.
`AppThemeSchemaReferenceTests` fails when a field has no row, when a row's text is stale, and
when a row names a field the schema no longer has.
To refresh: run that test with `THREADING_RENDER_OUT` set, then
`python3 scripts/generate_theme_reference.py <render-dir>/theme-schema.json`.
For decisions and measured tradeoffs, read [themes.md](themes.md).

`Mac` means the shipping window. `Preview` means `preview_app_theme`; a still sample does not
exercise event delivery or perpetual motion. `Phone` is limited to the fields stated below;
unprojected fields remain Mac-only. Owner paths are relative to `Sources/Threading/`.
This page does not claim per-field test coverage: a list kept by hand here only ever guessed.
Find the tests for a field by searching `Tests/` for its owner type or wire name.

Phone images use bounded PNG renditions: backdrop/sidebar fallback 1,290 px, mascot 512 px,
sprites 128 px; at most 1 MB each and 6 MB per theme. Backgrounds always aspect-fill and opacity
is capped at 0.25. Mascot layout, visibility, mood selection and motion gates are host-owned; the
logo stays on the Mac.
Typeface and process-registered owner fonts affect chrome; message bodies retain their own fonts.
Font assets use four 16 MiB slots and 1 MiB ranged requests. Attention/turn-finished sounds use
verified CAF receipts and notification consent; terminal glow uses the shared GPU renderer.
One reviewed current sidebar shader may travel through the asset route; window chrome stays Mac-only.

"""

def ownership(path):
    if path.startswith("roles"):
        where = "Mac chrome; Phone palette; Preview"
        if path in ("roles.bevel_highlight", "roles.bevel_shadow"):
            where = "Mac chrome; Preview (Phone carries the colour but draws no bevel)"
        return (where, "AppThemeEditing / LabelLegibility", "Core/Theme/AppThemeRole.swift")
    if path.startswith("terminal_colors"):
        glow = ".glow" in path or "remove_glow" in path
        return ("Mac/Phone terminal; Preview", "TerminalGlow" if glow else "ThemeContrast / AppThemeEditing", "Models/TerminalGlow.swift" if glow else "Models/TerminalTheme.swift")
    if path.startswith("chrome"):
        return ("Mac window frame; Preview title band", "WindowChromeStyle / AppThemeEditing", "Core/Theme/WindowChromeStyle.swift")
    if path.startswith("material"):
        phone = path in ("material", "material.backdrop") or any(path == "material." + field or path.startswith("material." + field + ".") for field in
                    ["panel_radius", "control_radius", "border_width", "glow", "backdrop.gradient",
                     "backdrop.image", "backdrop.particles", "typeface", "font_family", "identity_marks"])
        if path in ("material.backdrop.image.mode", "material.backdrop.image.alignment"):
            phone = False
        owner = "Core/Theme/AppTheme.swift"
        if path.startswith("material.backdrop"):
            owner = "Core/Theme/ThemeParticles.swift" if path.startswith("material.backdrop.particles") else "Core/Theme/ThemeBackdrop.swift"
        return ("Mac; Preview" + ("; Phone" if phone else ""), "AppThemeEditing", owner)
    if "title_morph" in path:
        return ("Mac/Phone names", "ThemeTitleMorphLimits / AppThemeEditing", "Core/Theme/ThemeTitleMorph.swift")
    if path.startswith("words") or path == "remove_words":
        return ("Mac status/composer/title; Phone words", "ThemeWordsLimits / AppThemeEditing", "Core/Theme/ThemeWords.swift")
    if path.startswith("sidebar"):
        parts = path.split(".")
        pose_picture = (path.startswith("sidebar.mascot.poses.")
                        and (len(parts) == 4 or parts[4] == "source"))
        phone = (path in ("sidebar.mascot", "sidebar.mascot.poses") or pose_picture
                 or path == "sidebar.image" or path.startswith("sidebar.image.source")
                 or path == "sidebar.image.opacity")
        return ("Mac sidebar; Preview" + ("; Phone image rendition" if phone else ""), "SidebarAppearance / AppThemeEditing / ThemeAssetStore", "Core/Theme/SidebarAppearance.swift")
    if path.startswith("sprites"):
        return ("Mac decoration; Preview; Phone particles (first 8)", "ThemeSpriteLimits / AppThemeEditing / ThemeAssetStore", "Core/Theme/ThemeSprite.swift")
    if path.startswith("moments"):
        return ("Mac events; Phone attention/turn-finished notification sound only", "ThemeMomentLimits / AppThemeEditing / ThemeAssetStore", "Core/Theme/ThemeMoments.swift")
    return ("Mac decoration/events; Preview stills", "AppThemeEditing / ThemeAssetStore", "Core/Theme/ThemeParticles.swift")

lines = [intro]
for layer, rows in layers.items():
    lines += [f"## {layer}\n\n", "| Wire path | Meaning and limits | Drawn where | Validator | Owner |\n",
              "|---|---|---|---|---|\n"]
    for path, schema in rows:
        description = " ".join(schema["description"].split()).replace("|", "\\|")
        where, validator, owner = ownership(path)
        lines.append(f"| `{path}` | {description} | {where} | {validator} | `{owner}` |\n")
    lines.append("\n")
(root / "docs/architecture/theme-reference.md").write_text("".join(lines).rstrip() + "\n")
