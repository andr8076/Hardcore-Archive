#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=/dev/null
source "$ROOT/packaging/media-runtime/versions.env"
# shellcheck source=/dev/null
source "$ROOT/lib/runtime.sh"

export HARDCORE_ARCHIVE_ROOT="$ROOT"
export HARDCORE_ARCHIVE_AUTO_RUNTIME=1
export HARDCORE_ARCHIVE_USE_SYSTEM_FFMPEG=0
export HARDCORE_ARCHIVE_STRICT_REAL_VIDEO_CI=1
export XDG_CACHE_HOME="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/hardcore-archive-real-video-cache"
rm -rf -- "$XDG_CACHE_HOME"

printf 'Preparing pinned Hardcore Archive media runtime...\n'
hardcore_runtime_prepare_video_toolchain

[[ ${HARDCORE_ARCHIVE_VIDEO_RUNTIME_MODE:-} == downloaded ]] || {
    printf 'FAIL: strict CI requires the checksum-verified HCA downloaded runtime, got mode %s.\n' \
        "${HARDCORE_ARCHIVE_VIDEO_RUNTIME_MODE:-unset}" >&2
    exit 10
}
[[ -x ${HARDCORE_ARCHIVE_FFMPEG:-} && -x ${HARDCORE_ARCHIVE_FFPROBE:-} ]] || {
    printf 'FAIL: strict CI runtime did not activate executable ffmpeg/ffprobe.\n' >&2
    exit 10
}

RUNTIME_ROOT=$(cd -- "$(dirname -- "$HARDCORE_ARCHIVE_FFMPEG")/.." && pwd -P)
MANIFEST="$RUNTIME_ROOT/runtime-manifest.txt"
[[ -r $MANIFEST ]] || { printf 'FAIL: runtime manifest missing.\n' >&2; exit 10; }

printf 'Activated runtime: %s\n' "$HARDCORE_ARCHIVE_VIDEO_RUNTIME_ID"
printf 'FFmpeg path: %s\n' "$HARDCORE_ARCHIVE_FFMPEG"
printf 'FFprobe path: %s\n' "$HARDCORE_ARCHIVE_FFPROBE"

if [[ $(uname -s) == Linux ]] && command -v ldd >/dev/null 2>&1; then
    missing=$( {
        ldd "$HARDCORE_ARCHIVE_FFMPEG" 2>/dev/null
        ldd "$HARDCORE_ARCHIVE_FFPROBE" 2>/dev/null
    } | awk '/not found/ {print}' | sort -u )
    if [[ -n $missing ]]; then
        printf 'FAIL: managed runtime has unresolved host shared libraries:\n%s\n' "$missing" >&2
        exit 10
    fi
fi

# The release bootstrap verifies the immutable asset's SHA-256. Also require the
# activated payload to match the source pins in this checkout so a stale rolling
# release cannot silently satisfy CI after versions.env changes.
grep -Fx "ffmpeg_version=$FFMPEG_VERSION" "$MANIFEST" >/dev/null || {
    printf 'FAIL: runtime FFmpeg version does not match versions.env (%s).\n' "$FFMPEG_VERSION" >&2
    cat "$MANIFEST" >&2
    exit 11
}
grep -Fx "vmaf_commit=$VMAF_COMMIT" "$MANIFEST" >/dev/null || {
    printf 'FAIL: runtime VMAF commit does not match versions.env (%s).\n' "$VMAF_COMMIT" >&2
    cat "$MANIFEST" >&2
    exit 11
}
grep -Fx "vmaf_model_policy=$VMAF_MODEL_POLICY" "$MANIFEST" >/dev/null || {
    printf 'FAIL: runtime VMAF model policy does not match versions.env (%s).\n' "$VMAF_MODEL_POLICY" >&2
    cat "$MANIFEST" >&2
    exit 11
}

bash "$ROOT/packaging/media-runtime/smoke-test.sh" "$RUNTIME_ROOT"

BUILD_CONF=$($HARDCORE_ARCHIVE_FFMPEG -hide_banner -buildconf 2>&1)
grep -F -- '--enable-libvmaf' <<< "$BUILD_CONF" >/dev/null || {
    printf 'FAIL: strict CI FFmpeg was not built with --enable-libvmaf.\n' >&2
    exit 12
}

FILTERS=$($HARDCORE_ARCHIVE_FFMPEG -hide_banner -filters 2>&1)
for filter in libvmaf scale drawbox setpts testsrc2; do
    grep -E "(^|[[:space:]])${filter}([[:space:]]|$)" <<< "$FILTERS" >/dev/null || {
        printf 'FAIL: required FFmpeg filter is missing: %s\n' "$filter" >&2
        exit 12
    }
done

ENCODERS=$($HARDCORE_ARCHIVE_FFMPEG -hide_banner -encoders 2>&1)
grep -E '(^|[[:space:]])ffv1([[:space:]]|$)' <<< "$ENCODERS" >/dev/null || {
    printf 'FAIL: FFV1 fixture encoder is missing.\n' >&2
    exit 12
}

probe_model() {
    local model=$1 err
    err=$(mktemp "${TMPDIR:-/tmp}/hardcore-model-probe.XXXXXX")
    if ! "$HARDCORE_ARCHIVE_FFMPEG" -hide_banner -v error -nostdin \
        -f lavfi -i 'testsrc2=s=64x64:r=2:d=1' \
        -f lavfi -i 'testsrc2=s=64x64:r=2:d=1' \
        -lavfi "libvmaf=model='version=${model}':n_threads=1:n_subsample=1" \
        -f null - >/dev/null 2>"$err"; then
        printf 'FAIL: required VMAF model is unavailable: %s\n' "$model" >&2
        tail -n 30 "$err" >&2 || true
        rm -f -- "$err"
        return 1
    fi
    rm -f -- "$err"
    printf 'VMAF model probe passed: %s\n' "$model"
}

probe_model vmaf_v0.6.1
probe_model vmaf_4k_v0.6.1

printf '\nRunning mandatory real-media production validation cases...\n'
python3 "$ROOT/tests/video-real-integration.py"
printf 'Strict real video quality integration passed.\n'
