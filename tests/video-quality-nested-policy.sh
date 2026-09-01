#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P || pwd -P)
CORE=${CORE:-$ROOT/lib/hardcore-archive-core.sh}
DOCTOR_CHECKS=${DOCTOR_CHECKS:-$ROOT/lib/hardcore-archive-doctor-checks.sh}
DOCTOR_VIDEO_FIX=${DOCTOR_VIDEO_FIX:-$ROOT/lib/hardcore-archive-doctor-video-fix.sh}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-video-quality-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

[[ -f $DOCTOR_CHECKS ]] || { printf 'Missing doctor checks: %s\n' "$DOCTOR_CHECKS" >&2; exit 1; }
[[ -f $DOCTOR_VIDEO_FIX ]] || { printf 'Missing doctor video fix: %s\n' "$DOCTOR_VIDEO_FIX" >&2; exit 1; }

# Syntax-check and inspect the exact checked-in engine users execute.
if [[ ${SKIP_CORE_PATCH_TEST:-0} != 1 ]]; then
    [[ -f $CORE ]] || { printf 'Missing core: %s\n' "$CORE" >&2; exit 1; }
    bash -n "$CORE"

    python3 - "$CORE" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
assert '# HARDCORE_COPY_LANE_PATCH_V1' in text
assert '# HARDCORE_MEDIA_NESTED_FIX_V1' in text
assert "json.load(handle)['pooled_metrics']['vmaf']['mean']" in text
assert 'grep -Eo \'"mean"[[:space:]]*:[[:space:]]*[0-9]+' not in text
assert 'encoder_args=("-rc_mode" "CQP" "-global_quality:v" "$quality")' in text
assert 'test_real_encode av1_vaapi av1 -rc_mode CQP -global_quality:v "$AV1_CRF"' in text
assert 'Strict quality policy: VMAF failure is a preflight failure' in text
assert '[[ "$quality_check" == off && "$duration_is_long" != true ]]' in text
assert 'elif [[ $quality_check != off ]]; then' in text
assert 'Sample VMAF quality validation was unavailable. Original preserved unchanged.' in text
assert 'candidate-not-smaller' in text
assert 'recursive-archive-failed' in text
assert 'candidate-integrity-failed' in text
assert 'quality_vmaf_threshold=\'\'' in text
assert 'VIDEO_HELPER_ARGS+=(--quality-vmaf "$VIDEO_MIN_VMAF")' in text
assert 'BATCH_CHILD_ARGS+=(--video-min-vmaf "$VIDEO_MIN_VMAF")' in text
assert '--quality-check "$QUALITY_CHECK" --video-min-vmaf "$VIDEO_MIN_VMAF"' in text
assert 'action\\toriginal path\\tarchived path\\toriginal bytes\\tcandidate bytes\\tarchived bytes\\treason' in text
assert '===== Nested archive decisions =====' in text
assert "read -r action original archived original_size candidate_size archived_size reason" in text
PY
fi

# Reproduce the VMAF bug: an unrelated pooled feature metric appears before the
# real VMAF metric. The parser must select pooled_metrics.vmaf.mean, not the
# first generic field named "mean".
cat > "$TMP/vmaf.json" <<'JSON'
{
  "pooled_metrics": {
    "integer_motion": {"min": 0.95, "max": 0.99, "mean": 0.964221},
    "vmaf": {"min": 93.1, "max": 98.2, "mean": 96.4221}
  }
}
JSON
score=$(python3 - "$TMP/vmaf.json" <<'PY'
import json, math, sys
with open(sys.argv[1], 'r', encoding='utf-8') as handle:
    data = json.load(handle)
value = float(data['pooled_metrics']['vmaf']['mean'])
if math.isfinite(value) and 0.0 <= value <= 100.0:
    print(f'{value:.6f}')
PY
)
[[ $score == 96.422100 ]] || { printf 'Wrong pooled VMAF score: %s\n' "$score" >&2; exit 1; }

# Probe FFmpeg option handling with a fake hardware encoder. A successful probe
# must use VAAPI CQP/global_quality and a warning that options were ignored must
# turn an otherwise successful encode into a hard probe failure.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/ffmpeg" <<'EOF_FFMPEG'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FFMPEG_ARGS_LOG"
out=${!#}
: > "$out"
case ${FFMPEG_TEST_MODE:-ok} in
    ignored)
        printf "Codec AVOption global_quality (Global quality) has not been used for any stream.\n" >&2
        ;;
    default)
        printf "[av1_vaapi] No quality level set; using default (25).\n" >&2
        ;;
esac
exit 0
EOF_FFMPEG
cat > "$TMP/bin/ffprobe" <<'EOF_FFPROBE'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_CODEC:-av1}"
EOF_FFPROBE
chmod +x "$TMP/bin/ffmpeg" "$TMP/bin/ffprobe"

PATH="$TMP/bin:$PATH"
export PATH
export FFMPEG_ARGS_LOG="$TMP/ffmpeg-args.log"
PLATFORM=Linux
linux_has_drm_vendor() { return 1; }
vaapi_device_for_vendor() { return 1; }
# shellcheck source=/dev/null
source "$DOCTOR_CHECKS"
# shellcheck source=/dev/null
source "$DOCTOR_VIDEO_FIX"

: > "$FFMPEG_ARGS_LOG"
export FFMPEG_TEST_MODE=ok FAKE_CODEC=av1
probe_hardware_encoder av1 av1_vaapi || { printf 'Valid AV1 VAAPI quality probe failed: %s\n' "$VIDEO_PROBE_ERROR" >&2; exit 1; }
grep -F -- '-rc_mode CQP' "$FFMPEG_ARGS_LOG" >/dev/null || { printf 'VAAPI probe did not request CQP.\n' >&2; exit 1; }
grep -F -- '-global_quality:v 33' "$FFMPEG_ARGS_LOG" >/dev/null || { printf 'VAAPI probe did not request quality 33.\n' >&2; exit 1; }
if grep -E '(^|[[:space:]])-qp([[:space:]]|$)' "$FFMPEG_ARGS_LOG" >/dev/null; then
    printf 'Obsolete -qp option is still used by the VAAPI doctor probe.\n' >&2
    exit 1
fi

export FFMPEG_TEST_MODE=ignored
if probe_hardware_encoder av1 av1_vaapi; then
    printf 'Ignored FFmpeg quality option was not treated as a hard probe failure.\n' >&2
    exit 1
fi
[[ $VIDEO_PROBE_ERROR == *'ignored required encoder quality options'* ]] || {
    printf 'Ignored-option failure did not explain the cause: %s\n' "$VIDEO_PROBE_ERROR" >&2
    exit 1
}

export FFMPEG_TEST_MODE=default
if probe_hardware_encoder av1 av1_vaapi; then
    printf 'Default-quality warning was not treated as a hard probe failure.\n' >&2
    exit 1
fi

printf 'Video quality and nested-report policy tests passed.\n'
