#!/usr/bin/env python3
from pathlib import Path

path = Path('lib/hardcore-archive-video-helper.sh')
text = path.read_text(encoding='utf-8')


def splice(start_marker: str, end_marker: str, replacement: str) -> None:
    global text
    start = text.index(start_marker)
    end = text.index(end_marker, start)
    text = text[:start] + replacement + text[end:]

# AV1 capability listing is owned by AV1Encode; HEVC keeps the legacy probe.
start = text.index('    printf "AV1 Encoders:\\n"\n', text.index('do_list_encoders() {'))
end = text.index('    printf "\\nHEVC / H.265 Encoders:\\n"\n', start)
text = text[:start] + '''    printf "AV1 Encoders:\\n"
    hardcore_av1encode_probe av1_vaapi 2>/dev/null && printf "  av1_vaapi          (AMD/Mesa VA-API Linux Hardware; AV1Encode proven)\\n"
    hardcore_av1encode_probe av1_nvenc 2>/dev/null && printf "  av1_nvenc          (NVIDIA NVENC; AV1Encode proven)\\n"
    hardcore_av1encode_probe av1_qsv 2>/dev/null && printf "  av1_qsv            (Intel QSV; AV1Encode proven)\\n"
    hardcore_av1encode_probe libsvtav1 2>/dev/null && printf "  libsvtav1          (Software SVT-AV1; AV1Encode proven, manual only)\\n"

''' + text[end:]

# Remove encoder-setting knowledge for AV1 from Hardcore Archive. The grouped
# case records only the semantic selection; AV1Encode owns the actual recipe.
start = text.index('        av1_vaapi)\n', text.index('apply_encoder() {'))
end = text.index('        hevc_videotoolbox)\n', start)
text = text[:start] + '''        av1_vaapi|av1_nvenc|av1_qsv|libsvtav1)
            expected_codec='av1'; output_suffix='av1'
            video_codec_label="AV1 via AV1Encode ($enc)"
            video_crf='AV1Encode-owned policy'; video_preset='AV1Encode-owned'; video_pix_fmt=''
            encoder_args=()
            ;;
''' + text[end:]
# Delete the later duplicate AV1 cases now covered by the grouped semantic case.
for begin, finish in [
    ('        av1_nvenc)\n', '        hevc_nvenc)\n'),
]:
    start = text.index(begin, text.index('apply_encoder() {'))
    # This range also contains av1_qsv/libsvtav1 and stops immediately before HEVC NVENC.
    end = text.index(finish, start)
    text = text[:start] + text[end:]

# Any accidental fall-through into the legacy real-encode selector must fail
# rather than silently recreate an AV1 FFmpeg recipe locally.
needle = '''            av1)
                if test_real_encode av1_vaapi av1 -rc_mode CQP -global_quality:v "$AV1_CRF"; then apply_encoder av1_vaapi
                elif test_real_encode av1_nvenc av1 -cq:v "$AV1_CRF" -preset:v p4; then apply_encoder av1_nvenc
                elif test_real_encode av1_qsv av1 -global_quality:v "$AV1_CRF" -preset:v balanced; then apply_encoder av1_qsv
                else die 'No compatible hardware AV1 encoder successfully processed the sample file.'
                fi
                ;;
'''
if needle not in text:
    raise SystemExit('legacy AV1 selector block changed unexpectedly')
text = text.replace(needle, '''            av1)
                die 'Internal routing error: AV1 capability selection must be delegated to AV1Encode.'
                ;;
''', 1)

# Every explicit AV1 encode now routes through protocol 2. In codec-auto mode,
# HCA still compares the AV1Encode prediction against its HEVC candidate first.
splice('use_av1encode_dependency=false\n', 'hardcore_execute_av1encode_plan() {', '''use_av1encode_dependency=false
AV1_DEPENDENCY_WORK=''
AV1_DEPENDENCY_REQUIREMENTS=''
AV1_DEPENDENCY_PLAN=''
AV1_DEPENDENCY_RESULT=''
if [[ $expected_codec == av1 && ${HARDCORE_ARCHIVE_VIDEO_CODEC_AUTO:-0} != 1 ]]; then
    use_av1encode_dependency=true
fi

hardcore_prepare_av1encode_plan() {
    local policy=auto_hardware_only quality_mode=required quality_target="$quality_vmaf_threshold"
    local maximum_height=null denoise=never audio_mode=copy_all
    [[ $(hardcore_video_encoder_class "$video_encoder" 2>/dev/null || true) != software ]] || policy=manual_software
    [[ $quality_check != off ]] || { quality_mode=off; quality_target=0; }
    [[ $apply_scaling != true ]] || maximum_height=$TARGET_HEIGHT
    [[ $apply_denoise != true ]] || denoise=required
    [[ $automatic_audio != true ]] || audio_mode=archive_optimize

    if [[ -n ${AV1_DEPENDENCY_WORK:-} && -d ${AV1_DEPENDENCY_WORK:-} ]]; then
        rm -rf --one-file-system -- "$AV1_DEPENDENCY_WORK" 2>/dev/null || true
    fi
    AV1_DEPENDENCY_WORK=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-av1encode-plan.XXXXXX") || return 1
    AV1_DEPENDENCY_REQUIREMENTS="$AV1_DEPENDENCY_WORK/requirements.json"
    AV1_DEPENDENCY_PLAN="$AV1_DEPENDENCY_WORK/plan.json"
    AV1_DEPENDENCY_RESULT="$AV1_DEPENDENCY_WORK/result.json"
    if ! hardcore_av1encode_write_requirements "$AV1_DEPENDENCY_REQUIREMENTS" "$input" "$temporary" \\
        "$policy" "$quality_target" "$maximum_height" "$denoise" 3 \\
        "$audio_mode" "$video_encoder" "$quality_mode"; then
        HARDCORE_AV1ENCODE_ERROR='Could not create structured AV1Encode requirements.'
        return 1
    fi
    hardcore_av1encode_evaluate "$AV1_DEPENDENCY_REQUIREMENTS" "$AV1_DEPENDENCY_PLAN"
    local evaluate_rc=$?
    (( evaluate_rc == 0 )) || return "$evaluate_rc"
    if [[ $HARDCORE_AV1ENCODE_PLAN_ENCODER != "$video_encoder" ]]; then
        HARDCORE_AV1ENCODE_ERROR="AV1Encode selected $HARDCORE_AV1ENCODE_PLAN_ENCODER, but Hardcore Archive requested $video_encoder."
        return 1
    fi
    video_codec_label="AV1 via AV1Encode protocol 2 ($HARDCORE_AV1ENCODE_PLAN_ENCODER)"
    video_crf='AV1Encode-owned policy; sealed opaque plan'
}

''')

# The AV1 half of automatic codec competition uses AV1Encode's semantic
# evaluation, never HCA's local AV1 quality/FFmpeg search.
splice('calibrate_hardware_candidate() {\n', 'calibrate_hardware_candidate_accelerated() {', '''calibrate_hardware_candidate() {
    if [[ ${1:-} == av1 ]]; then
        hardcore_timed video_calibration hardcore_calibrate_av1encode_candidate "${2:-}"
    else
        hardcore_timed video_calibration calibrate_hardware_candidate_accelerated "$@"
    fi
}

hardcore_calibrate_av1encode_candidate() {
    local encoder=$1 saved_encoder=$video_encoder plan_rc required_savings predicted
    CAL_BEST_QUALITY=''
    CAL_PREDICTED_SAVINGS=''
    CAL_REQUIRED_SAVINGS=''
    CAL_REASON=''
    CAL_QUALITY_LABEL='AV1Encode sealed plan'
    CAL_RESULT_VIDEO_BPS=''

    video_encoder=$encoder
    if hardcore_prepare_av1encode_plan; then
        :
    else
        plan_rc=$?
        video_encoder=$saved_encoder
        if (( plan_rc == 3 )); then
            CAL_REASON=${HARDCORE_AV1ENCODE_PLAN_REASON:-quality-floor-not-met}
            return 2
        fi
        CAL_REASON='av1encode-evaluation-failed'
        return 1
    fi
    video_encoder=$saved_encoder

    CAL_BEST_QUALITY=$HARDCORE_AV1ENCODE_PLAN_ID
    CAL_MIN_VMAF=$HARDCORE_AV1ENCODE_PREDICTED_QUALITY
    predicted=$HARDCORE_AV1ENCODE_PREDICTED_BYTES
    [[ $predicted =~ ^[0-9]+$ && $predicted -gt 0 ]] || {
        CAL_REASON='av1encode-size-prediction-unavailable'
        return 1
    }
    CAL_PREDICTED_SAVINGS=$(LC_NUMERIC=C awk -v original="$original_size" -v candidate="$predicted" 'BEGIN {
        if(original<=0){print 0; exit} printf "%.3f",(original-candidate)*100/original
    }')
    required_savings=$min_savings_percent
    if [[ $source_video_codec == av1 && $apply_scaling != true && $apply_denoise != true ]]; then
        required_savings=$(LC_NUMERIC=C awk -v minimum="$min_savings_percent" 'BEGIN {
            candidate=minimum+5; if(candidate<10) candidate=10; printf "%.3f",candidate
        }')
    fi
    CAL_REQUIRED_SAVINGS=$required_savings
    if ! LC_NUMERIC=C awk -v predicted="$CAL_PREDICTED_SAVINGS" -v required="$required_savings" \\
        'BEGIN {exit !(predicted>=required)}'; then
        CAL_REASON='minimum-saving-not-met'
        return 3
    fi
    CAL_REASON='candidate-valid'
    printf 'AV1Encode candidate: predicted saving %s%%; required %s%%; plan %s.\\n' \\
        "$CAL_PREDICTED_SAVINGS" "$required_savings" "$HARDCORE_AV1ENCODE_PLAN_ID"
    return 0
}

''')

# Applying an AV1 winner selects the already sealed dependency plan. HEVC keeps
# the existing local calibrated settings path.
start = text.index('apply_calibrated_candidate() {\n')
end = text.index('calibrate_and_choose_video_codec() {\n', start)
old = text[start:end]
body_start = old.index('    local codec=$1 encoder=$2 quality=$3 label=$4\n') + len('    local codec=$1 encoder=$2 quality=$3 label=$4\n')
legacy_body = old[body_start:]
# Strip the function's final closing brace/newlines; rewrap below.
if not legacy_body.endswith('}\n\n'):
    raise SystemExit('apply_calibrated_candidate layout changed unexpectedly')
legacy_body = legacy_body[:-3]
replacement = '''apply_calibrated_candidate() {
    local codec=$1 encoder=$2 quality=$3 label=$4
    if [[ $codec == av1 ]]; then
        video_encoder=$encoder
        expected_codec=av1
        output_suffix=av1
        video_codec_label="AV1 via AV1Encode protocol 2 ($encoder)"
        video_crf='AV1Encode-owned policy; sealed opaque plan'
        CAL_SELECTED_VALIDATED=true
        use_av1encode_dependency=true
        printf 'Selected AV1 through sealed AV1Encode plan %s.\\n' "$HARDCORE_AV1ENCODE_PLAN_ID"
        return 0
    fi
''' + legacy_body + '}\n\n'
text = text[:start] + replacement + text[end:]

# AV1Encode evaluation is the AV1 preflight. The local preflight remains HEVC-only.
needle = 'run_video_preflight() {\n'
if needle not in text:
    raise SystemExit('preflight function missing')
text = text.replace(needle, '''run_video_preflight() {
    if [[ $use_av1encode_dependency == true ]]; then
        printf "\\nVideo preflight: AV1Encode protocol-2 evaluation already validated this AV1 plan.\\n"
        return 0
    fi
''', 1)

# No production AV1 route may retain the old compatibility-path message.
if 'AV1 compatibility path retained for this job' in text or 'av1encode_dependency_reason' in text:
    raise SystemExit('legacy AV1 compatibility routing remains after patch')

path.write_text(text, encoding='utf-8')
