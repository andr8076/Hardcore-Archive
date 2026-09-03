#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-runtime-bootstrap.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

TARGET=linux-x86_64
TEST_BASH=$BASH
SOURCE="$TMP/source"
RELEASE="$TMP/release"
MOCKBIN="$TMP/mockbin"
mkdir -p "$SOURCE/packaging/media-runtime" "$RELEASE/runtime/bin" "$MOCKBIN" "$TMP/home"

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
VERSION_SHA=0123456789abcdef0123456789abcdef01234567
VERSIONED="hardcore-archive-media-runtime-$TARGET-$VERSION_SHA.tar.gz"
mv -- "$RELEASE/hardcore-archive-media-runtime-$TARGET.tar.gz" "$RELEASE/$VERSIONED"
sha256sum "$RELEASE/$VERSIONED" > "$RELEASE/$VERSIONED.sha256"
printf '%s\n' "$VERSIONED" > "$RELEASE/hardcore-archive-media-runtime-$TARGET.current"

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
printf '%s\n' "${url##*/}" >> "$HCA_TEST_DOWNLOAD_LOG"
sleep 0.2
EOF_CURL
chmod +x "$MOCKBIN/curl"

HOME="$TMP/home"
XDG_CACHE_HOME="$TMP/cache"
HARDCORE_ARCHIVE_ROOT=$SOURCE
HARDCORE_ARCHIVE_RUNTIME_REPOSITORY=test/repo
HARDCORE_ARCHIVE_AUTO_RUNTIME=1
PATH="$MOCKBIN:/usr/bin:/bin"
export HOME XDG_CACHE_HOME HARDCORE_ARCHIVE_ROOT HARDCORE_ARCHIVE_RUNTIME_REPOSITORY HARDCORE_ARCHIVE_AUTO_RUNTIME PATH HCA_TEST_RELEASE="$RELEASE"
export HCA_TEST_DOWNLOAD_LOG="$TMP/downloads.log"

cat > "$TMP/bootstrap-one.sh" <<EOF_BOOTSTRAP
#!/usr/bin/env bash
set -Eeuo pipefail
source "$ROOT/lib/runtime.sh"
hardcore_runtime_bootstrap "$TARGET"
EOF_BOOTSTRAP
chmod 700 "$TMP/bootstrap-one.sh"

# Two first runs sharing one empty cache must serialize the installation and
# perform only one archive/checksum download pair.
"$TEST_BASH" "$TMP/bootstrap-one.sh" & first=$!
"$TEST_BASH" "$TMP/bootstrap-one.sh" & second=$!
wait "$first"
wait "$second"
[[ $(wc -l < "$HCA_TEST_DOWNLOAD_LOG") == 3 ]] || {
    printf 'Concurrent bootstraps downloaded the runtime more than once.\n' >&2
    exit 1
}
grep -Fqx "$VERSIONED" "$HCA_TEST_DOWNLOAD_LOG"

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
[[ -x "$TMP/cache/hardcore-archive/media-runtime/$TARGET/runtime/bin/ffmpeg" ]] || {
    printf 'Downloaded runtime was not cached.\n' >&2
    exit 1
}

printf 'Runtime bootstrap tests passed.\n'
