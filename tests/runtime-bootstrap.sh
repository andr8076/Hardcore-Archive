#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-runtime-bootstrap.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

TARGET=linux-x86_64
SOURCE="$TMP/source"
RELEASE="$TMP/release"
MOCKBIN="$TMP/mockbin"
mkdir -p "$SOURCE/packaging/media-runtime" "$RELEASE/runtime/bin" "$MOCKBIN" "$TMP/home"
printf 'HCA_MEDIA_RUNTIME_REVISION=99\n' > "$SOURCE/packaging/media-runtime/versions.env"

cat > "$RELEASE/runtime/bin/ffmpeg" <<'EOF_FFMPEG'
#!/usr/bin/env bash
case " $* " in
    *" -version "*) printf 'ffmpeg version downloaded-test\n' ;;
    *" -buildconf "*) printf '%s\n' '--enable-libvmaf' ;;
    *) exit 0 ;;
esac
EOF_FFMPEG
cat > "$RELEASE/runtime/bin/ffprobe" <<'EOF_FFPROBE'
#!/usr/bin/env bash
printf 'ffprobe version downloaded-test\n'
EOF_FFPROBE
chmod +x "$RELEASE/runtime/bin/ffmpeg" "$RELEASE/runtime/bin/ffprobe"
printf 'revision=99\n' > "$RELEASE/runtime/runtime-manifest.txt"
(
    cd "$RELEASE"
    tar -czf "hardcore-archive-media-runtime-$TARGET.tar.gz" runtime
)
sha256sum "$RELEASE/hardcore-archive-media-runtime-$TARGET.tar.gz" > \
    "$RELEASE/hardcore-archive-media-runtime-$TARGET.tar.gz.sha256"

cat > "$MOCKBIN/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -e
out=''
url=''
while (( $# > 0 )); do
    case $1 in
        --output) out=$2; shift 2 ;;
        http*) url=$1; shift ;;
        *) shift ;;
    esac
done
cp -- "$HCA_TEST_RELEASE/${url##*/}" "$out"
EOF_CURL
chmod +x "$MOCKBIN/curl"

HOME="$TMP/home"
XDG_CACHE_HOME="$TMP/cache"
HARDCORE_ARCHIVE_ROOT=$SOURCE
HARDCORE_ARCHIVE_RUNTIME_REPOSITORY=test/repo
PATH="$MOCKBIN:/usr/bin:/bin"
export HOME XDG_CACHE_HOME HARDCORE_ARCHIVE_ROOT HARDCORE_ARCHIVE_RUNTIME_REPOSITORY PATH HCA_TEST_RELEASE="$RELEASE"

# shellcheck source=/dev/null
source "$ROOT/lib/runtime.sh"
hardcore_runtime_prepare_video_toolchain

[[ ${HARDCORE_ARCHIVE_VIDEO_RUNTIME_MODE:-} == downloaded ]] || {
    printf 'Downloaded runtime was not selected.\n' >&2
    exit 1
}
[[ $("$HARDCORE_ARCHIVE_FFMPEG" -version) == 'ffmpeg version downloaded-test' ]] || {
    printf 'Downloaded FFmpeg was not activated.\n' >&2
    exit 1
}
[[ -x "$TMP/cache/hardcore-archive/media-runtime/r99/$TARGET/runtime/bin/ffmpeg" ]] || {
    printf 'Downloaded runtime was not cached.\n' >&2
    exit 1
}

printf 'Runtime bootstrap tests passed.\n'
