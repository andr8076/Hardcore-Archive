#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-intel-bootstrap.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT
TARGET=linux-x86_64
RELEASE="$TMP/release"
PAYLOAD="$TMP/payload/runtime"
FAKES="$TMP/fakes"
mkdir -p "$RELEASE" "$PAYLOAD/bin" "$PAYLOAD/lib" "$PAYLOAD/licenses" "$FAKES" "$TMP/home"

printf '%s\n' \
  'runtime_format=2' \
  'runtime_kind=intel-media-sdk-legacy' \
  'ffmpeg_legacy_hevc_extopts=disabled' > "$PAYLOAD/runtime-manifest.txt"
: > "$PAYLOAD/lib/libmfx.so.1"
: > "$PAYLOAD/lib/libmfxhw64.so.1"
cat > "$PAYLOAD/bin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *' -buildconf '*) printf '%s\n' configuration: ' --enable-libmfx' ' --disable-libvpl' ;;
  *' -encoders '*) printf ' V..... hevc_qsv Intel QSV HEVC encoder\n' ;;
  *) printf 'ffmpeg version bootstrap-test\n' ;;
esac
EOF
cat > "$PAYLOAD/bin/ffprobe" <<'EOF'
#!/usr/bin/env bash
printf 'ffprobe version bootstrap-test\n'
EOF
cat > "$FAKES/readelf" <<'EOF'
#!/usr/bin/env bash
printf ' 0x1 (NEEDED) Shared library: [libmfx.so.1]\n'
EOF
cat > "$FAKES/ldd" <<'EOF'
#!/usr/bin/env bash
ffmpeg=${!#}
runtime=$(cd -- "$(dirname -- "$ffmpeg")/.." && pwd -P)
printf 'libmfx.so.1 => %s/lib/libmfx.so.1 (0x1)\n' "$runtime"
EOF
chmod +x "$PAYLOAD/bin/ffmpeg" "$PAYLOAD/bin/ffprobe" "$FAKES/readelf" "$FAKES/ldd"

SHA=0123456789abcdef0123456789abcdef01234567
ASSET="hardcore-archive-intel-legacy-runtime-$TARGET-$SHA.tar.gz"
tar -C "$TMP/payload" -czf "$RELEASE/$ASSET" runtime
sha256sum "$RELEASE/$ASSET" > "$RELEASE/$ASSET.sha256"
printf '%s\n' "$ASSET" > "$RELEASE/hardcore-archive-intel-legacy-runtime-$TARGET.current"

PKG="$TMP/intel-media-va-driver-non-free_1.2.3_amd64.deb"
mkdir -p "$TMP/pkg/DEBIAN" "$TMP/pkg/usr/lib/x86_64-linux-gnu/dri" "$TMP/pkg/usr/share/doc/intel-media-va-driver-non-free"
printf 'Package: intel-media-va-driver-non-free\nVersion: 1.2.3\nArchitecture: amd64\nMaintainer: Test <test@example.invalid>\nDescription: test\n' > "$TMP/pkg/DEBIAN/control"
printf 'full-feature-driver\n' > "$TMP/pkg/usr/lib/x86_64-linux-gnu/dri/iHD_drv_video.so"
printf 'test package copyright\n' > "$TMP/pkg/usr/share/doc/intel-media-va-driver-non-free/copyright"
dpkg-deb --build "$TMP/pkg" "$PKG" >/dev/null

source "$ROOT/lib/runtime.sh"
source "$ROOT/lib/intel-legacy-video.sh"
hardcore_runtime_download() {
    local output=$2
    cp -- "$RELEASE/${1##*/}" "$output"
    printf '%s\n' "${1##*/}" >> "$TMP/downloads.log"
}

export HOME="$TMP/home" XDG_CACHE_HOME="$TMP/cache" HARDCORE_ARCHIVE_ROOT="$ROOT"
export HARDCORE_ARCHIVE_INTEL_LEGACY_RELEVANT=1 HARDCORE_ARCHIVE_INTEL_LEGACY_AUTO_SETUP=1
export HARDCORE_ARCHIVE_INTEL_LEGACY_DRIVER_DEB="$PKG"
export HCA_LEGACY_READELF="$FAKES/readelf" HCA_LEGACY_LDD="$FAKES/ldd"
unset HARDCORE_ARCHIVE_INTEL_LEGACY_RUNTIME HARDCORE_ARCHIVE_INTEL_LEGACY_VA_DRIVER_DIR

hardcore_intel_legacy_discover
CACHED="$TMP/cache/hardcore-archive/intel-legacy-runtime/$TARGET/runtime"
[[ $HARDCORE_INTEL_LEGACY_RUNTIME_RESOLVED == "$CACHED" ]]
[[ -r $CACHED/lib/dri/iHD_drv_video.so ]]
grep -Fqx 'package=intel-media-va-driver-non-free' "$CACHED/lib/dri/driver-manifest.txt"
grep -Fqx 'version=1.2.3' "$CACHED/lib/dri/driver-manifest.txt"
[[ $(grep -Fxc "$ASSET" "$TMP/downloads.log") == 1 ]]
[[ ${LIBVA_DRIVER_NAME:-} == '' && ${INTEL_MEDIA_RUNTIME:-} == '' ]]

# A cached stack is stable and does not redownload on the next discovery.
hardcore_intel_legacy_discover
[[ $(grep -Fxc "$ASSET" "$TMP/downloads.log") == 1 ]]

# A mismatched release checksum fails closed and leaves no executable cache.
cp -a -- "$RELEASE" "$TMP/bad-release"
printf '%064d  %s\n' 0 "$ASSET" > "$TMP/bad-release/$ASSET.sha256"
(
  RELEASE="$TMP/bad-release"
  export XDG_CACHE_HOME="$TMP/bad-cache"
  if hardcore_intel_legacy_bootstrap_runtime; then exit 1; fi
  [[ $HARDCORE_INTEL_LEGACY_ERROR == *'checksum did not match'* ]]
  [[ ! -x "$TMP/bad-cache/hardcore-archive/intel-legacy-runtime/$TARGET/runtime/bin/ffmpeg" ]]
)

# Disabling automatic setup leaves an empty cache untouched.
(
  export XDG_CACHE_HOME="$TMP/disabled-cache" HARDCORE_ARCHIVE_INTEL_LEGACY_AUTO_SETUP=0
  unset HARDCORE_ARCHIVE_INTEL_LEGACY_RUNTIME HARDCORE_ARCHIVE_INTEL_LEGACY_VA_DRIVER_DIR
  HARDCORE_INTEL_LEGACY_RUNTIME_RESOLVED=''
  if hardcore_intel_legacy_discover; then exit 1; fi
  [[ ! -e "$TMP/disabled-cache/hardcore-archive/intel-legacy-runtime" ]]
)

printf 'Intel legacy automatic bootstrap tests passed.\n'
