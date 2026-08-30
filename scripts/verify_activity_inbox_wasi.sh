#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPOSITORY_ROOT="$(dirname -- "$SCRIPT_DIR")"
EXTENSION_PACKAGE="$REPOSITORY_ROOT/Packages/ThreadingExtensionKit"
MANIFEST="$EXTENSION_PACKAGE/Examples/ActivityInboxExtension/threading-extension.json"

if [ -n "${THREADING_SWIFT_ORG_SWIFT:-}" ]; then
  SWIFT_ORG_COMMAND="$THREADING_SWIFT_ORG_SWIFT"
elif [ -x "${HOME}/.swiftly/bin/swift" ]; then
  # Xcode's compiler cannot use Swift.org cross-compilation SDKs on macOS. Swiftly's shim
  # selects the matching open-source toolchain while leaving the selected Xcode untouched.
  SWIFT_ORG_COMMAND="${HOME}/.swiftly/bin/swift"
else
  echo "Activity Inbox WASI verification requires a Swift.org Swift toolchain." >&2
  echo "Set THREADING_SWIFT_ORG_SWIFT to its swift executable." >&2
  exit 69
fi

if [ ! -x "$SWIFT_ORG_COMMAND" ]; then
  echo "Swift.org Swift executable is not executable: $SWIFT_ORG_COMMAND" >&2
  exit 69
fi

WASM_SDK_ID="${THREADING_WASM_SDK_ID:-}"
if [ -z "$WASM_SDK_ID" ]; then
  WASM_SDK_ID="$($SWIFT_ORG_COMMAND sdk list | awk '/_wasm$/ { print; exit }')"
fi
case "$WASM_SDK_ID" in
  *_wasm) ;;
  *)
    echo "A non-embedded Swift WASI SDK ID is required; got '$WASM_SDK_ID'." >&2
    exit 69
    ;;
esac

XCODEBUILD_COMMAND="$(xcrun --find xcodebuild)"
if [ ! -x "$XCODEBUILD_COMMAND" ]; then
  echo "Xcode build executable is not executable: $XCODEBUILD_COMMAND" >&2
  exit 69
fi

TASK_TEMP_PARENT="$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd)"
TASK_TEMP_ROOT="$(mktemp -d "$TASK_TEMP_PARENT/threading-activity-wasi.XXXXXX")"
case "$TASK_TEMP_ROOT" in
  "$TASK_TEMP_PARENT"/threading-activity-wasi.*) ;;
  *)
    echo "Unexpected temporary directory: $TASK_TEMP_ROOT" >&2
    exit 70
    ;;
esac
trap 'rm -rf "$TASK_TEMP_ROOT"' EXIT

"$SWIFT_ORG_COMMAND" build \
  --package-path "$EXTENSION_PACKAGE" \
  --scratch-path "$TASK_TEMP_ROOT/activity-build" \
  --swift-sdk "$WASM_SDK_ID" \
  --configuration release \
  --product ActivityInboxExtensionExample
ACTIVITY_BIN_DIR="$("$SWIFT_ORG_COMMAND" build \
  --package-path "$EXTENSION_PACKAGE" \
  --scratch-path "$TASK_TEMP_ROOT/activity-build" \
  --swift-sdk "$WASM_SDK_ID" \
  --configuration release \
  --show-bin-path)"
MODULE="$ACTIVITY_BIN_DIR/ActivityInboxExtensionExample.wasm"
if [ ! -f "$MODULE" ]; then
  echo "Swift WASI build did not produce $MODULE" >&2
  exit 66
fi

"$XCODEBUILD_COMMAND" \
  -quiet \
  -project "$REPOSITORY_ROOT/Threading.xcodeproj" \
  -scheme ThreadingWasmExtensionRunner \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$TASK_TEMP_ROOT/DerivedData" \
  build \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  COMPILER_INDEX_STORE_ENABLE=NO
RUNNER="$TASK_TEMP_ROOT/DerivedData/Build/Products/Release/threading-wasm-extension-runner"
if [ ! -x "$RUNNER" ]; then
  echo "Xcode did not produce the shipping WebAssembly runner at $RUNNER" >&2
  exit 66
fi

/usr/bin/codesign --verify --strict --verbose=2 "$RUNNER"
RUNNER_ENTITLEMENTS="$TASK_TEMP_ROOT/runner-entitlements.plist"
/usr/bin/codesign -d --entitlements :- "$RUNNER" >"$RUNNER_ENTITLEMENTS" 2>/dev/null
if [ "$(/usr/libexec/PlistBuddy \
  -c 'Print :com.apple.security.app-sandbox' "$RUNNER_ENTITLEMENTS")" != "true" ]; then
  echo "Shipping WebAssembly runner is not signed with the App Sandbox entitlement." >&2
  exit 66
fi
if ! /usr/bin/codesign -d --verbose=4 "$RUNNER" 2>&1 \
  | grep -Eq 'flags=.*\(.*runtime.*\)'; then
  echo "Shipping WebAssembly runner is not signed with hardened runtime." >&2
  exit 66
fi

REGISTER_OUTPUT="$TASK_TEMP_ROOT/register.json"
SERVE_OUTPUT="$TASK_TEMP_ROOT/serve.json"
"$RUNNER" --threading-register 4<"$MODULE" >"$REGISTER_OUTPUT"
"$RUNNER" --threading-serve 4<"$MODULE" </dev/null >"$SERVE_OUTPUT"

python3 - "$MANIFEST" "$REGISTER_OUTPUT" "$SERVE_OUTPUT" <<'PY'
import json
import sys
from pathlib import Path

manifest_path, register_path, serve_path = map(Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_bytes())
register_bytes = register_path.read_bytes()
serve_bytes = serve_path.read_bytes()

if manifest.get("runtime") != "webAssembly":
    raise SystemExit("Activity Inbox manifest must declare the WebAssembly runtime")
if manifest.get("capabilities") != ["ui.workspace-navigation"]:
    raise SystemExit("Activity Inbox manifest declares authority outside workspace navigation")
if register_bytes != serve_bytes:
    raise SystemExit("register and serve emitted different startup registrations")
if not register_bytes.endswith(b"\n") or b"\n" in register_bytes[:-1]:
    raise SystemExit("runner registration must be exactly one newline-terminated JSON value")

registration = json.loads(register_bytes)
canonical_registration = (
    json.dumps(registration, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()
    + b"\n"
)
if register_bytes != canonical_registration:
    raise SystemExit("runner registration is not the compact sorted-key protocol encoding")

expected_empty = {
    "commands": [],
    "factDefinitions": [],
    "mcpTools": [],
    "panels": [],
    "previewableFileTypes": [],
    "services": [],
}
if {key: registration.get(key) for key in expected_empty} != expected_empty:
    raise SystemExit("Activity Inbox registered authority outside workspace navigation")
if set(registration) != {*expected_empty, "workspaceNavigators"}:
    raise SystemExit("Activity Inbox emitted an unexpected registration field")

manifest_navigators = json.dumps(
    manifest.get("workspaceNavigators"),
    ensure_ascii=False,
    separators=(",", ":"),
    sort_keys=True,
).encode()
registered_navigators = json.dumps(
    registration.get("workspaceNavigators"),
    ensure_ascii=False,
    separators=(",", ":"),
    sort_keys=True,
).encode()
if registered_navigators != manifest_navigators:
    raise SystemExit("WASI registration does not byte-semantically match the shipped manifest")
PY

echo "Activity Inbox passed the official WASI and shipping-runner boundary ($WASM_SDK_ID)."
