#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
HELPER="$ROOT/lib/hardcore-archive-image-helper.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-png-validation.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

bash -n "$HELPER"
mkdir -p "$TMP/bin"
FFMPEG_LOG="$TMP/ffmpeg.log"
export FFMPEG_LOG

# Extract only the hash helpers. The executable image helper intentionally runs
# its worker/main dispatcher when sourced, so the test stops before that code.
awk '/^oxipng_supports\(\)/ {exit} {print}' "$HELPER" > "$TMP/png-hash-lib.sh"

cat > "$TMP/bin/sha256sum" <<'PY'
#!/usr/bin/env python3
import hashlib, sys
print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest(), ' -')
PY
chmod +x "$TMP/bin/sha256sum"

cat > "$TMP/bin/ffmpeg" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
input=''
pixel_format=''
printf '%q ' "$@" >> "$FFMPEG_LOG"
printf '\n' >> "$FFMPEG_LOG"
while (( $# > 0 )); do
    case "$1" in
        -i) input=$2; shift 2 ;;
        -pix_fmt) pixel_format=$2; shift 2 ;;
        *) shift ;;
    esac
done
base=${input##*/}
case $base in
    mismatch-a.png) printf 'canonical-mismatch-a\n'; exit 0 ;;
    mismatch-b.png) printf 'canonical-mismatch-b\n'; exit 0 ;;
esac
if [[ -n $pixel_format ]]; then
    printf 'canonical-%s\n' "$pixel_format"
else
    # Model the bug from the real benchmark: native FFmpeg frame data differs
    # when the same rendered pixels use RGB versus palette/grayscale storage.
    printf 'native-%s\n' "$base"
fi
SH
chmod +x "$TMP/bin/ffmpeg"

PATH="$TMP/bin:$PATH"
export PATH
source "$TMP/png-hash-lib.sh"

make_png_header() {
    local path=$1 depth=$2 color_type=$3
    python3 - "$path" "$depth" "$color_type" <<'PY'
from pathlib import Path
import struct, sys
path = Path(sys.argv[1])
depth = int(sys.argv[2])
color_type = int(sys.argv[3])
signature = b'\x89PNG\r\n\x1a\n'
ihdr = struct.pack('>I', 13) + b'IHDR' + struct.pack('>IIBBBBB', 16, 16, depth, color_type, 0, 0, 0)
path.write_bytes(signature + ihdr)
PY
}

make_png_header "$TMP/rgb8.png" 8 2
make_png_header "$TMP/palette8.png" 8 3
make_png_header "$TMP/palette4.png" 4 3
make_png_header "$TMP/rgb16.png" 16 2
make_png_header "$TMP/mismatch-a.png" 8 2
make_png_header "$TMP/mismatch-b.png" 8 3
printf 'not a png\n' > "$TMP/invalid.png"

[[ $(png_bit_depth "$TMP/rgb8.png") == 8 ]]
[[ $(png_bit_depth "$TMP/palette8.png") == 8 ]]
[[ $(png_bit_depth "$TMP/palette4.png") == 4 ]]
[[ $(png_bit_depth "$TMP/rgb16.png") == 16 ]]
! png_bit_depth "$TMP/invalid.png" >/dev/null 2>&1

# Prove the old/native representation is different for these equivalent fixture
# identities. The production validator must no longer compare this representation.
native_rgb=$(ffmpeg -i "$TMP/rgb8.png")
native_palette=$(ffmpeg -i "$TMP/palette8.png")
[[ $native_rgb != "$native_palette" ]]

: > "$FFMPEG_LOG"
rgb_hash=$(png_pixel_hash "$TMP/rgb8.png")
palette_hash=$(png_pixel_hash "$TMP/palette8.png")
palette4_hash=$(png_pixel_hash "$TMP/palette4.png")
[[ $rgb_hash == "$palette_hash" ]]
[[ $rgb_hash == "$palette4_hash" ]]
grep -Fq -- '-pix_fmt rgba' "$FFMPEG_LOG"
! grep -Fq -- '-pix_fmt rgba64le' "$FFMPEG_LOG"

# 16-bit inputs are deliberately isolated from the 8-bit canonical path so a
# high-precision source can never pass merely because an 8-bit projection matches.
: > "$FFMPEG_LOG"
png_pixel_hash "$TMP/rgb16.png" >/dev/null
grep -Fq -- '-pix_fmt rgba64le' "$FFMPEG_LOG"

# Canonicalization must not turn validation into a rubber stamp. Distinct decoded
# pixel streams still produce distinct hashes and therefore remain rejectable.
mismatch_a=$(png_pixel_hash "$TMP/mismatch-a.png")
mismatch_b=$(png_pixel_hash "$TMP/mismatch-b.png")
[[ $mismatch_a != "$mismatch_b" ]]

printf 'Canonical PNG pixel validation tests passed.\n'
