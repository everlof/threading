#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build -c release -Xswiftc -enable-testing --product SidebarVisibleRowsHarness
bin=$(swift build -c release -Xswiftc -enable-testing --show-bin-path)
"$bin/SidebarVisibleRowsHarness"
