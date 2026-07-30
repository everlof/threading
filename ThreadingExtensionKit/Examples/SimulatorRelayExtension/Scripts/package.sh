#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: Scripts/package.sh <swift-wasm-sdk-id> [output-directory]" >&2
  exit 64
fi

SDK_ID="$1"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(dirname -- "$SCRIPT_DIR")"
SDK_ROOT="$(CDPATH= cd -- "$PROJECT_DIR/../.." && pwd)"
DOCUMENTATION_ROOT="$(dirname -- "$SDK_ROOT")/docs/extensions"
if [ -n "${THREADING_SWIFT_EXEC:-}" ]; then
  SWIFT_COMMAND="$THREADING_SWIFT_EXEC"
elif [ -x "${HOME}/.swiftly/bin/swift" ]; then
  # Xcode's bundled `swift` can list an installed Wasm SDK but cannot target it on macOS.
  # Prefer Swiftly's Swift.org toolchain when it is installed in the standard location.
  SWIFT_COMMAND="${HOME}/.swiftly/bin/swift"
else
  SWIFT_COMMAND="swift"
fi
OUTPUT_ROOT="${2:-"$PROJECT_DIR/Build"}"
OUTPUT="$OUTPUT_ROOT/codes.threading.simulator-relay.threadingextension"

if [ -e "$OUTPUT" ]; then
  echo "refusing to overwrite existing package: $OUTPUT" >&2
  exit 73
fi

THREADING_EXTENSION_SDK_PATH="$SDK_ROOT" "$SWIFT_COMMAND" build \
  --disable-sandbox \
  --package-path "$PROJECT_DIR" \
  --swift-sdk "$SDK_ID" \
  --product ExtensionMain
THREADING_EXTENSION_SDK_PATH="$SDK_ROOT" "$SWIFT_COMMAND" build \
  --package-path "$SDK_ROOT" \
  --product SimulatorRelayCompanionExample

CORE_BIN_DIR="$(THREADING_EXTENSION_SDK_PATH="$SDK_ROOT" "$SWIFT_COMMAND" build \
  --package-path "$PROJECT_DIR" \
  --swift-sdk "$SDK_ID" \
  --show-bin-path)"
COMPANION_BIN_DIR="$(THREADING_EXTENSION_SDK_PATH="$SDK_ROOT" "$SWIFT_COMMAND" build \
  --package-path "$SDK_ROOT" \
  --show-bin-path)"
MODULE="$CORE_BIN_DIR/ExtensionMain.wasm"
COMPANION_EXECUTABLE="$COMPANION_BIN_DIR/SimulatorRelayCompanionExample"

if [ ! -f "$MODULE" ]; then
  echo "WebAssembly build did not produce $MODULE" >&2
  exit 66
fi
if [ ! -x "$COMPANION_EXECUTABLE" ]; then
  echo "companion build did not produce $COMPANION_EXECUTABLE" >&2
  exit 66
fi

mkdir -p "$OUTPUT_ROOT"
STAGING="$(mktemp -d "$OUTPUT_ROOT/.simulator-relay.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

APP="$STAGING/Companions/SimulatorRelayCompanion.app"
mkdir -p \
  "$STAGING/bin" \
  "$STAGING/Source/Vendor/docs" \
  "$APP/Contents/MacOS"
cp "$PROJECT_DIR/threading-extension.json" "$STAGING/threading-extension.json"
cp "$MODULE" "$STAGING/bin/simulator-relay.wasm"
cp "$PROJECT_DIR/Companion/Info.plist" "$APP/Contents/Info.plist"
cp "$COMPANION_EXECUTABLE" \
  "$APP/Contents/MacOS/SimulatorRelayCompanionExample"

rsync -a \
  --exclude .build \
  --exclude Build \
  --exclude .git \
  --exclude .swiftpm \
  --exclude DerivedData \
  --exclude .DS_Store \
  "$PROJECT_DIR/" "$STAGING/Source/"
rsync -a \
  --exclude .build \
  --exclude Examples \
  --exclude .git \
  --exclude .swiftpm \
  --exclude .DS_Store \
  "$SDK_ROOT/" "$STAGING/Source/Vendor/ThreadingExtensionKit/"
rsync -a \
  --exclude .DS_Store \
  "$DOCUMENTATION_ROOT/" "$STAGING/Source/Vendor/docs/extensions/"

/usr/bin/codesign \
  --force \
  --sign - \
  --options runtime \
  --entitlements "$PROJECT_DIR/Companion/SimulatorRelayCompanion.entitlements" \
  "$APP"

mv "$STAGING" "$OUTPUT"
trap - EXIT
echo "$OUTPUT"
