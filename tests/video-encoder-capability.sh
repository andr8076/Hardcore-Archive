#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-capability-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/bin" "$TMP/probes"

cat > "$TMP/bin/ffmpeg" <<'EOF_FFMPEG'
#!/usr/bin/env bash
if [[ " $* " == *" -encoders "* ]]; then
    printf '%s\n' ' V..... av1_qsv AV1 QSV' ' V..... hevc_qsv HEVC QSV' ' V..... libx265 x265'
    if [[ ${OMIT_PRIMARY_LIBSVTAV1:-0} != 1 || ${0##*/} != ffmpeg ]]; then
        printf '%s\n' ' V..... libsvtav1 SVT-AV1'
    fi
    exit 0
fi
encoder='' previous=''
for argument in "$@"; do
    [[ $previous == -c:v ]] && encoder=$argument
    previous=$argument
done
[[ -z ${FAIL_ENCODER:-} || ${FAIL_ENCODER:-} != "$encoder" ]] || { printf 'mock runtime failure for %s\n' "$encoder" >&2; exit 27; }
output=${!#}
[[ $output != - ]] || exit "${FAIL_DECODE:-0}"
[[ ${EMPTY_ENCODER:-} != "$encoder" ]] || { : > "$output"; exit 0; }
case "$encoder" in
    av1_qsv|libsvtav1) codec=av1 ;;
    hevc_qsv|libx265) codec=hevc ;;
    *) exit 2 ;;
esac
[[ ${WRONG_ENCODER:-} != "$encoder" ]] || codec=hevc
printf '%s\n' "$codec" > "$output"
EOF_FFMPEG

cat > "$TMP/bin/ffprobe" <<'EOF_FFPROBE'
#!/usr/bin/env bash
cat -- "${!#}"
EOF_FFPROBE
chmod +x "$TMP/bin/ffmpeg" "$TMP/bin/ffprobe"
cp "$TMP/bin/ffmpeg" "$TMP/bin/system-ffmpeg"
PATH="$TMP/bin:$PATH"
TMPDIR="$TMP/probes"
export PATH TMPDIR

source "$ROOT/lib/video-encoder-capabilities.sh"

[[ $(hardcore_video_encoder_codec libsvtav1) == av1 ]]
[[ $(hardcore_video_encoder_codec libx265) == hevc ]]
[[ $(hardcore_video_encoder_class av1_qsv) == hardware ]]
[[ $(hardcore_video_encoder_class libsvtav1) == software ]]
hardcore_video_encoder_auto_eligible av1_qsv
! hardcore_video_encoder_auto_eligible libsvtav1
! probe_hardware_encoder av1 libsvtav1

probe_video_encoder_capability av1 av1_qsv
probe_video_encoder_capability av1 libsvtav1
probe_video_encoder_capability hevc libx265

# A managed/default FFmpeg may omit optional CPU codecs. The capability keeps
# the pre-activation host FFmpeg as a candidate-specific manual runtime.
HARDCORE_ARCHIVE_SYSTEM_FFMPEG="$TMP/bin/system-ffmpeg"
OMIT_PRIMARY_LIBSVTAV1=1 probe_video_encoder_capability av1 libsvtav1
[[ ${HARDCORE_VIDEO_CAPABILITY_COMMAND[0]} == "$TMP/bin/system-ffmpeg" ]]

! FAIL_ENCODER=av1_qsv probe_video_encoder_capability av1 av1_qsv
[[ $VIDEO_PROBE_ERROR == *'mock runtime failure'* ]]
! EMPTY_ENCODER=libsvtav1 probe_video_encoder_capability av1 libsvtav1
[[ $VIDEO_PROBE_ERROR == *'empty output'* ]]
! WRONG_ENCODER=libsvtav1 probe_video_encoder_capability av1 libsvtav1
[[ $VIDEO_PROBE_ERROR == *"instead of 'av1'"* ]]
! FAIL_DECODE=1 probe_video_encoder_capability hevc libx265
[[ $VIDEO_PROBE_ERROR == *'complete decode'* ]]

if find "$TMP/probes" -mindepth 1 -print -quit | grep -q .; then
    printf 'Capability probe leaked temporary files.\n' >&2
    exit 1
fi

printf 'Video encoder capability-proof tests passed.\n'
