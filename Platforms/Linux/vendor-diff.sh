#!/usr/bin/env bash
# Verify the exact NativeDiffAppKit renderer linked to the host-provided AppKit shim.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
python3 - <<'PY'
import hashlib
import json
from pathlib import Path

revision = '363c6197d8e334fa0aaf30550fb0a0bcac540e71'
pins = json.loads(Path('Package.resolved').read_text())['pins']
pin = next(value for value in pins if value['identity'] == 'nativediffkit')
if pin['state']['revision'] != revision:
    raise SystemExit('NativeDiffKit resolution differs from the verified renderer revision')
expected = {
    'DiffAppKitView.swift': '1733afaebbd2d4d7726063967251ccea3805afbe706a6987f4198b0c8275b1ad',
    'LICENSE': 'abf02028601d36e38f31cd027e28626da705c3543ef0406c79e24c8b84cec95c',
}
destination = Path('Sources/LinuxNativeDiffAppKit')
if {file.name for file in destination.iterdir()} != set(expected):
    raise SystemExit('Unrecorded or missing NativeDiffAppKit source/license')
for name, digest in expected.items():
    if hashlib.sha256((destination / name).read_bytes()).hexdigest() != digest:
        raise SystemExit(f'NativeDiffAppKit {name} differs from verified revision {revision}')
print(f'NativeDiffAppKit source/license match verified revision {revision}')
PY
