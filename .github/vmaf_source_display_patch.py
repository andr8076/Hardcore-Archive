#!/usr/bin/env python3
from pathlib import Path
import subprocess

CORE = Path('lib/hardcore-archive-core.sh')
text = CORE.read_text()
start_marker = "MEASURED_QUALITY_KIND=''\nMEASURED_QUALITY_SCORE=''\nQUALITY_WORKER_THREADS=''\nQUALITY_VMAF_AVAILABLE=''\n"
end_marker = "\n\nHARDCORE_AUTO_CODEC_MODE="
start = text.find(start_marker)
if start < 0:
    raise SystemExit('quality block start marker not found')
end = text.find(end_marker, start)
if end < 0:
    raise SystemExit('quality block end marker not found')

new_block = r'''MEASURED_QUALITY_KIND=''
MEASURED_QUALITY_SCORE=''
QUALITY_WORKER_THREADS=''
QUALITY_VMAF_AVAILABLE=''
QUALITY_VMAF_POLICY_VERSION='source-display-v1'

quality_worker_threads() {
    local requested=${HARDCORE_ARCHIVE_VIDEO_QUALITY_THREADS:-auto} available
    if [[ $requested != auto && ! $requested =~ ^([1-9]|[1-5][0-9]|6[0-4])$ ]]; then
        printf 'Error: VIDEO_QUALITY_THREADS must be auto or an integer from 1 to 64.\n' >&2
        return 1
    fi
    available=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)
    [[ $available =~ ^[1-9][0-9]{0,5}$ ]] || available=1
    if [[ $requested == auto ]]; then
        requested=$available
        (( requested > 8 )) && requested=8
    fi
    (( requested > available )) && requested=$available
    printf '%s' "$requested"
}

quality_round_even() {
    LC_NUMERIC=C awk -v value="$1" 'BEGIN {
        if (value <= 0) exit 1
        rounded=int(value/2+0.5)*2
        if (rounded < 2) rounded=2
        printf "%.0f", rounded
    }'
}

# Return the square-pixel display canvas represented by coded dimensions, SAR,
# and display rotation. FFmpeg autorotates by default, so 90/270-degree display
# rotation also inverts the pixel aspect ratio when deriving the viewed frame.
quality_display_geometry() {
    local coded_width=$1 coded_height=$2 sar=${3:-1:1} rotation=${4:-0}
    local sar_num=1 sar_den=1 display_width display_height
    [[ $coded_width =~ ^[1-9][0-9]*$ && $coded_height =~ ^[1-9][0-9]*$ ]] || return 1
    if [[ $sar =~ ^([1-9][0-9]*):([1-9][0-9]*)$ ]]; then
        sar_num=${BASH_REMATCH[1]}
        sar_den=${BASH_REMATCH[2]}
    fi
    [[ $rotation =~ ^-?[0-9]+$ ]] || rotation=0
    rotation=$(( (rotation % 360 + 360) % 360 ))
    case $rotation in
        90|270)
            display_width=$(LC_NUMERIC=C awk -v h="$coded_height" -v n="$sar_num" -v d="$sar_den" \
                'BEGIN {printf "%.9f", h*d/n}')
            display_height=$coded_width
            ;;
        *)
            display_width=$(LC_NUMERIC=C awk -v w="$coded_width" -v n="$sar_num" -v d="$sar_den" \
                'BEGIN {printf "%.9f", w*n/d}')
            display_height=$coded_height
            ;;
    esac
    display_width=$(quality_round_even "$display_width") || return 1
    display_height=$(quality_round_even "$display_height") || return 1
    printf '%s\t%s' "$display_width" "$display_height"
}

quality_source_display_geometry() {
    local dimensions coded_width coded_height sar rotation
    dimensions=$(ffprobe -v error -select_streams V:0 -show_entries stream=width,height \
        -of csv=p=0:s=x "$input" 2>/dev/null | head -n1) || return 1
    IFS=x read -r coded_width coded_height <<< "$dimensions"
    [[ $coded_width =~ ^[1-9][0-9]*$ && $coded_height =~ ^[1-9][0-9]*$ ]] || return 1
    sar=$(ffprobe -v error -select_streams V:0 -show_entries stream=sample_aspect_ratio \
        -of default=nw=1:nk=1 "$input" 2>/dev/null | head -n1 || true)
    rotation=$(ffprobe -v error -select_streams V:0 -show_entries stream_side_data=rotation \
        -of default=nw=1:nk=1 "$input" 2>/dev/null | head -n1 || true)
    quality_display_geometry "$coded_width" "$coded_height" "$sar" "$rotation"
}

# Keep the existing VMAF v0 score family so the configured floor is not
# silently reinterpreted. Use the official 4K/1.5H legacy model for UHD-or-
# larger source display canvases; otherwise retain the standard 1080p/3H model.
quality_vmaf_model_for_canvas() {
    local width=$1 height=$2 long_side short_side
    [[ $width =~ ^[1-9][0-9]*$ && $height =~ ^[1-9][0-9]*$ ]] || return 1
    if (( width >= height )); then
        long_side=$width; short_side=$height
    else
        long_side=$height; short_side=$width
    fi
    if (( long_side >= 3840 && short_side >= 2160 )); then
        printf 'vmaf_4k_v0.6.1\t4K/1.5H'
    else
        printf 'vmaf_v0.6.1\t1080p/3H'
    fi
}

# Both streams use the same display normalization: convert SAR to square
# pixels, fit without stretching, pad any DAR mismatch, use limited-range
# yuv420p, and compare on the source display canvas. Smaller candidates are
# therefore bicubic-upscaled instead of shrinking the reference to hide lost
# resolution. The identical chain also keeps color/range conversion symmetric.
quality_vmaf_filter_graph() {
    local eval_width=$1 eval_height=$2 log_file=$3 threads=$4 model=$5 ratio normalize fit
    ratio="${eval_width}/${eval_height}"
    normalize="scale=w='max(2,trunc(iw*if(eq(sar,0),1,sar)/2)*2)':h='max(2,trunc(ih/2)*2)':flags=bicubic:in_range=auto:out_range=tv,setsar=1"
    fit="scale=w='if(gt(a,${ratio}),${eval_width},-2)':h='if(gt(a,${ratio}),-2,${eval_height})':flags=bicubic:in_range=tv:out_range=tv,pad=${eval_width}:${eval_height}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,format=yuv420p"
    printf '%s' "[0:v:0]settb=AVTB,setpts=PTS-STARTPTS,${normalize},${fit}[ref];[1:v:0]settb=AVTB,setpts=PTS-STARTPTS,${normalize},${fit}[dist];[dist][ref]libvmaf=model='version=${model}':log_fmt=json:log_path=${log_file}:n_threads=${threads}:n_subsample=1:ts_sync_mode=nearest"
}

measure_preflight_quality() {
    local start=$1 length=$2 encoded=$3 geometry eval_width eval_height
    local model_info model model_condition log_file score started filter_graph
    MEASURED_QUALITY_KIND=''
    MEASURED_QUALITY_SCORE=''
    [[ $quality_check != off ]] || return 1

    geometry=$(quality_source_display_geometry) || return 1
    IFS=$'\t' read -r eval_width eval_height <<< "$geometry"
    model_info=$(quality_vmaf_model_for_canvas "$eval_width" "$eval_height") || return 1
    IFS=$'\t' read -r model model_condition <<< "$model_info"

    if [[ -z $QUALITY_WORKER_THREADS ]]; then
        QUALITY_WORKER_THREADS=$(quality_worker_threads) || return 1
    fi
    if [[ -z $QUALITY_VMAF_AVAILABLE ]]; then
        if has_filter libvmaf; then QUALITY_VMAF_AVAILABLE=true; else QUALITY_VMAF_AVAILABLE=false; fi
    fi
    if [[ $QUALITY_VMAF_AVAILABLE == true ]]; then
        log_file="${encoded}.vmaf.json"
        preflight_files+=("$log_file")
        rm -f -- "$log_file"
        printf '\nVMAF scoring: source-display %sx%s, %s (%s), %s CPU worker(s), every sample frame...\n' \
            "$eval_width" "$eval_height" "$model" "$model_condition" "$QUALITY_WORKER_THREADS"
        filter_graph=$(quality_vmaf_filter_graph "$eval_width" "$eval_height" "$log_file" \
            "$QUALITY_WORKER_THREADS" "$model") || return 1
        started=$SECONDS
        # Keep the existing timestamp policy: Matroska sample timestamps can
        # round to milliseconds, so use a common AVTB and nearest framesync.
        # No fps conversion or subsampling is introduced.
        if ffmpeg -hide_banner -v error -nostdin \
            -ss "$start" -t "$length" -i "$input" -i "$encoded" \
            -filter_complex "$filter_graph" \
            -an -f null - >/dev/null 2>&1; then
            printf 'VMAF scoring finished in %ss.\n' "$((SECONDS - started))"
            score=$(python3 - "$log_file" <<'PYVMAF'
import json, math, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as handle:
        value = float(json.load(handle)['pooled_metrics']['vmaf']['mean'])
    if math.isfinite(value) and 0.0 <= value <= 100.0:
        print(f'{value:.6f}')
except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
    pass
PYVMAF
)
            if [[ $score =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                MEASURED_QUALITY_KIND=VMAF
                MEASURED_QUALITY_SCORE=$score
                return 0
            fi
        else
            printf 'VMAF scoring failed after %ss.\n' "$((SECONDS - started))"
        fi
    fi

    # Strict quality policy: model/VMAF failure preserves the original; SSIM
    # is never substituted and the configured VMAF threshold is never lowered.
    return 1
}
'''

text = text[:start] + new_block + text[end:]
for before, after in (
    ("readonly SCRIPT_VERSION='2026-07-22-integrated-video-r3'", "readonly SCRIPT_VERSION='2026-09-07-integrated-video-r4'"),
    ('calibration-v3-nominal-fps-nearest-timestamps-center-validation', 'calibration-v4-source-display-resolution-bicubic-sar-nearest-vmaf-model'),
    ('"video-preprocessing-v2-selection"', '"video-preprocessing-v3-source-display-vmaf"'),
):
    count = text.count(before)
    if count != 1:
        raise SystemExit(f'expected one marker {before!r}, found {count}')
    text = text.replace(before, after, 1)
CORE.write_text(text)

# Verify both the outer core and the embedded helper shell program now, before
# allowing the workflow to commit the change.
subprocess.run(['bash', '-n', str(CORE)], check=True)
helper = text.split("<<'__HARDCORE_ARCHIVE_VIDEO_HELPER__'\n", 1)[1].split("\n__HARDCORE_ARCHIVE_VIDEO_HELPER__", 1)[0]
subprocess.run(['bash', '-n'], input=helper, text=True, check=True)

README = Path('README.md')
readme = README.read_text()
anchor = "VMAF scoring runs on the **CPU**, separately from hardware encoding. `VIDEO_QUALITY_THREADS=auto` explicitly enables up to 8 VMAF workers, bounded by the logical CPUs available to the process."
if anchor not in readme:
    raise SystemExit('README VMAF anchor not found')
addition = r'''

### VMAF viewing-resolution policy

Quality scoring uses a viewing canvas chosen from the **source display resolution**, never from the encoded candidate's dimensions. Source coded size, sample aspect ratio, and 90/270-degree display rotation are normalized to an even-sized square-pixel canvas. Both the reference and distorted stream then go through the same bicubic aspect-preserving fit, limited-range 8-bit 4:2:0 conversion, and padding when display aspect ratios differ. A smaller candidate is therefore upscaled to the source canvas, so resolution loss remains visible to VMAF instead of being hidden by shrinking the reference.

Timestamp handling is unchanged: both streams use `AVTB`, reset to `PTS-STARTPTS`, and libvmaf framesync uses `ts_sync_mode=nearest`; no frame-rate conversion and no VMAF frame subsampling are introduced.

Hardcore Archive deliberately keeps the established VMAF v0 score family so the configured quality floor (92 by default) is not silently reinterpreted by a different model generation. UHD/4K-or-larger source canvases use the official `vmaf_4k_v0.6.1` model, trained for 4K at 1.5H. Smaller source canvases use `vmaf_v0.6.1`, trained for a 1080p HDTV at 3H. Missing selected models fail closed and preserve the original video.

These models remain imperfect absolute predictors outside their training conditions. In particular, source-sized 720p/1440p evaluation, >4K content, HDR transfer functions, and high frame rates do not exactly match the legacy model training/viewing setup. Netflix's newer VMAF v1 family adds explicit 1080p/4K/HFR conditions and recommends 10-bit SDR evaluation, but adopting it would require separately re-validating Hardcore Archive's numeric quality threshold. This change therefore fixes cross-resolution scoring without changing the existing target semantics.
'''
readme = readme.replace(anchor, anchor + addition, 1)
README.write_text(readme)
