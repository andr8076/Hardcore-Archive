#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
RUNNER="$ROOT/lib/hardcore-archive-resource-run.py"
POLICY="$ROOT/lib/resource-pool.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-resource-pool-test.XXXXXX")
cleanup() {
    jobs -pr | xargs -r kill 2>/dev/null || true
    rm -rf -- "$TMP"
}
trap cleanup EXIT

python3 -m py_compile "$RUNNER"
bash -n "$POLICY"
source "$POLICY"

[[ $(hardcore_resource_media_initial_cpu 16 2 100) == 14 ]]
[[ $(hardcore_resource_media_initial_cpu 16 2 0) == 16 ]]
[[ $(hardcore_resource_media_initial_ram 12000 9000 100) == 3000 ]]
[[ $(hardcore_resource_media_initial_ram 12000 9000 0) == 12000 ]]
HARDCORE_ARCHIVE_VIDEO_QUALITY_THREADS=auto
export HARDCORE_ARCHIVE_VIDEO_QUALITY_THREADS
[[ $(hardcore_resource_video_cpu_claim 16 required) == 10 ]]
[[ $(hardcore_resource_video_cpu_claim 4 required) == 4 ]]
[[ $(hardcore_resource_video_cpu_claim 16 off) == 2 ]]

# Flexible image-style claims consume the CPU currently exposed by the pool and
# publish the exact grant to the executed worker.
POOL="$TMP/flexible"
python3 "$RUNNER" init \
    --pool "$POOL" --cpu-initial 2 --cpu-max 4 \
    --ram-initial-mib 256 --ram-max-mib 1024
OUT="$TMP/flexible.out"; export OUT
python3 "$RUNNER" run \
    --pool "$POOL" --cpu-min 1 --cpu-max 4 --ram-mib 256 \
    --label image --priority low -- \
    sh -c 'printf "%s\t%s\n" "$HARDCORE_RESOURCE_GRANTED_CPU" "$HARDCORE_RESOURCE_GRANTED_RAM_MIB" > "$OUT"'
[[ $(cat "$OUT") == $'2\t256' ]]

# A lane that cannot fit the initial LZMA-reserved slice waits. Expanding the
# same pool after LZMA completion makes the blocked command runnable without
# restarting or changing its requested quality/thread settings.
POOL="$TMP/expand"
python3 "$RUNNER" init \
    --pool "$POOL" --cpu-initial 1 --cpu-max 4 \
    --ram-initial-mib 0 --ram-max-mib 1024
MARKER="$TMP/expanded.marker"; export MARKER
python3 "$RUNNER" run \
    --pool "$POOL" --cpu-min 2 --cpu-max 2 --ram-mib 256 \
    --label video --priority high -- \
    sh -c 'printf "%s\n" "$HARDCORE_RESOURCE_GRANTED_CPU" > "$MARKER"' &
blocked_pid=$!
sleep 0.20
[[ ! -e $MARKER ]]
python3 "$RUNNER" expand --pool "$POOL" --cpu-total 4 --ram-total-mib 1024
wait "$blocked_pid"
[[ $(cat "$MARKER") == 2 ]]

# Kernel-owned fcntl locks must be released after an interrupted holder so a
# later lane cannot be permanently starved by a crashed worker.
POOL="$TMP/crash"
python3 "$RUNNER" init \
    --pool "$POOL" --cpu-initial 1 --cpu-max 1 \
    --ram-initial-mib 256 --ram-max-mib 256
READY="$TMP/holder.ready"; export READY
python3 "$RUNNER" run \
    --pool "$POOL" --cpu-min 1 --cpu-max 1 --ram-mib 256 \
    --label holder -- \
    sh -c 'touch "$READY"; exec sleep 30' &
holder_pid=$!
for _ in $(seq 1 50); do [[ -e $READY ]] && break; sleep 0.02; done
[[ -e $READY ]]
kill "$holder_pid"
wait "$holder_pid" 2>/dev/null || true
RECOVERED="$TMP/recovered"; export RECOVERED
python3 "$RUNNER" run \
    --pool "$POOL" --cpu-min 1 --cpu-max 1 --ram-mib 256 \
    --label recovery --wait-timeout 2 -- \
    sh -c 'touch "$RECOVERED"'
[[ -e $RECOVERED ]]

# Impossible claims fail immediately instead of waiting forever for capacity
# that the pool can never expose.
set +e
python3 "$RUNNER" run \
    --pool "$POOL" --cpu-min 2 --cpu-max 2 --ram-mib 0 \
    --label impossible --wait-timeout 1 -- true >/dev/null 2>&1
impossible_rc=$?
set -e
[[ $impossible_rc != 0 ]]

# RAM capacity rounds down, while claims round up.
POOL="$TMP/ram-rounding"
python3 "$RUNNER" init \
    --pool "$POOL" --cpu-initial 1 --cpu-max 1 \
    --ram-initial-mib 65 --ram-max-mib 300
set +e
python3 "$RUNNER" run \
    --pool "$POOL" --cpu-min 1 --cpu-max 1 --ram-mib 128 \
    --label rounding-block --wait-timeout 0.2 -- true >/dev/null 2>&1
rounding_rc=$?
set -e
[[ $rounding_rc != 0 ]]
python3 "$RUNNER" expand --pool "$POOL" --cpu-total 1 --ram-total-mib 130
ROUNDING_OUT="$TMP/rounding.out"; export ROUNDING_OUT
python3 "$RUNNER" run \
    --pool "$POOL" --cpu-min 1 --cpu-max 1 --ram-mib 128 \
    --label rounding-pass --wait-timeout 2 -- \
    sh -c 'printf "%s\n" "$HARDCORE_RESOURCE_GRANTED_RAM_MIB" > "$ROUNDING_OUT"'
[[ $(cat "$ROUNDING_OUT") == 128 ]]

printf 'Shared resource-pool tests passed.\n'
