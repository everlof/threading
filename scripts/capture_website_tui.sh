#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
capture_root="${THREADING_MARKETING_OUTPUT_ROOT:-$repository_root/.build/website-tui-evidence}"
capture_stamp="$(date '+%Y%m%d-%H%M%S')-$$"
capture_directory="$capture_root/live-provider-$capture_stamp"

expected_images=(
    threading-tui-git-review.png
    theme-tui-system-dark.png
    theme-tui-cyberpunk-dark.png
    theme-tui-swiss-light.png
    theme-tui-neo-brutalism-light.png
    theme-tui-claymorphism-light.png
    theme-tui-vaporwave-dark.png
)

mkdir -p "$capture_directory"

echo "Capturing Threading with the installed Codex TUI."
echo "This launches one read-only provider turn in a disposable Git repository."

export THREADING_LIVE_MARKETING_CAPTURE=1
export THREADING_RENDER_OUT="$capture_directory"

"$script_directory/test.sh" fast \
    -only-testing:ThreadingTests/GitReviewRenderTests/testRendersFullThreadingShellWithTUIAndGitReview

for image_name in "${expected_images[@]}"; do
    image_path="$capture_directory/$image_name"
    if [[ ! -f "$image_path" ]]; then
        echo "$image_path: error: expected live TUI capture is missing" >&2
        exit 1
    fi

    pixel_width="$(sips -g pixelWidth "$image_path" | awk '/pixelWidth/ { print $2 }')"
    pixel_height="$(sips -g pixelHeight "$image_path" | awk '/pixelHeight/ { print $2 }')"
    if [[ "$pixel_width" != "2560" || "$pixel_height" != "1520" ]]; then
        echo "$image_path: error: ${pixel_width}x${pixel_height}; expected 2560x1520" >&2
        exit 1
    fi
done

echo "Captured ${#expected_images[@]} reviewed-size PNGs in $capture_directory"
