"""Pixel contract for the production Actions icon and its selected menu state."""

from pathlib import Path
import subprocess


def assert_actions_mark(closed: Path, opened: Path, button_bounds) -> None:
    crop = f'{button_bounds.width}x{button_bounds.height}+{button_bounds.x}+{button_bounds.y}'

    def pixels(path: Path) -> bytes:
        rgba = subprocess.run(
            ['convert', str(path), '-crop', crop, '+repage', '-depth', '8', 'rgba:-'],
            check=True, capture_output=True, timeout=5,
        ).stdout
        assert len(rgba) == button_bounds.width * button_bounds.height * 4, \
            'Actions mark crop has unexpected dimensions'
        return rgba

    normal, selected = pixels(closed), pixels(opened)
    # Three disconnected dark runs across the centered glyph distinguish ellipsis artwork
    # from a changed plate or a menu repaint elsewhere in the window.
    maximum_runs = 0
    for y in range(button_bounds.height // 2 - 5, button_bounds.height // 2 + 5):
        previous = False
        runs = 0
        for x in range(5, button_bounds.width - 5):
            offset = (y * button_bounds.width + x) * 4
            ink = max(normal[offset:offset + 3]) < 120
            runs += int(ink and not previous)
            previous = ink
        maximum_runs = max(maximum_runs, runs)
    assert maximum_runs == 3, 'Actions ellipsis was not visible as three distinct dots'
    assert normal != selected, 'open menu did not paint the production control selected state'
