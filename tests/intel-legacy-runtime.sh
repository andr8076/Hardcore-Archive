#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TOOLS="$ROOT/packaging/intel-legacy-runtime"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
RUNTIME="$TMP/runtime"
FAKES="$TMP/fakes"
mkdir -p "$RUNTIME/bin" "$RUNTIME/lib" "$FAKES"

printf '%s\n' \
    'runtime_format=2' \
    'runtime_kind=intel-media-sdk-legacy' \
    'lifecycle=discontinued-unmaintained-compatibility-only' \
    'ffmpeg_legacy_hevc_extopts=disabled' \
    > "$RUNTIME/runtime-manifest.txt"
: > "$RUNTIME/lib/libmfx.so.1"
: > "$RUNTIME/lib/libmfxhw64.so.1"

cat > "$RUNTIME/bin/ffmpeg" <<'EOF_FFMPEG'
#!/usr/bin/env bash
case " $* " in
    *' -buildconf '*)
        printf '%s\n' 'configuration:' '    --enable-libmfx' '    --disable-libvpl'
        [[ ${HCA_FAKE_MODE:-} != build-vpl ]] || printf '%s\n' '    --enable-libvpl'
        ;;
    *' -encoders '*) printf ' V..... hevc_qsv Intel QSV HEVC encoder\n' ;;
    *) printf 'fake ffmpeg\n' ;;
esac
EOF_FFMPEG
cat > "$FAKES/readelf" <<'EOF_READELF'
#!/usr/bin/env bash
printf ' 0x0000000000000001 (NEEDED) Shared library: [libmfx.so.1]\n'
[[ ${HCA_FAKE_MODE:-} != dynamic-vpl ]] || printf ' 0x0000000000000001 (NEEDED) Shared library: [libvpl.so.2]\n'
EOF_READELF
cat > "$FAKES/ldd" <<'EOF_LDD'
#!/usr/bin/env bash
if [[ ${HCA_FAKE_MODE:-} == outside ]]; then
    printf 'libmfx.so.1 => /usr/lib/libmfx.so.1 (0x1)\n'
else
    printf 'libmfx.so.1 => %s/lib/libmfx.so.1 (0x1)\n' "$HCA_FAKE_RUNTIME"
fi
[[ ${HCA_FAKE_MODE:-} != linked-vpl ]] || printf 'libvpl.so.2 => /usr/lib/libvpl.so.2 (0x2)\n'
EOF_LDD
chmod +x "$RUNTIME/bin/ffmpeg" "$FAKES/readelf" "$FAKES/ldd"

inspect() {
    HCA_FAKE_RUNTIME="$RUNTIME" \
    HCA_LEGACY_READELF="$FAKES/readelf" \
    HCA_LEGACY_LDD="$FAKES/ldd" \
        bash "$TOOLS/inspect.sh" "$RUNTIME"
}
expect_failure() {
    local mode=$1 pattern=$2 output
    if output=$(HCA_FAKE_MODE="$mode" inspect 2>&1); then
        printf 'Expected inspector failure for mode %s\n' "$mode" >&2
        exit 1
    fi
    grep -Fq "$pattern" <<< "$output" || {
        printf 'Wrong failure for mode %s: %s\n' "$mode" "$output" >&2
        exit 1
    }
}

inspect | grep -Fq 'READY Runtime integrity'

# GitHub source ZIPs and some copy tools discard executable mode bits.
TOOL_COPY="$TMP/tool-copy"
mkdir -p "$TOOL_COPY"
cp -- "$TOOLS/inspect.sh" "$TOOLS/with-runtime.sh" "$TOOL_COPY/"
chmod 0644 "$TOOL_COPY/inspect.sh" "$TOOL_COPY/with-runtime.sh"
HCA_FAKE_RUNTIME="$RUNTIME" \
HCA_LEGACY_READELF="$FAKES/readelf" \
HCA_LEGACY_LDD="$FAKES/ldd" \
    bash "$TOOL_COPY/inspect.sh" "$RUNTIME" | grep -Fq 'READY Runtime integrity'

expect_failure build-vpl 'built with oneVPL'
expect_failure dynamic-vpl 'links to oneVPL'
expect_failure linked-vpl 'oneVPL was resolved'
expect_failure outside 'resolved outside'

mv "$RUNTIME/lib/libmfxhw64.so.1" "$TMP/libmfxhw64.so.1"
expect_failure missing-hardware 'libmfxhw64.so.1 is missing'
mv "$TMP/libmfxhw64.so.1" "$RUNTIME/lib/libmfxhw64.so.1"

export INTEL_MEDIA_RUNTIME=ONEVPL
export LD_LIBRARY_PATH=/host/library/path
CHILD=$("$TOOLS/with-runtime.sh" "$RUNTIME" bash -c 'printf "%s|%s" "$INTEL_MEDIA_RUNTIME" "$LD_LIBRARY_PATH"')
[[ $CHILD == "MSDK|$RUNTIME/lib" ]] || {
    printf 'Wrapper did not isolate the legacy child environment: %s\n' "$CHILD" >&2
    exit 1
}
[[ $INTEL_MEDIA_RUNTIME == ONEVPL && $LD_LIBRARY_PATH == /host/library/path ]] || {
    printf 'Wrapper leaked legacy configuration into the parent shell.\n' >&2
    exit 1
}

grep -Fq 'INTEL_MEDIA_RUNTIME=MSDK' "$TOOLS/with-runtime.sh"
! grep -Rq 'LIBVA_DRIVER_NAME=' "$TOOLS"
grep -Fq -- '--disable-libvpl' "$TOOLS/build.sh"
grep -Fq -- '--enable-libmfx' "$TOOLS/build.sh"
grep -Fq 'ffmpeg-hevc-legacy-no-extopts.patch' "$TOOLS/build.sh"
grep -Fq 'avctx->codec_id != AV_CODEC_ID_HEVC' "$TOOLS/ffmpeg-hevc-legacy-no-extopts.patch"
grep -Fq 'libmfxhw64.so.1' "$TOOLS/inspect.sh"
grep -Fq 'full_decode=ok' "$TOOLS/prove-p530.sh"
grep -Fq 'EXPECTED_REFERENCE_BYTES=' "$TOOLS/prove-p530.sh"
grep -Fq -- '-f rawvideo -pixel_format nv12' "$TOOLS/prove-p530.sh"
grep -Fq -- '-load_plugin hevc_hw -low_power 0' "$TOOLS/prove-p530.sh"
grep -Fq 'ENCODE_STATUS=${PIPESTATUS[0]}' "$TOOLS/prove-p530.sh"
grep -Fq 'LD_LIBRARY_PATH="$RUNTIME/lib"' "$TOOLS/prove-p530.sh"
grep -Fq 'Use Intel(R) Media SDK to create MFX session' "$TOOLS/prove-p530.sh"
grep -Fq 'hardware accelerated implementation' "$TOOLS/prove-p530.sh"
! grep -Fq 'LD_DEBUG=' "$TOOLS/prove-p530.sh"
grep -Fq 'Production AUTO integration remains a separate gated change' "$TOOLS/prove-p530.sh"

printf 'Intel legacy runtime isolation tests passed.\n'
