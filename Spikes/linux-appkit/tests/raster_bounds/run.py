#!/usr/bin/env python3
"""Compare the frozen pre-optimization rasterizer with the current one, using exact shim sources.

Run: python3 Spikes/linux-appkit/tests/raster_bounds/run.py --output /tmp/raster-bounds
The default -Onone measurements are algorithm evidence, not shipping launch measurements.
Neither binary opens windows. Build/bootstrap/bitmap allocation/PNG encoding are outside timing.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import statistics
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--iterations', type=int, default=5)
parser.add_argument('--optimization', choices=['Onone', 'O'], default='Onone')
parser.add_argument('--cpu-timings', action='store_true')
parser.add_argument('--profile-mask', action='store_true', help='instrument only scratch raster copies')
parser.add_argument('--current-only', action='store_true', help='profile current code without an equivalence claim')
parser.add_argument('--additional-baseline', type=Path, help='also compare a saved intermediate raster')
args = parser.parse_args()
if args.profile_mask:
    args.cpu_timings = True
if not 3 <= args.iterations <= 20:
    parser.error('iterations must be between 3 and 20')
fixture = Path(__file__).resolve().parent
spike = fixture.parents[1]
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
# Reusing --output must never let an earlier frame satisfy this run's pixel oracle. Keep each
# run's evidence in a fresh directory without deleting artifacts from previous comparisons.
frames = Path(tempfile.mkdtemp(prefix='frames-', dir=output))

# Compile into one isolated module so the fixture can call the internal rasterizer. Strip only
# imports of the shim's package name from its clients; drawing code remains byte-for-byte exact.
clients = []
for relative in ['Sources/Harness/Specimen.swift', 'Sources/Harness/Vendored/PlatinumBitmapFont.swift']:
    source = spike / relative
    destination = output / source.name
    destination.write_text(source.read_text().replace('import AppKit\n', ''))
    clients.append(str(destination))
sources = sorted(str(path) for path in (spike / 'Sources/AppKit').rglob('*.swift')
                 if path.name != 'Raster.swift')
measurements = {}
variants = [] if args.current_only else [('reference', fixture / 'ReferenceRaster.swift')]
if args.additional_baseline:
    variants.append(('intermediate', args.additional_baseline.resolve()))
variants.append(('bounded', spike / 'Sources/AppKit/Raster.swift'))
for variant, raster in variants:
    if args.profile_mask:
        source = raster.read_text()
        signature = 'static func mask(polygons: [[NSPoint]], evenOdd: Bool, width: Int, height: Int) -> [CGFloat] {'
        assert source.count(signature) == 1
        source = source.replace(signature, signature + '''
        let profileStarted = RasterBoundsFixture.processCPUTime()
        defer { RasterMaskProfile.record(seconds: RasterBoundsFixture.processCPUTime() - profileStarted,
                                         pixels: width * height) }
''')
        raster = output / (variant + '-profiled.swift')
        raster.write_text(source)
    binary = output / variant
    command = ['swiftc', '-parse-as-library', '-swift-version', '5', '-' + args.optimization,
               '-module-name', 'RasterBoundsFixture', '-module-cache-path', str(output / 'module-cache'),
               *sources, str(raster), *clients, str(fixture / 'HostGeometry.swift'),
               str(fixture / 'Fixture.swift'), '-o', str(binary)]
    if args.cpu_timings:
        command.extend(['-D', 'RASTER_CPU_TIMINGS'])
    if args.profile_mask:
        command.extend(['-D', 'RASTER_MASK_PROFILE'])
    subprocess.run(command, check=True, timeout=180)
    with (output / (variant + '.log')).open('w') as log:
        subprocess.run([str(binary), str(frames / variant), str(args.iterations)],
                       check=True, stdout=log, stderr=subprocess.STDOUT, text=True, timeout=600)
    log_text = (output / (variant + '.log')).read_text()
    values = {}
    for name, elapsed in re.findall(r'RASTER_TIMING (\S+) iteration=\d+ milliseconds=([\d.]+)', log_text):
        values.setdefault(name, []).append(float(elapsed))
    assert len(values) == 5 and all(len(item) == args.iterations for item in values.values()), log_text
    measurements[variant] = {name: {'median_ms': statistics.median(items), 'max_ms': max(items),
                                   'samples_ms': items} for name, items in values.items()}
    if args.cpu_timings:
        cpu = {}
        for name, elapsed in re.findall(r'RASTER_CPU (\S+) iteration=\d+ milliseconds=([\d.]+)', log_text):
            cpu.setdefault(name, []).append(float(elapsed))
        assert cpu.keys() == values.keys() and all(len(item) == args.iterations for item in cpu.values())
        for name, items in cpu.items():
            measurements[variant][name].update(cpu_median_ms=statistics.median(items),
                                              cpu_max_ms=max(items), cpu_samples_ms=items)
    if args.profile_mask:
        mask = {}
        for name, calls, pixels, elapsed in re.findall(
                r'RASTER_MASK (\S+) calls=(\d+) pixels=(\d+) milliseconds=([\d.]+)', log_text):
            mask.setdefault(name, []).append({'calls': int(calls), 'pixels': int(pixels),
                                              'cpu_ms': float(elapsed)})
        assert mask.keys() == values.keys() and all(len(items) == args.iterations for items in mask.values())
        for name, items in mask.items():
            measurements[variant][name].update(mask_samples=items,
                mask_cpu_median_ms=statistics.median(item['cpu_ms'] for item in items))

bounded = frames / 'bounded'
hashes = {}
for after in sorted([*bounded.glob('*.rgba'), *bounded.glob('*.mask')]):
    actual = after.read_bytes()
    for variant, _ in variants[:-1]:
        assert actual == (frames / variant / after.name).read_bytes(), \
            f'pixel/mask mismatch: {variant} {after.name}'
    hashes[after.name] = hashlib.sha256(actual).hexdigest()
    if not args.current_only:
        print(f'PASS exact {after.name}: {len(actual)} bytes')
assert len(hashes) == 8
report = {'optimization': args.optimization, 'iterations': args.iterations,
          'frames_directory': frames.name, 'timings': measurements, 'sha256': hashes}
(output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
for variant, _ in variants:
    for name, result in measurements[variant].items():
        print(f"{variant} {name}: median {result['median_ms']:.2f} ms; max {result['max_ms']:.2f} ms")
        if args.cpu_timings:
            print(f"  CPU median {result['cpu_median_ms']:.2f} ms; max {result['cpu_max_ms']:.2f} ms")
        if args.profile_mask:
            print(f"  Mask CPU median {result['mask_cpu_median_ms']:.2f} ms")
print(f'Report: {output / "report.json"}')
