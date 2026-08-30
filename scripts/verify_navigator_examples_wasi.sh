#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPOSITORY_ROOT="$(dirname -- "$SCRIPT_DIR")"
EXTENSION_PACKAGE="$REPOSITORY_ROOT/Packages/ThreadingExtensionKit"

if [ -n "${THREADING_SWIFT_ORG_SWIFT:-}" ]; then
  SWIFT_ORG_COMMAND="$THREADING_SWIFT_ORG_SWIFT"
elif [ -x "${HOME}/.swiftly/bin/swift" ]; then
  # Xcode's compiler cannot use Swift.org cross-compilation SDKs on macOS. Swiftly's shim
  # selects the matching open-source toolchain while leaving the selected Xcode untouched.
  SWIFT_ORG_COMMAND="${HOME}/.swiftly/bin/swift"
else
  echo "Navigator example WASI verification requires a Swift.org Swift toolchain." >&2
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
TASK_TEMP_ROOT="$(mktemp -d "$TASK_TEMP_PARENT/threading-navigator-wasi.XXXXXX")"
case "$TASK_TEMP_ROOT" in
  "$TASK_TEMP_PARENT"/threading-navigator-wasi.*) ;;
  *)
    echo "Unexpected temporary directory: $TASK_TEMP_ROOT" >&2
    exit 70
    ;;
esac
trap 'rm -rf "$TASK_TEMP_ROOT"' EXIT

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

verify_navigator_example() {
  EXAMPLE_NAME="$1"
  EXAMPLE_DIRECTORY="$2"
  EXAMPLE_PRODUCT="$3"
  EXAMPLE_SLUG="$4"
  MANIFEST="$EXTENSION_PACKAGE/Examples/$EXAMPLE_DIRECTORY/threading-extension.json"

  "$SWIFT_ORG_COMMAND" build \
    --package-path "$EXTENSION_PACKAGE" \
    --scratch-path "$TASK_TEMP_ROOT/extension-build" \
    --swift-sdk "$WASM_SDK_ID" \
    --configuration release \
    --product "$EXAMPLE_PRODUCT"
  EXAMPLE_BIN_DIR="$($SWIFT_ORG_COMMAND build \
    --package-path "$EXTENSION_PACKAGE" \
    --scratch-path "$TASK_TEMP_ROOT/extension-build" \
    --swift-sdk "$WASM_SDK_ID" \
    --configuration release \
    --show-bin-path)"
  MODULE="$EXAMPLE_BIN_DIR/$EXAMPLE_PRODUCT.wasm"
  if [ ! -f "$MODULE" ]; then
    echo "Swift WASI build did not produce $MODULE" >&2
    exit 66
  fi

  REGISTER_OUTPUT="$TASK_TEMP_ROOT/$EXAMPLE_SLUG-register.json"
  SERVE_OUTPUT="$TASK_TEMP_ROOT/$EXAMPLE_SLUG-serve.json"
  "$RUNNER" --threading-register 4<"$MODULE" >"$REGISTER_OUTPUT"
  "$RUNNER" --threading-serve 4<"$MODULE" </dev/null >"$SERVE_OUTPUT"

  python3 - "$EXAMPLE_NAME" "$MANIFEST" "$REGISTER_OUTPUT" "$SERVE_OUTPUT" <<'PY'
import json
import sys
from pathlib import Path

example_name = sys.argv[1]
manifest_path, register_path, serve_path = map(Path, sys.argv[2:])
manifest = json.loads(manifest_path.read_bytes())
register_bytes = register_path.read_bytes()
serve_bytes = serve_path.read_bytes()

if manifest.get("runtime") != "webAssembly":
    raise SystemExit(f"{example_name} manifest must declare the WebAssembly runtime")
if manifest.get("capabilities") != ["ui.workspace-navigation"]:
    raise SystemExit(f"{example_name} manifest declares authority outside workspace navigation")
if register_bytes != serve_bytes:
    raise SystemExit(f"{example_name} register and serve emitted different startup registrations")
if not register_bytes.endswith(b"\n") or b"\n" in register_bytes[:-1]:
    raise SystemExit(f"{example_name} registration must be one newline-terminated JSON value")

registration = json.loads(register_bytes)
canonical_registration = (
    json.dumps(registration, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()
    + b"\n"
)
if register_bytes != canonical_registration:
    raise SystemExit(f"{example_name} registration is not compact sorted-key JSON")

expected_empty = {
    "commands": [],
    "factDefinitions": [],
    "mcpTools": [],
    "panels": [],
    "previewableFileTypes": [],
    "services": [],
}
if {key: registration.get(key) for key in expected_empty} != expected_empty:
    raise SystemExit(f"{example_name} registered authority outside workspace navigation")
if set(registration) != {*expected_empty, "workspaceNavigators"}:
    raise SystemExit(f"{example_name} emitted an unexpected registration field")

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
    raise SystemExit(
        f"{example_name} WASI registration does not match the shipped manifest"
    )
PY

  echo "$EXAMPLE_NAME passed the official WASI and shipping-runner boundary."
}

verify_navigator_example \
  "Activity Inbox" \
  "ActivityInboxExtension" \
  "ActivityInboxExtensionExample" \
  "activity-inbox"
verify_navigator_example \
  "T3 Sidebar" \
  "T3SidebarExtension" \
  "T3SidebarExtensionExample" \
  "t3-sidebar"

echo "Navigator examples passed the official WASI boundary ($WASM_SDK_ID)."
