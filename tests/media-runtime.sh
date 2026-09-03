#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-media-runtime.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/media-runtime.sh"

key=$(hardcore_media_runtime_platform_key) || {
    printf 'Current test platform is not supported by media-runtime.sh.\n' >&2
    exit 1
}

make_fake_tools() {
    local dir=$1 label=$2
    mkdir -p "$dir"
    cat > "$dir/ffmpeg" <<EOF_FFMPEG
#!/usr/bin/env bash
if [[ \${1:-} == -version ]]; then printf 'ffmpeg version $label\\n'; fi
exit 0
EOF_FFMPEG
    cat > "$dir/ffprobe" <<EOF_FFPROBE
#!/usr/bin/env bash
if [[ \${1:-} == -version ]]; then printf 'ffprobe version $label\\n'; fi
exit 0
EOF_FFPROBE
    chmod +x "$dir/ffmpeg" "$dir/ffprobe"
}

SYSTEM_BIN="$TMP/system/bin"
PROJECT="$TMP/project"
BUNDLED="$PROJECT/runtime/$key"
CUSTOM="$TMP/custom"
make_fake_tools "$SYSTEM_BIN" system-test
make_fake_tools "$BUNDLED/bin" bundled-test
make_fake_tools "$CUSTOM/bin" custom-test
mkdir -p "$BUNDLED/lib" "$BUNDLED/share/vmaf/model"
printf 'hca-media-test-runtime\n' > "$BUNDLED/runtime-id"

(
    PATH="$SYSTEM_BIN:/usr/bin:/bin"
    unset HARDCORE_FFMPEG_DIR HARDCORE_MEDIA_RUNTIME
    hardcore_media_runtime_select "$PROJECT"
    [[ $HARDCORE_MEDIA_RUNTIME_SOURCE == bundled ]]
    [[ $HARDCORE_MEDIA_RUNTIME_ID == hca-media-test-runtime ]]
    [[ $(command -v ffmpeg) == "$BUNDLED/bin/ffmpeg" ]]
    [[ ${HARDCORE_ARCHIVE_VMAF_MODEL_DIR:-} == "$BUNDLED/share/vmaf/model" ]]
    [[ ${HARDCORE_ARCHIVE_MEDIA_RUNTIME_SOURCE:-} == bundled ]]
)

(
    PATH="$SYSTEM_BIN:/usr/bin:/bin"
    HARDCORE_MEDIA_RUNTIME=system
    unset HARDCORE_FFMPEG_DIR
    hardcore_media_runtime_select "$PROJECT"
    [[ $HARDCORE_MEDIA_RUNTIME_SOURCE == system ]]
    [[ $(command -v ffmpeg) == "$SYSTEM_BIN/ffmpeg" ]]
    [[ $HARDCORE_MEDIA_RUNTIME_ID == system:*system-test* ]]
)

(
    PATH="$SYSTEM_BIN:/usr/bin:/bin"
    HARDCORE_FFMPEG_DIR="$CUSTOM"
    HARDCORE_MEDIA_RUNTIME=auto
    hardcore_media_runtime_select "$PROJECT"
    [[ $HARDCORE_MEDIA_RUNTIME_SOURCE == custom ]]
    [[ $(command -v ffmpeg) == "$CUSTOM/bin/ffmpeg" ]]
)

(
    BROKEN_PROJECT="$TMP/broken-project"
    mkdir -p "$BROKEN_PROJECT/runtime/$key/bin"
    PATH="$SYSTEM_BIN:/usr/bin:/bin"
    unset HARDCORE_FFMPEG_DIR HARDCORE_MEDIA_RUNTIME
    if hardcore_media_runtime_select "$BROKEN_PROJECT" 2>/dev/null; then
        printf 'Incomplete bundled runtime was accepted.\n' >&2
        exit 1
    fi
)

printf 'Media runtime selection tests passed.\n'
