#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
FRONTEND="$ROOT/hardcore-archive.sh"
[[ -f $FRONTEND ]] || { printf 'Missing frontend: %s\n' "$FRONTEND" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-archive-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/app/lib" "$TMP/home/.config/hardcore-archive"
cp "$FRONTEND" "$TMP/app/hardcore-archive.sh"

cat > "$TMP/app/lib/hardcore-archive-core.sh" <<'FAKE_CORE'
printf 'VIDEO_AUDIO_COPY=%s\n' "${VIDEO_AUDIO_COPY-unset}"
printf 'ARG=%s\n' "$@"
FAKE_CORE

run_frontend() {
    HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" \
        bash "$TMP/app/hardcore-archive.sh" "$@"
}

assert_has() {
    local output=$1 expected=$2
    grep -Fqx -- "$expected" <<< "$output" || {
        printf 'Expected line not found: %s\nOutput:\n%s\n' "$expected" "$output" >&2
        exit 1
    }
}

assert_lacks() {
    local output=$1 unexpected=$2
    if grep -Fqx -- "$unexpected" <<< "$output"; then
        printf 'Unexpected line found: %s\nOutput:\n%s\n' "$unexpected" "$output" >&2
        exit 1
    fi
}

out=$(run_frontend source)
assert_has "$out" 'ARG=--no-video-transcode'
assert_has "$out" 'ARG=--no-image-optimize'
assert_has "$out" 'ARG=--no-nested-repack'

out=$(run_frontend --video-transcode source)
assert_lacks "$out" 'ARG=--no-video-transcode'
assert_has "$out" 'ARG=--no-image-optimize'
assert_has "$out" 'ARG=--no-nested-repack'

printf 'VIDEO_TRANSCODE=true\nIMAGE_OPTIMIZE=true\nNESTED_REPACK=true\n' \
    > "$TMP/home/.config/hardcore-archive/config"
out=$(run_frontend source)
assert_lacks "$out" 'ARG=--no-video-transcode'
assert_lacks "$out" 'ARG=--no-image-optimize'
assert_lacks "$out" 'ARG=--no-nested-repack'

printf 'VIDEO_TRANSCODE=false\nIMAGE_OPTIMIZE=false\nNESTED_REPACK=false\n' \
    > "$TMP/home/.config/hardcore-archive/config"
out=$(run_frontend --video-transcode --image-optimize --nested-repack source)
assert_lacks "$out" 'ARG=--no-video-transcode'
assert_lacks "$out" 'ARG=--no-image-optimize'
assert_lacks "$out" 'ARG=--no-nested-repack'
assert_has "$out" 'ARG=--config'

out=$(run_frontend --video-transcode --no-video-transcode source)
assert_has "$out" 'ARG=--no-video-transcode'

out=$(run_frontend --video-transcode --video-copy-audio source)
assert_has "$out" 'VIDEO_AUDIO_COPY=true'

out=$(run_frontend --no-config source)
assert_has "$out" 'ARG=--no-video-transcode'
assert_has "$out" 'ARG=--no-image-optimize'
assert_has "$out" 'ARG=--no-nested-repack'

printf 'Frontend policy tests passed.\n'
