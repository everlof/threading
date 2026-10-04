# Sourced, not run. The Linux toolchain every Linux build of the daemon uses.
#
# It matches the Swift in the Xcode this repository builds with, so both builds of the daemon are
# checked by the same compiler. Move all three together. Read by scripts/test-ptyd-linux.sh on the
# host and by scripts/linux/build-ptyd-static.sh inside the container or on a Linux build host.
# shellcheck disable=SC2034 # consumed by the scripts that source this file
readonly threading_linux_swift_image="swift:6.3.2-noble"
readonly threading_static_sdk_url="https://download.swift.org/swift-6.3.2-release/static-sdk/swift-6.3.2-RELEASE/swift-6.3.2-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz"
readonly threading_static_sdk_checksum="3fd798bef6f4408f1ea5a6f94ce4d4052830c4326ab85ebc04f983f01b3da407"
