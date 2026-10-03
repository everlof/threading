#!/usr/bin/env python3
"""Export Threading's authored OKLCH house palette for the Linux AppKit host.

This reads the two production AppThemeStyles.threading variants and applies the same
OKLCH gamut mapping and AppTheme role derivations. The hosted Mac XCTest checks the
result against production AppTheme.resolved and TerminalTheme values when available.
"""

import json
import math
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
STYLES = ROOT / "Sources/Threading/Core/Theme/AppThemeStyles.swift"
ROLES = ROOT / "Sources/Threading/Core/Theme/AppThemeRole.swift"
OUTPUT = ROOT / "Platforms/Linux/Sources/WindowHarness/Resources/Theme/threading.json"


def oklch(lightness, chroma, hue, alpha=1.0):
    radians = math.radians(hue)
    a = chroma * math.cos(radians)
    b = chroma * math.sin(radians)

    def linear_channels(scale):
        aa, bb = a * scale, b * scale
        long = (lightness + 0.3963377774 * aa + 0.2158037573 * bb) ** 3
        medium = (lightness - 0.1055613458 * aa - 0.0638541728 * bb) ** 3
        short = (lightness - 0.0894841775 * aa - 1.2914855480 * bb) ** 3
        return (
            4.0767416621 * long - 3.3077115913 * medium + 0.2309699292 * short,
            -1.2684380046 * long + 2.6097574011 * medium - 0.3413193965 * short,
            -0.0041960863 * long - 0.7034186147 * medium + 1.7076147010 * short,
        )

    def fits(scale):
        return all(-0.0005 <= value <= 1.0005 for value in linear_channels(scale))

    scale = 1.0
    if not fits(scale):
        low, high = 0.0, 1.0
        for _ in range(24):
            middle = (low + high) / 2
            if fits(middle):
                low = middle
            else:
                high = middle
        scale = low

    def encode(value):
        value = min(max(value, 0.0), 1.0)
        return value * 12.92 if value <= 0.0031308 else 1.055 * value ** (1 / 2.4) - 0.055

    return [encode(value) for value in linear_channels(scale)] + [alpha]


def parse_colors(block):
    colors = {}
    for name, values in re.findall(r"(?:\.|\b)(\w+):\s*oklch\(([^)]*)\)", block):
        numbers = [float(value.strip().removeprefix("alpha:")) for value in values.split(",")]
        colors[name] = oklch(*numbers)
    return colors


def alpha(color, value):
    return color[:3] + [value]


def lightened(color, amount):
    target = 1.0 if amount >= 0 else 0.0
    return [channel + (target - channel) * abs(amount) for channel in color[:3]] + [color[3]]


def derived(name, roles, dark):
    if name == "fieldSurface":
        return roles["panel"]
    if name in ("floatingSurface", "tooltipSurface"):
        return roles["elevated"]
    if name == "elevated":
        return lightened(roles["panel"], 0.06 if dark else -0.04)
    if name == "controlResting":
        return alpha(roles["label"], 0.08)
    if name == "controlHover":
        return alpha(roles["label"], 0.14)
    if name == "divider":
        return alpha(roles["border"], 0.5)
    if name in ("secondaryLabel", "tertiaryLabel", "quaternaryLabel"):
        return alpha(roles["label"], {
            "secondaryLabel": 0.7, "tertiaryLabel": 0.45, "quaternaryLabel": 0.25,
        }[name])
    if name == "accentMuted":
        return alpha(roles["accent"], 0.22)
    if name == "selection":
        return alpha(roles["accent"], 0.35)
    if name == "diffAdded":
        return roles["statusPositive"]
    if name == "diffRemoved":
        return roles["statusNegative"]
    if name == "syntaxComment":
        return alpha(roles["label"], 0.45)
    if name == "surface":
        return roles["ground"]
    if name == "panel":
        return lightened(roles["surface"], 0.05 if dark else -0.03)
    if name == "bevelHighlight":
        return lightened(roles["surface"], 0.45)
    if name == "bevelShadow":
        return lightened(roles["surface"], -0.45)
    raise ValueError(f"Unresolved production role: {name}")


def main():
    source = STYLES.read_text()
    role_source = ROLES.read_text().split("public var systemColor", 1)[0]
    names = re.findall(r"^\s*case (\w+)\s*(?:$|///)", role_source, re.MULTILINE)
    variants = {}
    for mode in ("light", "dark"):
        match = re.search(
            rf"private static let threading{mode.title()} = AppTheme\.Variant\(\s*"
            rf"roles:\s*\[(.*?)\],\s*terminalPalette:\s*TerminalTheme\((.*?)\),\s*material:",
            source, re.DOTALL,
        )
        if not match:
            raise ValueError(f"Could not find Threading {mode} variant")
        roles = parse_colors(match.group(1))
        terminal = parse_colors(match.group(2))
        for name in names:
            if name not in roles:
                roles[name] = derived(name, roles, mode == "dark")
        roles.update({f"terminal.{name}": color for name, color in terminal.items()})
        variants[mode] = {
            name: [round(value, 6) for value in color]
            for name, color in roles.items()
        }
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(variants, indent=2, sort_keys=True) + "\n")
    print(f"Exported {len(variants['light'])} light and {len(variants['dark'])} dark roles to {OUTPUT}")


if __name__ == "__main__":
    main()
