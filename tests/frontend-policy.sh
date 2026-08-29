#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
FRONTEND="$ROOT/hardcore-archive.sh"
[[ -f $FRONTEND ]] || { printf 'Missing frontend: %s\n' "$FRONTEND" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-archive-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/app/lib" "$TMP/home/.config/hardcore-archive" "$TMP/bin"
cp "$FRONTEND" "$TMP/app/hardcore-archive.sh"

cat > "$TMP/app/lib/hardcore-archive-core.sh" <<'FAKE_CORE'
printf 'VIDEO_AUDIO_COPY=%s\n' "${VIDEO_AUDIO_COPY-unset}"
printf 'ARG=%s\n' "$@"
FAKE_CORE

# Deterministic FFmpeg capability stub. It deliberately exposes only VA-API
# hardware encoders so policy tests do not depend on the CI host's GPU.
cat > "$TMP/bin/ffmpeg" <<'FAKE_FFMPEG'
#!/usr/bin/env bash
if [[ " $* " == *" -encoders "* ]]; then
    cat <<'ENCODERS'
 V..... av1_vaapi             AV1 (VAAPI)
 V..... hevc_vaapi            H.265/HEVC (VAAPI)
ENCODERS
    exit 0
fi
exit 0
FAKE_FFMPEG
chmod +x "$TMP/bin/ffmpeg"

run_frontend() {
    HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" PATH="$TMP/bin:$PATH" \
        bash "$TMP/app/hardcore-archive.sh" "$@"
}

assert_has() {
    local output=$1 expected=$2
    grep -Fqx -- "$expected" <<< "$output" || {
        printf 'Expected line not found: %s\nOutput:\n%s\n' "$expected" "$output" >&2
        exit 1
    }
}

assert_contains() {
    local output=$1 expected=$2
    grep -Fq -- "$expected" <<< "$output" || {
        printf 'Expected text not found: %s\nOutput:\n%s\n' "$expected" "$output" >&2
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

out=$(run_frontend source 2>&1)
assert_has "$out" 'ARG=--no-video-transcode'
assert_has "$out" 'ARG=--no-image-optimize'
assert_has "$out" 'ARG=--no-nested-repack'

out=$(run_frontend --video-transcode source 2>&1)
assert_lacks "$out" 'ARG=--no-video-transcode'
assert_has "$out" 'ARG=--video-encoder'
assert_has "$out" 'ARG=av1_vaapi'
assert_has "$out" 'ARG=--video-parallel'
assert_contains "$out" 'Hardware video policy: AV1 via av1_vaapi'

out=$(run_frontend --video-transcode --video-codec hevc source 2>&1)
assert_has "$out" 'ARG=hevc_vaapi'
assert_contains "$out" 'Hardware video policy: HEVC via hevc_vaapi'

printf 'VIDEO_TRANSCODE=true\nIMAGE_OPTIMIZE=true\nNESTED_REPACK=true\n' \
    > "$TMP/home/.config/hardcore-archive/config"
out=$(run_frontend source 2>&1)
assert_lacks "$out" 'ARG=--no-video-transcode'
assert_lacks "$out" 'ARG=--no-image-optimize'
assert_lacks "$out" 'ARG=--no-nested-repack'
assert_has "$out" 'ARG=av1_vaapi'
assert_has "$out" 'ARG=--video-parallel'

printf 'VIDEO_TRANSCODE=false\nIMAGE_OPTIMIZE=false\nNESTED_REPACK=false\n' \
    > "$TMP/home/.config/hardcore-archive/config"
out=$(run_frontend --video-transcode --image-optimize --nested-repack source 2>&1)
assert_lacks "$out" 'ARG=--no-video-transcode'
assert_lacks "$out" 'ARG=--no-image-optimize'
assert_lacks "$out" 'ARG=--no-nested-repack'
assert_has "$out" 'ARG=--config'
assert_has "$out" 'ARG=av1_vaapi'

out=$(run_frontend --video-transcode --no-video-transcode source 2>&1)
assert_has "$out" 'ARG=--no-video-transcode'

out=$(run_frontend --video-transcode --video-copy-audio source 2>&1)
assert_has "$out" 'VIDEO_AUDIO_COPY=true'

set +e
out=$(run_frontend --video-transcode --video-encoder libsvtav1 source 2>&1)
rc=$?
set -e
(( rc != 0 )) || { printf 'Software video encoder was not rejected.\n' >&2; exit 1; }
assert_contains "$out" 'CPU video fallback is disabled by policy.'

printf 'VIDEO_TRANSCODE=true\nVIDEO_ENCODER=libsvtav1\n' \
    > "$TMP/home/.config/hardcore-archive/config"
set +e
out=$(run_frontend source 2>&1)
rc=$?
set -e
(( rc != 0 )) || { printf 'Software config encoder was not rejected.\n' >&2; exit 1; }
assert_contains "$out" 'CPU video fallback is disabled by policy.'

out=$(run_frontend --no-config source 2>&1)
assert_has "$out" 'ARG=--no-video-transcode'
assert_has "$out" 'ARG=--no-image-optimize'
assert_has "$out" 'ARG=--no-nested-repack'

printf 'Frontend policy tests passed.\n'
