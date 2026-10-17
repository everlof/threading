"""Contrast of rendered sRGB pixels, shared by native installed-runtime journeys."""

import subprocess


def assert_sidebar_pane_chrome(path, sidebar_width=240, scale=1):
    """The ordinary one-session sidebar is a pane, with only its trailing structural rule."""
    width, height = map(int, subprocess.check_output(
        ['identify', '-format', '%w %h', str(path)], text=True, timeout=5).split())
    assert width > sidebar_width and height > 400, (width, height)
    pixels = subprocess.check_output(['convert', str(path), '-depth', '8', 'rgb:-'], timeout=5)

    def pixel(x, y):
        offset = (y * width + x) * 3
        return pixels[offset:offset + 3]

    middle = height // 2
    assert pixel(0, middle) == pixel(8, middle), 'sidebar still has a specimen frame on its left edge'
    assert pixel(0, 0) == pixel(100, 0), 'sidebar header still has a rounded specimen corner'
    assert pixel(100, height - 1) == pixel(100, height - 8), 'sidebar still has a specimen bottom frame'
    divider = pixel(sidebar_width - 1, middle)
    assert divider != pixel(sidebar_width - 8, middle), 'sidebar lost its pane divider'
    for y in (0, middle, height - 1):
        assert pixel(sidebar_width - 1, y) == divider, 'pane divider does not span the whole sidebar'
        for offset in range(1, scale + 1):
            assert pixel(sidebar_width - offset, y) == divider, 'pane divider lost its one-point weight'


def pixel_contrast(first, second):
    def luminance(pixel):
        channels = [value / 255 for value in pixel[:3]]
        linear = [value / 12.92 if value <= .04045 else ((value + .055) / 1.055) ** 2.4
                  for value in channels]
        return sum(value * weight for value, weight in zip(linear, (.2126, .7152, .0722)))

    first_light, second_light = luminance(first), luminance(second)
    return (max(first_light, second_light) + .05) / (min(first_light, second_light) + .05)


def assert_placeholder_ink(path, palette, project_bounds, scale=1):
    """The opening welcome draws the brand mark and primary greeting in the real shell."""
    width, height = map(int, subprocess.check_output(
        ['identify', '-format', '%w %h', str(path)], text=True, timeout=5).split())
    pixels = subprocess.check_output(['convert', str(path), '-depth', '8', 'rgb:-'], timeout=5)
    center = (240 * scale + width) // 2
    ground = tuple(round(channel * 255) for channel in palette['ground'][:3])
    # The standing composer's hero occupies the space above its project chip. Inspect
    # the mark and up to three wrapped greeting lines, independent of the submit position.
    bands = []
    for y in range(max(0, project_bounds.y - 4 * scale)):
        has_ink = any(tuple(pixels[(y * width + x) * 3:(y * width + x) * 3 + 3]) != ground
                      for x in range(260 * scale, width - 20 * scale))
        if has_ink:
            if not bands or y > bands[-1][1] + 1:
                bands.append([y, y])
            else:
                bands[-1][1] = y
    assert 2 <= len(bands) <= 4, ('composer hero ink bands', bands)
    icon_pixels = [(x, y)
                   for y in range(bands[0][0], bands[0][1] + 1)
                   for x in range(center - 22 * scale, center + 22 * scale)
                   if tuple(pixels[(y * width + x) * 3:(y * width + x) * 3 + 3]) != ground]
    assert icon_pixels, 'opening welcome lost its Threading mark'
    icon_width = max(x for x, _ in icon_pixels) - min(x for x, _ in icon_pixels) + 1
    icon_height = max(y for _, y in icon_pixels) - min(y for _, y in icon_pixels) + 1
    assert 24 * scale < icon_width <= 40 * scale and 30 * scale <= icon_height <= 40 * scale, (
        'welcome mark optical bounds', icon_width, icon_height, scale)
    mark = tuple(round(channel * 255) for channel in palette['sidebar.brandMark'][:3])
    assert any(tuple(pixels[(y * width + x) * 3:(y * width + x) * 3 + 3]) == mark
               for x, y in icon_pixels), 'welcome lost the themed brand ink'
    for top, bottom in bands[1:]:
        role = 'label'
        red, green, blue, alpha = palette[role]
        ink = tuple(round(channel * 255) for channel in (red, green, blue))
        # Small 1× text need not contain a fully covered pixel. Enumerate the exact 8-bit
        # source-over colors for strongly covered glyph pixels instead of tolerating a
        # color distance that could accept the old neutral-gray adapter.
        expected = set()
        for coverage in range(180, 256):
            source = int(coverage * alpha + .5)
            expected.add(tuple((channel * source + base * (255 - source) + 127) // 255
                               for channel, base in zip(ink, ground)))
        x0, x1 = max(240 * scale, center - 230 * scale), min(width, center + 230 * scale)
        y0, y1 = top, bottom + 1
        matches = sum(tuple(pixels[(y * width + x) * 3:(y * width + x) * 3 + 3]) in expected
                      for y in range(y0, y1) for x in range(x0, x1))
        assert matches >= 8, (f'empty pane lost {role} ink', matches)


def assert_sidebar_region_colors(path, palette, scale=1):
    """The real sidebar paints the exported region recipe, including the full-column wash."""
    width, height = map(int, subprocess.check_output(
        ['identify', '-format', '%w %h', str(path)], text=True, timeout=5).split())
    pixels = subprocess.check_output(['convert', str(path), '-depth', '8', 'rgb:-'], timeout=5)

    def pixel(x, y):
        offset = (y * width + x) * 3
        return tuple(pixels[offset:offset + 3])

    well = tuple(round(channel * 255) for channel in palette['sidebar.navigatorWell'][:3])
    assert pixel(100, height // 2) == well, 'navigator painted the generic surface instead of its authored well'
    selection = tuple(round(channel * 255) for channel in palette['accent'][:3])
    assert pixel(9 * scale, 54 * scale) == selection, 'saved-session selection still uses the diagnostic blue'
    first = palette['sidebar.gradientStart'][:3]
    last = palette['sidebar.gradientEnd'][:3]
    # These samples miss the header's words, buttons and bottom rule. The wash spans the
    # whole column behind the well, so its fraction uses the window height, not header height.
    for y in (0, 35 * scale):
        fraction = (y + .5) / height
        expected = tuple(round((start + (end - start) * fraction) * 255)
                         for start, end in zip(first, last))
        assert pixel(100, y) == expected, (f'sidebar wash at y={y}', pixel(100, y), expected)


    # The brand stays in its measured 24-point slot through navigation and appearance changes.
    # Require actual exported ink inside both the mark and the adjacent wordmark, rather than
    # accepting an empty header whose surrounding wash happens to be correct.
    mark = tuple(round(channel * 255) for channel in palette['sidebar.brandMark'][:3])
    label = tuple(round(channel * 255) for channel in palette['label'][:3])
    assert any(pixel(x, y) == mark for y in range(8 * scale, 32 * scale)
               for x in range(12 * scale, 36 * scale)), 'production brand mark missing from header'
    assert any(pixel(x, y) == label for y in range(8 * scale, 32 * scale)
               for x in range(42 * scale, 120 * scale)), 'brand wordmark missing from header'


def opening_prompt_frame(editor_bounds, scale=1):
    """The opening prompt includes 10pt vertical insets, a 26pt footer and its 10pt gap."""
    return dict(x=editor_bounds.x - 12 * scale, y=editor_bounds.y - 10 * scale,
                width=editor_bounds.width + 24 * scale, height=editor_bounds.height + 56 * scale)


def assert_opening_prompt_surface(path, editor_bounds, palette, scale=1):
    """The whole prompt paints its field, even before its document grows to the viewport."""
    frame = opening_prompt_frame(editor_bounds, scale)
    x, y = frame['x'] + 8 * scale, frame['y'] + 16 * scale
    height = frame['height'] - 32 * scale
    pixels = subprocess.check_output(['convert', str(path), '-crop', f'1x{height}+{x}+{y}',
                                     '+repage', '-depth', '8', 'rgb:-'], timeout=5)
    field = bytes(round(channel * 255) for channel in palette['fieldSurface'][:3])
    assert pixels == field * height, 'opening prompt fill does not cover its whole viewport'


def assert_composer_focus_chrome(focused_path, resting_path, frame, scale=1):
    """The real input uses a two-point accent focus ring and a one-point resting border."""
    x = int(frame['x']) + int(frame['width']) // 2
    y = int(frame['y'])

    def edge(path):
        pixels = subprocess.check_output(['convert', str(path), '-crop', f'1x12+{x}+{y}',
                                         '+repage', '-depth', '8', 'rgb:-'], timeout=5)
        samples = [pixels[index:index + 3] for index in range(0, len(pixels), 3)]
        width = next((index for index, color in enumerate(samples) if color != samples[0]), len(samples))
        return samples[0], width

    focused_color, focused_width = edge(focused_path)
    resting_color, resting_width = edge(resting_path)
    assert focused_color != resting_color, 'composer focus did not change border ink'
    assert focused_width == 2 * scale, f'expected two-point focus ring at {scale}x, got {focused_width} pixels'
    assert resting_width == scale, f'expected one-point resting border at {scale}x, got {resting_width} pixels'
