#!/bin/bash
set -euo pipefail
repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_directory="${repository_directory}/.build/audio-tone-fixture/AudioSpectrumTone.app"
mkdir -p "${fixture_directory}/Contents/MacOS"
xcrun swiftc -parse-as-library \
  "${repository_directory}/Tests/Fixtures/Audio/AudioSpectrumToneFixture.swift" \
  -o "${fixture_directory}/Contents/MacOS/AudioSpectrumTone"
python3 - "${fixture_directory}/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({
        'CFBundleIdentifier': 'codes.threading.tests.audio-tone',
        'CFBundleExecutable': 'AudioSpectrumTone',
        'CFBundleName': 'Threading Audio Test Tone',
        'CFBundlePackageType': 'APPL',
        'LSUIElement': True,
    }, output)
PY
export THREADING_TEST_LIVE_AUDIO=1
export THREADING_TEST_AUDIO_TONE_APP="${fixture_directory}"
"${repository_directory}/scripts/test.sh" fast \
  -only-testing:ThreadingTests/AudioSpectrumCaptureIntegrationTests "$@"
