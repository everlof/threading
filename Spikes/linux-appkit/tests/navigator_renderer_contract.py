"""The Linux list text leaf shapes Unicode inside mounted row rectangles."""
import ctypes as c
import sys


class Row(c.Structure):
    _fields_ = [(field, c.c_int) for field in
                ('x', 'y', 'width', 'height', 'inset', 'offset', 'length', 'selected')]


draw_labels = c.CDLL(sys.argv[1]).tw_draw_navigator_labels
draw_labels.argtypes = [c.POINTER(c.c_ubyte), c.c_int, c.c_int,
                        c.POINTER(c.c_ubyte), c.c_int, c.POINTER(Row), c.c_int]
draw_labels.restype = c.c_int
width, height = 320, 180
base = bytes((222, 222, 222, 255)) * (width * height)


def draw(text, selected=0, row=None):
    encoded = text.encode('utf-8')
    content = (c.c_ubyte * len(encoded)).from_buffer_copy(encoded)
    rect = row or Row(12, 56, 296, 44, 52, 0, len(encoded), selected)
    pixels = (c.c_ubyte * len(base)).from_buffer_copy(base)
    assert draw_labels(pixels, width, height, content, len(encoded),
                       c.pointer(rect), 1) == 0
    return bytes(pixels)


unicode = draw('Project06-界 e\u0301')
assert unicode != draw('Project06-? e?'), 'Unicode was replaced before shaping'
selected = draw('Project06-界 e\u0301', selected=1)
assert unicode != selected, 'selection did not change ink'
assert any(unicode[index] != base[index] for index in range(len(base)))
for frame in (unicode, selected):
    for offset in range(0, len(frame), 4):
        assert frame[offset] == frame[offset + 1] == frame[offset + 2], \
            'transparent intermediate introduced colored text fringes'
for y in range(height):
    for x in range(width):
        if 64 <= x < 296 and 56 <= y < 100:
            continue
        offset = (y * width + x) * 4
        assert unicode[offset:offset + 4] == base[offset:offset + 4], (x, y)

pixels = (c.c_ubyte * len(base)).from_buffer_copy(base)
bad = (c.c_ubyte * 1)(255)
row = Row(12, 56, 296, 44, 52, 0, 1, 0)
assert draw_labels(pixels, width, height, bad, 1, c.pointer(row), 1) != 0
assert bytes(pixels) == base, 'invalid text mutated the frame'
good = (c.c_ubyte * 1)(ord('a'))
row = Row(12, 56, 309, 44, 52, 0, 1, 0)
assert draw_labels(pixels, width, height, good, 1, c.pointer(row), 1) != 0
rows = (Row * 34)(*[Row(12, 56, 296, 44, 52, 0, 1, 0) for _ in range(34)])
assert draw_labels(pixels, width, height, good, 1, rows, 34) != 0
print('PASS bounded Pango navigator text preserves Unicode, selection ink and row clipping')
