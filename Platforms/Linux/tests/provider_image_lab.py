"""Render the explicitly requested leaf lab on macOS, or verify/report Mac vs Linux captures.

render-macos OUTPUT: compile the same ImageHarness + unchanged production TemplateImageDrawing.
compare MAC_OUTPUT LINUX_OUTPUT REPORT: validate alpha/fit/clip then report exact pixel deltas.
The report is investigation evidence, never baseline acceptance or a substitute for native UI.
"""
import html
import json
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[3]


def read(directory):
    manifest = json.loads((directory / 'manifest.json').read_text())
    assert len(manifest) == 36
    values = {}
    for case in manifest:
        name, width = case['file'], case['width']
        raw = (directory / (name + '.rgba')).read_bytes()
        assert len(raw) == width * width * 4
        values[name] = (case, [tuple(raw[i:i + 4]) for i in range(0, len(raw), 4)])
    return values


def verify(values):
    for name, (case, pixels) in values.items():
        scale, scene, width = case['scale'], case['scene'], case['width']
        expected = [16, 24, 32, 16] if scene == 'wide' else [16, 16, 32, 32]
        assert case['fitted'] == expected, (name, case['fitted'])
        alpha = [pixel[3] for pixel in pixels]
        plain = values[f"{case['provider'].lower()}-plain-{scale}x"][1]
        transparent = scene in ('alpha', 'inherited', 'wide', 'clip', 'plain')
        assert any(pixel != pixels[0] for pixel in pixels), name + ': blank image'
        for index, pixel in enumerate(pixels):
            x, y = index % width, index // width
            inside = (expected[0] * scale <= x < (expected[0] + expected[2]) * scale
                      and expected[1] * scale <= y < (expected[1] + expected[3]) * scale)
            if not inside or (scene == 'clip' and x >= 32 * scale):
                assert pixel[3] == 0 if transparent else pixel == pixels[0], (name, x, y, pixel)
            if scene in ('selected', 'unselected', 'alpha-background') and plain[index][3] == 0:
                assert pixel == pixels[0], (name, 'opaque template square leakage', x, y)
            if scene in ('alpha', 'inherited'):
                assert abs(pixel[3] - plain[index][3] * .5) <= 2, (name, 'opacity applied twice', x, y)
                if pixel[3] >= 100:
                    assert max(abs(actual - wanted) for actual, wanted in
                               zip(pixel[:3], (204, 102, 51))) <= 4, (name, 'black retained under tint', pixel)
        if transparent:
            covered = [(i % width, i // width) for i, value in enumerate(alpha) if value > 8]
            assert covered, name
            extent = (max(x for x, _ in covered) - min(x for x, _ in covered) + 1,
                      max(y for _, y in covered) - min(y for _, y in covered) + 1)
            if scene == 'wide':
                # Both actual square catalogue marks have nonempty support reaching their bounds;
                # the logical 2:1 image must remain twice as wide inside the square slot.
                assert 1.7 <= extent[0] / extent[1] <= 2.3, (name, extent)
    print('PASS each backend: bounded aspect fit, clip, isolated alpha tint and inherited opacity')


def compare(mac, linux, output):
    left, right = read(mac), read(linux)
    verify(left)
    verify(right)
    assert set(left) == set(right)
    output.mkdir(parents=True, exist_ok=False)
    import shutil
    rows, summary = [], []
    for name in left:
        case, a = left[name]
        _, b = right[name]
        changed = sum(x != y for x, y in zip(a, b))
        maximum = max(abs(x - y) for pa, pb in zip(a, b) for x, y in zip(pa, pb))
        summary.append({'case': name, 'changedPixels': changed, 'maximumChannelDelta': maximum,
                        'totalPixels': len(a)})
        for label, directory in [('appkit', mac), ('shim', linux)]:
            shutil.copyfile(directory / (name + '.png'), output / (name + '-' + label + '.png'))
        rows.append('<tr><td>' + html.escape(name) + '</td><td><img src="' + name
                    + '-appkit.png"></td><td><img src="' + name + '-shim.png"></td><td>'
                    + f'{changed}/{len(a)} changed pixels; max channel delta {maximum}</td></tr>')
    (output / 'comparison.json').write_text(json.dumps(summary, indent=2) + '\n')
    (output / 'index.html').write_text('<!doctype html><meta charset="utf-8"><title>Provider image leaf comparison</title>'
        '<style>body{font:14px system-ui;background:#eee}td{padding:8px}img{width:128px;height:128px;'
        'image-rendering:pixelated;background:repeating-conic-gradient(#ddd 0% 25%,white 0% 50%) 0/16px 16px}</style>'
        '<h1>Unchanged TemplateImageDrawing: AppKit / shim</h1><p>Exact decoded RGBA differences are reported without '
        'a visual tolerance or baseline acceptance. Transparent RGB differences also count. Native workspace evidence '
        'is captured separately.</p><table><tr><th>Case</th><th>AppKit</th><th>Linux shim</th><th>Exact difference</th></tr>'
        + ''.join(rows) + '</table>')
    print(output / 'index.html')


if sys.argv[1] == 'render-macos' and len(sys.argv) == 3:
    destination = Path(sys.argv[2]).resolve()
    assert not destination.exists(), 'output must be a new evidence directory'
    with tempfile.TemporaryDirectory(prefix='threading-provider-image-') as temporary:
        executable = str(Path(temporary) / 'ImageHarness')
        subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(Path(temporary) / 'module-cache'), '-o', executable,
                        str(repo / 'Platforms/Linux/Sources/ImageHarness/ImageHarness.swift'),
                        str(repo / 'Sources/Threading/UI/Design/TemplateImageDrawing.swift')],
                       check=True, timeout=120)
        subprocess.run([executable, str(repo / 'Sources/Threading/Resources/Assets.xcassets'),
                        str(destination)], check=True, timeout=30)
    verify(read(destination))
elif sys.argv[1] == 'compare' and len(sys.argv) == 5:
    compare(*(Path(argument).resolve() for argument in sys.argv[2:]))
else:
    raise SystemExit(__doc__)
