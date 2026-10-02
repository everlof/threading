"""Pixel contract for the native Actions button's decorative disclosure mark."""

from pathlib import Path
import subprocess


def assert_disclosure_mark(closed: Path, opened: Path, button_bounds) -> None:
    # The title ends before this trailing slot. Inspect only the mark so a changed
    # button fill, menu contents, or terminal framebuffer cannot satisfy the test.
    crop = f'14x20+{button_bounds.x + 76}+{button_bounds.y + 8}'

    def halves(path: Path) -> tuple[int, int]:
        rgba = subprocess.run(
            ['convert', str(path), '-crop', crop, '+repage', '-depth', '8', 'rgba:-'],
            check=True, capture_output=True, timeout=5,
        ).stdout
        assert len(rgba) == 14 * 20 * 4, 'Actions mark crop has unexpected dimensions'
        rows = []
        for y in range(20):
            row = 0
            for x in range(14):
                offset = (y * 14 + x) * 4
                red, green, blue = rgba[offset:offset + 3]
                if min(red, green, blue) >= 170:
                    row += 1
            rows.append(row)
        return sum(rows[:10]), sum(rows[10:])

    closed_top, closed_bottom = halves(closed)
    open_top, open_bottom = halves(opened)
    assert closed_top + closed_bottom >= 12, 'closed Actions mark is not visible'
    assert open_top + open_bottom >= 12, 'open Actions mark is not visible'
    assert closed_top >= closed_bottom + 4, 'closed Actions mark does not point down'
    assert open_bottom >= open_top + 4, 'open Actions mark does not point up'
