#!/usr/bin/env python3
"""Add calibrated AV1 VA-API q_idx selection and hard preflight rejection."""
from __future__ import annotations

import os
import pathlib
import sys

MARKER = "# HARDCORE_AV1_VAAPI_CALIBRATION_V1"


def fail(label: str, count: int) -> None:
    print(
        f"Error: AV1 VAAPI calibration patch failed: {label}: expected one anchor, found {count}",
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
        '''            # HARDCORE_AV1_VAAPI_CALIBRATION_V1
            video_crf="CQP q_idx 128 (pre-calibration)"; video_preset='N/A'; video_pix_fmt='vaapi'
            encoder_args=("-rc_mode" "CQP" "-global_quality:v" "128")''',
        "AV1 VAAPI pre-calibration q_idx",
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
AV1_CAL_MIN_VMAF=''
AV1_CAL_AVG_VIDEO_BPS=''

evaluate_vaapi_av1_qidx() {
    local qidx=$1
    local sample_length=4
    local -a positions=(0.10 0.50 0.90)
    local position start sample_file actual_length sample_size sample_bps
    local total_bps=0 sample_count=0 minimum_vmaf=101
    local -a command=()

    if LC_NUMERIC=C awk -v d="$duration" 'BEGIN {exit !(d<12)}'; then
        positions=(0.50)
        sample_length=$(LC_NUMERIC=C awk -v d="$duration" 'BEGIN {
            v=d; if(v>4)v=4; if(v<1)v=1; printf "%.3f",v
        }')
    fi

    for position in "${positions[@]}"; do
        start=$(LC_NUMERIC=C awk -v d="$duration" -v l="$sample_length" -v p="$position" 'BEGIN {
            room=d-l; if(room<0)room=0; s=room*p; if(s<0)s=0; printf "%.3f",s
        }')
        sample_file="${output_dir}/.${output_name}.calibrate-q${qidx}.$$.${sample_count}.mkv"
        preflight_files+=("$sample_file" "${sample_file}.vmaf.json")
        rm -f -- "$sample_file" "${sample_file}.vmaf.json"

        command=(
            ffmpeg -hide_banner -v error -nostdin -y
            -init_hw_device "vaapi=va:" -filter_hw_device va
            -ss "$start" -i "$input" -t "$sample_length"
            -map '0:V:0' -an -sn -dn
            -c:v av1_vaapi -rc_mode CQP -global_quality:v "$qidx"
        )
        [[ -n "$filter_chain" ]] && command+=(-vf "$filter_chain")
        command+=(-f matroska "$sample_file")

        if ! "${command[@]}"; then
            printf 'q_idx %s: sample encode failed.\n' "$qidx"
            rm -f -- "$sample_file" "${sample_file}.vmaf.json"
            return 1
        fi

        actual_length=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$sample_file" 2>/dev/null | head -n1)
        sample_size=$(stat -c '%s' -- "$sample_file" 2>/dev/null || printf 0)
        if [[ ! $actual_length =~ ^[0-9]+([.][0-9]+)?$ ]] || (( sample_size <= 0 )); then
            printf 'q_idx %s: invalid calibration sample.\n' "$qidx"
            rm -f -- "$sample_file" "${sample_file}.vmaf.json"
            return 1
        fi
        sample_bps=$(LC_NUMERIC=C awk -v bytes="$sample_size" -v seconds="$actual_length" \
            'BEGIN {if(seconds<=0)print 0; else printf "%.0f",bytes*8/seconds}')
        total_bps=$((total_bps + sample_bps))
        sample_count=$((sample_count + 1))

        if ! measure_preflight_quality "$start" "$actual_length" "$sample_file" || \
           [[ $MEASURED_QUALITY_KIND != VMAF ]]; then
            printf 'q_idx %s: VMAF measurement failed.\n' "$qidx"
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
    AV1_CAL_MIN_VMAF=$minimum_vmaf
    AV1_CAL_AVG_VIDEO_BPS=$((total_bps / sample_count))
    return 0
}

calibrate_vaapi_av1_qidx() {
    [[ "$video_encoder" == av1_vaapi ]] || return 0
    [[ "$quality_check" != off ]] || {
        printf 'AV1 VAAPI calibration requires VMAF; quality checking is disabled. Original preserved unchanged.\n'
        return 3
    }
    [[ "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
        printf 'AV1 VAAPI calibration could not determine duration. Original preserved unchanged.\n'
        return 3
    }

    local required_savings="$min_savings_percent"
    if [[ "$source_video_codec" == "$expected_codec" && "$apply_scaling" != true && "$apply_denoise" != true ]]; then
        required_savings=$(LC_NUMERIC=C awk -v minimum="$min_savings_percent" 'BEGIN {
            candidate=minimum+5; if(candidate<10) candidate=10; printf "%.3f",candidate
        }')
    fi

    local source_average_bps
    source_average_bps=$(LC_NUMERIC=C awk -v bytes="$original_size" -v seconds="$duration" \
        'BEGIN {if(seconds<=0)print 0; else printf "%.0f",bytes*8/seconds}')
    if [[ ! $source_average_bps =~ ^[0-9]+$ ]] || (( source_average_bps <= 0 )); then
        printf 'AV1 VAAPI calibration could not determine source bitrate. Original preserved unchanged.\n'
        return 3
    fi

    # FFmpeg's AV1 VAAPI global_quality is AV1 q_idx: higher means more
    # compression/lower quality. Binary-search the complete usable range and
    # retain the highest q_idx whose worst representative VMAF still passes.
    local low=1 high=255 mid best_qidx=0 best_video_bps=0
    local predicted_output_bps predicted_savings

    printf '\nAV1 VAAPI q_idx calibration\n'
    printf '%s\n' '────────────────────────────────────────────────────────────'
    printf 'Searching q_idx 1..255 for worst-sample VMAF >= %s.\n' "$quality_vmaf_threshold"

    while (( low <= high )); do
        mid=$(((low + high) / 2))
        if ! evaluate_vaapi_av1_qidx "$mid"; then
            printf 'AV1 VAAPI calibration probe failed at q_idx %s. Original preserved unchanged.\n' "$mid"
            return 3
        fi

        printf 'q_idx %s: worst VMAF %s.\n' "$mid" "$AV1_CAL_MIN_VMAF"
        if LC_NUMERIC=C awk -v v="$AV1_CAL_MIN_VMAF" -v threshold="$quality_vmaf_threshold" \
            'BEGIN {exit !(v>=threshold)}'; then
            best_qidx=$mid
            best_video_bps=$AV1_CAL_AVG_VIDEO_BPS
            low=$((mid + 1))
        else
            high=$((mid - 1))
        fi
    done

    if (( best_qidx <= 0 )); then
        printf 'No AV1 VAAPI q_idx met the VMAF %s target. Original preserved unchanged.\n' "$quality_vmaf_threshold"
        return 3
    fi

    predicted_output_bps=$(LC_NUMERIC=C awk -v video="$best_video_bps" -v audio="$estimated_output_audio_bps" \
        'BEGIN {printf "%.0f",(video+audio)*1.015}')
    predicted_savings=$(LC_NUMERIC=C awk -v source="$source_average_bps" -v output="$predicted_output_bps" 'BEGIN {
        if(source<=0){print 0; exit} printf "%.2f",(source-output)*100/source
    }')

    printf 'Highest quality-valid q_idx: %s; predicted saving: %s%%.\n' "$best_qidx" "$predicted_savings"
    if ! LC_NUMERIC=C awk -v saving="$predicted_savings" -v required="$required_savings" \
        'BEGIN {exit !(saving>=required)}'; then
        printf 'Best quality-valid AV1 VAAPI setting cannot meet the %s%% size target. Original preserved unchanged.\n' "$required_savings"
        return 3
    fi

    encoder_args=("-rc_mode" "CQP" "-global_quality:v" "$best_qidx")
    video_crf="CQP q_idx ${best_qidx} (calibrated)"
    printf 'Selected AV1 VAAPI q_idx %s.\n' "$best_qidx"
    return 0
}

'''
    text = repl(
        text,
        "\nrun_video_preflight() {",
        "\n" + calibration + "run_video_preflight() {",
        "calibration functions insertion",
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
        "run_video_preflight\n\nprintf '\\\nRecommended encoding plan\\\n'",
        '''calibrate_vaapi_av1_qidx
calibration_rc=$?
if (( calibration_rc == 3 )); then
    exit 3
elif (( calibration_rc != 0 )); then
    die "AV1 VAAPI calibration failed with exit code $calibration_rc."
fi

run_video_preflight

printf '\\
Recommended encoding plan\\
' ''',
        "calibration invocation",
    )

    dst.write_text(text, encoding="utf-8")
    os.chmod(dst, 0o700)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
