#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-package-name.XXXXXX")
cleanup() {
    rm -rf -- "$TMP"
    [[ -n ${RUNTIME_DIR:-} ]] && rm -rf -- "$RUNTIME_DIR"
}
trap cleanup EXIT

kernel=$(uname -s 2>/dev/null || printf unknown)
arch=$(uname -m 2>/dev/null || printf unknown)
case $kernel in
    Linux) platform=linux ;;
    Darwin) platform=macos ;;
    *) printf 'Unsupported test platform: %s\n' "$kernel" >&2; exit 1 ;;
esac
case $arch in
    x86_64|amd64) arch=x86_64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) printf 'Unsupported test architecture: %s\n' "$arch" >&2; exit 1 ;;
esac
key="$platform-$arch"
RUNTIME_DIR="$ROOT/runtime/$key"

# The source repository deliberately has no generated runtime. Supply the
# smallest valid fake one needed to exercise only the release packager.
mkdir -p "$RUNTIME_DIR/bin"
cat > "$RUNTIME_DIR/bin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$RUNTIME_DIR/bin/ffprobe" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$RUNTIME_DIR/bin/ffmpeg" "$RUNTIME_DIR/bin/ffprobe"
printf 'test-runtime\n' > "$RUNTIME_DIR/runtime-id"

archive=$(
    HCA_RELEASE_DEST="$TMP/dist" \
    HCA_RELEASE_VERSION='refs/pull/1/merge' \
    bash "$ROOT/packaging/package-release.sh"
)
expected="$TMP/dist/hardcore-archive-refs-pull-1-merge-$key.tar.gz"

[[ $archive == "$expected" ]] || {
    printf 'Unexpected package path:\n  got:      %s\n  expected: %s\n' "$archive" "$expected" >&2
    exit 1
}
[[ -f $archive ]] || {
    printf 'Package was not created: %s\n' "$archive" >&2
    exit 1
}
[[ $(basename -- "$archive") != */* ]]

tar -tzf "$archive" >/dev/null
printf 'Release package name sanitization test passed.\n'
