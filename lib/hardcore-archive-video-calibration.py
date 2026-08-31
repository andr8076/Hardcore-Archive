#!/usr/bin/env python3
"""Calibrate hardware video quality and choose AV1 vs HEVC per file when requested."""
from __future__ import annotations

import os
import pathlib
import sys

MARKER = "# HARDCORE_VIDEO_CODEC_COMPETITION_V2"


def fail(label: str, count: int) -> None:
    print(
        f"Error: video codec competition patch failed: {label}: expected one anchor, found {count}",
        file=sys.stderr,
    )
    raise SystemExit(1)


def repl(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        fail(label, count)
    return text.replace(old, new, 1)


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} INPUT_CORE OUTPUT_CORE", file=sys.stderr)
        return 2

    src, dst = map(pathlib.Path, sys.argv[1:])
    text = src.read_text(encoding="utf-8")
    if MARKER in text:
        dst.write_text(text, encoding="utf-8")
        os.chmod(dst, 0o700)
        return 0

    text = repl(
        text,
        '''            video_crf="CQP ${AV1_CRF}"; video_preset='N/A'; video_pix_fmt='vaapi'
            encoder_args=("-rc_mode" "CQP" "-global_quality:v" "$AV1_CRF")''',
        '''            # HARDCORE_VIDEO_CODEC_COMPETITION_V2
            video_crf="CQP q_idx 128 (pre-calibration)"; video_preset='N/A'; video_pix_fmt='vaapi'
            encoder_args=("-rc_mode" "CQP" "-global_quality:v" "128")''',
        "AV1 VAAPI pre-calibration q_idx",
    )
    text = repl(
        text,
        '''            video_crf="CQP ${HEVC_CRF}"; video_preset='N/A'; video_pix_fmt='vaapi'
            encoder_args=("-rc_mode" "CQP" "-global_quality:v" "$HEVC_CRF")''',
        '''            video_crf="CQP QP 26 (pre-calibration)"; video_preset='N/A'; video_pix_fmt='vaapi'
            encoder_args=("-rc_mode" "CQP" "-global_quality:v" "26")''',
        "HEVC VAAPI pre-calibration QP",
    )

    old_vmaf_filter = (
        '[0:v:0]setpts=PTS-STARTPTS,scale=${width}:${height}:flags=lanczos,'
        'format=yuv420p[ref];[1:v:0]setpts=PTS-STARTPTS,format=yuv420p[dist];'
        '[dist][ref]libvmaf=log_fmt=json:log_path=${log_file}'
    )
    new_vmaf_filter = (
        '[0:v:0]setpts=PTS-STARTPTS,scale=${width}:${height}:flags=lanczos:'
        'out_range=tv,format=yuv420p[ref];'
        '[1:v:0]setpts=PTS-STARTPTS,scale=${width}:${height}:flags=bilinear:'
        'out_range=tv,format=yuv420p[dist];'
        '[dist][ref]libvmaf=log_fmt=json:log_path=${log_file}'
    )
    text = repl(text, old_vmaf_filter, new_vmaf_filter, "VMAF range normalisation")

    calibration = r'''
HARDCORE_AUTO_CODEC_MODE=${HARDCORE_ARCHIVE_VIDEO_CODEC_AUTO:-0}
HARDCORE_AUTO_AV1_ENCODER=${HARDCORE_ARCHIVE_AUTO_AV1_ENCODER:-}
HARDCORE_AUTO_HEVC_ENCODER=${HARDCORE_ARCHIVE_AUTO_HEVC_ENCODER:-}
CAL_MIN_VMAF=''
CAL_AVG_VIDEO_BPS=''
CAL_BEST_QUALITY=''
CAL_PREDICTED_SAVINGS=''
CAL_REQUIRED_SAVINGS=''
CAL_REASON=''
CAL_QUALITY_LABEL=''

calibration_encoder_supported() {
    case "$1" in
        av1_vaapi|hevc_vaapi|av1_nvenc|hevc_nvenc|av1_qsv|hevc_qsv) return 0 ;;
        *) return 1 ;;
    esac
}

calibration_quality_range() {
    case "$1" in
        av1_vaapi) printf '1 255 q_idx' ;;
        hevc_vaapi) printf '1 51 QP' ;;
        av1_nvenc|hevc_nvenc) printf '1 51 CQ' ;;
        av1_qsv|hevc_qsv) printf '1 51 ICQ' ;;
        *) return 1 ;;
    esac
}

calibration_apply_quality() {
    local encoder=$1 quality=$2
    case "$encoder" in
        av1_vaapi|hevc_vaapi)
            encoder_args=("-rc_mode" "CQP" "-global_quality:v" "$quality") ;;
        av1_nvenc|hevc_nvenc)
            encoder_args=("-cq:v" "$quality" "-preset:v" "p4") ;;
        av1_qsv|hevc_qsv)
            encoder_args=("-global_quality:v" "$quality" "-preset:v" "balanced") ;;
        *) return 1 ;;
    esac
}

calibration_build_filter_chain() {
    local encoder=$1
    local -a filters=()
    [[ "$apply_denoise" == true ]] && filters+=("$DENOISE_FILTER")
    [[ "$apply_scaling" == true ]] && filters+=("scale=-2:${TARGET_HEIGHT}:flags=lanczos")
    if [[ $encoder == *_vaapi ]]; then
        filters+=("format=nv12" "hwupload")
    fi
    CAL_FILTER_CHAIN=''
    ((${#filters[@]} > 0)) && CAL_FILTER_CHAIN=$(IFS=,; printf '%s' "${filters[*]}")
}

calibration_candidate_command() {
    local encoder=$1 quality=$2 start=$3 sample_length=$4 sample_file=$5
    local CAL_FILTER_CHAIN=''
    calibration_build_filter_chain "$encoder"
    CAL_COMMAND=(ffmpeg -hide_banner -v error -nostdin -y)
    [[ $encoder == *_vaapi ]] && CAL_COMMAND+=(-init_hw_device "vaapi=va:" -filter_hw_device va)
    CAL_COMMAND+=(
        -ss "$start" -i "$input" -t "$sample_length"
        -map '0:V:0' -an -sn -dn
        -c:v "$encoder"
    )
    case "$encoder" in
        av1_vaapi|hevc_vaapi) CAL_COMMAND+=(-rc_mode CQP -global_quality:v "$quality") ;;
        av1_nvenc|hevc_nvenc) CAL_COMMAND+=(-cq:v "$quality" -preset:v p4 -pix_fmt:v p010le) ;;
        av1_qsv|hevc_qsv) CAL_COMMAND+=(-global_quality:v "$quality" -preset:v balanced -pix_fmt:v p010le) ;;
        *) return 1 ;;
    esac
    [[ -n "$CAL_FILTER_CHAIN" ]] && CAL_COMMAND+=(-vf "$CAL_FILTER_CHAIN")
    CAL_COMMAND+=(-f matroska "$sample_file")
}

evaluate_hardware_quality() {
    local codec=$1 encoder=$2 quality=$3
    local sample_length=3
    local -a positions=(0.10 0.50 0.90)
    local position start sample_file actual_length sample_size sample_bps
    local total_bps=0 sample_count=0 minimum_vmaf=101
    local -a CAL_COMMAND=()

    if LC_NUMERIC=C awk -v d="$duration" 'BEGIN {exit !(d<9)}'; then
        positions=(0.50)
        sample_length=$(LC_NUMERIC=C awk -v d="$duration" 'BEGIN {
            v=d; if(v>3)v=3; if(v<1)v=1; printf "%.3f",v
        }')
    fi

    for position in "${positions[@]}"; do
        start=$(LC_NUMERIC=C awk -v d="$duration" -v l="$sample_length" -v p="$position" 'BEGIN {
            room=d-l; if(room<0)room=0; s=room*p; if(s<0)s=0; printf "%.3f",s
        }')
        sample_file="${output_dir}/.${output_name}.calibrate-${codec}-${quality}.$$.${sample_count}.mkv"
        preflight_files+=("$sample_file" "${sample_file}.vmaf.json")
        rm -f -- "$sample_file" "${sample_file}.vmaf.json"

        calibration_candidate_command "$encoder" "$quality" "$start" "$sample_length" "$sample_file" || return 1
        if ! "${CAL_COMMAND[@]}"; then
            printf '%s via %s quality %s: sample encode failed.\n' "${codec^^}" "$encoder" "$quality"
            rm -f -- "$sample_file" "${sample_file}.vmaf.json"
            return 1
        fi

        actual_length=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$sample_file" 2>/dev/null | head -n1)
        sample_size=$(stat -c '%s' -- "$sample_file" 2>/dev/null || printf 0)
        if [[ ! $actual_length =~ ^[0-9]+([.][0-9]+)?$ ]] || (( sample_size <= 0 )); then
            rm -f -- "$sample_file" "${sample_file}.vmaf.json"
            return 1
        fi
        sample_bps=$(LC_NUMERIC=C awk -v bytes="$sample_size" -v seconds="$actual_length" \
            'BEGIN {if(seconds<=0)print 0; else printf "%.0f",bytes*8/seconds}')
        total_bps=$((total_bps + sample_bps))
        sample_count=$((sample_count + 1))

        if ! measure_preflight_quality "$start" "$actual_length" "$sample_file" || \
           [[ $MEASURED_QUALITY_KIND != VMAF ]]; then
            rm -f -- "$sample_file" "${sample_file}.vmaf.json"
            return 1
        fi
        if LC_NUMERIC=C awk -v a="$MEASURED_QUALITY_SCORE" -v b="$minimum_vmaf" \
            'BEGIN {exit !(a<b)}'; then
            minimum_vmaf=$MEASURED_QUALITY_SCORE
        fi
        rm -f -- "$sample_file" "${sample_file}.vmaf.json"
    done

    (( sample_count > 0 )) || return 1
    CAL_MIN_VMAF=$minimum_vmaf
    CAL_AVG_VIDEO_BPS=$((total_bps / sample_count))
    return 0
}

calibrate_hardware_candidate() {
    local codec=$1 encoder=$2
    local range low high quality_label mid best_quality=0 best_video_bps=0
    local source_average_bps predicted_output_bps required_savings

    CAL_BEST_QUALITY=''
    CAL_PREDICTED_SAVINGS=''
    CAL_REQUIRED_SAVINGS=''
    CAL_REASON=''
    CAL_QUALITY_LABEL=''

    calibration_encoder_supported "$encoder" || {
        CAL_REASON='encoder-family-not-calibrated'
        return 4
    }
    range=$(calibration_quality_range "$encoder") || return 4
    read -r low high quality_label <<< "$range"
    CAL_QUALITY_LABEL=$quality_label

    source_average_bps=$(LC_NUMERIC=C awk -v bytes="$original_size" -v seconds="$duration" \
        'BEGIN {if(seconds<=0)print 0; else printf "%.0f",bytes*8/seconds}')
    [[ $source_average_bps =~ ^[0-9]+$ ]] && (( source_average_bps > 0 )) || {
        CAL_REASON='source-bitrate-unavailable'; return 1;
    }

    required_savings="$min_savings_percent"
    if [[ "$source_video_codec" == "$codec" && "$apply_scaling" != true && "$apply_denoise" != true ]]; then
        required_savings=$(LC_NUMERIC=C awk -v minimum="$min_savings_percent" 'BEGIN {
            candidate=minimum+5; if(candidate<10) candidate=10; printf "%.3f",candidate
        }')
    fi
    CAL_REQUIRED_SAVINGS=$required_savings

    printf '\n%s hardware quality calibration\n' "${codec^^}"
    printf '%s\n' '────────────────────────────────────────────────────────────'
    printf 'Encoder: %s | searching %s %s..%s for worst-sample VMAF >= %s.\n' \
        "$encoder" "$quality_label" "$low" "$high" "$quality_vmaf_threshold"

    while (( low <= high )); do
        mid=$(((low + high) / 2))
        if ! evaluate_hardware_quality "$codec" "$encoder" "$mid"; then
            CAL_REASON="sample-probe-failed-at-${mid}"
            return 1
        fi
        printf '%s %s: worst VMAF %s.\n' "$quality_label" "$mid" "$CAL_MIN_VMAF"
        if LC_NUMERIC=C awk -v v="$CAL_MIN_VMAF" -v threshold="$quality_vmaf_threshold" \
            'BEGIN {exit !(v>=threshold)}'; then
            best_quality=$mid
            best_video_bps=$CAL_AVG_VIDEO_BPS
            low=$((mid + 1))
        else
            high=$((mid - 1))
        fi
    done

    if (( best_quality <= 0 )); then
        CAL_REASON='quality-floor-not-met'
        return 2
    fi

    predicted_output_bps=$(LC_NUMERIC=C awk -v video="$best_video_bps" -v audio="$estimated_output_audio_bps" \
        'BEGIN {printf "%.0f",(video+audio)*1.015}')
    CAL_PREDICTED_SAVINGS=$(LC_NUMERIC=C awk -v source="$source_average_bps" -v output="$predicted_output_bps" 'BEGIN {
        if(source<=0){print 0; exit} printf "%.2f",(source-output)*100/source
    }')
    CAL_BEST_QUALITY=$best_quality
    printf '%s quality-valid boundary: %s %s; predicted saving %s%%; required %s%%.\n' \
        "${codec^^}" "$quality_label" "$best_quality" "$CAL_PREDICTED_SAVINGS" "$required_savings"

    if ! LC_NUMERIC=C awk -v saving="$CAL_PREDICTED_SAVINGS" -v required="$required_savings" \
        'BEGIN {exit !(saving>=required)}'; then
        CAL_REASON='minimum-saving-not-met'
        return 3
    fi
    CAL_REASON='candidate-valid'
    return 0
}

apply_calibrated_candidate() {
    local codec=$1 encoder=$2 quality=$3 label=$4
    local CAL_FILTER_CHAIN=''
    apply_encoder "$encoder"
    calibration_apply_quality "$encoder" "$quality" || return 1
    calibration_build_filter_chain "$encoder"
    filter_chain=$CAL_FILTER_CHAIN
    case "$encoder" in
        av1_vaapi) video_crf="CQP q_idx ${quality} (calibrated)" ;;
        hevc_vaapi) video_crf="CQP QP ${quality} (calibrated)" ;;
        av1_nvenc|hevc_nvenc) video_crf="CQ ${quality} (calibrated)" ;;
        av1_qsv|hevc_qsv) video_crf="ICQ ${quality} (calibrated)" ;;
    esac
    printf 'Selected %s via %s at %s %s.\n' "${codec^^}" "$encoder" "$label" "$quality"
}

calibrate_and_choose_video_codec() {
    [[ "$quality_check" != off ]] || {
        if [[ $HARDCORE_AUTO_CODEC_MODE == 1 ]]; then
            printf 'Automatic AV1/HEVC comparison requires VMAF; original preserved unchanged.\n'
            return 3
        fi
        return 0
    }
    [[ "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
        printf 'Video quality calibration could not determine duration. Original preserved unchanged.\n'
        return 3
    }

    local av1_encoder='' hevc_encoder='' av1_rc=9 hevc_rc=9
    local av1_quality='' hevc_quality='' av1_saving='' hevc_saving=''
    local av1_reason='unavailable' hevc_reason='unavailable'
    local av1_label='' hevc_label=''

    if [[ $HARDCORE_AUTO_CODEC_MODE == 1 ]]; then
        av1_encoder=$HARDCORE_AUTO_AV1_ENCODER
        hevc_encoder=$HARDCORE_AUTO_HEVC_ENCODER
    else
        case "$expected_codec" in
            av1) av1_encoder=$video_encoder ;;
            hevc) hevc_encoder=$video_encoder ;;
        esac
    fi

    if [[ -n $av1_encoder ]]; then
        if calibrate_hardware_candidate av1 "$av1_encoder"; then av1_rc=0; else av1_rc=$?; fi
        av1_quality=$CAL_BEST_QUALITY; av1_saving=$CAL_PREDICTED_SAVINGS; av1_reason=$CAL_REASON; av1_label=$CAL_QUALITY_LABEL
    fi
    if [[ -n $hevc_encoder ]]; then
        if calibrate_hardware_candidate hevc "$hevc_encoder"; then hevc_rc=0; else hevc_rc=$?; fi
        hevc_quality=$CAL_BEST_QUALITY; hevc_saving=$CAL_PREDICTED_SAVINGS; hevc_reason=$CAL_REASON; hevc_label=$CAL_QUALITY_LABEL
    fi

    if [[ $HARDCORE_AUTO_CODEC_MODE != 1 ]]; then
        local rc quality saving reason label codec encoder
        if [[ -n $av1_encoder ]]; then rc=$av1_rc; quality=$av1_quality; saving=$av1_saving; reason=$av1_reason; label=$av1_label; codec=av1; encoder=$av1_encoder
        else rc=$hevc_rc; quality=$hevc_quality; saving=$hevc_saving; reason=$hevc_reason; label=$hevc_label; codec=hevc; encoder=$hevc_encoder; fi
        if (( rc == 4 )); then
            printf '%s encoder %s has no calibrated search policy; using its existing validated settings.\n' "${codec^^}" "$encoder"
            return 0
        fi
        if (( rc != 0 )); then
            printf '%s calibration rejected this file (%s). Original preserved unchanged.\n' "${codec^^}" "$reason"
            return 3
        fi
        apply_calibrated_candidate "$codec" "$encoder" "$quality" "$label"
        return $?
    fi

    printf '\nAutomatic codec competition\n'
    printf '%s\n' '════════════════════════════════════════════════════════════'
    printf 'AV1:  encoder=%s | result=%s | quality=%s %s | predicted saving=%s%%\n' \
        "${av1_encoder:-unavailable}" "$av1_reason" "${av1_label:-n/a}" "${av1_quality:-n/a}" "${av1_saving:-n/a}"
    printf 'HEVC: encoder=%s | result=%s | quality=%s %s | predicted saving=%s%%\n' \
        "${hevc_encoder:-unavailable}" "$hevc_reason" "${hevc_label:-n/a}" "${hevc_quality:-n/a}" "${hevc_saving:-n/a}"

    if (( av1_rc == 4 )) && [[ -n $av1_encoder && -z $hevc_encoder ]]; then
        printf 'Only AV1 is available and its encoder family has no calibrated competition policy; keeping existing AV1 settings.\n'
        return 0
    fi
    if (( hevc_rc == 4 )) && [[ -n $hevc_encoder && -z $av1_encoder ]]; then
        printf 'Only HEVC is available and its encoder family has no calibrated competition policy; keeping existing HEVC settings.\n'
        return 0
    fi

    if (( av1_rc == 0 && hevc_rc == 0 )); then
        if LC_NUMERIC=C awk -v a="$av1_saving" -v h="$hevc_saving" 'BEGIN {exit !(a>=h)}'; then
            printf 'Winner: AV1, because its quality-valid candidate is predicted smaller.\n'
            apply_calibrated_candidate av1 "$av1_encoder" "$av1_quality" "$av1_label"
        else
            printf 'Winner: HEVC, because its quality-valid candidate is predicted smaller.\n'
            apply_calibrated_candidate hevc "$hevc_encoder" "$hevc_quality" "$hevc_label"
        fi
        return $?
    elif (( av1_rc == 0 )); then
        printf 'Winner: AV1; HEVC did not produce an accepted quality/size candidate.\n'
        apply_calibrated_candidate av1 "$av1_encoder" "$av1_quality" "$av1_label"
        return $?
    elif (( hevc_rc == 0 )); then
        printf 'Winner: HEVC; AV1 did not produce an accepted quality/size candidate.\n'
        apply_calibrated_candidate hevc "$hevc_encoder" "$hevc_quality" "$hevc_label"
        return $?
    fi

    printf 'Neither AV1 nor HEVC produced a candidate meeting both VMAF and minimum-savings requirements. Original preserved unchanged.\n'
    return 3
}

'''
    text = repl(
        text,
        "\nrun_video_preflight() {",
        "\n" + calibration + "run_video_preflight() {",
        "codec competition functions insertion",
    )

    old_guard = r'''    if LC_NUMERIC=C awk -v predicted="$predicted_savings" -v required="$required_savings" \
        -v margin="$safety_margin" -v variation="$variation" \
        'BEGIN {exit !((predicted+margin)<required && variation<=35)}'; then
        printf 'Preflight predicts insufficient savings. Original preserved unchanged.\n'
        exit 3
    fi'''
    new_guard = r'''    if LC_NUMERIC=C awk -v predicted="$predicted_savings" 'BEGIN {exit !(predicted<=-20)}'; then
        printf 'Preflight predicts severe expansion (%s%% saving). Original preserved unchanged.\n' "$predicted_savings"
        exit 3
    fi

    if LC_NUMERIC=C awk -v predicted="$predicted_savings" -v required="$required_savings" \
        -v margin="$safety_margin" -v variation="$variation" \
        'BEGIN {exit !((predicted+margin)<required && variation<=35)}'; then
        printf 'Preflight predicts insufficient savings. Original preserved unchanged.\n'
        exit 3
    fi'''
    text = repl(text, old_guard, new_guard, "authoritative negative preflight")

    text = repl(
        text,
        """run_video_preflight

printf '\\nRecommended encoding plan\\n'""",
        '''calibrate_and_choose_video_codec
calibration_rc=$?
if (( calibration_rc == 3 )); then
    exit 3
elif (( calibration_rc != 0 )); then
    die "Video codec calibration/selection failed with exit code $calibration_rc."
fi

run_video_preflight

printf '\\nRecommended encoding plan\\n' ''',
        "codec competition invocation",
    )

    dst.write_text(text, encoding="utf-8")
    os.chmod(dst, 0o700)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
