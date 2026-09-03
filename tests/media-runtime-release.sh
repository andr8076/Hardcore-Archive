#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/media-runtime.sh"

hardcore_media_runtime_select "$ROOT"
[[ $HARDCORE_MEDIA_RUNTIME_SOURCE == bundled ]] || {
    printf 'Expected bundled media runtime, got: %s\n' "$HARDCORE_MEDIA_RUNTIME_SOURCE" >&2
    exit 1
}
[[ -n $HARDCORE_MEDIA_RUNTIME_ID && $HARDCORE_MEDIA_RUNTIME_ID != unselected ]]
[[ $(command -v ffmpeg) == "$HARDCORE_MEDIA_RUNTIME_BIN_DIR/ffmpeg" ]]
[[ $(command -v ffprobe) == "$HARDCORE_MEDIA_RUNTIME_BIN_DIR/ffprobe" ]]

ffmpeg -version | head -n1 | grep -Fq 'hca-vmaf-'
ffmpeg -hide_banner -filters 2>/dev/null | awk 'NF >= 2 {print $2}' | grep -Fxq libvmaf
ffmpeg -hide_banner -v error -nostdin \
    -f lavfi -i 'color=c=black:s=64x64:r=1:d=1' \
    -f lavfi -i 'color=c=black:s=64x64:r=1:d=1' \
    -filter_complex '[0:v][1:v]libvmaf=n_threads=1' \
    -frames:v 1 -f null - >/dev/null

if ffmpeg -buildconf 2>&1 | grep -Fq -- '--enable-nonfree'; then
    printf 'Bundled runtime unexpectedly contains --enable-nonfree.\n' >&2
    exit 1
fi

printf 'Bundled media runtime verification passed: %s\n' "$HARDCORE_MEDIA_RUNTIME_ID"
