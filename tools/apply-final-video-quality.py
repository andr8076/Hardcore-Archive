#!/usr/bin/env python3
"""One-shot deterministic patch for completed-output video quality validation."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


def regex_once(text: str, pattern: str, replacement: str, label: str) -> str:
    changed, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
    if count != 1:
        raise SystemExit(f"{label}: expected one regex match, found {count}")
    return changed


core_path = ROOT / "lib/hardcore-archive-core.sh"
core = core_path.read_text()

core = replace_once(
    core,
    'export HARDCORE_ARCHIVE_MEDIA_HELPER=$MEDIA_HELPER\n',
    'export HARDCORE_ARCHIVE_MEDIA_HELPER=$MEDIA_HELPER\n'
    'VIDEO_QUALITY_HELPER=${HARDCORE_ARCHIVE_VIDEO_QUALITY_HELPER:-"$(dirname -- "${BASH_SOURCE[0]}")/hardcore-archive-video-quality.py"}\n'
    'VIDEO_QUALITY_FINAL_SH=${HARDCORE_ARCHIVE_VIDEO_QUALITY_FINAL_SH:-"$(dirname -- "${BASH_SOURCE[0]}")/video-quality-final.sh"}\n',
    "quality helper paths",
)

core = replace_once(
    core,
    'VIDEO_MIN_SAVINGS_PERCENT="3"\n',
    'VIDEO_MIN_SAVINGS_PERCENT="3"\n'
    'VIDEO_QUALITY_VALIDATION=${HARDCORE_ARCHIVE_VIDEO_QUALITY_VALIDATION:-sampled}\n'
    'VIDEO_QUALITY_SAMPLE_SECONDS=${HARDCORE_ARCHIVE_VIDEO_QUALITY_SAMPLE_SECONDS:-4}\n'
    'VIDEO_QUALITY_INTERVAL_SECONDS=${HARDCORE_ARCHIVE_VIDEO_QUALITY_INTERVAL_SECONDS:-300}\n'
    'VIDEO_QUALITY_MIN_SAMPLES=${HARDCORE_ARCHIVE_VIDEO_QUALITY_MIN_SAMPLES:-5}\n'
    'VIDEO_QUALITY_MAX_SAMPLES=${HARDCORE_ARCHIVE_VIDEO_QUALITY_MAX_SAMPLES:-16}\n'
    'VIDEO_QUALITY_COMPLEXITY_SAMPLES=${HARDCORE_ARCHIVE_VIDEO_QUALITY_COMPLEXITY_SAMPLES:-2}\n'
    'VIDEO_QUALITY_LOW_PERCENTILE=${HARDCORE_ARCHIVE_VIDEO_QUALITY_LOW_PERCENTILE:-10}\n'
    'VIDEO_QUALITY_PERCENTILE_DELTA=${HARDCORE_ARCHIVE_VIDEO_QUALITY_PERCENTILE_DELTA:-4}\n'
    'VIDEO_QUALITY_SUSTAINED_DELTA=${HARDCORE_ARCHIVE_VIDEO_QUALITY_SUSTAINED_DELTA:-6}\n'
    'VIDEO_QUALITY_SUSTAINED_SECONDS=${HARDCORE_ARCHIVE_VIDEO_QUALITY_SUSTAINED_SECONDS:-1}\n'
    'VIDEO_QUALITY_RETRIES=${HARDCORE_ARCHIVE_VIDEO_QUALITY_RETRIES:-1}\n'
    'VIDEO_QUALITY_RETRY_STEP=${HARDCORE_ARCHIVE_VIDEO_QUALITY_RETRY_STEP:-2}\n',
    "quality defaults",
)

core = replace_once(
    core,
    '  --video-no-preflight     Disable representative sample testing.\n'
    '  --quality-check MODE     auto, off, or required. Default: auto.\n',
    '  --video-no-preflight     Disable representative calibration/preflight testing.\n'
    '  --video-quality-validation MODE\n'
    '                           sampled (bounded duration-scaled coverage) or full.\n'
    '                           Default: sampled. Full scores the completed timeline.\n'
    '  --quality-check MODE     auto, off, or required. Default: auto.\n',
    "usage",
)

core = replace_once(
    core,
    '            VIDEO_MIN_SAVINGS_PERCENT) VIDEO_MIN_SAVINGS_PERCENT=$value ;;\n'
    '            VIDEO_CALIBRATION_CACHE|VIDEO_CALIBRATION_EARLY_ABORT)\n',
    '            VIDEO_MIN_SAVINGS_PERCENT) VIDEO_MIN_SAVINGS_PERCENT=$value ;;\n'
    '            VIDEO_QUALITY_VALIDATION|VIDEO_QUALITY_SAMPLE_SECONDS|VIDEO_QUALITY_INTERVAL_SECONDS|\\\n'
    '            VIDEO_QUALITY_MIN_SAMPLES|VIDEO_QUALITY_MAX_SAMPLES|VIDEO_QUALITY_COMPLEXITY_SAMPLES|\\\n'
    '            VIDEO_QUALITY_LOW_PERCENTILE|VIDEO_QUALITY_PERCENTILE_DELTA|VIDEO_QUALITY_SUSTAINED_DELTA|\\\n'
    '            VIDEO_QUALITY_SUSTAINED_SECONDS|VIDEO_QUALITY_RETRIES|VIDEO_QUALITY_RETRY_STEP)\n'
    '                [[ ${HARDCORE_ARCHIVE_VIDEO_QUALITY_POLICY_INHERITED:-0} == 1 ]] && continue\n'
    '                case $key in\n'
    '                    VIDEO_QUALITY_VALIDATION) VIDEO_QUALITY_VALIDATION=${value,,} ;;\n'
    '                    VIDEO_QUALITY_SAMPLE_SECONDS) VIDEO_QUALITY_SAMPLE_SECONDS=$value ;;\n'
    '                    VIDEO_QUALITY_INTERVAL_SECONDS) VIDEO_QUALITY_INTERVAL_SECONDS=$value ;;\n'
    '                    VIDEO_QUALITY_MIN_SAMPLES) VIDEO_QUALITY_MIN_SAMPLES=$value ;;\n'
    '                    VIDEO_QUALITY_MAX_SAMPLES) VIDEO_QUALITY_MAX_SAMPLES=$value ;;\n'
    '                    VIDEO_QUALITY_COMPLEXITY_SAMPLES) VIDEO_QUALITY_COMPLEXITY_SAMPLES=$value ;;\n'
    '                    VIDEO_QUALITY_LOW_PERCENTILE) VIDEO_QUALITY_LOW_PERCENTILE=$value ;;\n'
    '                    VIDEO_QUALITY_PERCENTILE_DELTA) VIDEO_QUALITY_PERCENTILE_DELTA=$value ;;\n'
    '                    VIDEO_QUALITY_SUSTAINED_DELTA) VIDEO_QUALITY_SUSTAINED_DELTA=$value ;;\n'
    '                    VIDEO_QUALITY_SUSTAINED_SECONDS) VIDEO_QUALITY_SUSTAINED_SECONDS=$value ;;\n'
    '                    VIDEO_QUALITY_RETRIES) VIDEO_QUALITY_RETRIES=$value ;;\n'
    '                    VIDEO_QUALITY_RETRY_STEP) VIDEO_QUALITY_RETRY_STEP=$value ;;\n'
    '                esac\n'
    '                ;;\n'
    '            VIDEO_CALIBRATION_CACHE|VIDEO_CALIBRATION_EARLY_ABORT)\n',
    "config parser",
)

core = replace_once(
    core,
    '        --video-no-preflight)\n'
    '            VIDEO_PREFLIGHT=false\n'
    '            shift\n'
    '            ;;\n',
    '        --video-quality-validation)\n'
    '            (( $# >= 2 )) || die "--video-quality-validation requires sampled or full."\n'
    '            VIDEO_QUALITY_VALIDATION=${2,,}\n'
    '            shift 2\n'
    '            ;;\n'
    '        --video-quality-validation=*)\n'
    '            VIDEO_QUALITY_VALIDATION=${1#*=}\n'
    '            VIDEO_QUALITY_VALIDATION=${VIDEO_QUALITY_VALIDATION,,}\n'
    '            shift\n'
    '            ;;\n'
    '        --video-no-preflight)\n'
    '            VIDEO_PREFLIGHT=false\n'
    '            shift\n'
    '            ;;\n',
    "cli validation mode",
)

validation_anchor = 'LC_NUMERIC=C awk -v v="$VIDEO_MIN_VMAF" \'BEGIN {exit !(v >= 0 && v <= 100)}\' || die "Video minimum VMAF must be between 0 and 100."\n'
validation_block = validation_anchor + r'''case "$VIDEO_QUALITY_VALIDATION" in
    sampled|full) ;;
    *) die "Video quality validation must be sampled or full." ;;
esac
[[ $VIDEO_QUALITY_SAMPLE_SECONDS =~ ^[0-9]+([.][0-9]+)?$ ]] || die "Video quality sample seconds must be numeric."
LC_NUMERIC=C awk -v v="$VIDEO_QUALITY_SAMPLE_SECONDS" 'BEGIN {exit !(v>=1 && v<=30)}' || die "Video quality sample seconds must be between 1 and 30."
[[ $VIDEO_QUALITY_INTERVAL_SECONDS =~ ^[0-9]+([.][0-9]+)?$ ]] || die "Video quality interval seconds must be numeric."
LC_NUMERIC=C awk -v v="$VIDEO_QUALITY_INTERVAL_SECONDS" 'BEGIN {exit !(v>=30 && v<=86400)}' || die "Video quality interval seconds must be between 30 and 86400."
[[ $VIDEO_QUALITY_MIN_SAMPLES =~ ^[1-9][0-9]*$ && $VIDEO_QUALITY_MAX_SAMPLES =~ ^[1-9][0-9]*$ ]] || die "Video quality sample bounds must be positive integers."
(( VIDEO_QUALITY_MIN_SAMPLES <= VIDEO_QUALITY_MAX_SAMPLES && VIDEO_QUALITY_MAX_SAMPLES <= 32 )) || die "Video quality sample bounds must satisfy min <= max <= 32."
[[ $VIDEO_QUALITY_COMPLEXITY_SAMPLES =~ ^[0-9]+$ ]] || die "Video quality complexity samples must be a non-negative integer."
(( VIDEO_QUALITY_COMPLEXITY_SAMPLES <= 8 && VIDEO_QUALITY_COMPLEXITY_SAMPLES < VIDEO_QUALITY_MAX_SAMPLES )) || die "Video quality complexity samples must be below max samples and at most 8."
for _quality_value in VIDEO_QUALITY_LOW_PERCENTILE VIDEO_QUALITY_PERCENTILE_DELTA VIDEO_QUALITY_SUSTAINED_DELTA VIDEO_QUALITY_SUSTAINED_SECONDS; do
    _quality_number=${!_quality_value}
    [[ $_quality_number =~ ^[0-9]+([.][0-9]+)?$ ]] || die "$_quality_value must be numeric."
done
LC_NUMERIC=C awk -v v="$VIDEO_QUALITY_LOW_PERCENTILE" 'BEGIN {exit !(v>=0 && v<=50)}' || die "Video quality low percentile must be between 0 and 50."
LC_NUMERIC=C awk -v v="$VIDEO_QUALITY_PERCENTILE_DELTA" 'BEGIN {exit !(v>=0 && v<=30)}' || die "Video quality percentile delta must be between 0 and 30."
LC_NUMERIC=C awk -v v="$VIDEO_QUALITY_SUSTAINED_DELTA" 'BEGIN {exit !(v>=0 && v<=30)}' || die "Video quality sustained delta must be between 0 and 30."
LC_NUMERIC=C awk -v v="$VIDEO_QUALITY_SUSTAINED_SECONDS" 'BEGIN {exit !(v>0 && v<=10)}' || die "Video quality sustained seconds must be greater than 0 and at most 10."
[[ $VIDEO_QUALITY_RETRIES =~ ^[0-3]$ ]] || die "Video quality retries must be an integer from 0 to 3."
[[ $VIDEO_QUALITY_RETRY_STEP =~ ^[1-9][0-9]*$ ]] || die "Video quality retry step must be a positive integer."
(( VIDEO_QUALITY_RETRY_STEP <= 20 )) || die "Video quality retry step must be at most 20."

# Child archive/video jobs inherit the exact acceptance policy selected by the
# parent. Their config loader deliberately leaves these exported values alone.
export HARDCORE_ARCHIVE_VIDEO_QUALITY_POLICY_INHERITED=1
export HARDCORE_ARCHIVE_VIDEO_QUALITY_VALIDATION="$VIDEO_QUALITY_VALIDATION"
export HARDCORE_ARCHIVE_VIDEO_QUALITY_SAMPLE_SECONDS="$VIDEO_QUALITY_SAMPLE_SECONDS"
export HARDCORE_ARCHIVE_VIDEO_QUALITY_INTERVAL_SECONDS="$VIDEO_QUALITY_INTERVAL_SECONDS"
export HARDCORE_ARCHIVE_VIDEO_QUALITY_MIN_SAMPLES="$VIDEO_QUALITY_MIN_SAMPLES"
export HARDCORE_ARCHIVE_VIDEO_QUALITY_MAX_SAMPLES="$VIDEO_QUALITY_MAX_SAMPLES"
export HARDCORE_ARCHIVE_VIDEO_QUALITY_COMPLEXITY_SAMPLES="$VIDEO_QUALITY_COMPLEXITY_SAMPLES"
export HARDCORE_ARCHIVE_VIDEO_QUALITY_LOW_PERCENTILE="$VIDEO_QUALITY_LOW_PERCENTILE"
export HARDCORE_ARCHIVE_VIDEO_QUALITY_PERCENTILE_DELTA="$VIDEO_QUALITY_PERCENTILE_DELTA"
export HARDCORE_ARCHIVE_VIDEO_QUALITY_SUSTAINED_DELTA="$VIDEO_QUALITY_SUSTAINED_DELTA"
export HARDCORE_ARCHIVE_VIDEO_QUALITY_SUSTAINED_SECONDS="$VIDEO_QUALITY_SUSTAINED_SECONDS"
export HARDCORE_ARCHIVE_VIDEO_QUALITY_RETRIES="$VIDEO_QUALITY_RETRIES"
export HARDCORE_ARCHIVE_VIDEO_QUALITY_RETRY_STEP="$VIDEO_QUALITY_RETRY_STEP"
'''
core = replace_once(core, validation_anchor, validation_block, "validation settings")

core = replace_once(
    core,
    '    [[ -f $MEDIA_HELPER ]] || die "The trusted special-media helper is missing: $MEDIA_HELPER"\n',
    '    [[ -f $MEDIA_HELPER ]] || die "The trusted special-media helper is missing: $MEDIA_HELPER"\n'
    '    [[ -f $VIDEO_QUALITY_FINAL_SH ]] || die "The completed-video quality runner is missing: $VIDEO_QUALITY_FINAL_SH"\n'
    '    if [[ $QUALITY_CHECK != off ]]; then\n'
    '        [[ -f $VIDEO_QUALITY_HELPER ]] || die "The completed-video quality policy helper is missing: $VIDEO_QUALITY_HELPER"\n'
    '    fi\n',
    "quality dependency",
)

core = replace_once(
    core,
    '    "$IMAGE_OPTIMIZE" "$IMAGE_MODE" | \\\n    sha256sum | awk \'{print substr($1,1,24)}\')\n',
    '    "$IMAGE_OPTIMIZE" "$IMAGE_MODE" \\\n'
    '    "video-acceptance-v1-duration-scaled" "$VIDEO_QUALITY_VALIDATION" \\\n'
    '    "$VIDEO_QUALITY_SAMPLE_SECONDS" "$VIDEO_QUALITY_INTERVAL_SECONDS" "$VIDEO_QUALITY_MIN_SAMPLES" \\\n'
    '    "$VIDEO_QUALITY_MAX_SAMPLES" "$VIDEO_QUALITY_COMPLEXITY_SAMPLES" "$VIDEO_QUALITY_LOW_PERCENTILE" \\\n'
    '    "$VIDEO_QUALITY_PERCENTILE_DELTA" "$VIDEO_QUALITY_SUSTAINED_DELTA" "$VIDEO_QUALITY_SUSTAINED_SECONDS" \\\n'
    '    "$VIDEO_QUALITY_RETRIES" "$VIDEO_QUALITY_RETRY_STEP" | \\\n'
    '    sha256sum | awk \'{print substr($1,1,24)}\')\n',
    "job identity",
)

core = replace_once(
    core,
    '        "video-preprocessing-v3-source-display-vmaf" "${HARDCORE_ARCHIVE_VIDEO_ACCELERATION:-auto}" \\\n'
    '        "${HARDCORE_ARCHIVE_VIDEO_GPU_FILTERS:-auto}" "${HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE:-0}" | \\\n',
    '        "video-acceptance-v1-duration-scaled" "${HARDCORE_ARCHIVE_VIDEO_ACCELERATION:-auto}" \\\n'
    '        "${HARDCORE_ARCHIVE_VIDEO_GPU_FILTERS:-auto}" "${HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE:-0}" \\\n'
    '        "$VIDEO_QUALITY_VALIDATION" "$VIDEO_QUALITY_SAMPLE_SECONDS" "$VIDEO_QUALITY_INTERVAL_SECONDS" \\\n'
    '        "$VIDEO_QUALITY_MIN_SAMPLES" "$VIDEO_QUALITY_MAX_SAMPLES" "$VIDEO_QUALITY_COMPLEXITY_SAMPLES" \\\n'
    '        "$VIDEO_QUALITY_LOW_PERCENTILE" "$VIDEO_QUALITY_PERCENTILE_DELTA" "$VIDEO_QUALITY_SUSTAINED_DELTA" \\\n'
    '        "$VIDEO_QUALITY_SUSTAINED_SECONDS" "$VIDEO_QUALITY_RETRIES" "$VIDEO_QUALITY_RETRY_STEP" | \\\n',
    "completed output cache identity",
)

core = replace_once(
    core,
    "        HARDCORE_ARCHIVE_VIDEO_QUALITY_THREADS=\"$RESOURCE_VIDEO_QUALITY_ENV\"\n        bash \"$VIDEO_HELPER\" \"${VIDEO_HELPER_ARGS[@]}\"\n",
    "        HARDCORE_ARCHIVE_VIDEO_QUALITY_THREADS=\"$RESOURCE_VIDEO_QUALITY_ENV\"\n"
    "        HARDCORE_ARCHIVE_VIDEO_QUALITY_HELPER=\"$VIDEO_QUALITY_HELPER\"\n"
    "        HARDCORE_ARCHIVE_VIDEO_QUALITY_FINAL_SH=\"$VIDEO_QUALITY_FINAL_SH\"\n"
    "        HARDCORE_ARCHIVE_VIDEO_QUALITY_VALIDATION=\"$VIDEO_QUALITY_VALIDATION\"\n"
    "        HARDCORE_ARCHIVE_VIDEO_QUALITY_SAMPLE_SECONDS=\"$VIDEO_QUALITY_SAMPLE_SECONDS\"\n"
    "        HARDCORE_ARCHIVE_VIDEO_QUALITY_INTERVAL_SECONDS=\"$VIDEO_QUALITY_INTERVAL_SECONDS\"\n"
    "        HARDCORE_ARCHIVE_VIDEO_QUALITY_MIN_SAMPLES=\"$VIDEO_QUALITY_MIN_SAMPLES\"\n"
    "        HARDCORE_ARCHIVE_VIDEO_QUALITY_MAX_SAMPLES=\"$VIDEO_QUALITY_MAX_SAMPLES\"\n"
    "        HARDCORE_ARCHIVE_VIDEO_QUALITY_COMPLEXITY_SAMPLES=\"$VIDEO_QUALITY_COMPLEXITY_SAMPLES\"\n"
    "        HARDCORE_ARCHIVE_VIDEO_QUALITY_LOW_PERCENTILE=\"$VIDEO_QUALITY_LOW_PERCENTILE\"\n"
    "        HARDCORE_ARCHIVE_VIDEO_QUALITY_PERCENTILE_DELTA=\"$VIDEO_QUALITY_PERCENTILE_DELTA\"\n"
    "        HARDCORE_ARCHIVE_VIDEO_QUALITY_SUSTAINED_DELTA=\"$VIDEO_QUALITY_SUSTAINED_DELTA\"\n"
    "        HARDCORE_ARCHIVE_VIDEO_QUALITY_SUSTAINED_SECONDS=\"$VIDEO_QUALITY_SUSTAINED_SECONDS\"\n"
    "        HARDCORE_ARCHIVE_VIDEO_QUALITY_RETRIES=\"$VIDEO_QUALITY_RETRIES\"\n"
    "        HARDCORE_ARCHIVE_VIDEO_QUALITY_RETRY_STEP=\"$VIDEO_QUALITY_RETRY_STEP\"\n"
    "        bash \"$VIDEO_HELPER\" \"${VIDEO_HELPER_ARGS[@]}\"\n",
    "video helper environment",
)

core = replace_once(
    core,
    "quality_vmaf_threshold=''\nquality_ssim_threshold=0.985\n",
    "quality_vmaf_threshold=''\n"
    "quality_ssim_threshold=0.985\n"
    "video_quality_validation=${HARDCORE_ARCHIVE_VIDEO_QUALITY_VALIDATION:-sampled}\n"
    "video_quality_sample_seconds=${HARDCORE_ARCHIVE_VIDEO_QUALITY_SAMPLE_SECONDS:-4}\n"
    "video_quality_interval_seconds=${HARDCORE_ARCHIVE_VIDEO_QUALITY_INTERVAL_SECONDS:-300}\n"
    "video_quality_min_samples=${HARDCORE_ARCHIVE_VIDEO_QUALITY_MIN_SAMPLES:-5}\n"
    "video_quality_max_samples=${HARDCORE_ARCHIVE_VIDEO_QUALITY_MAX_SAMPLES:-16}\n"
    "video_quality_complexity_samples=${HARDCORE_ARCHIVE_VIDEO_QUALITY_COMPLEXITY_SAMPLES:-2}\n"
    "video_quality_low_percentile=${HARDCORE_ARCHIVE_VIDEO_QUALITY_LOW_PERCENTILE:-10}\n"
    "video_quality_percentile_delta=${HARDCORE_ARCHIVE_VIDEO_QUALITY_PERCENTILE_DELTA:-4}\n"
    "video_quality_sustained_delta=${HARDCORE_ARCHIVE_VIDEO_QUALITY_SUSTAINED_DELTA:-6}\n"
    "video_quality_sustained_seconds=${HARDCORE_ARCHIVE_VIDEO_QUALITY_SUSTAINED_SECONDS:-1}\n"
    "video_quality_retries=${HARDCORE_ARCHIVE_VIDEO_QUALITY_RETRIES:-1}\n"
    "video_quality_retry_step=${HARDCORE_ARCHIVE_VIDEO_QUALITY_RETRY_STEP:-2}\n",
    "embedded helper quality defaults",
)

core = replace_once(
    core,
    "die() { printf 'Error: %s\\n' \"$*\" >&2; exit 1; }\nhas_command() { command -v \"$1\" >/dev/null 2>&1; }\n",
    "die() { printf 'Error: %s\\n' \"$*\" >&2; exit 1; }\n"
    "[[ -n ${HARDCORE_ARCHIVE_VIDEO_QUALITY_FINAL_SH:-} && -f ${HARDCORE_ARCHIVE_VIDEO_QUALITY_FINAL_SH:-} ]] || die 'Completed-video quality runner is unavailable.'\n"
    "source \"$HARDCORE_ARCHIVE_VIDEO_QUALITY_FINAL_SH\"\n"
    "has_command() { command -v \"$1\" >/dev/null 2>&1; }\n",
    "source final validation module",
)

core = replace_once(
    core,
    "    key=$(printf '%s\\0' 'calibration-v4-source-display-resolution-bicubic-sar-nearest-vmaf-model' \\\n",
    "    key=$(printf '%s\\0' 'calibration-v5-source-display-final-acceptance-policy' \\\n",
    "calibration cache version",
)
core = replace_once(
    core,
    '        "$quality_vmaf_threshold" "$(hardcore_video_accel_signature "$encoder")" | sha256sum | awk \'{print $1}\') || return 0\n',
    '        "$quality_vmaf_threshold" \\\n'
    '        "final=${video_quality_validation}:${video_quality_sample_seconds}:${video_quality_interval_seconds}:${video_quality_min_samples}:${video_quality_max_samples}:${video_quality_complexity_samples}:${video_quality_low_percentile}:${video_quality_percentile_delta}:${video_quality_sustained_delta}:${video_quality_sustained_seconds}:${video_quality_retries}:${video_quality_retry_step}" \\\n'
    '        "$(hardcore_video_accel_signature "$encoder")" | sha256sum | awk \'{print $1}\') || return 0\n',
    "calibration acceptance identity",
)

core = replace_once(
    core,
    "printf 'Validation:         Codec, duration and full decode\\n'\n",
    "printf 'Validation:         Codec, duration, full decode + completed-output VMAF (%s)\\n' \"$video_quality_validation\"\n",
    "plan validation label",
)

core = replace_once(
    core,
    "if ! hardcore_video_encode_full; then\n    rm -f -- \"$temporary\"\n    temporary=''\n    die 'Video encoding or validation failed after compatible preprocessing retries.'\nfi\n",
    "encode_rc=0\n"
    "hardcore_video_encode_full || encode_rc=$?\n"
    "if (( encode_rc != 0 )); then\n"
    "    rm -f -- \"$temporary\"\n"
    "    temporary=''\n"
    "    if (( encode_rc == 3 )); then\n"
    "        printf 'Completed output did not pass the configured visual-quality acceptance policy. Original preserved unchanged.\\n'\n"
    "        exit 3\n"
    "    fi\n"
    "    die 'Video encoding or structural validation failed after compatible preprocessing retries.'\n"
    "fi\n",
    "quality rejection fallback",
)

core = replace_once(
    core,
    "        printf 'Minimum accepted saving: %s%%\\n' \"$VIDEO_MIN_SAVINGS_PERCENT\"\n"
    "        printf 'Preflight sampling: %s\\n' \"$($VIDEO_PREFLIGHT && printf 'enabled' || printf 'disabled')\"\n",
    "        printf 'Minimum accepted saving: %s%%\\n' \"$VIDEO_MIN_SAVINGS_PERCENT\"\n"
    "        printf 'Calibration/preflight sampling: %s\\n' \"$($VIDEO_PREFLIGHT && printf 'enabled' || printf 'disabled')\"\n"
    "        printf 'Completed-output quality validation: %s\\n' \"$VIDEO_QUALITY_VALIDATION\"\n"
    "        printf 'Completed-output sample policy: %ss windows, interval %ss, %s..%s samples + up to %s complexity windows\\n' \\\n"
    "            \"$VIDEO_QUALITY_SAMPLE_SECONDS\" \"$VIDEO_QUALITY_INTERVAL_SECONDS\" \"$VIDEO_QUALITY_MIN_SAMPLES\" \"$VIDEO_QUALITY_MAX_SAMPLES\" \"$VIDEO_QUALITY_COMPLEXITY_SAMPLES\"\n"
    "        printf 'Local quality criteria: p%s >= target-%s; sustained %ss below target-%s rejects\\n' \\\n"
    "            \"$VIDEO_QUALITY_LOW_PERCENTILE\" \"$VIDEO_QUALITY_PERCENTILE_DELTA\" \"$VIDEO_QUALITY_SUSTAINED_SECONDS\" \"$VIDEO_QUALITY_SUSTAINED_DELTA\"\n",
    "video manifest policy",
)

core = core.replace('SCRIPT_VERSION="2026-09-04"', 'SCRIPT_VERSION="2026-09-07"', 1)
core = core.replace("readonly SCRIPT_VERSION='2026-09-07-integrated-video-r4'", "readonly SCRIPT_VERSION='2026-09-07-integrated-video-r5'", 1)
core_path.write_text(core)


accel_path = ROOT / "lib/video-acceleration.sh"
accel = accel_path.read_text()
new_encode_full = r'''hardcore_video_encode_full() {
    local preprocessing_attempt=0 quality_retry_count=0
    hardcore_video_accel_prepare "$video_encoder"
    while (( preprocessing_attempt < 3 )); do
        preprocessing_attempt=$((preprocessing_attempt + 1))
        quality_retry_count=0
        while true; do
            rm -f -- "$temporary"
            if hardcore_video_encode_attempt; then
                if hardcore_video_validate_completed_quality "$temporary"; then
                    return 0
                fi
                rm -f -- "$temporary"
                if [[ ${VIDEO_FINAL_QUALITY_RETRYABLE:-false} == true ]] &&
                   (( quality_retry_count < video_quality_retries )) &&
                   hardcore_video_raise_quality; then
                    quality_retry_count=$((quality_retry_count + 1))
                    printf 'Completed-output quality retry %s/%s.\n' "$quality_retry_count" "$video_quality_retries"
                    continue
                fi
                return 3
            fi

            rm -f -- "$temporary"
            break
        done

        # Structural/encode failure still follows the existing preprocessing
        # fallback path. A quality rejection never silently changes the target.
        (( preprocessing_attempt < 3 )) && hardcore_video_accel_force_cpu "$video_encoder" || return 1
        calibrate_and_choose_video_codec || return 1
        run_video_preflight || return 1
    done
    return 1
}
'''
accel = regex_once(
    accel,
    r'hardcore_video_encode_full\(\) \{.*?\n\}\n\nexport -f hardcore_video_accel_init',
    new_encode_full + '\nexport -f hardcore_video_accel_init',
    "encode full acceptance",
)
accel_path.write_text(accel)


config_path = ROOT / "config"
config = config_path.read_text()
config = replace_once(
    config,
    'VIDEO_CALIBRATION_EARLY_ABORT=true\n',
    'VIDEO_CALIBRATION_EARLY_ABORT=true\n'
    '# Completed outputs are independently validated after the full encode.\n'
    '# sampled: bounded duration-scaled windows; full: score the complete timeline.\n'
    'VIDEO_QUALITY_VALIDATION=sampled\n'
    '# Sampled mode: 4-second windows; at least five, increasing with duration, capped at 16.\n'
    'VIDEO_QUALITY_SAMPLE_SECONDS=4\n'
    'VIDEO_QUALITY_INTERVAL_SECONDS=300\n'
    'VIDEO_QUALITY_MIN_SAMPLES=5\n'
    'VIDEO_QUALITY_MAX_SAMPLES=16\n'
    '# Add up to two deterministic high-packet-rate windows as difficult-scene hints.\n'
    'VIDEO_QUALITY_COMPLEXITY_SAMPLES=2\n'
    '# Every sampled window mean must still meet QUALITY_CHECK. In addition,\n'
    '# p10 may fall at most 4 points and >=1s below target-6 rejects.\n'
    'VIDEO_QUALITY_LOW_PERCENTILE=10\n'
    'VIDEO_QUALITY_PERCENTILE_DELTA=4\n'
    'VIDEO_QUALITY_SUSTAINED_DELTA=6\n'
    'VIDEO_QUALITY_SUSTAINED_SECONDS=1\n'
    '# One bounded higher-quality retry is allowed; the VMAF target never moves.\n'
    'VIDEO_QUALITY_RETRIES=1\n'
    'VIDEO_QUALITY_RETRY_STEP=2\n',
    "config defaults",
)
config_path.write_text(config)


readme_path = ROOT / "README.md"
readme = readme_path.read_text()
section = r'''### Completed-output video quality validation

Encoder calibration remains deliberately inexpensive: supported hardware encoders still search quality using the existing three 3-second calibration positions near 10%, 50%, and 90%. Those measurements choose an encoder/quality boundary; they **do not authorize the completed file by themselves**.

After the real full encode and CPU decode audit, Hardcore Archive independently compares the **actual completed output** with the original using the same source-display-resolution VMAF policy described above. The reference is never shrunk to a reduced candidate resolution, timestamps use the existing AVTB/`PTS-STARTPTS`/nearest-frame policy, and both inputs use the same color/range normalization.

The default `VIDEO_QUALITY_VALIDATION=sampled` policy is deterministic and bounded. Four-second windows are distributed across the complete duration. It starts with at least five uniform windows, adds coverage as duration grows (`VIDEO_QUALITY_INTERVAL_SECONDS`, default 300 seconds), and stops at `VIDEO_QUALITY_MAX_SAMPLES` (default 16). With five windows the centers are approximately 10/30/50/70/90%, so degradation outside the old calibration positions receives explicit coverage. Clips up to the default 20-second sampling budget are covered continuously. Up to two additional non-overlapping windows are selected from high packet-rate regions as an inexpensive, reproducible difficult-scene **heuristic**; packet rate is not a perceptual complexity detector and failure to obtain those hints does not remove the uniform samples.

Acceptance is stricter than an average alone. The aggregate mean and **every sampled-window mean** must meet the configured VMAF target. The default low-percentile criterion additionally requires p10 to stay within 4 VMAF points of the target, and a continuous run of roughly one second below target-6 rejects the candidate. Sustained duration is derived from each measured segment's actual frame population rather than assuming a fixed frame rate, so variable-frame-rate material is not evaluated as though it were always 30 or 60 fps. One isolated noisy frame is therefore not enough to reject an otherwise good video, while sustained/localized degradation cannot hide behind a high global average.

Use `--video-quality-validation full` (or `VIDEO_QUALITY_VALIDATION=full`) to run VMAF across the completed timeline. Full mode is much slower: it can approach another full decode of both source and candidate plus VMAF computation and can produce a large temporary VMAF log. Sampled mode is intentionally cheaper: at the shipped maximum it scores at most about 64 seconds of non-overlapping source material, plus inexpensive packet-header inspection. **Sampled validation is sampled assurance, not a whole-video guarantee.** Full mode provides whole-timeline metric coverage, but VMAF itself remains a model of perceptual quality rather than proof that every viewer will judge every frame perfect.

Missing, empty, malformed, or failed final measurements never authorize a transcode. A measured quality rejection may trigger the configured bounded higher-quality retry (`VIDEO_QUALITY_RETRIES`, default 1); the VMAF target is never lowered. If the backend cannot move to a higher-quality setting, retries are exhausted, validation still fails, or the higher-quality output no longer meets minimum savings, the original is preserved. Hardware-only encoding and the existing CPU/RAM resource limits remain unchanged.

Completed-output resume identities and calibration/preprocessing identities include the final-validation mode, sampling bounds, local-quality criteria, and retry policy. Changing any of those settings invalidates older evidence instead of silently reusing a transcode accepted under a different policy.

'''
readme = replace_once(readme, '### Calibration reuse\n', section + '### Calibration reuse\n', "README final validation section")
readme = readme.replace(
    'VMAF scoring and the final full decode audit remain on the CPU. The audit treats decoder errors as fatal (`-xerror`). Stream-count, codec, duration, final size and archive verification checks remain in place. Acceleration does not change the VMAF target, sampling timestamps or audio/subtitle/attachment/chapter mappings.',
    'VMAF scoring, completed-output acceptance, and the final full decode audit remain on the CPU. The decode audit treats decoder errors as fatal (`-xerror`); completed-output VMAF is a separate fidelity gate. Stream-count, codec, duration, final size and archive verification checks remain in place. Acceleration does not change the VMAF target, timestamp alignment or audio/subtitle/attachment/chapter mappings.',
)
readme = readme.replace(
    'The selected candidate reuses those measurements instead of repeating the separate three-segment preflight. Final codec, duration, stream-count, full-decode and actual-size checks remain in place.',
    'The selected candidate reuses those measurements instead of repeating the separate three-segment preflight. The completed output must still pass its independent sampled/full VMAF acceptance check plus final codec, duration, stream-count, full-decode and actual-size checks.',
)
readme_path.write_text(readme)


layout_path = ROOT / "tests/module-layout.sh"
layout = layout_path.read_text()
layout = replace_once(
    layout,
    '    common platform config doctor inventory planner scheduler archive video images resource-pool timing calibration-identity video-acceleration media-policy runtime\n',
    '    common platform config doctor inventory planner scheduler archive video images resource-pool timing calibration-identity video-acceleration video-quality-final media-policy runtime\n',
    "module list",
)
layout = replace_once(
    layout,
    'python3 -m py_compile "$ROOT/lib/hardcore-archive-zopfli-adaptive.py"\n',
    'python3 -m py_compile "$ROOT/lib/hardcore-archive-zopfli-adaptive.py"\n'
    'python3 -m py_compile "$ROOT/lib/hardcore-archive-video-quality.py"\n',
    "video quality pycompile",
)
layout_path.write_text(layout)


workflow_path = ROOT / ".github/workflows/runtime-tests.yml"
workflow = workflow_path.read_text()
workflow = replace_once(
    workflow,
    '          python3 tests/video-quality-performance.py\n',
    '          python3 tests/video-quality-performance.py\n'
    '          python3 tests/video-final-quality.py\n',
    "runtime quality test",
)
workflow_path.write_text(workflow)


frontend_path = ROOT / "tests/frontend-policy.sh"
frontend = frontend_path.read_text()
frontend = replace_once(
    frontend,
    'bash "$ROOT/tests/video-quality-performance.sh"\n',
    'bash "$ROOT/tests/video-quality-performance.sh"\n'
    'python3 "$ROOT/tests/video-final-quality.py"\n',
    "frontend quality test",
)
frontend_path.write_text(frontend)

print("Completed-video quality patch applied successfully.")
