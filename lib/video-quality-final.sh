#!/usr/bin/env bash

# Completed-output quality validation for the embedded video helper. This module
# is sourced by that helper and intentionally relies on its existing
# source-display geometry/model/filter functions so calibration and final
# acceptance cannot drift into different VMAF comparison policies.

hardcore_video_stream_relative_seek() {
    local path=$1 relative=$2 probe=${3:-ffprobe} origin
    origin=$("$probe" -v error -select_streams V:0 -show_entries stream=start_time \
        -of default=nw=1:nk=1 "$path" 2>/dev/null | head -n1 || true)
    [[ $origin =~ ^-?[0-9]+([.][0-9]+)?$ ]] || origin=0
    LC_NUMERIC=C awk -v relative="$relative" -v origin="$origin" \
        'BEGIN { printf "%.6f", relative + origin }'
}

hardcore_video_stream_relative_duration() {
    local path=$1 probe=${2:-ffprobe} origin endpoint value
    origin=$("$probe" -v error -select_streams V:0 -show_entries stream=start_time \
        -of default=nw=1:nk=1 "$path" 2>/dev/null | head -n1 || true)
    [[ $origin =~ ^-?[0-9]+([.][0-9]+)?$ ]] || origin=0
    endpoint=$("$probe" -v error -select_streams V:0 -show_packets \
        -show_entries packet=pts_time,duration_time -of csv=p=0 "$path" 2>/dev/null | \
        LC_NUMERIC=C awk -F, '
            $1 ~ /^-?[0-9]+([.][0-9]+)?$/ {
                pts=$1+0; d=0
                if ($2 ~ /^[0-9]+([.][0-9]+)?$/) d=$2+0
                e=pts+d
                if (!seen || e>max) { max=e; seen=1 }
            }
            END { if (seen) printf "%.9f", max }
        ')
    if [[ $endpoint =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
        value=$(LC_NUMERIC=C awk -v endpoint="$endpoint" -v origin="$origin" \
            'BEGIN { d=endpoint-origin; if (d>0) printf "%.6f", d }')
        [[ $value =~ ^[0-9]+([.][0-9]+)?$ ]] && { printf '%s' "$value"; return 0; }
    fi
    return 1
}

hardcore_video_measure_completed_segment() {
    local candidate=$1 kind=$2 start=$3 length=$4 index=$5 manifest=$6
    local geometry eval_width eval_height model_info model model_condition log_file filter_graph
    local decode_ffmpeg='' normalized_reference='' normalized_candidate='' seek_ffprobe=ffprobe
    local reference_seek candidate_seek
    geometry=$(quality_source_display_geometry) || return 1
    IFS=$'\t' read -r eval_width eval_height <<< "$geometry"
    model_info=$(quality_vmaf_model_for_canvas "$eval_width" "$eval_height") || return 1
    IFS=$'\t' read -r model model_condition <<< "$model_info"

    if [[ -z ${QUALITY_WORKER_THREADS:-} ]]; then
        QUALITY_WORKER_THREADS=$(quality_worker_threads) || return 1
    fi
    if [[ -z ${QUALITY_VMAF_AVAILABLE:-} ]]; then
        if has_filter libvmaf; then QUALITY_VMAF_AVAILABLE=true; else QUALITY_VMAF_AVAILABLE=false; fi
    fi
    [[ $QUALITY_VMAF_AVAILABLE == true ]] || return 1

    log_file="${candidate}.final-vmaf.$$.${index}.json"
    preflight_files+=("$log_file")
    rm -f -- "$log_file"
    filter_graph=$(quality_vmaf_filter_graph "$eval_width" "$eval_height" "$log_file" \
        "$QUALITY_WORKER_THREADS" "$model") || return 1

    if [[ ${use_av1encode_dependency:-false} == true &&
          -x ${HARDCORE_ARCHIVE_SYSTEM_FFPROBE:-} ]]; then
        seek_ffprobe=$HARDCORE_ARCHIVE_SYSTEM_FFPROBE
    fi
    # Sample plans are expressed relative to the video stream origin. Seek FFmpeg
    # in the file timestamp domain so VMAF measures the same frame population
    # that the independent evidence probe later validates.
    reference_seek=$(hardcore_video_stream_relative_seek "$input" "$start" "$seek_ffprobe") || return 1
    candidate_seek=$(hardcore_video_stream_relative_seek "$candidate" "$start" "$seek_ffprobe") || return 1

    # The archive's managed VMAF build may deliberately omit AV1 software
    # decoding. AV1Encode has already proved the saved host FFmpeg can decode
    # its output completely, so normalize both bounded windows losslessly and
    # reserve the managed runtime for scoring.
    if [[ ${use_av1encode_dependency:-false} == true &&
          -x ${HARDCORE_ARCHIVE_SYSTEM_FFMPEG:-} ]]; then
        decode_ffmpeg=$HARDCORE_ARCHIVE_SYSTEM_FFMPEG
        normalized_reference="${candidate}.final-reference.$$.${index}.mkv"
        normalized_candidate="${candidate}.final-candidate.$$.${index}.mkv"
        preflight_files+=("$normalized_reference" "$normalized_candidate")
        if ! "$decode_ffmpeg" -hide_banner -v error -nostdin -y \
            -ss "$reference_seek" -t "$length" -i "$input" -map '0:V:0' -an -sn -dn \
            -c:v ffv1 "$normalized_reference" ||
           ! "$decode_ffmpeg" -hide_banner -v error -nostdin -y \
            -ss "$candidate_seek" -t "$length" -i "$candidate" -map '0:V:0' -an -sn -dn \
            -c:v ffv1 "$normalized_candidate"; then
            return 1
        fi
        if ! ffmpeg -hide_banner -v error -nostdin \
            -i "$normalized_reference" -i "$normalized_candidate" \
            -filter_complex "$filter_graph" -an -f null - >/dev/null 2>&1; then
            return 1
        fi
    # Unlike calibration samples, the completed candidate retains the original
    # timeline. Seek BOTH inputs to the same deterministic window, then let the
    # existing AVTB/PTS-reset/nearest-framesync graph align the decoded frames.
    elif ! ffmpeg -hide_banner -v error -nostdin \
        -ss "$reference_seek" -t "$length" -i "$input" \
        -ss "$candidate_seek" -t "$length" -i "$candidate" \
        -filter_complex "$filter_graph" -an -f null - >/dev/null 2>&1; then
        return 1
    fi
    [[ -s $log_file ]] || return 1
    printf '%s\t%s\t%s\t%s\n' "$kind" "$start" "$length" "$log_file" >> "$manifest"
}

hardcore_video_validate_completed_quality() {
    local candidate=$1 plan manifest result started elapsed rc=0 index=0
    local kind start length requested_seconds requested_percent coverage_seconds coverage_percent
    local mean minimum_window low_value low_percentile longest reasons status windows frames evidence_complete
    local evidence_ffprobe=ffprobe timeline_duration

    VIDEO_FINAL_QUALITY_RESULT=''
    VIDEO_FINAL_QUALITY_REASON=''
    VIDEO_FINAL_QUALITY_RETRYABLE=false
    if [[ ${quality_check:-off} == off ]]; then
        printf 'Completed-output VMAF validation: explicitly disabled by quality policy.\n'
        return 0
    fi
    [[ -n ${HARDCORE_ARCHIVE_VIDEO_QUALITY_HELPER:-} && -f ${HARDCORE_ARCHIVE_VIDEO_QUALITY_HELPER:-} ]] || {
        VIDEO_FINAL_QUALITY_REASON='quality-helper-missing'
        printf 'Completed-output VMAF validation unavailable: policy helper missing.\n'
        return 1
    }

    if [[ ${use_av1encode_dependency:-false} == true &&
          -x ${HARDCORE_ARCHIVE_SYSTEM_FFPROBE:-} ]]; then
        evidence_ffprobe=$HARDCORE_ARCHIVE_SYSTEM_FFPROBE
    fi
    timeline_duration=$(hardcore_video_stream_relative_duration "$input" "$evidence_ffprobe") || {
        VIDEO_FINAL_QUALITY_REASON='video-timeline-duration-unavailable'
        printf 'Completed-output quality could not determine the primary video timeline duration. Original will be preserved.\n'
        return 1
    }

    plan=$(mktemp "${TMPDIR:-/tmp}/hardcore-video-quality-plan.XXXXXX") || return 1
    manifest=$(mktemp "${TMPDIR:-/tmp}/hardcore-video-quality-measurements.XXXXXX") || { rm -f -- "$plan"; return 1; }
    preflight_files+=("$plan" "$manifest")
    : > "$manifest"

    if ! python3 "$HARDCORE_ARCHIVE_VIDEO_QUALITY_HELPER" plan \
        --input "$candidate" --duration "$timeline_duration" --mode "$video_quality_validation" \
        --sample-seconds "$video_quality_sample_seconds" \
        --interval-seconds "$video_quality_interval_seconds" \
        --min-samples "$video_quality_min_samples" \
        --max-samples "$video_quality_max_samples" \
        --complexity-samples "$video_quality_complexity_samples" > "$plan"; then
        VIDEO_FINAL_QUALITY_REASON='sample-plan-failed'
        printf 'Completed-output quality sample planning failed. Original will be preserved.\n'
        return 1
    fi
    [[ -s $plan ]] || {
        VIDEO_FINAL_QUALITY_REASON='sample-plan-empty'
        printf 'Completed-output quality sample plan was empty. Original will be preserved.\n'
        return 1
    }

    printf '\nCompleted-output VMAF acceptance (%s mode)\n' "$video_quality_validation"
    printf '%s\n' '────────────────────────────────────────────────────────────'
    started=$SECONDS
    while IFS=$'\t' read -r kind start length; do
        [[ -n $kind && $start =~ ^[0-9]+([.][0-9]+)?$ && $length =~ ^[0-9]+([.][0-9]+)?$ ]] || {
            VIDEO_FINAL_QUALITY_REASON='malformed-sample-plan'
            return 1
        }
        index=$((index + 1))
        printf 'Acceptance sample %s: %s at %ss for %ss... ' "$index" "$kind" "$start" "$length"
        if hardcore_video_measure_completed_segment "$candidate" "$kind" "$start" "$length" "$index" "$manifest"; then
            printf 'measured.\n'
        else
            printf 'FAILED.\n'
            VIDEO_FINAL_QUALITY_REASON="measurement-failed-at-${start}"
            printf 'A missing/failed VMAF measurement cannot authorize this transcode.\n'
            return 1
        fi
    done < "$plan"

    if result=$(python3 "$HARDCORE_ARCHIVE_VIDEO_QUALITY_HELPER" evaluate \
        --manifest "$manifest" --duration "$timeline_duration" --threshold "$quality_vmaf_threshold" \
        --reference "$input" --candidate "$candidate" --ffprobe "$evidence_ffprobe" \
        --low-percentile "$video_quality_low_percentile" \
        --percentile-delta "$video_quality_percentile_delta" \
        --sustained-delta "$video_quality_sustained_delta" \
        --sustained-seconds "$video_quality_sustained_seconds"); then
        rc=0
    else
        rc=$?
    fi
    elapsed=$((SECONDS - started))
    VIDEO_FINAL_QUALITY_RESULT=$result

    if [[ -z $result ]]; then
        VIDEO_FINAL_QUALITY_REASON='empty-quality-result'
        printf 'Completed-output quality evaluation returned no result after %ss.\n' "$elapsed"
        return 1
    fi

    IFS=$'\t' read -r status windows frames requested_seconds requested_percent coverage_seconds coverage_percent evidence_complete mean minimum_window low_percentile low_value longest reasons < <(
        python3 - "$result" <<'PYFINALQUALITY'
import json,sys
try:
    d=json.loads(sys.argv[1])
    reasons='; '.join(str(x) for x in d.get('reasons', [])) or d.get('error','')
    print('\t'.join([
        str(d.get('status','error')), str(d.get('windows','?')), str(d.get('frames','?')),
        f"{float(d.get('requested_coverage_seconds',0)):.3f}", f"{float(d.get('requested_coverage_percent',0)):.2f}",
        f"{float(d.get('coverage_seconds',0)):.3f}", f"{float(d.get('coverage_percent',0)):.2f}",
        str(d.get('evidence_complete',False)).lower(),
        f"{float(d.get('mean_vmaf',0)):.3f}", f"{float(d.get('minimum_window_mean',0)):.3f}",
        str(d.get('low_percentile','?')), f"{float(d.get('low_percentile_vmaf',0)):.3f}",
        f"{float(d.get('longest_sustained_seconds',0)):.3f}", reasons,
    ]))
except Exception as exc:
    print('error\t?\t?\t0\t0\t0\t0\tfalse\t0\t0\t?\t0\t0\tmalformed-result:'+str(exc))
PYFINALQUALITY
    )

    printf 'Requested coverage: %ss/%ss (%s%% of timeline).\n' \
        "$requested_seconds" "$timeline_duration" "$requested_percent"
    printf 'Confirmed quality coverage: %ss/%ss (%s%% of timeline), %s VMAF frame score(s); validation time %ss.\n' \
        "$coverage_seconds" "$timeline_duration" "$coverage_percent" "$frames" "$elapsed"
    printf 'Scores: mean %s; worst window mean %s; p%s %s; longest sustained-low run %ss.\n' \
        "$mean" "$minimum_window" "$low_percentile" "$low_value" "$longest"
    if [[ $video_quality_validation == sampled ]]; then
        printf 'Assurance scope: sampled only; only windows with complete timestamp/frame evidence count as confirmed coverage.\n'
    else
        printf 'Assurance scope: full mode; the requested timeline must have complete timestamp/frame evidence before acceptance.\n'
    fi

    if (( rc == 0 )) && [[ $status == pass && $evidence_complete == true ]]; then
        printf 'Completed-output VMAF acceptance passed at the configured target %s.\n' "$quality_vmaf_threshold"
        return 0
    fi

    VIDEO_FINAL_QUALITY_REASON=${reasons:-quality-evaluation-failed}
    [[ $status == reject && $rc -eq 3 ]] && VIDEO_FINAL_QUALITY_RETRYABLE=true
    if [[ $status == error ]]; then
        printf 'Completed-output VMAF evidence INCOMPLETE: %s\n' "$VIDEO_FINAL_QUALITY_REASON"
    else
        printf 'Completed-output VMAF acceptance REJECTED: %s\n' "$VIDEO_FINAL_QUALITY_REASON"
    fi
    return 1
}

hardcore_video_raise_quality() {
    local next='' current='' index
    (( ${video_quality_retry_step:-0} > 0 )) || return 1

    case ${video_encoder:-} in
        av1_vaapi|hevc_vaapi|av1_nvenc|hevc_nvenc|av1_qsv|hevc_qsv|hevc_qsv_legacy)
            current=${CAL_BEST_QUALITY:-}
            [[ $current =~ ^[1-9][0-9]*$ ]] || return 1
            next=$(python3 "$HARDCORE_ARCHIVE_VIDEO_QUALITY_HELPER" retry-quality \
                --encoder "$video_encoder" --quality "$current" --step "$video_quality_retry_step" 2>/dev/null) || return 1
            [[ $next =~ ^[1-9][0-9]*$ && $next != "$current" ]] || return 1
            calibration_apply_quality "$video_encoder" "$next" || return 1
            CAL_BEST_QUALITY=$next
            case "$video_encoder" in
                av1_vaapi) video_crf="CQP q_idx ${next} (final-quality retry)" ;;
                hevc_vaapi) video_crf="CQP QP ${next} (final-quality retry)" ;;
                av1_nvenc|hevc_nvenc) video_crf="CQ ${next} (final-quality retry)" ;;
                av1_qsv|hevc_qsv|hevc_qsv_legacy) video_crf="ICQ ${next} (final-quality retry)" ;;
            esac
            ;;
        hevc_videotoolbox)
            # VideoToolbox uses the opposite direction: larger -q:v is higher
            # quality. Rewrite only the argument paired with -q:v.
            for ((index=0; index<${#encoder_args[@]}-1; index++)); do
                if [[ ${encoder_args[index]} == -q:v && ${encoder_args[index+1]} =~ ^[0-9]+$ ]]; then
                    current=${encoder_args[index+1]}
                    next=$(python3 "$HARDCORE_ARCHIVE_VIDEO_QUALITY_HELPER" retry-quality \
                        --encoder "$video_encoder" --quality "$current" --step "$video_quality_retry_step" 2>/dev/null) || return 1
                    encoder_args[index+1]=$next
                    video_crf="Quality ${next} (final-quality retry)"
                    break
                fi
            done
            [[ -n $next ]] || return 1
            ;;
        *) return 1 ;;
    esac

    printf 'Retrying completed encode at higher quality: %s -> %s (%s). VMAF target remains %s.\n' \
        "$current" "$next" "$video_encoder" "$quality_vmaf_threshold"
    return 0
}

export -f hardcore_video_stream_relative_seek hardcore_video_stream_relative_duration hardcore_video_measure_completed_segment hardcore_video_validate_completed_quality hardcore_video_raise_quality
