#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
POLICY="$ROOT/lib/resource-pool.sh"
RUNNER="$ROOT/lib/hardcore-archive-resource-run.py"
NESTED="$ROOT/lib/nested.sh"
WORKER="$ROOT/lib/hardcore-archive-nested-worker.sh"
CORE="$ROOT/lib/hardcore-archive-core.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-nested-parallel.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

bash -n "$NESTED"
bash -n "$WORKER"
source "$POLICY"

mkdir -p "$TMP/source" "$TMP/work" "$TMP/output" "$TMP/bin"
truncate -s 100000 "$TMP/source/a.zip"
truncate -s 100000 "$TMP/source/b.zip"
printf 'source/a.zip\nsource/b.zip\n' > "$TMP/nested.list"

cat > "$TMP/bin/fake7z" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case ${1:-} in
    l)
        printf 'Path = payload.bin\nSize = 1048576\nEncrypted = -\n'
        ;;
    a|t|x) : ;;
    *) : ;;
esac
SH
chmod +x "$TMP/bin/fake7z"

# The fake worker deliberately finishes b before a. It still runs through the
# real shared pool, records its actual token grant, and creates a valid smaller
# staged candidate/result row.
cat > "$TMP/fake-worker.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
relative=''; output=''; stage=''; result=''; log=''
while (( $# > 0 )); do
    case "$1" in
        --relative) relative=$2; shift 2 ;;
        --output-rel) output=$2; shift 2 ;;
        --stage-parent) stage=$2; shift 2 ;;
        --result) result=$2; shift 2 ;;
        --log) log=$2; shift 2 ;;
        --) break ;;
        *) shift; [[ $# -gt 0 && ${1:-} != --* ]] && shift || true ;;
    esac
done
{
    flock 9
    active=$(cat "$EVENT_DIR/active" 2>/dev/null || printf 0)
    active=$((active + 1)); printf '%s\n' "$active" > "$EVENT_DIR/active"
    maximum=$(cat "$EVENT_DIR/max" 2>/dev/null || printf 0)
    (( active > maximum )) && printf '%s\n' "$active" > "$EVENT_DIR/max"
    printf 'start\t%s\t%s\t%s\n' "$relative" "$HARDCORE_RESOURCE_GRANTED_CPU" "$HARDCORE_RESOURCE_GRANTED_RAM_MIB" >> "$EVENT_DIR/events"
} 9>"$EVENT_DIR/lock"
case $relative in *a.zip) sleep 0.40 ;; *) sleep 0.10 ;; esac
mkdir -p -- "$(dirname -- "$stage/$output")" "$(dirname -- "$result")"
truncate -s 50000 "$stage/$output"
printf 'repacked\t%s\t%s\t100000\t50000\t50000\tcandidate-smaller\n' "$relative" "$output" > "$result"
printf 'fake worker complete: %s\n' "$relative" >> "$log"
{
    flock 9
    active=$(cat "$EVENT_DIR/active")
    active=$((active - 1)); printf '%s\n' "$active" > "$EVENT_DIR/active"
    printf 'end\t%s\n' "$relative" >> "$EVENT_DIR/events"
} 9>"$EVENT_DIR/lock"
SH
chmod +x "$TMP/fake-worker.sh"

EVENT_DIR="$TMP/events"; export EVENT_DIR
mkdir -p "$EVENT_DIR"; printf '0\n' > "$EVENT_DIR/active"; printf '0\n' > "$EVENT_DIR/max"; : > "$EVENT_DIR/events"
RESOURCE_POOL_DIR="$TMP/pool"
python3 "$RUNNER" init --pool "$RESOURCE_POOL_DIR" --cpu-initial 4 --cpu-max 4 --ram-initial-mib 2048 --ram-max-mib 2048

MIB=$((1024 * 1024))
NESTED_COUNT=2
NESTED_BYTES=200000
NESTED_REPACK=true
NESTED_MAX_DEPTH=3
NESTED_LIST="$TMP/nested.list"
NESTED_RESULT_MANIFEST="$TMP/nested-results.tsv"
NESTED_REPACKED_LIST="$TMP/nested-repacked.list"
NESTED_FALLBACK_LIST="$TMP/nested-fallback.list"
NESTED_MANIFEST_FILE="$TMP/nested-manifest.tsv"
NESTED_STAGE_PARENT=''
NESTED_REPACKED_COUNT=0
NESTED_FALLBACK_COUNT=0
NESTED_SAVED_BYTES=0
SOURCE_PARENT="$TMP"
SOURCE="$TMP/source"
WORK_ROOT="$TMP/work"
ARCHIVE_PARENT="$TMP/output"
WORK_DIR_OVERRIDE="$TMP/work"
RESOURCE_POOL_ENABLED=true
RESOURCE_POOL_EXPANDED=true
RESOURCE_POOL_RUNNER="$RUNNER"
RESOURCE_POOL_MAX_RAM_MIB=2048
CPU_THREADS=4
MAX_FORMAT_DICTIONARY_MIB=4096
VIDEO_TRANSCODE=false
VIDEO_CODEC=av1
VIDEO_MODE=balanced
VIDEO_SPECIAL_POLICY=ask
QUALITY_CHECK=off
VIDEO_MIN_VMAF=92
VIDEO_ENCODER=''
IMAGE_OPTIMIZE=false
IMAGE_MODE=maximum
VERIFY_MODE_EFFECTIVE=hashes
EFFORT=extreme
MC_AUTO=false
SEVEN_ZIP="$TMP/bin/fake7z"
SEVEN_ZIP_LOG="$TMP/7z.log"
TEMP_ARCHIVE="$TMP/final.partial.7z"
: > "$SEVEN_ZIP_LOG"
HARDCORE_ARCHIVE_NESTED_HELPER_SOURCE="$TMP/fake-worker.sh"
export HARDCORE_ARCHIVE_NESTED_HELPER_SOURCE

human_bytes() { printf '%s B' "$1"; }
die() { printf 'TEST DIE: %s\n' "$*" >&2; exit 1; }
warn() { printf 'TEST WARN: %s\n' "$*" >&2; }
choose_nested_work_root() { NESTED_WORK_ROOT="$TMP/work"; }
archive_replacement_path() { printf '%s.7z' "${1%.*}"; }
resolve_current_script() { printf '%s/fake-core.sh\n' "$TMP"; }
safe_slug() { printf '%s' "${1//\//-}"; }
hardcore_calibration_identity() { printf 'fixture-id\n'; }
resource_pool_release_lzma_reservation() { RESOURCE_POOL_EXPANDED=true; }
hardcore_visual_open_log() { :; }
run_logged_stage() { shift 2; "$@"; }

source "$NESTED"
prepare_and_add_nested_archives

# Both jobs must really have overlapped through the shared pool.
(( $(cat "$EVENT_DIR/max") >= 2 ))
grep -Fq $'start\tsource/a.zip\t2\t576' "$EVENT_DIR/events"
grep -Fq $'start\tsource/b.zip\t2\t576' "$EVENT_DIR/events"

# Completion order was b then a, but the shared manifest is deterministic and
# follows source order because workers never append to it directly.
mapfile -t rows < "$NESTED_RESULT_MANIFEST"
[[ ${#rows[@]} == 2 ]]
[[ ${rows[0]} == $'repacked\tsource/a.zip\tsource/a.7z\t100000\t50000\t50000\tcandidate-smaller' ]]
[[ ${rows[1]} == $'repacked\tsource/b.zip\tsource/b.7z\t100000\t50000\t50000\tcandidate-smaller' ]]
[[ $NESTED_REPACKED_COUNT == 2 && $NESTED_FALLBACK_COUNT == 0 && $NESTED_SAVED_BYTES == 100000 ]]
[[ $(cat "$NESTED_REPACKED_LIST") == $'source/a.7z\nsource/b.7z' ]]
[[ ! -s $NESTED_FALLBACK_LIST ]]

# Static integration: recursive children must be clamped to their parent grant,
# nested candidates must force pool creation, and the parallel module must
# override the old serial implementation before execution.
grep -Fq 'HARDCORE_ARCHIVE_PARENT_CPU_GRANT' "$CORE"
grep -Fq 'HARDCORE_ARCHIVE_PARENT_RAM_GRANT_MIB' "$CORE"
grep -Fq '$NESTED_REPACK && (( NESTED_COUNT > 0 ))' "$CORE"
grep -Fq 'source "$(dirname -- "${BASH_SOURCE[0]}")/nested.sh"' "$CORE"

printf 'Parallel nested-archive scheduling tests passed.\n'
