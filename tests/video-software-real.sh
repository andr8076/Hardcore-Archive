#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-software-video-real.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT INT TERM HUP

command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 || {
    printf 'SKIP real software video acceptance: ffmpeg/ffprobe unavailable.\n'
    exit 0
}

# shellcheck source=/dev/null
source "$ROOT/lib/video-encoder-capabilities.sh"

source_file="$TMP/reference.mkv"
hardcore_video_probe_run_bounded 30 ffmpeg -hide_banner -v error -nostdin -y \
    -f lavfi -i 'testsrc2=s=320x180:r=24:d=1' \
    -f lavfi -i 'sine=frequency=440:sample_rate=48000:d=1' \
    -map 0:v:0 -map 1:a:0 -c:v ffv1 -c:a pcm_s16le \
    -metadata title='Hardcore capability proof' "$source_file"

tested=0
for specification in 'av1 libsvtav1 35 10' 'hevc libx265 28 ultrafast'; do
    IFS=' ' read -r codec encoder quality preset <<< "$specification"
    if ! probe_software_encoder "$codec" "$encoder"; then
        printf 'SKIP real %s acceptance: %s\n' "$encoder" "${VIDEO_PROBE_ERROR//$'\n'/ }"
        continue
    fi

    output="$TMP/$encoder.mkv"
    encode_log="$TMP/$encoder.encode.log"
    if ! hardcore_video_probe_run_bounded 45 ffmpeg -hide_banner -v error -nostdin -y \
        -i "$source_file" -map 0:v:0 -map '0:a?' -map_metadata 0 -map_chapters 0 \
        -c:v "$encoder" -crf:v "$quality" -preset:v "$preset" -pix_fmt yuv420p \
        -c:a copy "$output" >/dev/null 2>"$encode_log"; then
        printf 'FAIL real %s production-style encode. Last output follows:\n' "$encoder" >&2
        tail -n 20 "$encode_log" >&2 || true
        exit 1
    fi
    [[ -s $output ]]
    [[ $(ffprobe -v error -select_streams V:0 -show_entries stream=codec_name \
        -of default=nw=1:nk=1 "$output" | head -n1) == "$codec" ]]
    [[ $(ffprobe -v error -select_streams a -show_entries stream=index \
        -of csv=p=0 "$output" | sed '/^[[:space:]]*$/d' | wc -l) -eq 1 ]]
    [[ $(ffprobe -v error -show_entries format_tags=title \
        -of default=nw=1:nk=1 "$output" | head -n1) == 'Hardcore capability proof' ]]
    duration=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$output" | head -n1)
    awk -v duration="$duration" 'BEGIN {exit !(duration >= 0.8 && duration <= 1.2)}'
    hardcore_video_probe_run_bounded 30 ffmpeg -hide_banner -v error -xerror -nostdin \
        -i "$output" -map '0:V' -map '0:a?' -f null -

    if ffmpeg -hide_banner -filters 2>/dev/null | awk '$2=="libvmaf" {found=1} END {exit !found}'; then
        hardcore_video_probe_run_bounded 45 ffmpeg -hide_banner -v error -nostdin \
            -i "$source_file" -i "$output" \
            -lavfi '[0:v]setpts=PTS-STARTPTS[ref];[1:v]setpts=PTS-STARTPTS[dist];[dist][ref]libvmaf=n_threads=1' \
            -f null -
    fi
    tested=$((tested + 1))
    printf 'PASS real software video acceptance: %s/%s.\n' "$codec" "$encoder"
done

if (( tested == 0 )); then
    printf 'SKIP real software video acceptance: no software candidate passed its real probe.\n'
else
    printf 'Real software video acceptance tests passed (%s candidate(s)).\n' "$tested"
fi
