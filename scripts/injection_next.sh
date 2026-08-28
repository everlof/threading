#!/bin/bash
#
# Opt-in InjectionNext hot reloading for the macOS app and iOS Simulator app.
#
# The normal project contains no InjectionNext package or linked runtime. This script downloads
# one pinned, notarized release into the user's cache, then starts an InjectionNext-supervised
# Xcode whose macOS and iOS Simulator Debug app builds alone receive an injection xcconfig.
# The IDE ignores XCODE_XCCONFIG_FILE (only xcodebuild copies that variable into its build
# request), so the config reaches the supervised Xcode through the OverridingXCConfigPath user
# default, installed for the session and removed when InjectionNext quits.
#
# Usage:
#   scripts/injection_next.sh xcode      # launch the opt-in supervised Xcode
#   scripts/injection_next.sh stop       # remove the session's build override now
#   scripts/injection_next.sh bootstrap  # download and verify the pinned tool
#   scripts/injection_next.sh status     # inspect the cached tool, override and selected Xcode
#   scripts/injection_next.sh logs       # print the latest InjectionNext log

set -euo pipefail

readonly injection_version="2.0.1"
readonly injection_archive_sha256="7390db00a82bebf6fa2b828f28e40d29b12d551e4c749a15779ce79eae1d9737"
readonly injection_bundle_identifier="com.johnholdsworth.InjectionNext"
readonly injection_team_identifier="9V5A8WE85E"
readonly injection_download_url="https://github.com/johnno1962/InjectionNext/releases/download/${injection_version}/InjectionNext.zip"

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
injection_cache_base="${THREADING_INJECTION_NEXT_CACHE:-${HOME}/Library/Caches/codes.threading/InjectionNext}"
injection_version_directory="${injection_cache_base}/${injection_version}"
injection_app="${injection_version_directory}/InjectionNext.app"
injection_release_macos_dylib="${injection_app}/Contents/Resources/libmacosxInjection.dylib"
injection_release_ios_simulator_dylib="${injection_app}/Contents/Resources/libiphonesimulatorInjection.dylib"
injection_runtime_directory="${injection_version_directory}/Runtime"
injection_macos_dylib="${injection_runtime_directory}/libmacosxInjection.dylib"
injection_ios_simulator_dylib="${injection_runtime_directory}/libiphonesimulatorInjection.dylib"
injection_xcconfig="${script_directory}/config/injection-next.xcconfig"
session_xcconfig="${injection_version_directory}/session.xcconfig"
log_directory="${injection_version_directory}/Logs"
# Xcode and xcodebuild both fall back to this user default when no -xcconfig flag is given, so
# the override exists only while a supervised session does.
readonly xcode_defaults_domain="com.apple.dt.Xcode"
readonly override_defaults_key="OverridingXCConfigPath"
threading_project="${repository_directory}/Threading.xcodeproj"
selected_developer_directory="$(/usr/bin/xcode-select -p)"
selected_xcode_app="${selected_developer_directory%/Contents/Developer}"

usage() {
    sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fail() {
    echo "error: $*" >&2
    exit 1
}

plist_value() {
    local key="$1"
    local plist="$2"
    /usr/libexec/PlistBuddy -c "Print :${key}" "${plist}" 2>/dev/null
}

verify_injection_app() {
    local app="$1"
    local info_plist="${app}/Contents/Info.plist"

    [[ -d "${app}" ]] || fail "InjectionNext ${injection_version} is not cached; run '$0 bootstrap'."
    [[ -f "${info_plist}" ]] || fail "cached InjectionNext has no Info.plist: ${app}"
    [[ "$(plist_value CFBundleIdentifier "${info_plist}")" == "${injection_bundle_identifier}" ]] ||
        fail "cached app has the wrong bundle identifier"
    [[ "$(plist_value CFBundleShortVersionString "${info_plist}")" == "${injection_version}" ]] ||
        fail "cached app is not InjectionNext ${injection_version}"
    [[ -f "${app}/Contents/Resources/libmacosxInjection.dylib" ]] ||
        fail "cached app has no macOS injection client dylib"
    [[ -f "${app}/Contents/Resources/libiphonesimulatorInjection.dylib" ]] ||
        fail "cached app has no iOS Simulator injection client dylib"

    /usr/bin/codesign --verify --deep --strict "${app}" 2>/dev/null ||
        fail "cached InjectionNext signature does not verify"

    local signing_details
    signing_details="$(/usr/bin/codesign -dvvv "${app}" 2>&1)"
    [[ "${signing_details}" == *"TeamIdentifier=${injection_team_identifier}"* ]] ||
        fail "cached InjectionNext is not signed by the pinned developer team"

    /usr/sbin/spctl --assess --type execute "${app}" 2>/dev/null ||
        fail "Gatekeeper did not accept cached InjectionNext"
}

verify_runtime_dylib() {
    local dylib="$1"
    local expected_install_name="${2:-${dylib}}"

    [[ -f "${dylib}" ]] || return 1
    /usr/bin/codesign --verify --strict "${dylib}" 2>/dev/null || return 1

    # The release dylib's install name is rooted at /Applications. Every architecture in the
    # prepared copy must instead name the exact cache-local file the linker and loader will use.
    /usr/bin/otool -D "${dylib}" |
        /usr/bin/awk -v expected="${expected_install_name}" '
            NR > 1 && index($0, " (architecture ") == 0 {
                found = 1
                if ($0 != expected) exit 1
            }
            END { if (!found) exit 1 }
        '
}

prepare_runtime_dylib() {
    local release_dylib="$1"
    local prepared_dylib="$2"

    if verify_runtime_dylib "${prepared_dylib}"; then
        return
    fi

    /bin/mkdir -p "${injection_runtime_directory}"
    local staged_dylib="${prepared_dylib}.staged.$$"
    /usr/bin/ditto "${release_dylib}" "${staged_dylib}"
    /usr/bin/install_name_tool -id "${prepared_dylib}" "${staged_dylib}"
    /usr/bin/codesign --force --sign - --timestamp=none "${staged_dylib}" >/dev/null
    if ! verify_runtime_dylib "${staged_dylib}" "${prepared_dylib}"; then
        /usr/bin/find "${staged_dylib}" -depth -delete 2>/dev/null || true
        fail "could not prepare cache-local InjectionNext client: ${prepared_dylib}"
    fi
    /bin/mv -f "${staged_dylib}" "${prepared_dylib}"
    verify_runtime_dylib "${prepared_dylib}" ||
        fail "prepared InjectionNext client did not survive installation: ${prepared_dylib}"
}

prepare_runtime_dylibs() {
    prepare_runtime_dylib "${injection_release_macos_dylib}" "${injection_macos_dylib}"
    prepare_runtime_dylib \
        "${injection_release_ios_simulator_dylib}" \
        "${injection_ios_simulator_dylib}"
}

bootstrap() {
    if [[ -d "${injection_app}" ]]; then
        verify_injection_app "${injection_app}"
        prepare_runtime_dylibs
        echo "InjectionNext ${injection_version} is already verified at ${injection_app}"
        return
    fi

    /bin/mkdir -p "${injection_cache_base}"
    local staging_directory
    staging_directory="$(mktemp -d "${injection_cache_base}/download.XXXXXX")"

    cleanup_staging() {
        if [[ -d "${staging_directory}" ]]; then
            /usr/bin/find "${staging_directory}" -depth -delete
        fi
    }
    trap cleanup_staging RETURN

    local archive="${staging_directory}/InjectionNext.zip"
    echo "Downloading InjectionNext ${injection_version}…"
    /usr/bin/curl --fail --location --silent --show-error \
        "${injection_download_url}" \
        --output "${archive}"

    local actual_sha256
    actual_sha256="$(/usr/bin/shasum -a 256 "${archive}" | /usr/bin/awk '{print $1}')"
    [[ "${actual_sha256}" == "${injection_archive_sha256}" ]] ||
        fail "InjectionNext archive checksum did not match the pinned release"

    /usr/bin/ditto -x -k "${archive}" "${staging_directory}/unpacked"
    local staged_app="${staging_directory}/unpacked/InjectionNext.app"
    verify_injection_app "${staged_app}"

    /bin/mkdir -p "${injection_version_directory}"
    /bin/mv "${staged_app}" "${injection_app}"
    trap - RETURN
    cleanup_staging
    prepare_runtime_dylibs

    echo "Installed verified InjectionNext ${injection_version} in the user cache."
}

verify_selected_xcode() {
    local info_plist="${selected_xcode_app}/Contents/Info.plist"
    [[ -d "${selected_xcode_app}" && -f "${info_plist}" ]] ||
        fail "xcode-select does not point inside an Xcode app: ${selected_developer_directory}"
    [[ "$(plist_value CFBundleIdentifier "${info_plist}")" == "com.apple.dt.Xcode" ]] ||
        fail "selected developer directory is not an Xcode app: ${selected_developer_directory}"
}

current_override() {
    /usr/bin/defaults read "${xcode_defaults_domain}" "${override_defaults_key}" 2>/dev/null || true
}

# The IDE resolves neither XCODE_XCCONFIG_FILE nor the environment variables the repository
# config refers to, so the session file states both client paths absolutely and includes the
# repository config, which keeps every Debug/wrapper/platform gate in the one reviewed place.
write_session_xcconfig() {
    /bin/mkdir -p "${injection_version_directory}"
    cat > "${session_xcconfig}" <<EOF
// Generated by scripts/injection_next.sh for one supervised InjectionNext session.
// Removed together with the ${override_defaults_key} user default when the session ends.
THREADING_INJECTION_MACOS_DYLIB = ${injection_macos_dylib}
THREADING_INJECTION_IOS_SIMULATOR_DYLIB = ${injection_ios_simulator_dylib}
#include "${injection_xcconfig}"
EOF
}

install_build_override() {
    local existing
    existing="$(current_override)"
    if [[ -n "${existing}" && "${existing}" != "${session_xcconfig}" ]]; then
        fail "${xcode_defaults_domain} ${override_defaults_key} already points at ${existing}; remove it before starting a session"
    fi
    write_session_xcconfig
    /usr/bin/defaults write "${xcode_defaults_domain}" "${override_defaults_key}" -string "${session_xcconfig}"
}

# Removes only an override this script installed; anybody else's stays untouched.
remove_build_override() {
    local existing
    existing="$(current_override)"
    if [[ "${existing}" == "${session_xcconfig}" ]]; then
        /usr/bin/defaults delete "${xcode_defaults_domain}" "${override_defaults_key}"
        echo "Removed the ${override_defaults_key} build override."
    elif [[ -n "${existing}" ]]; then
        echo "Leaving ${override_defaults_key} alone: it points at ${existing}, not this session's file."
    else
        echo "No ${override_defaults_key} build override is installed."
    fi
    /bin/rm -f "${session_xcconfig}"
}

# A supervised session ends when InjectionNext quits. Ordinary Xcode and command-line builds must
# not go on linking the client after that, so a detached waiter takes the override back then.
start_override_waiter() {
    local server_log="$1"
    /usr/bin/nohup /bin/bash -c '
        while /usr/bin/pgrep -x InjectionNext >/dev/null; do /bin/sleep 5; done
        exec "$0" stop
    ' "${BASH_SOURCE[0]}" >>"${server_log}" 2>&1 </dev/null &
    disown
}

launch_supervised_xcode() {
    bootstrap
    verify_selected_xcode

    if /usr/bin/pgrep -x InjectionNext >/dev/null; then
        fail "quit the running InjectionNext before starting this opt-in session"
    fi
    if /usr/bin/pgrep -x Xcode >/dev/null; then
        fail "quit Xcode first; InjectionNext must launch the Xcode used for this session"
    fi

    /bin/mkdir -p "${log_directory}"
    local timestamp
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    local server_log="${log_directory}/InjectionNext-${timestamp}.log"

    install_build_override

    local open_arguments=(
        -n
        --stdout "${server_log}"
        --stderr "${server_log}"
    )
    echo "Launching with ordinary user state; quit every Threading before pressing Run."

    /usr/bin/open "${open_arguments[@]}" "${injection_app}" --args \
        -XcodePath "${selected_xcode_app}" \
        -autoLaunchXcode YES \
        -hideXcodeAlert YES \
        -projectPath "${threading_project}"
    # Let InjectionNext appear in the process table before the waiter starts watching for it.
    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        /usr/bin/pgrep -x InjectionNext >/dev/null && break
        /bin/sleep 1
    done
    start_override_waiter "${server_log}"
    echo "InjectionNext log: ${server_log}"
    echo "Build override: ${override_defaults_key} = ${session_xcconfig}"
    echo "  (removed when InjectionNext quits, or now with '$0 stop')"
    echo "In the launched Xcode: run Threading on My Mac and ThreadingMobile on an iOS Simulator."
    echo "Use two project windows to keep both Run sessions live at the same time."
    echo "Once both clients have connected, saving an existing Swift function body injects it."
}

latest_log() {
    local pattern="$1"
    /usr/bin/find "${log_directory}" -maxdepth 1 -type f -name "${pattern}" -print 2>/dev/null |
        /usr/bin/sort -r |
        /usr/bin/head -1
}

show_logs() {
    local log
    log="$(latest_log 'InjectionNext-*.log')"
    [[ -n "${log}" ]] || fail "no InjectionNext logs exist yet; run '$0 xcode'."
    echo "==> ${log} <=="
    /usr/bin/tail -200 "${log}"
}

command="${1:-}"
case "${command}" in
    bootstrap)
        bootstrap
        ;;
    status)
        verify_injection_app "${injection_app}"
        verify_runtime_dylib "${injection_macos_dylib}" ||
            fail "cache-local macOS client is not prepared; run '$0 bootstrap'."
        verify_runtime_dylib "${injection_ios_simulator_dylib}" ||
            fail "cache-local iOS Simulator client is not prepared; run '$0 bootstrap'."
        verify_selected_xcode
        echo "InjectionNext ${injection_version} is verified at ${injection_app}"
        echo "macOS client: ${injection_macos_dylib}"
        echo "iOS Simulator client: ${injection_ios_simulator_dylib}"
        echo "Selected Xcode: ${selected_xcode_app}"
        override="$(current_override)"
        if [[ -n "${override}" ]]; then
            echo "Build override: ${override_defaults_key} = ${override}"
        else
            echo "Build override: none (ordinary builds link no injection client)"
        fi
        ;;
    xcode)
        launch_supervised_xcode
        ;;
    stop)
        remove_build_override
        ;;
    logs)
        show_logs
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac
