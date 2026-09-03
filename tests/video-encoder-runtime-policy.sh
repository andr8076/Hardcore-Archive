#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
MENU="$ROOT/lib/hardcore-archive-doctor-encoder-menu.sh"
RUNTIME="$ROOT/lib/hardcore-archive-doctor-encoder-runtime.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-encoder-runtime.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/ffmpeg"
chmod 700 "$TMP/bin/ffmpeg"
PATH="$TMP/bin:$PATH"
export PATH

for required in "$MENU" "$RUNTIME"; do
    [[ -f $required ]] || { printf 'Missing encoder runtime test dependency: %s\n' "$required" >&2; exit 1; }
done
bash -n "$MENU"
bash -n "$RUNTIME"
grep -Fq 'HARDCORE_ENCODER_PROBE_SIZE=${HARDCORE_ENCODER_PROBE_SIZE:-640x360}' "$RUNTIME"
grep -Fq -- '-preset:v medium' "$RUNTIME"
grep -Fq 'hardcore_encoder_has_controlling_tty' "$RUNTIME"
grep -Fq '/dev/tty' "$RUNTIME"

# The menu wraps these functions when sourced.
check_video_capability() { return 0; }
probe_hardware_encoder() { VIDEO_PROBE_ERROR=''; return 0; }
source "$MENU"
source "$RUNTIME"

PLATFORM=Linux
linux_has_drm_vendor() { [[ $1 == 0x1002 ]]; }
encoder_available() {
    case "$1" in
        av1_vaapi|hevc_vaapi|av1_nvenc|hevc_nvenc|av1_qsv|hevc_qsv|libaom-av1|librav1e|libsvtav1|libx265) return 0 ;;
        *) return 1 ;;
    esac
}
# Collection behavior is tested independently from FFmpeg hardware availability.
probe_hardware_encoder() { VIDEO_PROBE_ERROR=''; return 0; }
HARDCORE_ARCHIVE_RENDER_NODES='/dev/dri/renderD128'
export HARDCORE_ARCHIVE_RENDER_NODES
hardcore_encoder_menu_collect

# AMD-only host: only AV1/HEVC VAAPI are hardware candidates. FFmpeg-built
# NVIDIA and Intel encoders must not be reported as broken hardware.
(( ${#HARDCORE_ENCODER_MENU_ENCODER[@]} == 2 )) || {
    printf 'Expected exactly 2 AMD VAAPI choices, got %s\n' "${#HARDCORE_ENCODER_MENU_ENCODER[@]}" >&2
    exit 1
}
[[ ${HARDCORE_ENCODER_MENU_ENCODER[0]} == av1_vaapi ]]
[[ ${HARDCORE_ENCODER_MENU_ENCODER[1]} == hevc_vaapi ]]
(( ${#HARDCORE_ENCODER_MENU_FAILED[@]} == 0 ))
(( ${#HARDCORE_ENCODER_MENU_CPU[@]} == 4 ))

# The persistent logger can pipe stdout; prompt input must still work separately.
EFFECTIVE_VIDEO_CODEC=auto
REQUESTED_VIDEO_ENCODER=''
HARDCORE_ARCHIVE_TEST_STDIN=1
unset HARDCORE_ARCHIVE_VAAPI_DEVICE 2>/dev/null || true
hardcore_encoder_menu_prompt <<< '2'
[[ $EFFECTIVE_VIDEO_CODEC == hevc ]]
[[ $REQUESTED_VIDEO_ENCODER == hevc_vaapi ]]
[[ ${HARDCORE_ARCHIVE_VAAPI_DEVICE:-} == /dev/dri/renderD128 ]]

printf 'Encoder runtime probe/backend/prompt tests passed.\n'
