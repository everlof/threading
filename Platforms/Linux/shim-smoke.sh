#!/usr/bin/env bash
# Build and exercise the AppKit-named shim's layout and rendered UI specimen on Linux.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

mkdir -p out
artifact_dir=$(mktemp -d "$PWD/out/shim-smoke.XXXXXX")
container_dir="/repo/Platforms/Linux/out/${artifact_dir##*/}"

docker run --rm -i --platform linux/arm64 \
  -v "$PWD/../..:/repo" -w /repo/Platforms/Linux \
  -e "SPIKE_OUT=$container_dir" swift:6.3.2-noble bash -s <<'INNER'
set -euo pipefail
apt-get update -qq >/dev/null
apt-get install -y -qq libpango1.0-dev >/dev/null
./vendor.sh --verify
swift build --product Harness
bin=$(swift build --show-bin-path)
if ! SPIKE_SKIP_LAYOUT_BENCHMARK=1 timeout 120 "$bin/Harness" > "$SPIKE_OUT/run.log" 2>&1; then
  cat "$SPIKE_OUT/run.log" >&2
  exit 1
fi
grep -Fxq 'layout: all cases pass' "$SPIKE_OUT/run.log"
grep -Fxq 'backing alignment: all cases pass' "$SPIKE_OUT/run.log"

mkdir "$SPIKE_OUT/injected-failure"
if SPIKE_INJECT_LAYOUT_FAILURE=1 SPIKE_SKIP_LAYOUT_BENCHMARK=1 \
  SPIKE_OUT="$SPIKE_OUT/injected-failure" timeout 30 "$bin/Harness" \
  > "$SPIKE_OUT/injected-failure/run.log" 2>&1; then
  echo 'Harness accepted an injected layout failure' >&2
  exit 1
fi
grep -Fq 'layout FAIL: injected layout failure' "$SPIKE_OUT/injected-failure/run.log"
INNER

python3 - "$artifact_dir" <<'PY'
from pathlib import Path
import struct
import sys
import zlib

root = Path(sys.argv[1])
expected = {'smoke.png': (640, 240), 'specimen.png': (900, 480),
            'constraints.png': (960, 450)}
for name, dimensions in expected.items():
    data = (root / name).read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', name
    offset = 8
    chunks = []
    while offset + 12 <= len(data):
        size = struct.unpack_from('>I', data, offset)[0]
        end = offset + 12 + size
        assert end <= len(data), name
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + size]
        crc = struct.unpack_from('>I', data, offset + 8 + size)[0]
        assert zlib.crc32(kind + payload) == crc, name
        chunks.append(kind)
        if kind == b'IHDR':
            assert struct.unpack_from('>II', payload) == dimensions, name
        offset = end
        if kind == b'IEND':
            break
    assert chunks[0] == b'IHDR' and b'IDAT' in chunks, name
    assert chunks[-1] == b'IEND' and offset == len(data), name
assert not list((root / 'injected-failure').glob('*.png'))
print('PASS shim layout, PNG specimens, and injected failure exit')
PY

test -s "$artifact_dir/specimen.png"
grep -Fxq 'layout: all cases pass' "$artifact_dir/run.log"
echo "Shim artifacts: $artifact_dir"
