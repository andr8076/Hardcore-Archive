#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd -- "$HERE/../.." && pwd -P)
TARGET=''
TOOLS=''
MEDIA=''
OUT="$ROOT/dist/portable"

usage() {
    printf 'Usage: %s --target TARGET --tools-runtime DIR --media-runtime DIR [--output DIR]\n' "$0"
}
while (( $# > 0 )); do
    case $1 in
        --target) TARGET=${2:-}; shift 2 ;;
        --tools-runtime) TOOLS=${2:-}; shift 2 ;;
        --media-runtime) MEDIA=${2:-}; shift 2 ;;
        --output) OUT=${2:-}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ $TARGET =~ ^(linux|macos)-(x86_64|arm64)$ && -n $TOOLS && -n $MEDIA ]] || {
    usage >&2
    exit 2
}

runtime_dir() {
    if [[ -d $1/runtime ]]; then printf '%s/runtime\n' "$1"
    else printf '%s\n' "$1"; fi
}
TOOLS=$(runtime_dir "$TOOLS")
MEDIA=$(runtime_dir "$MEDIA")
[[ -r $TOOLS/tools-runtime-manifest.txt && -x $TOOLS/bin/bash && -x $TOOLS/bin/python3 ]] || {
    printf 'Incomplete tools runtime: %s\n' "$TOOLS" >&2
    exit 3
}
[[ -x $MEDIA/bin/ffmpeg && -x $MEDIA/bin/ffprobe ]] || {
    printf 'Incomplete media runtime: %s\n' "$MEDIA" >&2
    exit 3
}

mkdir -p -- "$OUT"
OUT=$(cd -- "$OUT" && pwd -P)
STAGE=$(mktemp -d "$OUT/.assemble.XXXXXX")
cleanup() { rm -rf -- "$STAGE"; }
trap cleanup EXIT
NAME="hardcore-archive-$TARGET"
APP="$STAGE/$NAME"
mkdir -p -- "$APP"

# Export exactly the checked-in application source, then merge the two tested
# runtime inputs. Release builds therefore cannot accidentally include local
# build products or credentials.
git -C "$ROOT" archive --format=tar HEAD | tar -xf - -C "$APP"
[[ -x $ROOT/vendor/AV1Encode/AV1Encode.sh ]] || {
    printf 'AV1Encode submodule is not initialized. Run: git submodule update --init --recursive\n' >&2
    exit 3
}
mkdir -p -- "$APP/vendor/AV1Encode"
git -C "$ROOT/vendor/AV1Encode" archive --format=tar HEAD |
    tar -xf - -C "$APP/vendor/AV1Encode"
mkdir -p -- "$APP/runtime"
cp -a -- "$TOOLS/." "$APP/runtime/"
cp -a -- "$MEDIA/." "$APP/runtime/"
if [[ -r $APP/runtime/runtime-manifest.txt ]]; then
    mv -- "$APP/runtime/runtime-manifest.txt" "$APP/runtime/media-runtime-manifest.txt"
elif [[ ! -r $APP/runtime/media-runtime-manifest.txt ]]; then
    printf 'Media runtime has no manifest.\n' >&2
    exit 3
fi
if [[ $TARGET == macos-* ]]; then
    bash "$ROOT/packaging/media-runtime/relocate-macos.sh" "$APP/runtime"
fi

TOOLS_HASH=$(sha256sum "$APP/runtime/tools-runtime-manifest.txt" 2>/dev/null | awk '{print $1}' || \
    shasum -a 256 "$APP/runtime/tools-runtime-manifest.txt" | awk '{print $1}')
MEDIA_HASH=$(sha256sum "$APP/runtime/media-runtime-manifest.txt" 2>/dev/null | awk '{print $1}' || \
    shasum -a 256 "$APP/runtime/media-runtime-manifest.txt" | awk '{print $1}')
cat > "$APP/runtime/runtime-manifest.txt" <<EOF_MANIFEST
target=$TARGET
source_commit=$(git -C "$ROOT" rev-parse HEAD)
tools_manifest_sha256=$TOOLS_HASH
media_manifest_sha256=$MEDIA_HASH
EOF_MANIFEST

chmod +x "$APP/hardcore-archive" "$APP/hardcore-archive.sh" "$APP/hardcore-archive-runner.sh"
ARCHIVE="$OUT/$NAME.tar.gz"
rm -f -- "$ARCHIVE" "$ARCHIVE.sha256"
tar -C "$STAGE" -czf "$ARCHIVE" "$NAME"
if command -v sha256sum >/dev/null 2>&1; then sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
else shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"; fi
printf '%s\n' "$ARCHIVE"
