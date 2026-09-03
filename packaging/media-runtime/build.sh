#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd -- "$HERE/../.." && pwd -P)
# shellcheck source=/dev/null
source "$HERE/versions.env"

WORK=${HCA_RUNTIME_WORK:-$ROOT/.runtime-build}
OUT=${HCA_RUNTIME_OUT:-$ROOT/dist/media-runtime}
JOBS=${HCA_RUNTIME_JOBS:-}
if [[ -z $JOBS ]]; then
    if command -v nproc >/dev/null 2>&1; then JOBS=$(nproc)
    else JOBS=$(sysctl -n hw.logicalcpu 2>/dev/null || printf 4); fi
fi

for cmd in git meson ninja pkg-config curl tar make; do
    command -v "$cmd" >/dev/null 2>&1 || { printf 'Missing build dependency: %s\n' "$cmd" >&2; exit 2; }
done

rm -rf -- "$WORK" "$OUT"
mkdir -p "$WORK/src" "$WORK/prefix" "$OUT/runtime/bin" "$OUT/runtime/lib" "$OUT/runtime/licenses"

printf 'Building libvmaf at %s\n' "$VMAF_COMMIT"
VMAF_AVX512=false
case $(uname -m) in x86_64|amd64) VMAF_AVX512=true ;; esac
git clone --filter=blob:none "$VMAF_GIT_URL" "$WORK/src/vmaf"
git -C "$WORK/src/vmaf" checkout --detach "$VMAF_COMMIT"
[[ $(git -C "$WORK/src/vmaf" rev-parse HEAD) == "$VMAF_COMMIT" ]] || { printf 'VMAF pin mismatch.\n' >&2; exit 3; }

meson setup "$WORK/src/vmaf/libvmaf/build" "$WORK/src/vmaf/libvmaf" \
    --prefix "$WORK/prefix" \
    --libdir lib \
    --buildtype release \
    --default-library shared \
    -Denable_tests=false \
    -Denable_docs=false \
    -Denable_avx512="$VMAF_AVX512" \
    -Dbuilt_in_models=true
ninja -C "$WORK/src/vmaf/libvmaf/build" -j "$JOBS"
ninja -C "$WORK/src/vmaf/libvmaf/build" install

if [[ $(uname -s) == Linux ]]; then
    printf 'Installing pinned nv-codec-headers at %s\n' "$NV_CODEC_HEADERS_COMMIT"
    git clone --filter=blob:none "$NV_CODEC_HEADERS_GIT_URL" "$WORK/src/nv-codec-headers"
    git -C "$WORK/src/nv-codec-headers" checkout --detach "$NV_CODEC_HEADERS_COMMIT"
    [[ $(git -C "$WORK/src/nv-codec-headers" rev-parse HEAD) == "$NV_CODEC_HEADERS_COMMIT" ]] || {
        printf 'nv-codec-headers pin mismatch.\n' >&2
        exit 3
    }
    make -C "$WORK/src/nv-codec-headers" PREFIX="$WORK/prefix" install
fi

printf 'Building FFmpeg %s\n' "$FFMPEG_VERSION"
curl --fail --location --proto '=https' --tlsv1.2 "$FFMPEG_URL" -o "$WORK/ffmpeg.tar.xz"
tar -xJf "$WORK/ffmpeg.tar.xz" -C "$WORK/src"
FFSRC="$WORK/src/ffmpeg-$FFMPEG_VERSION"
[[ -x $FFSRC/configure ]] || { printf 'Unexpected FFmpeg source archive layout.\n' >&2; exit 3; }

export PKG_CONFIG_PATH="$WORK/prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
COMMON_FLAGS=(
    --prefix="$WORK/ffmpeg-prefix"
    --disable-doc
    --disable-debug
    --disable-shared
    --enable-static
    --enable-libvmaf
)

case $(uname -s) in
    Linux)
        RPATH='-Wl,-rpath,$ORIGIN/../lib'
        pkg-config --exists libdrm libva && COMMON_FLAGS+=(--enable-libdrm --enable-vaapi)
        pkg-config --exists ffnvcodec && COMMON_FLAGS+=(--enable-nvenc --enable-cuvid)
        pkg-config --exists vpl && COMMON_FLAGS+=(--enable-libvpl)
        ;;
    Darwin)
        RPATH='-Wl,-rpath,@loader_path/../lib'
        COMMON_FLAGS+=(--enable-videotoolbox)
        ;;
    *)
        printf 'Unsupported release-build host: %s\n' "$(uname -s)" >&2
        exit 2
        ;;
esac

(
    cd "$FFSRC"
    ./configure "${COMMON_FLAGS[@]}" \
        --extra-cflags="-I$WORK/prefix/include" \
        --extra-ldflags="-L$WORK/prefix/lib $RPATH"
    make -j "$JOBS" ffmpeg ffprobe
)

cp -- "$FFSRC/ffmpeg" "$OUT/runtime/bin/ffmpeg"
cp -- "$FFSRC/ffprobe" "$OUT/runtime/bin/ffprobe"
if [[ $(uname -s) == Darwin ]]; then
    cp -P -- "$WORK/prefix/lib/"libvmaf*.dylib "$OUT/runtime/lib/"
else
    cp -P -- "$WORK/prefix/lib/"libvmaf.so* "$OUT/runtime/lib/"
fi
cp -- "$FFSRC/LICENSE.md" "$OUT/runtime/licenses/FFmpeg-LICENSE.md"
cp -- "$WORK/src/vmaf/LICENSE" "$OUT/runtime/licenses/VMAF-LICENSE"

if "$OUT/runtime/bin/ffmpeg" -hide_banner -buildconf 2>&1 | grep -F -- '--enable-nonfree' >/dev/null; then
    printf 'Refusing to package an FFmpeg build configured --enable-nonfree.\n' >&2
    exit 4
fi
if ! "$OUT/runtime/bin/ffmpeg" -hide_banner -filters 2>/dev/null | grep -E '(^|[[:space:]])libvmaf([[:space:]]|$)' >/dev/null; then
    printf 'Built FFmpeg does not expose libvmaf.\n' >&2
    exit 4
fi

FFMPEG_BUILD=$($OUT/runtime/bin/ffmpeg -hide_banner -version 2>&1 | head -n1)
cat > "$OUT/runtime/runtime-manifest.txt" <<EOF_MANIFEST
hca_media_runtime_revision=$HCA_MEDIA_RUNTIME_REVISION
ffmpeg_version=$FFMPEG_VERSION
ffmpeg_source=$FFMPEG_URL
ffmpeg_build=$FFMPEG_BUILD
vmaf_commit=$VMAF_COMMIT
vmaf_model_policy=$VMAF_MODEL_POLICY
nv_codec_headers_commit=${NV_CODEC_HEADERS_COMMIT:-none}
platform=$(uname -s)
architecture=$(uname -m)
EOF_MANIFEST

printf 'Runtime created at %s/runtime\n' "$OUT"
printf 'Run packaging/media-runtime/smoke-test.sh %q/runtime before publishing it.\n' "$OUT"
