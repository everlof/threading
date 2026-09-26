#!/usr/bin/env bash
#
# Creates the Sentry release that exactly matches an exported Apple app, uploads the dSYMs from
# that same archive, associates commits, and records a deploy only after publication succeeds.
# The auth token is supplied by the caller's secret store; this script never reads or writes it.

set -euo pipefail

readonly DEFAULT_ORG="threading"
readonly DEFAULT_PROJECT="threading-macos"

fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

usage() {
    cat >&2 <<'EOF'
usage:
  scripts/sentry-release.sh prepare --app <App.app> --debug-files <dSYMs> --output <file>
  scripts/sentry-release.sh deploy --release-file <file> --environment <name> [--url <url>]
  scripts/sentry-release.sh release-name --app <App.app>
EOF
    exit 2
}

require_cli_and_credentials() {
    command -v sentry-cli >/dev/null || fail "sentry-cli is required for release telemetry"
    [[ -n "${SENTRY_AUTH_TOKEN:-}" ]] \
        || fail "SENTRY_AUTH_TOKEN is unset; add the organization token to the release secret store"
    export SENTRY_ORG="${SENTRY_ORG:-$DEFAULT_ORG}"
    export SENTRY_PROJECT="${SENTRY_PROJECT:-$DEFAULT_PROJECT}"
    validate_org_binding
}

validate_org_binding() {
    local projects status=0
    projects="$(sentry-cli projects list --org "$SENTRY_ORG" 2>&1)" || status=$?
    if [[ "$projects" == *"rather than manually-configured organization"* ]]; then
        fail "the Sentry token is bound to a different organization than $SENTRY_ORG"
    fi
    if [[ "$status" != "0" ]]; then
        printf '%s\n' "$projects" >&2
        fail "the Sentry token cannot read organization $SENTRY_ORG"
    fi
    if ! awk -F '|' -v wanted="$SENTRY_PROJECT" '
        {
            slug = $3
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", slug)
            if (slug == wanted) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' <<< "$projects"; then
        fail "project $SENTRY_ORG/$SENTRY_PROJECT is not visible to the Sentry token"
    fi
}

app_info_plist() {
    local app="$1"
    if [[ -f "$app/Contents/Info.plist" ]]; then
        printf '%s\n' "$app/Contents/Info.plist"
    elif [[ -f "$app/Info.plist" ]]; then
        printf '%s\n' "$app/Info.plist"
    else
        fail "app bundle has no Info.plist: $app"
    fi
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

release_name() {
    local app="$1"
    [[ -d "$app" ]] || fail "app bundle does not exist: $app"

    local info_plist bundle_id version build
    info_plist="$(app_info_plist "$app")"
    bundle_id="$(plist_value "$info_plist" CFBundleIdentifier)"
    version="$(plist_value "$info_plist" CFBundleShortVersionString)"
    build="$(plist_value "$info_plist" CFBundleVersion)"
    [[ -n "$bundle_id" && -n "$version" && -n "$build" ]] \
        || fail "the app bundle has an incomplete Sentry release identity"
    printf '%s@%s+%s\n' "$bundle_id" "$version" "$build"
}

prepare_release() {
    local app="" debug_files="" output=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app) shift; app="${1:-}" ;;
            --debug-files) shift; debug_files="${1:-}" ;;
            --output) shift; output="${1:-}" ;;
            *) usage ;;
        esac
        shift
    done
    [[ -n "$app" && -n "$debug_files" && -n "$output" ]] || usage
    [[ -d "$debug_files" ]] || fail "debug-file directory does not exist: $debug_files"
    find "$debug_files" -name '*.dSYM' -print -quit | grep -q . \
        || fail "the shipping archive contains no dSYM bundles: $debug_files"
    require_cli_and_credentials

    local release
    release="$(release_name "$app")"
    if sentry-cli releases info "$release" >/dev/null 2>&1; then
        echo "Reusing Sentry release $release"
    else
        sentry-cli releases new -p "$SENTRY_PROJECT" "$release"
    fi

    # --wait-for turns server-side processing errors into build failures. Sources are developer
    # source context only; no user content or runtime files are taken from the app.
    sentry-cli debug-files upload \
        -p "$SENTRY_PROJECT" \
        --include-sources \
        --wait-for 300 \
        "$debug_files"
    sentry-cli releases set-commits \
        -p "$SENTRY_PROJECT" \
        --auto \
        --ignore-missing \
        "$release"
    sentry-cli releases finalize -p "$SENTRY_PROJECT" "$release"

    mkdir -p "$(dirname "$output")"
    printf '%s\n' "$release" > "$output"
    echo "Prepared Sentry release $release"
}

deploy_release() {
    local release_file="" environment="" url=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --release-file) shift; release_file="${1:-}" ;;
            --environment) shift; environment="${1:-}" ;;
            --url) shift; url="${1:-}" ;;
            *) usage ;;
        esac
        shift
    done
    [[ -n "$release_file" && -n "$environment" ]] || usage
    [[ -f "$release_file" ]] || fail "Sentry release receipt does not exist: $release_file"
    require_cli_and_credentials

    local release deployments
    read -r release < "$release_file"
    [[ -n "$release" ]] || fail "Sentry release receipt is empty: $release_file"
    deployments="$(sentry-cli deploys list -p "$SENTRY_PROJECT" --release "$release")"
    if awk -F '|' -v wanted="$environment" '
        {
            value = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (value == wanted) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' <<< "$deployments"; then
        echo "Sentry deploy already recorded for $release in $environment"
        return 0
    fi

    local args=(--release "$release" --env "$environment")
    [[ -z "$url" ]] || args+=(--url "$url")
    sentry-cli deploys new "${args[@]}"
    echo "Recorded Sentry deploy for $release in $environment"
}

[[ $# -gt 0 ]] || usage
command="$1"
shift
case "$command" in
    prepare) prepare_release "$@" ;;
    deploy) deploy_release "$@" ;;
    release-name)
        [[ "${1:-}" == "--app" && -n "${2:-}" && $# -eq 2 ]] || usage
        release_name "$2"
        ;;
    *) usage ;;
esac
