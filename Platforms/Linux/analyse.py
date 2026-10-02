#!/usr/bin/env python3
"""Groups the sweep's missing symbols into subsystems and asks the only question that matters
when a gap list has 116 entries: how much of it has to close before any file is actually freed.

A ranked list of missing symbols reads like a queue. It is not one — it is a conjunction, and a
file compiles when its *last* blocker goes, not its first. This prints both the per-bucket counts
and the greedy cumulative curve, so the difference is visible instead of assumed.

    ./analyse.py [out/sweep.tsv]
"""
import sys
from collections import Counter

SWEEP = sys.argv[1] if len(sys.argv) > 1 else "out/sweep.tsv"

TEXT = {
    "NSTextField", "NSTextView", "NSText", "NSTextFieldDelegate", "NSMutableParagraphStyle",
    "NSParagraphStyle", "NSAttributedString", "NSString", "NSTextAlignment", "NSLayoutManager",
    "NSTextContainer", "NSTextStorage", "NSUnderlineStyle", "NSFont", "NSFontDescriptor",
    "NSFontManager", "NSSearchField", "NSSecureTextField",
}
IMAGE = {
    "NSImage", "NSImageView", "NSBitmapImageRep", "NSImageInterpolation", "NSImageRep",
    "CGImage", "CGImageAlphaInfo", "CGDataProvider", "CGColorSpace", "NSImageScaling", "NSShadow",
}
EVENTS = {
    "NSEvent", "NSCursor", "NSTrackingArea", "NSResponder", "NSPasteboard",
    "NSHapticFeedbackManager", "NSMenu", "NSMenuItem", "NSGestureRecognizer",
}
WINDOW = {
    "NSWindow", "NSScreen", "NSApp", "NSApplication", "NSViewController", "NSWorkspace",
    "NSVisualEffectView", "NSColorWell", "NSAlert", "NSPopover", "NSAppearance", "NSAnimationContext",
}
CONTROLS = {
    "NSControl", "NSButton", "NSTableView", "NSTableColumn", "NSTableRowView",
    "NSTableViewDelegate", "NSTableViewDataSource", "NSOutlineView", "NSScrollView", "NSScroller",
    "NSSlider", "NSSwitch", "NSSegmentedControl", "NSPopUpButton", "NSComboBox",
    "NSProgressIndicator", "NSCollectionView", "NSSplitView", "NSClipView", "NSBox", "NSStepper",
}
LAYERS_PREFIX = ("CA",)
LAYERS = {"CGContext", "CGPath", "CGMutablePath", "CGColor", "CATransform3D", "CGContextShim"}
STACK = {"NSStackView", "NSGridView"}
LAYOUT = {"NSLayoutConstraint", "NSLayoutGuide", "NSLayoutAnchor", "NSLayoutDimension"}


def bucket(symbol: str) -> str:
    head = symbol.split(".")[0]
    if symbol.startswith("NSAccessibility") or head == "NSAccessibility":
        return "accessibility"
    if head in TEXT or head.startswith("CT"):
        return "text"
    if head in STACK:
        return "stack views"
    if head in IMAGE:
        return "images"
    if head in LAYERS or head.startswith(LAYERS_PREFIX):
        return "layers/CG"
    if head in EVENTS:
        return "input/events"
    if head in WINDOW:
        return "window/app"
    if head in CONTROLS:
        return "controls"
    if head in LAYOUT:
        return "layout"
    return f"other ({head})"


rows = [line.rstrip("\n").split("\t") for line in open(SWEEP)]
gap = []
for row in rows:
    if len(row) < 2 or row[1] != "shim-gap":
        continue
    symbols = [s for s in (row[2].split(",") if len(row) > 2 else []) if s]
    gap.append((row[0], {bucket(s) for s in symbols}))

print(f"{len(gap)} files with a gap, out of {len(rows)}")
print()
print("files blocked by exactly N subsystems:")
for count, files in sorted(Counter(len(b) for _, b in gap).items()):
    print(f"  {count} subsystem(s): {files} files")
print()

single = Counter(next(iter(b)) for _, b in gap if len(b) == 1)
print("blocked by one subsystem only (closing it frees the file outright):")
for name, count in single.most_common():
    print(f"  {name:16s} {count}")
if not single:
    print("  none")
print()

print("greedy cumulative — closing the subsystem that frees the most, repeatedly:")
remaining = {name: set(b) for name, b in gap}
closed = []
while remaining:
    tally = Counter()
    for blockers in remaining.values():
        for blocker in blockers:
            tally[blocker] += 1
    if not tally:
        break
    pick = tally.most_common(1)[0][0]
    closed.append(pick)
    for name in list(remaining):
        remaining[name].discard(pick)
        if not remaining[name]:
            del remaining[name]
    freed = len(gap) - len(remaining)
    print(f"  after {', '.join(closed):<70s} {freed:3d}/{len(gap)} clear")
    if len(closed) >= 10:
        break
