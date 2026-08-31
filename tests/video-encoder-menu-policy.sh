#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
MENU="$ROOT/lib/hardcore-archive-doctor-encoder-menu.sh"
VAAPI_PATCH="$ROOT/lib/hardcore-archive-vaapi-device.py"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-encoder-menu-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

[[ -f $MENU ]] || { printf 'Missing encoder menu: %s\n' "$MENU" >&2; exit 1; }
[[ -f $VAAPI_PATCH ]] || { printf 'Missing VAAPI device patcher: %s\n' "$VAAPI_PATCH" >&2; exit 1; }
bash -n "$MENU"
python3 -m py_compile "$VAAPI_PATCH"
grep -Fq 'vaapi=va:$device' "$MENU"
grep -Fq 'CPU / software encoders (detected, not selectable: GPU encoding is mandatory)' "$MENU"
grep -Fq 'HARDCORE_ARCHIVE_VAAPI_DEVICE=$device' "$MENU"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/ffmpeg" <<'EOF_FFMPEG'
#!/usr/bin/env bash
exit 0
EOF_FFMPEG
chmod +x "$TMP/bin/ffmpeg"
PATH="$TMP/bin:$PATH"
export PATH

# The menu module wraps these doctor functions when sourced.
check_video_capability() { return 0; }
probe_hardware_encoder() { VIDEO_PROBE_ERROR=''; return 0; }
# shellcheck source=/dev/null
source "$MENU"

# Replace the probe after sourcing so collection can be tested without a GPU.
encoder_available() {
    case "$1" in
        av1_vaapi|hevc_vaapi|av1_nvenc|libsvtav1|libx265) return 0 ;;
        *) return 1 ;;
    esac
}
probe_hardware_encoder() { VIDEO_PROBE_ERROR=''; return 0; }

HARDCORE_ARCHIVE_RENDER_NODES='/dev/dri/renderD128:/dev/dri/renderD129'
export HARDCORE_ARCHIVE_RENDER_NODES
hardcore_encoder_menu_collect

# Two VAAPI codecs x two render nodes, plus one NVENC candidate.
(( ${#HARDCORE_ENCODER_MENU_ENCODER[@]} == 5 )) || {
    printf 'Expected 5 working GPU menu choices, got %s\n' "${#HARDCORE_ENCODER_MENU_ENCODER[@]}" >&2
    exit 1
}
(( ${#HARDCORE_ENCODER_MENU_CPU[@]} == 2 )) || {
    printf 'Expected 2 CPU informational encoders, got %s\n' "${#HARDCORE_ENCODER_MENU_CPU[@]}" >&2
    exit 1
}

menu_output=$(hardcore_encoder_menu_display 2>&1)
grep -Fq 'GPU / hardware encoders (selectable)' <<< "$menu_output"
grep -Fq '[0] AUTO' <<< "$menu_output"
grep -Fq 'av1_vaapi' <<< "$menu_output"
grep -Fq '/dev/dri/renderD128' <<< "$menu_output"
grep -Fq 'CPU / software encoders' <<< "$menu_output"
grep -Fq 'libsvtav1' <<< "$menu_output"
grep -Fq 'libx265' <<< "$menu_output"

EFFECTIVE_VIDEO_CODEC=auto
REQUESTED_VIDEO_ENCODER=''
unset HARDCORE_ARCHIVE_VAAPI_DEVICE 2>/dev/null || true
hardcore_encoder_menu_prompt <<< '1'
[[ $EFFECTIVE_VIDEO_CODEC == av1 ]]
[[ $REQUESTED_VIDEO_ENCODER == av1_vaapi ]]
[[ ${HARDCORE_ARCHIVE_VAAPI_DEVICE:-} == /dev/dri/renderD128 ]]

printf 'Interactive GPU encoder menu tests passed.\n'
