#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-runtime-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/runtime/bin"

cat > "$TMP/runtime/bin/ffmpeg" <<'EOF_FFMPEG'
#!/usr/bin/env bash
case " $* " in
    *" -version "*) printf 'ffmpeg version hca-test\n' ;;
    *" -buildconf "*) printf '%s\n' '--enable-libvmaf' ;;
    *) exit 0 ;;
esac
EOF_FFMPEG
cat > "$TMP/runtime/bin/ffprobe" <<'EOF_FFPROBE'
#!/usr/bin/env bash
printf 'ffprobe version hca-test\n'
EOF_FFPROBE
chmod +x "$TMP/runtime/bin/ffmpeg" "$TMP/runtime/bin/ffprobe"
printf 'ffmpeg=hca-test\nvmaf=test\nmodel=builtin-default\n' > "$TMP/runtime/runtime-manifest.txt"

HARDCORE_ARCHIVE_ROOT=$TMP
export HARDCORE_ARCHIVE_ROOT
# shellcheck source=/dev/null
source "$ROOT/lib/runtime.sh"
hardcore_runtime_prepare_video_toolchain

[[ ${HARDCORE_ARCHIVE_VIDEO_RUNTIME_MODE:-} == bundled ]] || {
    printf 'Bundled runtime was not selected.\n' >&2
    exit 1
}
[[ $(command -v ffmpeg) == "$TMP/runtime/bin/ffmpeg" ]] || {
    printf 'Bundled ffmpeg did not take PATH precedence.\n' >&2
    exit 1
}
[[ $(command -v ffprobe) == "$TMP/runtime/bin/ffprobe" ]] || {
    printf 'Bundled ffprobe did not take PATH precedence.\n' >&2
    exit 1
}
[[ ${HARDCORE_ARCHIVE_VIDEO_RUNTIME_ID:-} == hca-video-* ]] || {
    printf 'Runtime identity was not generated.\n' >&2
    exit 1
}

grep -Fq 'tag=media-runtime-latest' "$ROOT/lib/runtime.sh" || {
    printf 'Runtime bootstrap does not use the rolling media-runtime-latest release.\n' >&2
    exit 1
}
! grep -Fq 'HCA_MEDIA_RUNTIME_REVISION' "$ROOT/lib/runtime.sh" || {
    printf 'Runtime bootstrap still depends on revision bookkeeping.\n' >&2
    exit 1
}

printf 'Bundled media runtime tests passed.\n'
