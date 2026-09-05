#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
HELPER="$ROOT/lib/hardcore-archive-image-helper.sh"
CORE="$ROOT/lib/hardcore-archive-core.sh"
IMAGES="$ROOT/lib/images.sh"
RUNNER="$ROOT/lib/hardcore-archive-resource-run.py"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-image-performance.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

bash -n "$HELPER"
bash -n "$IMAGES"

# The deterministic fallback still covers the complete logical CPU budget while
# scaling process fan-out to available RAM. Machine calibration may replace the
# automatic split at runtime, but explicit jobs continue to use this policy.
source "$IMAGES"
[[ $(hardcore_images_compute_cpu_schedule 16 100 auto 8192) == $'8\t2\t16' ]]
[[ $(hardcore_images_compute_cpu_schedule 16 1 auto 8192) == $'1\t16\t16' ]]
[[ $(hardcore_images_compute_cpu_schedule 64 100 auto 65536) == $'32\t2\t64' ]]
[[ $(hardcore_images_compute_cpu_schedule 12 100 3 8192) == $'3\t4\t12' ]]
[[ $(hardcore_images_compute_cpu_schedule 16 100 16 4096) == $'4\t4\t16' ]]
[[ $(hardcore_images_worker_cap 64 4096) == 4 ]]

mkdir -p "$TMP/bin" "$TMP/source" "$TMP/stage"
OXI_LOG="$TMP/oxipng.log"
NICE_LOG="$TMP/nice.log"
export OXI_LOG NICE_LOG
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

cat > "$TMP/bin/nice" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$NICE_LOG"
printf '\n' >> "$NICE_LOG"
if [[ ${1:-} == -n ]]; then shift 2; fi
exec "$@"
SH
chmod +x "$TMP/bin/nice"

PATH="$TMP/bin:$PATH"
export PATH
truncate -s $((1024 * 1024)) "$TMP/source/test.png"
printf 'test.png\n' > "$TMP/list"

run_case() {
    local mode=$1
    : > "$OXI_LOG"
    : > "$NICE_LOG"
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
grep -Fq -- '-n 5' "$NICE_LOG"
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

RESOURCE_POOL="$TMP/image-resource-pool"
python3 "$RUNNER" init \
    --pool "$RESOURCE_POOL" --cpu-initial 2 --cpu-max 6 \
    --ram-initial-mib 256 --ram-max-mib 1024
: > "$OXI_LOG"
: > "$NICE_LOG"
: > "$TMP/result"
rm -rf "$TMP/stage"; mkdir -p "$TMP/stage"
bash "$HELPER" \
    --source-parent "$TMP/source" \
    --stage-parent "$TMP/stage" \
    --list "$TMP/list" \
    --result "$TMP/result" \
    --log "$TMP/helper.log" \
    --mode balanced \
    --jobs 1 \
    --threads-per-worker 6 \
    --resource-pool "$RESOURCE_POOL" \
    --resource-runner "$RUNNER"
grep -Fq -- '--threads 2' "$OXI_LOG"
! grep -Fq -- '--threads 6' "$OXI_LOG"

python3 - "$CORE" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text(encoding='utf-8')
assert 'source "$(dirname -- "${BASH_SOURCE[0]}")/images.sh"' in text
assert 'hardcore_images_choose_cpu_schedule' in text
assert 'IMAGE_SCHEDULER_SOURCE' in text
assert 'HARDCORE_ARCHIVE_IMAGE_SCHEDULER_CACHE_DIR' in text
assert '--threads-per-worker "$IMAGE_THREADS_PER_WORKER"' in text
assert 'hardcore-archive-image-helper.sh' in text
PY

printf 'Calibrated OxiPNG policy tests passed.\n'