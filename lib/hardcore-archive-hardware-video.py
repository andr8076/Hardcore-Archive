#!/usr/bin/env python3
"""Enforce hardware-only video encoding and persistent diagnostics in runtime core."""
from __future__ import annotations
import os
import pathlib
import sys

MARKER = "# HARDCORE_HARDWARE_ONLY_VIDEO_V1"


def fail(label: str, count: int) -> None:
    print(f"Error: hardware-video engine patch failed: {label}: expected one anchor, found {count}", file=sys.stderr)
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

    text = repl(text, "\nprobe_parent_video_encoder() {", r'''

# HARDCORE_HARDWARE_ONLY_VIDEO_V1
video_encoder_is_hardware() {
    case "$1" in
        av1_vaapi|av1_nvenc|av1_qsv|hevc_videotoolbox|hevc_vaapi|hevc_nvenc|hevc_qsv)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

probe_parent_video_encoder() {''', "hardware encoder predicate")

    # No dependency path may consider a software encoder sufficient.
    text = repl(text,
        "for candidate in av1_vaapi av1_nvenc av1_qsv libsvtav1; do",
        "for candidate in av1_vaapi av1_nvenc av1_qsv; do",
        "AV1 dependency candidates")
    text = repl(text,
        "for candidate in hevc_videotoolbox hevc_vaapi hevc_nvenc hevc_qsv libx265; do",
        "for candidate in hevc_videotoolbox hevc_vaapi hevc_nvenc hevc_qsv; do",
        "HEVC dependency candidates")

    # FFmpeg 9 VAAPI quality control in the parent hardware probe too.
    text = repl(text,
        '''            *_vaapi) command+=( -vf 'format=nv12,hwupload' -c:v "$candidate" -qp 33 ) ;;''',
        '''            *_vaapi) command+=( -vf 'format=nv12,hwupload' -c:v "$candidate" -rc_mode CQP -global_quality:v 33 ) ;;''',
        "parent VAAPI probe quality")

    # Reject software/non-hardware encoders before the legacy helper's existing
    # forced-encoder branch can accept them. Keeping the remainder of that old
    # branch intact makes this anchor independent of its multiline printf style.
    text = repl(text,
        '''        apply_encoder "$force_encoder"''',
        '''        case "$force_encoder" in
            av1_vaapi|av1_nvenc|av1_qsv|hevc_videotoolbox|hevc_vaapi|hevc_nvenc|hevc_qsv) ;;
            *) die "Software/non-hardware video encoder '$force_encoder' is forbidden. Hardware encoding is mandatory." ;;
        esac
        apply_encoder "$force_encoder"''',
        "forced hardware encoder guard")

    # Even the helper's autonomous path may never fall through to CPU encoders.
    text = repl(text,
        """                elif test_real_encode libsvtav1 av1 -crf:v "$AV1_CRF" -preset:v "$AV1_PRESET"; then apply_encoder libsvtav1
                else die 'No compatible AV1 encoder successfully processed the sample file.'""",
        """                else die 'No compatible hardware AV1 encoder successfully processed the sample file.'""",
        "AV1 software fallback")
    text = repl(text,
        """                elif test_real_encode libx265 hevc -crf:v "$HEVC_CRF" -preset:v "$HEVC_PRESET"; then apply_encoder libx265
                else die 'No compatible HEVC encoder successfully processed the sample file.'""",
        """                else die 'No compatible hardware HEVC encoder successfully processed the sample file.'""",
        "HEVC software fallback")

    # Legacy video modes used to choose CPU encoders. Keep the mode's quality
    # policy, but make encoder selection hardware-only.
    text = repl(text,
        '''        maximum)
            if [[ -z $VIDEO_ENCODER ]]; then
                if [[ $VIDEO_CODEC == av1 ]] && ffmpeg -hide_banner -encoders 2>/dev/null | grep -w libsvtav1 >/dev/null; then
                    VIDEO_ENCODER=libsvtav1
                elif [[ $VIDEO_CODEC == hevc ]] && ffmpeg -hide_banner -encoders 2>/dev/null | grep -w libx265 >/dev/null; then
                    VIDEO_ENCODER=libx265
                fi
            fi
            $VIDEO_PARALLEL_EXPLICIT || VIDEO_PARALLEL=false
            [[ $QUALITY_CHECK == auto ]] && QUALITY_CHECK=required
            ;;''',
        '''        maximum)
            if [[ -z $VIDEO_ENCODER ]]; then
                probe_parent_video_encoder || die "Hardware video encoding is mandatory, but no compatible hardware encoder passed the real-file probe."
            fi
            $VIDEO_PARALLEL_EXPLICIT || VIDEO_PARALLEL=true
            [[ $QUALITY_CHECK == auto ]] && QUALITY_CHECK=required
            ;;''',
        "maximum mode hardware selection")
    text = repl(text,
        '''                else
                    [[ $VIDEO_CODEC == av1 ]] && VIDEO_ENCODER=libsvtav1 || VIDEO_ENCODER=libx265
                    $VIDEO_PARALLEL_EXPLICIT || VIDEO_PARALLEL=false
                fi''',
        '''                else
                    die "Hardware video encoding is mandatory, but the hardware probe failed."
                fi''',
        "balanced mode CPU fallback")
    text = repl(text,
        '''            if [[ -z $VIDEO_ENCODER ]]; then
                [[ $VIDEO_CODEC == av1 ]] && VIDEO_ENCODER=libsvtav1 || VIDEO_ENCODER=libx265
            fi''',
        '''            if [[ -z $VIDEO_ENCODER ]]; then
                die "Hardware video encoding is mandatory, but the hardware probe failed."
            fi''',
        "fast mode CPU fallback")

    # Any core path (including recursive nested jobs) must have a real hardware
    # encoder locked before staging/transcoding starts.
    text = repl(text,
        '''    esac
fi

# Pick a persistent local working area.''',
        '''    esac
    [[ -n $VIDEO_ENCODER ]] || die "Hardware video encoding is mandatory, but no hardware encoder could be selected."
    video_encoder_is_hardware "$VIDEO_ENCODER" || die "Software/non-hardware video encoder '$VIDEO_ENCODER' is forbidden. Hardware encoding is mandatory."
    $VIDEO_PARALLEL_EXPLICIT || VIDEO_PARALLEL=true
    printf 'Hardware video encoder locked: %s\\n' "$VIDEO_ENCODER"
fi

# Pick a persistent local working area.''',
        "core hardware lock")

    # Recursive nested jobs previously dropped the resolved hardware encoder and
    # could therefore enter legacy CPU fallback logic.
    text = repl(text,
        '''    inherited+=(--video-codec "$VIDEO_CODEC" --video-mode "$VIDEO_MODE" --quality-check "$QUALITY_CHECK")''',
        '''    inherited+=(--video-codec "$VIDEO_CODEC" --video-mode "$VIDEO_MODE" --quality-check "$QUALITY_CHECK")
    [[ -n $VIDEO_ENCODER ]] && inherited+=(--video-encoder "$VIDEO_ENCODER")''',
        "nested hardware encoder inheritance")

    # Put the exact command in VIDEO_LOG before a full transcode begins.
    text = repl(text,
        '''command+=("${audio_args[@]}" "$temporary")''',
        '''command+=("${audio_args[@]}" "$temporary")
printf 'FFmpeg command:'
printf ' %q' "${command[@]}"
printf '\\n' ''',
        "FFmpeg command trace")

    # On interruption/failure, preserve raw component logs and state beside the
    # permanent run transcript established by the runtime runner.
    diagnostic = r'''
    if (( exit_status != 0 )) && [[ -n ${HARDCORE_ARCHIVE_DIAGNOSTIC_DIR:-} ]]; then
        mkdir -p -- "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR" 2>/dev/null || true
        [[ -s ${VIDEO_LOG:-} ]] && cp -- "$VIDEO_LOG" "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/video.log" 2>/dev/null || true
        [[ -s ${IMAGE_LOG:-} ]] && cp -- "$IMAGE_LOG" "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/image.log" 2>/dev/null || true
        [[ -s ${SEVEN_ZIP_LOG:-} ]] && cp -- "$SEVEN_ZIP_LOG" "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/7zip.log" 2>/dev/null || true
        [[ -s ${MC_TUNING_LOG:-} ]] && cp -- "$MC_TUNING_LOG" "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/match-cycle.log" 2>/dev/null || true
        {
            printf 'exit_status=%s\n' "$exit_status"
            printf 'failure_context=%s\n' "${FAILURE_CONTEXT:-unknown}"
            printf 'video_transcode=%s\n' "${VIDEO_TRANSCODE:-unknown}"
            printf 'video_codec=%s\n' "${VIDEO_CODEC:-unknown}"
            printf 'video_encoder=%s\n' "${VIDEO_ENCODER:-unset}"
            printf 'video_pipeline_pid=%s\n' "${VIDEO_PIPELINE_PID:-none}"
            printf 'video_completed=%s\n' "${VIDEO_COMPRESSED_COUNT:-0}"
            printf 'video_preserved=%s\n' "${VIDEO_FALLBACK_COUNT:-0}"
            printf 'nested_repacked=%s\n' "${NESTED_REPACKED_COUNT:-0}"
            printf 'nested_preserved=%s\n' "${NESTED_FALLBACK_COUNT:-0}"
        } > "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/state.txt" 2>/dev/null || true
    fi
'''
    text = repl(text,
        '''    rm -f -- "$VIDEO_LIST" "$IMAGE_LIST" "$NESTED_LIST" "$COPY_LIST" "$SNAPSHOT_BEFORE"''',
        diagnostic + '''
    rm -f -- "$VIDEO_LIST" "$IMAGE_LIST" "$NESTED_LIST" "$COPY_LIST" "$SNAPSHOT_BEFORE"''',
        "persistent failure diagnostics")

    dst.write_text(text, encoding="utf-8")
    os.chmod(dst, 0o700)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
