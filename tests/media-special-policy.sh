#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-media-policy.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

source "$ROOT/lib/media-policy.sh"
mkdir -p "$TMP/source"
: > "$TMP/source/ordinary.mp4"
: > "$TMP/source/special movie.mkv"
printf '%s\n' ordinary.mp4 'special movie.mkv' > "$TMP/videos"

cat > "$TMP/helper.py" <<'PY'
import pathlib, sys
if sys.argv[1] == 'classify' and pathlib.Path(sys.argv[2]).name == 'special movie.mkv':
    print('HDR video; lossless/object audio (truehd)')
PY

SOURCE_PARENT=$TMP/source
VIDEO_LIST=$TMP/videos
VIDEO_SPECIAL_LIST=$TMP/special
VIDEO_SPECIAL_PRESERVE_LIST=$TMP/preserve
VIDEO_SPECIAL_OMIT_LIST=$TMP/omit
MEDIA_HELPER=$TMP/helper.py
ASSUME_YES=false
ANALYZE_ONLY=false

VIDEO_SPECIAL_POLICY=preserve
hardcore_media_resolve >/dev/null
grep -Fqx 'special movie.mkv' "$VIDEO_SPECIAL_PRESERVE_LIST"
[[ ! -s $VIDEO_SPECIAL_OMIT_LIST ]]

VIDEO_SPECIAL_POLICY=convert
hardcore_media_resolve >/dev/null
[[ ! -s $VIDEO_SPECIAL_PRESERVE_LIST && ! -s $VIDEO_SPECIAL_OMIT_LIST ]]

VIDEO_SPECIAL_POLICY=omit
hardcore_media_resolve >/dev/null
grep -Fqx 'special movie.mkv' "$VIDEO_SPECIAL_OMIT_LIST"

# The default is fail-safe when no terminal can receive a question.
VIDEO_SPECIAL_POLICY=ask
hardcore_media_resolve </dev/null >/dev/null
grep -Fqx 'special movie.mkv' "$VIDEO_SPECIAL_PRESERVE_LIST"

# Omission is deliberately the fourth per-file choice.
: > "$VIDEO_SPECIAL_PRESERVE_LIST"
: > "$VIDEO_SPECIAL_OMIT_LIST"
hardcore_media_prompt_one 'special movie.mkv' 'HDR video' <<< '4' >/dev/null
grep -Fqx 'special movie.mkv' "$VIDEO_SPECIAL_OMIT_LIST"
[[ ! -s $VIDEO_SPECIAL_PRESERVE_LIST ]]

grep -Fq "action='omitted'" "$ROOT/lib/hardcore-archive-core.sh"
grep -Fq "Videos selected for omission cannot be combined with --remove-source" "$ROOT/lib/hardcore-archive-core.sh"
grep -Fq -- 'primary_indexes[$stream_index]=1' "$ROOT/lib/video-acceleration.sh"
grep -Fq -- 'video_maps+=(-map "0:$stream_index")' "$ROOT/lib/video-acceleration.sh"
grep -Fq -- '"${video_maps[@]}" -map '\''0:a?'\'' -map '\''0:s?'\'' -map '\''0:d?'\'' -map '\''0:t?'\''' "$ROOT/lib/video-acceleration.sh"
grep -Fq 'validate "$input" "$temporary"' "$ROOT/lib/hardcore-archive-core.sh"

printf 'Special-media policy tests passed.\n'
