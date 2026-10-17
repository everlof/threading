#!/usr/bin/env bash
# Build both preview artifacts, then exercise them in a Swift-free Ubuntu image.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
./vendor-core.sh --verify
./vendor-diff.sh --verify
mkdir -p out/bundle-smoke
evidence=$(mktemp -d "$PWD/out/bundle-smoke/run.XXXXXXXX")
printf 'bundle-smoke evidence: %s\n' "$evidence"
# A linked worktree's .git pointer may lead outside the Docker mount.
source_revision=${THREADING_LINUX_SOURCE_REVISION:-}
source_dirty=${THREADING_LINUX_SOURCE_DIRTY:-}
if [[ -z $source_revision && -z $source_dirty ]]; then
  source_revision=$(git -C ../.. rev-parse HEAD)
  source_status=$(git -C ../.. status --porcelain)
  source_dirty=$([[ -z $source_status ]] && echo false || echo true)
fi
if [[ ! $source_revision =~ ^[0-9a-f]{40,64}$ || ( $source_dirty != true && $source_dirty != false ) ]]; then
  echo 'bundle-smoke: valid source revision and dirty status are required' >&2
  exit 1
fi

docker run --rm -i --platform linux/arm64 \
  -e "THREADING_LINUX_SOURCE_REVISION=$source_revision" \
  -e "THREADING_LINUX_SOURCE_DIRTY=$source_dirty" \
  -v "$PWD/../..:/repo" \
  -w /repo/Platforms/Linux swift:6.3.2-noble bash -s <<'BUILD'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC
apt-get update -qq >/dev/null
apt-get install -y -qq libsqlite3-dev libsdl2-dev libpango1.0-dev libatk-bridge2.0-dev libglib2.0-dev libgdk-pixbuf-2.0-dev librsvg2-common zlib1g-dev python3 >/dev/null
./package-app.sh
clang -shared -fPIC -Wall -Wextra -Werror tests/gtk_present_delay.c -ldl -o out/gtk-present-delay.so
out/threading-linux-preview-ubuntu24.04-arm64/bin/WindowHarness --project-row-layout-fixture
out/threading-linux-preview-ubuntu24.04-arm64/bin/WindowHarness --session-row-layout-fixture
out/threading-linux-preview-ubuntu24.04-arm64/bin/WindowHarness --terminal-row-layout-fixture
timeout 120 out/threading-linux-preview-ubuntu24.04-arm64/bin/WindowHarness --app-event-contract
# Exercise the same Release emulator/client modules before leaving the build container.
swift build -c release --static-swift-stdlib -Xswiftc -enable-testing --product NativeAgentProcessHarness
swift build -c release --static-swift-stdlib -Xswiftc -enable-testing --product NativeConversationHarness
swift build -c release --static-swift-stdlib -Xswiftc -enable-testing --product NativeRemoteContractHarness
swift build -c release --static-swift-stdlib -Xswiftc -enable-testing --product CoreSliceHarness
swift build -c release --static-swift-stdlib -Xswiftc -enable-testing --product PortablePTYClientHarness
swift build -c release --static-swift-stdlib -Xswiftc -enable-testing --product TableHeightHarness
swift build -c release --static-swift-stdlib -Xswiftc -enable-testing --product OutlineViewHarness
swift build -c release --static-swift-stdlib -Xswiftc -enable-testing --product SidebarVisibleRowsHarness
swift build -c release --static-swift-stdlib -Xswiftc -enable-testing --product PriorityLayoutHarness
swift build -c release --static-swift-stdlib -Xswiftc -enable-testing --product ViewClippingHarness
swift build -c release --product ParagraphWrappingHarness
swift build -c release --static-swift-stdlib -Xswiftc -enable-testing --product CompleteLabelHarness
contract_bin=$(swift build -c release --show-bin-path)
timeout 60 "$contract_bin/NativeAgentProcessHarness"
timeout 60 "$contract_bin/NativeConversationHarness" tests/native_conversation/providers.py
timeout 60 "$contract_bin/NativeRemoteContractHarness"
timeout 120 "$contract_bin/CoreSliceHarness"
timeout 120 "$contract_bin/TableHeightHarness"
timeout 120 "$contract_bin/OutlineViewHarness"
timeout 120 "$contract_bin/SidebarVisibleRowsHarness"
timeout 120 "$contract_bin/PriorityLayoutHarness"
timeout 120 "$contract_bin/ViewClippingHarness"
timeout 120 "$contract_bin/ParagraphWrappingHarness"
timeout 120 "$contract_bin/CompleteLabelHarness"
contract_fixture=$(mktemp -d /tmp/threading-contracts.XXXXXXXX)
out/threading-linux-preview-ubuntu24.04-arm64/bin/threading-ptyd \
  --socket "$contract_fixture/pty.sock" --state "$contract_fixture/daemon" >"$contract_fixture/daemon.log" 2>&1 &
contract_daemon=$!
trap 'kill "$contract_daemon" 2>/dev/null || true; wait "$contract_daemon" 2>/dev/null || true; rm -rf -- "$contract_fixture"' EXIT
for ((attempt=0; attempt<100; attempt++)); do
  [[ -S "$contract_fixture/pty.sock" ]] && break
  kill -0 "$contract_daemon" || { cat "$contract_fixture/daemon.log"; exit 1; }
  sleep .1
done
timeout 30 "$contract_bin/PortablePTYClientHarness" "$contract_fixture/pty.sock"
timeout 60 "$contract_bin/NativeConversationHarness" tests/native_conversation/providers.py "$contract_fixture/pty.sock"
clang -O2 -Wall -Wextra -Werror tests/document_text_contract.c \
  Sources/AppKitTextBridge/DocumentText.c -I Sources/AppKitTextBridge/include \
  $(pkg-config --cflags --libs pangocairo) -pthread -lm -o "$contract_fixture/document-text-contract"
timeout 120 "$contract_fixture/document-text-contract"
clang -O2 -Wall -Wextra -Werror tests/native_agent_process/pipe_write_contract.c \
  Sources/CNativeAgentProcess/NativeAgentProcess.c -I Sources/CNativeAgentProcess/include \
  -pthread -o "$contract_fixture/native-pipe-contract"
timeout 30 "$contract_fixture/native-pipe-contract"
# Run the cleanup trap without depending on the container CLI forwarding stdin EOF.
exit 0
BUILD

grep -Fxq "source_revision=$source_revision" out/threading-linux-preview-ubuntu24.04-arm64/BUNDLE-MANIFEST
grep -Fxq "source_dirty=$source_dirty" out/threading-linux-preview-ubuntu24.04-arm64/BUNDLE-MANIFEST

docker run --rm -i --platform linux/arm64 \
  -v "$PWD/out/threading-linux-preview-ubuntu24.04-arm64.tar.gz:/archive.tar.gz:ro" \
  -v "$PWD/out/threading-linux-preview-ubuntu24.04-arm64.deb:/preview.deb:ro" \
  -v "$PWD/tests/app_startup_smoke.py:/test.py:ro" \
  -v "$PWD/tests/live_reinstall_smoke.py:/live-reinstall-test.py:ro" \
  -v "$PWD/tests/terminal_restart_smoke.py:/terminal_restart_smoke.py:ro" \
  -v "$PWD/tests/terminal_catalogue_smoke.py:/terminal_catalogue_smoke.py:ro" \
  -v "$PWD/tests/terminal_catalogue_limits_smoke.py:/terminal_catalogue_limits_smoke.py:ro" \
  -v "$PWD/tests/terminal_directory_smoke.py:/terminal_directory_smoke.py:ro" \
  -v "$PWD/tests/terminal_directory_identity_smoke.py:/terminal_directory_identity_smoke.py:ro" \
  -v "$PWD/tests/workspace_smoke.py:/workspace_smoke.py:ro" \
  -v "$PWD/tests/agent_catalogue_smoke.py:/agent_catalogue_smoke.py:ro" \
  -v "$PWD/out/gtk-present-delay.so:/gtk-present-delay.so:ro" \
  -v "$PWD/tests/provider_marks_smoke.py:/provider_marks_smoke.py:ro" \
  -v "$PWD/tests/runtime_pixel_contract.py:/runtime_pixel_contract.py:ro" \
  -v "$PWD/tests/saved_catalog_menu.py:/saved_catalog_menu.py:ro" \
  -v "$PWD/tests/account_picker_rows_smoke.py:/account_picker_rows_smoke.py:ro" \
  -v "$PWD/tests/project_count_smoke.py:/project_count_smoke.py:ro" \
  -v "$PWD/tests/multi_project_outline_smoke.py:/multi_project_outline_smoke.py:ro" \
  -v "$PWD/tests/terminal_creation_selection_smoke.py:/terminal_creation_selection_smoke.py:ro" \
  -v "$PWD/tests/empty_sidebar_smoke.py:/empty_sidebar_smoke.py:ro" \
  -v "$PWD/tests/folder_drop_source.py:/folder_drop_source.py:ro" \
  -v "$PWD/tests/native_outline_smoke.py:/native_outline_smoke.py:ro" \
  -v "$PWD/tests/project_actions_smoke.py:/project_actions_smoke.py:ro" \
  -v "$PWD/tests/project_create_menu_smoke.py:/project_create_menu_smoke.py:ro" \
  -v "$PWD/tests/composer_smoke.py:/composer_smoke.py:ro" \
  -v "$PWD/tests/composer_permissions_smoke.py:/composer_permissions_smoke.py:ro" \
  -v "$PWD/tests/composer_models_smoke.py:/composer_models_smoke.py:ro" \
  -v "$PWD/tests/document_ui_smoke.py:/document_ui_smoke.py:ro" \
  -v "$PWD/tests/short_user_row_smoke.py:/short_user_row_smoke.py:ro" \
  -v "$PWD/tests/native_workspace_smoke.py:/native_workspace_smoke.py:ro" \
  -v "$PWD/tests/native_permission_smoke.py:/native_permission_smoke.py:ro" \
  -v "$PWD/tests/native_conversation/providers.py:/native-conversation-providers.py:ro" \
  -v "$PWD/tests/user_bubble_smoke.py:/user_bubble_smoke.py:ro" \
  -v "$PWD/tests/automatic_rows_smoke.py:/automatic_rows_smoke.py:ro" \
  -v "$PWD/tests/diff_ui_smoke.py:/diff_ui_smoke.py:ro" \
  -v "$PWD/tests/stream_conversation_smoke.py:/stream_conversation_smoke.py:ro" \
  -v "$PWD/tests/stream_agent_fixture.py:/stream_agent_fixture.py:ro" \
  -v "$PWD/tests/x11_cursor.py:/x11_cursor.py:ro" \
  -v "$PWD/tests/composer_account_smoke.py:/composer_account_smoke.py:ro" \
  -v "$PWD/tests/add_project_button_smoke.py:/add_project_button_smoke.py:ro" \
  -v "$PWD/tests/actions_smoke.py:/actions_smoke.py:ro" \
  -v "$PWD/tests/session_actions_smoke.py:/session_actions_smoke.py:ro" \
  -v "$PWD/tests/open_in_smoke.py:/open_in_smoke.py:ro" \
  -v "$PWD/tests/actions_mark_contract.py:/actions_mark_contract.py:ro" \
  -v "$PWD/tests/saved_terminal_child.py:/saved_terminal_child.py:ro" \
  -v "$PWD/tests/saved_terminal_refusal_smoke.py:/saved_terminal_refusal_smoke.py:ro" \
  -v "$PWD/tests/bundle_runtime_smoke.sh:/runner.sh:ro" \
  -v "$PWD/tests/desktop_entry_smoke.sh:/desktop-test.sh:ro" \
  -v "$PWD/tests/provider_path_smoke.sh:/provider-path-test.sh:ro" \
  -v "$evidence:/evidence" ubuntu:24.04 bash /runner.sh
