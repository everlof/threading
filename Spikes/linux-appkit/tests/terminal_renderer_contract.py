"""The optimized renderer must match direct Pango for identical screen-cell values."""
import ctypes as c
import os
import sys

class Cell(c.Structure):
    _fields_ = [("offset", c.c_int), ("length", c.c_int), ("width", c.c_int),
                ("foreground", c.c_uint32), ("background", c.c_uint32),
                ("bold", c.c_int), ("underline", c.c_int)]
renderer = c.CDLL(sys.argv[1]).tw_render_terminal
renderer.argtypes = [c.POINTER(c.c_ubyte), c.c_int, c.c_int, c.POINTER(Cell), c.c_int, c.c_int,
                     c.c_char_p, c.c_int, c.c_int, c.c_int,
                     c.c_char_p, c.c_int, c.c_int, c.c_int]
renderer.restype = c.c_int
columns, rows = 40, 12
cells = (Cell * (columns * rows))()
text = bytearray()
for i in range(len(cells)):
    glyph = chr(32 + i % 95) if i % 7 else "e\u0301"
    encoded = glyph.encode()
    cells[i] = Cell(len(text), len(encoded), 1, 0x285080 + i * 113, 0x101820 + i * 31, i % 2, i % 3 == 0)
    text.extend(encoded)
# A wide glyph and its continuation exercise clipping/backgrounds around cached ASCII.
encoded = "界".encode()
cells[41] = Cell(len(text), len(encoded), 2, 0xBADA55, 0x17191D, 0, 0)
text.extend(encoded)
cells[42] = Cell(0, 0, 0, 0xFFFFFF, 0x17191D, 0, 0)

def draw(reference, preedit=b""):
    os.environ["THREADING_TERMINAL_REFERENCE_RENDERER"] = "1" if reference else "0"
    pixels = (c.c_ubyte * (columns * 10 * rows * 22 * 4))()
    assert renderer(pixels, columns * 10, rows * 22, cells, columns, rows, bytes(text), len(text),
                    7, 10, preedit, len(preedit), 0, 2) == 0
    return bytes(pixels)
expected = draw(True)
for _ in range(3):
    actual = draw(False)
    assert actual == expected, f"cached renderer changed {sum(a != b for a, b in zip(actual, expected))} channel bytes"
composition = "你好".encode()
assert draw(False, composition) != actual, "uncommitted text has no visible preview"
assert draw(True, composition) == draw(False, composition), "preedit changed cached terminal pixels"
scratch = (c.c_ubyte * (columns * 10 * rows * 22 * 4))()
assert renderer(scratch, columns * 10, rows * 22, cells, columns, rows, bytes(text), len(text),
                7, 10, b"\xff", 1, 0, 0) != 0, "invalid preedit was rendered"
print("PASS cached and direct Pango pixels match for ASCII weights, colors, underlines, combining and wide cells")
print("PASS bounded Pango IME preedit renders Unicode and refuses invalid UTF-8")
