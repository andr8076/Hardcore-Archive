#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
RUNTIME=
REPORT=
while (( $# )); do
    case $1 in
        --runtime) (( $# >= 2 )) || { printf '%s requires a value\n' "$1" >&2; exit 2; }; RUNTIME=$2; shift 2 ;;
        --report) (( $# >= 2 )) || { printf '%s requires a value\n' "$1" >&2; exit 2; }; REPORT=$2; shift 2 ;;
        -h|--help)
            printf 'Usage: %s --runtime DIR [--report FILE]\n' "${0##*/}"
            exit 0
            ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[[ -n $RUNTIME ]] || { printf -- '--runtime is required\n' >&2; exit 2; }
RUNTIME=$(cd -- "$RUNTIME" 2>/dev/null && pwd -P) || { printf 'Runtime does not exist: %s\n' "$RUNTIME" >&2; exit 2; }
if [[ -n $REPORT ]]; then
    REPORT_DIR=$(dirname -- "$REPORT")
    mkdir -p -- "$REPORT_DIR"
    REPORT=$(cd -- "$REPORT_DIR" && pwd -P)/$(basename -- "$REPORT")
    exec > >(tee "$REPORT") 2>&1
fi

[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || {
    printf 'FAIL This acceptance test requires Linux x86_64.\n' >&2
    exit 2
}
for cmd in awk date grep ldd mktemp python3 readelf sed tee timeout; do
    command -v "$cmd" >/dev/null 2>&1 || { printf 'FAIL Missing diagnostic command: %s\n' "$cmd" >&2; exit 2; }
done

LEGACY_FFMPEG="$RUNTIME/bin/ffmpeg"
LEGACY_FFPROBE="$RUNTIME/bin/ffprobe"
MODERN_FFMPEG=${HCA_MODERN_FFMPEG:-$(command -v ffmpeg || true)}
MODERN_FFPROBE=${HCA_MODERN_FFPROBE:-$(command -v ffprobe || true)}
[[ -x $MODERN_FFMPEG && -x $MODERN_FFPROBE ]] || {
    printf 'FAIL A normal modern ffmpeg and ffprobe are required for comparison and reference generation.\n' >&2
    exit 2
}

TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
REFERENCE="$TMP/reference.nv12"
OUTPUT="$TMP/legacy-hevc.mkv"
ENCODE_LOG="$TMP/legacy-encode.log"

heading() { printf '\n== %s ==\n' "$1"; }
run_bounded() {
    if command -v timeout >/dev/null 2>&1; then timeout --kill-after=3 45 "$@"; else "$@"; fi
}
run_modern_probe_bounded() {
    if command -v timeout >/dev/null 2>&1; then timeout --kill-after=2 12 "$@"; else "$@"; fi
}
legacy() { bash "$HERE/with-runtime.sh" "$RUNTIME" "$@"; }
modern_probe() {
    local label=$1 status
    shift
    if run_modern_probe_bounded "$MODERN_FFMPEG" -nostdin -hide_banner -loglevel error -f lavfi \
        -i testsrc2=size=640x360:rate=30 -frames:v 30 "$@" -an -f null - >/dev/null 2>"$TMP/modern-$label.log"; then
        printf 'PASS Modern probe %-12s real encode succeeded\n' "$label"
    else
        status=$?
        if [[ $status == 124 || $status == 137 ]]; then
            printf 'FAIL Modern probe %-12s timed out\n' "$label"
        else
            printf 'FAIL Modern probe %-12s real encode failed: ' "$label"
            sed '/^[[:space:]]*$/d' "$TMP/modern-$label.log" | tail -n 1 || true
        fi
    fi
}

heading 'Host GPU and driver'
if command -v lspci >/dev/null 2>&1; then
    lspci -nnk | grep -A3 -E 'VGA compatible controller|Display controller|3D controller' || true
else
    printf 'INFO lspci is unavailable.\n'
fi
for driver_link in /sys/class/drm/card*/device/driver; do
    [[ -e $driver_link ]] || continue
    printf 'DRM driver %s: %s\n' "$driver_link" "$(basename -- "$(readlink -f -- "$driver_link")")"
done
[[ -e /dev/dri/renderD128 ]] && ls -l /dev/dri/renderD128 || printf 'INFO /dev/dri/renderD128 is absent.\n'

heading 'Modern FFmpeg identity'
"$MODERN_FFMPEG" -hide_banner -version | head -n 1
"$MODERN_FFMPEG" -hide_banner -buildconf
ldd "$MODERN_FFMPEG" | grep -E 'libmfx|libvpl|libva|libdrm' || printf 'INFO No matching dynamic media libraries shown by ldd.\n'

heading 'Legacy compatibility runtime integrity'
bash "$HERE/inspect.sh" "$RUNTIME"
legacy "$LEGACY_FFMPEG" -hide_banner -version | head -n 1
legacy "$LEGACY_FFMPEG" -hide_banner -buildconf
legacy ldd "$LEGACY_FFMPEG" | grep -E 'libmfx|libvpl|libva|libdrm' || true

heading 'Reference generation'
python3 - "$REFERENCE" <<'PY'
import sys

width, height, frames = 640, 360, 150
row = bytes(16 + (x * 180 // width) for x in range(width))
base_luma = bytearray(row * height)
neutral_chroma = bytes([128]) * (width * height // 2)

with open(sys.argv[1], "wb") as output:
    for frame in range(frames):
        luma = base_luma.copy()
        left = (frame * 3) % (width - 64)
        top = (frame * 2) % (height - 64)
        for y in range(top, top + 64):
            start = y * width + left
            luma[start:start + 64] = b"\xeb" * 64
        output.write(luma)
        output.write(neutral_chroma)
PY
EXPECTED_REFERENCE_BYTES=$(( 640 * 360 * 3 / 2 * 150 ))
REFERENCE_BYTES=$(wc -c < "$REFERENCE")
[[ $REFERENCE_BYTES == "$EXPECTED_REFERENCE_BYTES" ]] || {
    printf 'FAIL Raw reference has %s bytes; expected %s.\n' "$REFERENCE_BYTES" "$EXPECTED_REFERENCE_BYTES" >&2
    exit 1
}
printf 'PASS Deterministic 5-second 640x360 raw NV12 reference generated.\n'

heading 'Genuine legacy HEVC encode'
START_NS=$(date +%s%N)
set +e
run_bounded env \
    INTEL_MEDIA_RUNTIME=MSDK \
    LD_LIBRARY_PATH="$RUNTIME/lib" \
    "$LEGACY_FFMPEG" -nostdin -hide_banner -loglevel verbose -y \
    -f rawvideo -pixel_format nv12 -video_size 640x360 -framerate 30 -i "$REFERENCE" -an \
    -frames:v 150 \
    -c:v hevc_qsv -load_plugin hevc_hw -low_power 0 \
    -global_quality 28 -preset medium \
    "$OUTPUT" 2>&1 | tee "$ENCODE_LOG"
ENCODE_STATUS=${PIPESTATUS[0]}
set -e
if (( ENCODE_STATUS != 0 )); then
    if (( ENCODE_STATUS == 124 || ENCODE_STATUS == 137 )); then
        printf 'FAIL The legacy HEVC encode timed out (status %s).\n' "$ENCODE_STATUS" >&2
    else
        printf 'FAIL The legacy HEVC encode exited with status %s.\n' "$ENCODE_STATUS" >&2
    fi
    exit 1
fi
END_NS=$(date +%s%N)
ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))
[[ -s $OUTPUT ]] || { printf 'FAIL The legacy encode produced an empty output.\n' >&2; exit 1; }

grep -Fq 'Use Intel(R) Media SDK to create MFX session' "$ENCODE_LOG" || {
    printf 'FAIL FFmpeg did not report creation of an Intel Media SDK session.\n' >&2
    exit 1
}
grep -Fq 'Initialized an internal MFX session using hardware accelerated implementation' "$ENCODE_LOG" || {
    printf 'FAIL FFmpeg did not report a hardware-accelerated Media SDK implementation.\n' >&2
    exit 1
}
! grep -Fq 'software implementation' "$ENCODE_LOG" || {
    printf 'FAIL FFmpeg reported a software Media SDK implementation.\n' >&2
    exit 1
}
printf 'PASS Legacy FFmpeg used an Intel Media SDK hardware implementation.\n'
printf 'PASS Runtime integrity inspection excludes oneVPL and resolves private libmfx.\n'
printf 'Legacy encode elapsed_ms=%s\n' "$ELAPSED_MS"
grep -E 'frame=.*(fps=|speed=)' "$ENCODE_LOG" | tail -n 1 || true

heading 'Output verification'
CODEC=$(legacy "$LEGACY_FFPROBE" -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$OUTPUT")
[[ $CODEC == hevc ]] || { printf 'FAIL Expected HEVC output, got: %s\n' "$CODEC" >&2; exit 1; }
DURATION=$(legacy "$LEGACY_FFPROBE" -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUTPUT")
awk -v d="$DURATION" 'BEGIN { exit !(d >= 4.8 && d <= 5.2) }' || {
    printf 'FAIL Output duration is outside 4.8-5.2 seconds: %s\n' "$DURATION" >&2
    exit 1
}
run_bounded bash "$HERE/with-runtime.sh" "$RUNTIME" "$LEGACY_FFMPEG" \
    -hide_banner -loglevel error -xerror -i "$OUTPUT" -map 0:v:0 -f null -
printf 'PASS codec=hevc duration=%s full_decode=ok\n' "$DURATION"

heading 'Quality and software performance comparison'
if "$MODERN_FFMPEG" -hide_banner -filters 2>&1 | grep -Eq '(^|[[:space:]])libvmaf([[:space:]]|$)'; then
    VMAF_LOG="$TMP/vmaf.log"
    if run_bounded "$MODERN_FFMPEG" -hide_banner -i "$OUTPUT" \
        -f rawvideo -pixel_format nv12 -video_size 640x360 -framerate 30 -i "$REFERENCE" \
        -lavfi '[0:v][1:v]libvmaf' -f null - > /dev/null 2>"$VMAF_LOG"; then
        VMAF=$(sed -n 's/.*VMAF score: \([0-9.]*\).*/\1/p' "$VMAF_LOG" | tail -n 1)
        printf 'VMAF=%s\n' "${VMAF:-completed-score-not-parsed}"
    else
        printf 'INFO VMAF was available but comparison failed; this does not waive production quality validation.\n'
    fi
else
    printf 'INFO Modern FFmpeg has no libvmaf filter; VMAF was not measured.\n'
fi

compare_software() {
    local encoder=$1 log="$TMP/$1.log" out="$TMP/$1.mkv" start end elapsed
    "$MODERN_FFMPEG" -hide_banner -encoders 2>&1 | grep -Eq "[[:space:]]$encoder([[:space:]]|$)" || {
        printf 'SKIP %s unavailable\n' "$encoder"; return 0;
    }
    start=$(date +%s%N)
    if run_bounded "$MODERN_FFMPEG" -hide_banner -y \
        -f rawvideo -pixel_format nv12 -video_size 640x360 -framerate 30 -i "$REFERENCE" \
        -an -c:v "$encoder" -crf 28 "$out" > /dev/null 2>"$log"; then
        end=$(date +%s%N)
        elapsed=$(( (end - start) / 1000000 ))
        printf 'Software comparison encoder=%s elapsed_ms=%s bytes=%s\n' "$encoder" "$elapsed" "$(wc -c < "$out")"
        grep -E 'frame=.*(fps=|speed=)' "$log" | tail -n 1 || true
    else
        printf 'INFO Software comparison encoder=%s failed or exceeded 45 seconds.\n' "$encoder"
    fi
}
compare_software libx265
compare_software libsvtav1

# Probe the known-broken modern paths only after the legacy encode has been
# completely verified. On legacy i915/media-driver combinations, killing a
# hung modern probe can leave the next hardware process unable to initialise.
heading 'Modern hardware capability probes'
modern_probe av1_qsv -vf format=nv12 -c:v av1_qsv -global_quality 30 -preset medium
modern_probe hevc_qsv -vf format=nv12 -c:v hevc_qsv -global_quality 28 -preset medium
if [[ -e /dev/dri/renderD128 ]]; then
    modern_probe hevc_vaapi -vaapi_device /dev/dri/renderD128 -vf format=nv12,hwupload -c:v hevc_vaapi -qp 28
else
    printf 'SKIP Modern probe hevc_vaapi: no render node\n'
fi

heading 'Acceptance result'
printf 'PROVEN HEVC via Intel QSV (legacy Media SDK compatibility runtime)\n'
printf 'Selected feasibility candidate: intel-msdk-legacy/hevc_qsv (hardware)\n'
printf 'Production AUTO integration remains a separate gated change after this report is reviewed.\n'
[[ -n $REPORT ]] && printf 'Report: %s\n' "$REPORT"
