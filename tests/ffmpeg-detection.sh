#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
BASE="$ROOT/lib/hardcore-archive-doctor-base.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-ffmpeg-detect.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/ffmpeg" <<'EOF_FFMPEG'
#!/usr/bin/env bash
case " $* " in
    *" -filters "*)
        printf 'Filters:\n'
        printf ' .. libvmaf           VV->V      Calculate VMAF.\n'
        # Keep writing well after the wanted entry. grep -q based detection can
        # SIGPIPE this producer under pipefail and falsely report no match.
        for ((i=0; i<50000; i++)); do printf ' .. filler_filter_%05d V->V filler\n' "$i"; done
        ;;
    *" -encoders "*)
        printf 'Encoders:\n'
        printf ' V..... av1_vaapi           AV1 VAAPI\n'
        for ((i=0; i<50000; i++)); do printf ' V..... filler_encoder_%05d filler\n' "$i"; done
        ;;
    *) exit 0 ;;
esac
EOF_FFMPEG
chmod +x "$TMP/bin/ffmpeg"

PATH="$TMP/bin:$PATH"
export PATH
# shellcheck source=/dev/null
source "$BASE"

filter_available libvmaf || { printf 'libvmaf false-negative under pipefail.\n' >&2; exit 1; }
encoder_available av1_vaapi || { printf 'av1_vaapi false-negative under pipefail.\n' >&2; exit 1; }
! filter_available definitely_missing_filter || { printf 'Missing filter falsely detected.\n' >&2; exit 1; }
! encoder_available definitely_missing_encoder || { printf 'Missing encoder falsely detected.\n' >&2; exit 1; }

printf 'FFmpeg table detection tests passed.\n'
