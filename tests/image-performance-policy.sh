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

# Automatic dispatch is CPU-bounded only. RAM is enforced by the shared pool,
# so changing available RAM must not silently reduce JPEG/file parallelism.
source "$IMAGES"
[[ $(hardcore_images_compute_cpu_schedule 16 100 auto 8192) == $'16\t1\t16' ]]
[[ $(hardcore_images_compute_cpu_schedule 16 100 auto 1024) == $'16\t1\t16' ]]
[[ $(hardcore_images_compute_cpu_schedule 16 1 auto 8192) == $'1\t16\t16' ]]
[[ $(hardcore_images_compute_cpu_schedule 64 100 auto 4096) == $'64\t1\t64' ]]
[[ $(hardcore_images_compute_cpu_schedule 12 100 3 8192) == $'3\t4\t12' ]]
[[ $(hardcore_images_compute_cpu_schedule 16 100 16 4096) == $'16\t1\t16' ]]
[[ $(hardcore_images_worker_cap 64 4096) == 64 ]]
[[ $(hardcore_images_png_fallback_threads 8 2 8 auto) == 4 ]]
[[ $(hardcore_images_png_fallback_threads 8 100 8 auto) == 1 ]]
[[ $(hardcore_images_png_fallback_threads 8 10 3 3) == 3 ]]

mkdir -p "$TMP/bin" "$TMP/source" "$TMP/stage"
OXI_LOG="$TMP/oxipng.log"
NICE_LOG="$TMP/nice.log"
CLAIM_LOG="$TMP/claims.log"
export OXI_LOG NICE_LOG CLAIM_LOG
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

cat > "$TMP/bin/djpeg" <<'SH'
#!/usr/bin/env bash
printf 'jpeg-pixel-hash-fixture\n'
SH
chmod +x "$TMP/bin/djpeg"

cat > "$TMP/bin/jpegtran" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
input=${!#}
size=$(stat -c '%s' -- "$input")
next=$((size * 9 / 10))
head -c "$next" -- "$input"
SH
chmod +x "$TMP/bin/jpegtran"

cat > "$TMP/bin/nice" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$NICE_LOG"
printf '\n' >> "$NICE_LOG"
if [[ ${1:-} == -n ]]; then shift 2; fi
exec "$@"
SH
chmod +x "$TMP/bin/nice"

cat > "$TMP/fake-resource-run.py" <<'PY'
#!/usr/bin/env python3
import os, sys
args=sys.argv[1:]
def value(flag):
    return args[args.index(flag)+1]
minimum=value('--cpu-min'); maximum=value('--cpu-max'); label=value('--label')
with open(os.environ['CLAIM_LOG'],'a',encoding='utf-8') as handle:
    handle.write(f'{label}\t{minimum}\t{maximum}\n')
sep=args.index('--')
command=args[sep+1:]
env=os.environ.copy(); env['HARDCORE_RESOURCE_GRANTED_CPU']=maximum
os.execvpe(command[0],command,env)
PY
chmod +x "$TMP/fake-resource-run.py"

PATH="$TMP/bin:$PATH"
export PATH
# Keep the large synthetic payload used by the optimization-policy test, but
# give it a real PNG signature + IHDR so production header validation is tested
# instead of relying on an all-zero file merely named .png.
python3 - "$TMP/source/test.png" <<'PY'
from pathlib import Path
import struct, sys
path = Path(sys.argv[1])
size = 1024 * 1024
signature = b'\x89PNG\r\n\x1a\n'
ihdr = struct.pack('>I', 13) + b'IHDR' + struct.pack('>IIBBBBB', 16, 16, 8, 2, 0, 0, 0)
prefix = signature + ihdr
path.write_bytes(prefix + b'\0' * (size - len(prefix)))
PY
truncate -s $((1024 * 1024)) "$TMP/source/test.jpg"
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
grep -Fq -- '--zi 1' "$OXI_LOG"
grep -Fq -- '--zi 5' "$OXI_LOG"
grep -Fq -- '--ziwi 2' "$OXI_LOG"
grep -Fq 'oxipng-maximum+adaptive-zopfli-strong' "$TMP/result"
grep -Fq 'Zopfli adaptive summary: attempts=1' "$TMP/helper.log"
grep -Fq 'extra_bytes_per_second=' "$TMP/helper.log"

# Actual resource-pool integration: only two CPU tokens are initially exposed,
# so a PNG with a six-CPU ceiling must consume the actual two-CPU grant.
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

# Heterogeneous claims: JPEG is exactly 1 CPU, while PNG is a flexible 1..4
# request. A fake runner records the claim shape before directly executing it.
printf 'test.jpg\ntest.png\n' > "$TMP/mixed-list"
: > "$CLAIM_LOG"
: > "$OXI_LOG"
: > "$TMP/result"
rm -rf "$TMP/stage"; mkdir -p "$TMP/stage"
bash "$HELPER" \
    --source-parent "$TMP/source" \
    --stage-parent "$TMP/stage" \
    --list "$TMP/mixed-list" \
    --result "$TMP/result" \
    --log "$TMP/helper.log" \
    --mode balanced \
    --jobs 2 \
    --threads-per-worker 4 \
    --resource-pool "$TMP/dummy-pool" \
    --resource-runner "$TMP/fake-resource-run.py"
grep -Fxq $'image-jpeg\t1\t1' "$CLAIM_LOG"
grep -Fxq $'image-png\t1\t4' "$CLAIM_LOG"
grep -Fq -- '--threads 4' "$OXI_LOG"
grep -Fq $'optimized\ttest.jpg\ttest.jpg' "$TMP/result"
grep -Fq $'optimized\ttest.png\ttest.png' "$TMP/result"

python3 - "$CORE" "$HELPER" <<'PY'
from pathlib import Path
import sys
core = Path(sys.argv[1]).read_text(encoding='utf-8')
helper = Path(sys.argv[2]).read_text(encoding='utf-8')
assert 'source "$(dirname -- "${BASH_SOURCE[0]}")/images.sh"' in core
assert 'hardcore_images_choose_cpu_schedule' in core
assert 'IMAGE_SCHEDULER_SOURCE' in core
assert 'HARDCORE_ARCHIVE_IMAGE_SCHEDULER_CACHE_DIR' in core
assert '--threads-per-worker "$IMAGE_THREADS_PER_WORKER"' in core
assert 'hardcore-archive-image-helper.sh' in core
assert 'hardcore-archive-zopfli-adaptive.py' in helper
assert "worker_label='image-jpeg'" in helper
assert "worker_label='image-png'" in helper
assert '--cpu-min 1' in helper
assert '--cpu-max "$worker_cpu_max"' in helper
PY

printf 'Heterogeneous image scheduling tests passed.\n'
