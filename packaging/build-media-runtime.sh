#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
FFMPEG_VERSION=${HCA_FFMPEG_VERSION:-9.0.1}
VMAF_VERSION=${HCA_VMAF_VERSION:-3.2.0}
OPUS_VERSION=${HCA_OPUS_VERSION:-1.5.2}
RUNTIME_REVISION=${HCA_MEDIA_RUNTIME_REVISION:-r1}
OUTPUT=''

usage() {
    cat <<'EOF'
Usage: bash packaging/build-media-runtime.sh [--output DIRECTORY]

Build the pinned FFmpeg + libvmaf runtime used by Hardcore Archive releases.
The build intentionally leaves GPU drivers/runtime ownership to the host OS.
EOF
}

while (( $# )); do
    case $1 in
        --output)
            (( $# >= 2 )) || { printf 'Error: --output requires a directory.\n' >&2; exit 2; }
            OUTPUT=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Error: unknown option: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

for tool in curl tar make cc pkg-config meson ninja python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'Error: required build tool is missing: %s\n' "$tool" >&2
        exit 3
    }
done

kernel=$(uname -s 2>/dev/null || printf unknown)
arch=$(uname -m 2>/dev/null || printf unknown)
case $kernel in
    Linux) platform=linux ;;
    Darwin) platform=macos ;;
    *) printf 'Error: unsupported build platform: %s\n' "$kernel" >&2; exit 3 ;;
esac
case $arch in
    x86_64|amd64) arch=x86_64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) printf 'Error: unsupported build architecture: %s\n' "$arch" >&2; exit 3 ;;
esac
key="$platform-$arch"
OUTPUT=${OUTPUT:-$ROOT/runtime/$key}
OUTPUT=$(mkdir -p -- "$OUTPUT" && cd -- "$OUTPUT" && pwd -P)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-media-build.XXXXXX")
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT
DEPS="$WORK/deps"
mkdir -p "$DEPS" "$OUTPUT/bin" "$OUTPUT/lib" "$OUTPUT/share/vmaf" "$OUTPUT/licenses"

if command -v nproc >/dev/null 2>&1; then JOBS=$(nproc); else JOBS=$(sysctl -n hw.logicalcpu 2>/dev/null || printf 2); fi
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || JOBS=2

fetch() {
    local url=$1 destination=$2
    printf 'Downloading %s\n' "$url"
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "$destination" "$url"
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Build libopus statically so the release FFmpeg audio path does not gain a new
# runtime package dependency.
fetch "https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz" "$WORK/opus.tar.gz"
tar -xf "$WORK/opus.tar.gz" -C "$WORK"
(
    cd "$WORK/opus-$OPUS_VERSION"
    ./configure --prefix="$DEPS" --disable-shared --enable-static
    make -j"$JOBS"
    make install
)

# libvmaf stays a shared library beside FFmpeg. This keeps the redistributed
# dependency boundary explicit and makes version/license auditing straightforward.
fetch "https://github.com/Netflix/vmaf/archive/refs/tags/v${VMAF_VERSION}.tar.gz" "$WORK/vmaf.tar.gz"
tar -xf "$WORK/vmaf.tar.gz" -C "$WORK"
VMAF_SRC="$WORK/vmaf-$VMAF_VERSION"
meson setup "$VMAF_SRC/libvmaf/build" "$VMAF_SRC/libvmaf" \
    --prefix="$OUTPUT" \
    --libdir=lib \
    --buildtype=release \
    --default-library=shared \
    -Denable_tests=false \
    -Denable_docs=false
meson compile -C "$VMAF_SRC/libvmaf/build" -j "$JOBS"
meson install -C "$VMAF_SRC/libvmaf/build"
cp -R "$VMAF_SRC/model" "$OUTPUT/share/vmaf/model"
cp "$VMAF_SRC/LICENSE" "$OUTPUT/licenses/VMAF-LICENSE"

# Build FFmpeg from the pinned distributor release. External GPL/nonfree codec
# libraries are not enabled. Hardware interfaces are auto-detected from headers
# present on the release builder and remain dynamically backed by host drivers.
fetch "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" "$WORK/ffmpeg.tar.xz"
tar -xf "$WORK/ffmpeg.tar.xz" -C "$WORK"
FFMPEG_SRC="$WORK/ffmpeg-$FFMPEG_VERSION"

PKG_CONFIG_PATH="$OUTPUT/lib/pkgconfig:$DEPS/lib/pkgconfig:$DEPS/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export PKG_CONFIG_PATH
extra_cflags="-I$OUTPUT/include -I$DEPS/include"
extra_ldflags="-L$OUTPUT/lib -L$DEPS/lib -L$DEPS/lib64"
if [[ $platform == linux ]]; then
    extra_ldflags="$extra_ldflags -Wl,-rpath,\$ORIGIN/../lib"
else
    extra_ldflags="$extra_ldflags -Wl,-rpath,@executable_path/../lib"
fi

(
    cd "$FFMPEG_SRC"
    ./configure \
        --prefix="$OUTPUT" \
        --disable-debug \
        --disable-doc \
        --disable-ffplay \
        --enable-libvmaf \
        --enable-libopus \
        --pkg-config-flags=--static \
        --extra-version="hca-vmaf-${VMAF_VERSION}-${RUNTIME_REVISION}" \
        --extra-cflags="$extra_cflags" \
        --extra-ldflags="$extra_ldflags"
    make -j"$JOBS" ffmpeg ffprobe
    cp ffmpeg ffprobe "$OUTPUT/bin/"
    cp COPYING.LGPLv2.1 "$OUTPUT/licenses/FFmpeg-COPYING.LGPLv2.1"
)
cp "$WORK/opus-$OPUS_VERSION/COPYING" "$OUTPUT/licenses/Opus-COPYING"

case $platform in
    linux)
        export LD_LIBRARY_PATH="$OUTPUT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        ;;
    macos)
        export DYLD_LIBRARY_PATH="$OUTPUT/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
        ;;
esac

if "$OUTPUT/bin/ffmpeg" -buildconf 2>&1 | grep -Fq -- '--enable-nonfree'; then
    printf 'Error: refusing to package an FFmpeg build configured with --enable-nonfree.\n' >&2
    exit 4
fi
if ! "$OUTPUT/bin/ffmpeg" -hide_banner -filters 2>/dev/null | awk 'NF >= 2 {print $2}' | grep -Fxq libvmaf; then
    printf 'Error: built FFmpeg does not expose the libvmaf filter.\n' >&2
    exit 4
fi

# Real invocation, not only filter-table detection. This catches loader, ABI and
# default-model failures before a runtime can become a release artifact.
"$OUTPUT/bin/ffmpeg" -hide_banner -v error -nostdin \
    -f lavfi -i 'color=c=black:s=64x64:r=1:d=1' \
    -f lavfi -i 'color=c=black:s=64x64:r=1:d=1' \
    -filter_complex '[0:v][1:v]libvmaf=n_threads=1' \
    -frames:v 1 -f null - >/dev/null

runtime_id="hca-media-ffmpeg-${FFMPEG_VERSION}-vmaf-${VMAF_VERSION}-opus-${OPUS_VERSION}-${RUNTIME_REVISION}"
printf '%s\n' "$runtime_id" > "$OUTPUT/runtime-id"

{
    printf 'runtime_id=%s\n' "$runtime_id"
    printf 'platform=%s\n' "$key"
    printf 'ffmpeg_version=%s\n' "$FFMPEG_VERSION"
    printf 'vmaf_version=%s\n' "$VMAF_VERSION"
    printf 'opus_version=%s\n' "$OPUS_VERSION"
    printf 'runtime_revision=%s\n' "$RUNTIME_REVISION"
    printf 'ffmpeg_sha256=%s\n' "$(sha256_file "$OUTPUT/bin/ffmpeg")"
    printf 'ffprobe_sha256=%s\n' "$(sha256_file "$OUTPUT/bin/ffprobe")"
    printf 'libvmaf_files=\n'
    find "$OUTPUT/lib" -maxdepth 1 -type f -name 'libvmaf*' -print | sort | while IFS= read -r file; do
        printf '  %s %s\n' "$(sha256_file "$file")" "${file#$OUTPUT/}"
    done
    printf '\nffmpeg_version_output:\n'
    "$OUTPUT/bin/ffmpeg" -version
    printf '\nffmpeg_buildconf:\n'
    "$OUTPUT/bin/ffmpeg" -buildconf
    printf '\nhardware_encoder_table_entries:\n'
    "$OUTPUT/bin/ffmpeg" -hide_banner -encoders 2>/dev/null | \
        grep -E '(^|[[:space:]])(av1|hevc)_(vaapi|nvenc|qsv|videotoolbox)([[:space:]]|$)' || true
} > "$OUTPUT/manifest.txt"

printf 'Built Hardcore Archive media runtime: %s\n' "$OUTPUT"
printf 'Runtime ID: %s\n' "$runtime_id"
