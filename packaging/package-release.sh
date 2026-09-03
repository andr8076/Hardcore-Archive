#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
VERSION=${HCA_RELEASE_VERSION:-${GITHUB_REF_NAME:-dev}}
DEST=${HCA_RELEASE_DEST:-$ROOT/dist}

kernel=$(uname -s 2>/dev/null || printf unknown)
arch=$(uname -m 2>/dev/null || printf unknown)
case $kernel in Linux) platform=linux ;; Darwin) platform=macos ;; *) printf 'Unsupported platform: %s\n' "$kernel" >&2; exit 2 ;; esac
case $arch in x86_64|amd64) arch=x86_64 ;; arm64|aarch64) arch=arm64 ;; *) printf 'Unsupported architecture: %s\n' "$arch" >&2; exit 2 ;; esac
key="$platform-$arch"
runtime="$ROOT/runtime/$key"
[[ -x $runtime/bin/ffmpeg && -x $runtime/bin/ffprobe && -r $runtime/runtime-id ]] || {
    printf 'Error: complete bundled runtime is missing: %s\n' "$runtime" >&2
    exit 3
}

mkdir -p "$DEST"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-release.XXXXXX")
cleanup() { rm -rf -- "$STAGE"; }
trap cleanup EXIT
name="hardcore-archive-${VERSION}-${key}"
out="$STAGE/$name"
mkdir -p "$out"

cp "$ROOT/hardcore-archive" "$ROOT/hardcore-archive.sh" "$ROOT/hardcore-archive-runner.sh" \
   "$ROOT/hardcore-archive-runner-policy.sh" "$ROOT/config" "$out/"
cp -R "$ROOT/lib" "$out/lib"
mkdir -p "$out/runtime" "$out/docs"
cp -R "$runtime" "$out/runtime/$key"
cp "$ROOT/runtime/README.md" "$out/runtime/README.md"
cp "$ROOT/docs/media-runtime.md" "$out/docs/media-runtime.md"
[[ -f $ROOT/README.md ]] && cp "$ROOT/README.md" "$out/README.md"
[[ -f $ROOT/LICENSE ]] && cp "$ROOT/LICENSE" "$out/LICENSE"

chmod +x "$out/hardcore-archive" "$out/hardcore-archive.sh" "$out/hardcore-archive-runner.sh" "$out/hardcore-archive-runner-policy.sh"
find "$out/lib" -type f \( -name '*.py' -o -name 'hardcore-archive-doctor-encoder-runtime.sh' -o -name 'hardcore-archive-doctor.sh' \) -exec chmod +x {} + 2>/dev/null || true

archive="$DEST/$name.tar.gz"
tar -C "$STAGE" -czf "$archive" "$name"
printf '%s\n' "$archive"
