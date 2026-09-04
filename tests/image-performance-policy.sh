#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
HELPER="$ROOT/lib/hardcore-archive-image-helper.sh"
CORE="$ROOT/lib/hardcore-archive-core.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-image-performance.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

bash -n "$HELPER"

mkdir -p "$TMP/bin" "$TMP/source" "$TMP/stage"
OXI_LOG="$TMP/oxipng.log"
export OXI_LOG
cat > "$TMP/bin/oxipng" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --help ]]; then
    cat <<'EOF'
  -t, --threads <num>
      --zopfli
      --zi <iterations>
      --ziwi <iterations>
      --timeout <secs>
EOF
    exit 0
fi
printf '%q ' "$@" >> "$OXI_LOG"
printf '\n' >> "$OXI_LOG"
target=${!#}
size=$(stat -c '%s' -- "$target")
if [[ " $* " == *" --zopfli "* ]]; then
    next=$((size - 4096))
else
    next=$((size * 9 / 10))
fi
(( next > 0 )) || next=1
truncate -s "$next" "$target"
SH
chmod +x "$TMP/bin/oxipng"

cat > "$TMP/bin/ffmpeg" <<'SH'
#!/usr/bin/env bash
printf 'pixel-hash-fixture\n'
SH
chmod +x "$TMP/bin/ffmpeg"

PATH="$TMP/bin:$PATH"
export PATH
truncate -s $((1024 * 1024)) "$TMP/source/test.png"
printf 'test.png\n' > "$TMP/list"

run_case() {
    local mode=$1
    : > "$OXI_LOG"
    : > "$TMP/result"
    rm -rf "$TMP/stage"; mkdir -p "$TMP/stage"
    bash "$HELPER" \
        --source-parent "$TMP/source" \
        --stage-parent "$TMP/stage" \
        --list "$TMP/list" \
        --result "$TMP/result" \
        --log "$TMP/helper.log" \
        --mode "$mode" \
        --jobs 1 \
        --threads-per-worker 6
}

run_case balanced
grep -Fq -- '--threads 6' "$OXI_LOG"
grep -Fq -- '-o 4' "$OXI_LOG"
! grep -Fq -- '--zopfli' "$OXI_LOG"
grep -Fq $'optimized\ttest.png\ttest.png' "$TMP/result"

run_case fast
grep -Fq -- '--threads 6' "$OXI_LOG"
grep -Fq -- '-o 2' "$OXI_LOG"
! grep -Fq -- '--zopfli' "$OXI_LOG"

run_case maximum
grep -Fq -- '-o 6' "$OXI_LOG"
grep -Fq -- '--threads 6' "$OXI_LOG"
grep -Fq -- '--zopfli' "$OXI_LOG"
grep -Fq -- '--zi 5' "$OXI_LOG"
grep -Fq -- '--ziwi 2' "$OXI_LOG"
grep -Fq 'oxipng-maximum+bounded-zopfli' "$TMP/result"

python3 - "$CORE" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text(encoding='utf-8')
assert 'IMAGE_THREADS_PER_WORKER=1' in text
assert 'IMAGE_THREADS_PER_WORKER=$((spare_image_threads / IMAGE_JOBS_EFFECTIVE))' in text
assert '--threads-per-worker "$IMAGE_THREADS_PER_WORKER"' in text
assert 'hardcore-archive-image-helper.sh' in text
PY

printf 'Adaptive OxiPNG policy tests passed.\n'
