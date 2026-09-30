"""The Linux list text leaf shapes Unicode inside mounted row rectangles."""
import ctypes as c
import sys


class Row(c.Structure):
    _fields_ = [(field, c.c_int) for field in
                ('x', 'y', 'width', 'height', 'inset', 'offset', 'length', 'selected', 'trailingInset', 'detail')]

    def __init__(self, *values):
        super().__init__(*(values + (12, 0) if len(values) == 8 else values))


library = c.CDLL(sys.argv[1])
draw_labels = library.tw_draw_navigator_labels
draw_labels.argtypes = [c.POINTER(c.c_ubyte), c.c_int, c.c_int,
                        c.POINTER(c.c_ubyte), c.c_int, c.POINTER(Row), c.c_int]
draw_labels.restype = c.c_int
# Measure the shipping Pango font without a width/ellipsis constraint. A status must fit in
# its reserved region in full; merely seeing ink would also pass a truncated 'Retai…'.
def pointer_function(name, arguments):
    function = getattr(library, name)
    function.argtypes, function.restype = arguments, c.c_void_p
    return function


font_map = pointer_function('pango_cairo_font_map_get_default', [])()
context = pointer_function('pango_font_map_create_context', [c.c_void_p])(font_map)
layout = pointer_function('pango_layout_new', [c.c_void_p])(context)
font = pointer_function('pango_font_description_from_string', [c.c_char_p])(b'DejaVu Sans')
library.pango_font_description_set_absolute_size.argtypes = [c.c_void_p, c.c_double]
library.pango_font_description_set_absolute_size(font, 14 * 1024)
library.pango_layout_set_font_description.argtypes = [c.c_void_p, c.c_void_p]
library.pango_layout_set_font_description(layout, font)
library.pango_layout_set_text.argtypes = [c.c_void_p, c.c_char_p, c.c_int]
library.pango_layout_get_pixel_size.argtypes = [c.c_void_p, c.POINTER(c.c_int), c.POINTER(c.c_int)]
for text, maximum in [(word, 76) for word in ('Retained', 'Snoozed', 'Woke', 'Scheduled')] + [
        (provider + ' · DDDDDDDD', 232) for provider in ('Claude Code', 'Codex', 'OpenCode', 'Grok', 'Cursor')]:
    encoded = text.encode()
    library.pango_layout_set_text(layout, encoded, len(encoded))
    measured_width, measured_height = c.c_int(), c.c_int()
    library.pango_layout_get_pixel_size(layout, c.byref(measured_width), c.byref(measured_height))
    assert measured_width.value <= maximum and measured_height.value <= 24, \
        (text, measured_width.value, measured_height.value, maximum)
library.pango_font_description_free.argtypes = [c.c_void_p]
library.pango_font_description_free(font)
library.g_object_unref.argtypes = [c.c_void_p]
library.g_object_unref(layout)
library.g_object_unref(context)

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
rows = (Row * 99)(*[Row(12, 56, 296, 44, 52, 0, 1, 0) for _ in range(99)])
assert draw_labels(pixels, width, height, good, 1, rows, 99) != 0
assert bytes(pixels) == base


def fragments(title, identity='Codex · work 日本語', state='Retained', selected=0):
    encoded = bytearray()
    regions = []
    for text, rect, detail in [(title, (64, 56, 148, 24), 0),
                               (identity, (64, 80, 232, 20), 1),
                               (state, (220, 56, 76, 24), 1)]:
        raw = text.encode('utf-8')
        regions.append(Row(*rect, 0, len(encoded), len(raw), selected, 0, detail))
        encoded.extend(raw)
    content = (c.c_ubyte * len(encoded)).from_buffer_copy(encoded)
    descriptors = (Row * len(regions))(*regions)
    pixels = (c.c_ubyte * len(base)).from_buffer_copy(base)
    assert draw_labels(pixels, width, height, content, len(encoded), descriptors, len(regions)) == 0
    return bytes(pixels)


def region(frame, x, y, w, h):
    return b''.join(frame[((y + row) * width + x) * 4:((y + row) * width + x + w) * 4]
                    for row in range(h))


for selection in (0, 1):
    first = fragments('解析 — ' + 'a very long title ' * 20, selected=selection)
    renamed = fragments('Entirely different title ' * 20, selected=selection)
    for rect in ((64, 80, 232, 20), (220, 56, 76, 24)):
        assert region(first, *rect) != region(base, *rect), 'detail/status did not render'
        assert region(first, *rect) == region(renamed, *rect), 'title leaked into independent metadata'
    assert region(first, 64, 56, 148, 24) != region(renamed, 64, 56, 148, 24)
    for y in range(height):
        for x in range(width):
            if any(left <= x < left + w and top <= y < top + h
                   for left, top, w, h in ((64, 56, 148, 24), (64, 80, 232, 20), (220, 56, 76, 24))):
                continue
            offset = (y * width + x) * 4
            assert first[offset:offset + 4] == base[offset:offset + 4], (x, y)

# The whole descriptor batch is admitted before any pixels change, including a malformed
# later fragment, a negative/truncating inset, and an unknown text role.
for bad_row in (Row(64, 56, 20, 24, 0, 0, 1, 0, 20, 0),
                Row(64, 56, 20, 24, 0, 0, 1, 0, -1, 0),
                Row(64, 56, 20, 24, 0, 0, 1, 0, 0, 2)):
    pair = (Row * 2)(Row(64, 56, 148, 24, 0, 0, 1, 0, 0, 0), bad_row)
    pixels = (c.c_ubyte * len(base)).from_buffer_copy(base)
    assert draw_labels(pixels, width, height, good, 1, pair, 2) != 0
    assert bytes(pixels) == base, 'partial text batch rendered before admission completed'

print('PASS bounded Pango text preserves Unicode, selection, independent title/identity/status clips, and atomic refusal')
