#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORKLOAD_ROOT=${1:-$ROOT/benchmarks/workloads}
RESULT_ROOT=${2:-$ROOT/benchmarks/results/workloads-$(date '+%Y%m%d-%H%M%S')}
MEASURE="$ROOT/benchmarks/measure-extended.py"
HARDCORE_BIN=${HARDCORE_ARCHIVE_BIN:-$ROOT/hardcore-archive}
WITH_MEDIA=${HARDCORE_BENCHMARK_WITH_MEDIA:-0}
PROFILE_FILTER=${HARDCORE_BENCHMARK_PROFILES:-all}
CASE_FILTER=${HARDCORE_BENCHMARK_CASES:-hardcore-full,sevenzip-byte-preserving}
MEMORY_LIMIT_MIB=${HARDCORE_BENCHMARK_MEMORY_LIMIT_MIB:-0}
[[ $MEMORY_LIMIT_MIB =~ ^[0-9]+$ ]] || { printf 'Error: HARDCORE_BENCHMARK_MEMORY_LIMIT_MIB must be an integer.\n' >&2; exit 2; }

SEVEN_ZIP=${SEVEN_ZIP_BIN:-}
if [[ -z $SEVEN_ZIP ]]; then
    for candidate in 7zz 7z 7za; do
        if command -v "$candidate" >/dev/null 2>&1; then
            SEVEN_ZIP=$(command -v "$candidate")
            break
        fi
    done
fi

[[ -x $HARDCORE_BIN ]] || { printf 'Error: Hardcore Archive entry point is not executable: %s\n' "$HARDCORE_BIN" >&2; exit 2; }
[[ -f $MEASURE ]] || { printf 'Error: extended measurement helper is missing: %s\n' "$MEASURE" >&2; exit 2; }
[[ -n $SEVEN_ZIP && -x $SEVEN_ZIP ]] || { printf 'Error: 7-Zip is required.\n' >&2; exit 2; }

if [[ ! -d $WORKLOAD_ROOT ]]; then
    printf 'Generating real-world benchmark workloads...\n'
    generator_args=("$ROOT/benchmarks/generate-workloads.py" "$WORKLOAD_ROOT")
    [[ $WITH_MEDIA == 1 ]] && generator_args+=(--with-media --profiles documents,small-files,images,media,archives,containers,mixed,everything)
    python3 "${generator_args[@]}"
fi

mkdir -p -- "$RESULT_ROOT"
RESULTS="$RESULT_ROOT/results.tsv"
SUMMARY="$RESULT_ROOT/summary.tsv"
ENVIRONMENT="$RESULT_ROOT/environment.tsv"
printf 'profile\tcase\tphase\twall_seconds\tpeak_rss_kib\tuser_seconds\tsystem_seconds\taverage_cpu_percent\tarchive_bytes\tsource_bytes\tratio_percent\n' > "$RESULTS"
printf 'profile\tcase\tsource_files\tsource_bytes\tarchive_bytes\tratio_percent\tcreation_seconds\tverification_seconds\textraction_seconds\tcreate_average_cpu_percent\tcreate_user_seconds\tcreate_system_seconds\tpeak_memory_kib\tverification_kind\n' > "$SUMMARY"

declare -A PHASE_WALL=() PHASE_PEAK=() PHASE_USER=() PHASE_SYSTEM=() PHASE_CPU=()

archive_bytes() {
    local archive=$1
    [[ -f $archive ]] || { printf '0\n'; return 0; }
    stat -c '%s' -- "$archive" 2>/dev/null || stat -f '%z' -- "$archive"
}

source_stats() {
    python3 - "$1" <<'PY'
import os, pathlib, sys
root = pathlib.Path(sys.argv[1])
files = [p for p in root.rglob('*') if p.is_file()]
print(f"{len(files)}\t{sum(os.stat(p, follow_symlinks=False).st_size for p in files)}")
PY
}

verify_manifest() {
    local source=$1 manifest=$2
    python3 - "$source" "$manifest" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = pathlib.Path(sys.argv[2])
listed = set()
for raw in manifest.read_text(encoding='utf-8').splitlines():
    if not raw:
        continue
    try:
        expected, relative = raw.split('  ', 1)
    except ValueError:
        raise SystemExit(f'invalid workload manifest line: {raw!r}')
    path = root / relative
    if not path.is_file():
        raise SystemExit(f'workload file is missing: {relative}')
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f'workload hash mismatch: {relative}')
    listed.add(relative)
actual_paths = {str(path.relative_to(root)) for path in root.rglob('*') if path.is_file()}
extra = sorted(actual_paths - listed)
missing = sorted(listed - actual_paths)
if extra or missing:
    raise SystemExit(f'workload manifest/path mismatch: extra={extra[:5]} missing={missing[:5]}')
PY
}

ratio_percent() {
    local archive_size=$1 source_size=$2
    LC_NUMERIC=C awk -v a="$archive_size" -v s="$source_size" 'BEGIN {if(s>0) printf "%.4f",a*100/s; else print "0"}'
}

csv_contains() {
    local csv=$1 needle=$2 item
    local -a items=()
    [[ $csv == all ]] && return 0
    IFS=',' read -ra items <<< "$csv"
    for item in "${items[@]}"; do
        [[ $item == "$needle" ]] && return 0
    done
    return 1
}

measure_phase() {
    local profile=$1 case_name=$2 phase=$3 metric=$4 archive=$5 source_size=$6
    shift 6
    local wall peak user system cpu size ratio key
    local -a command=("$@")
    if (( MEMORY_LIMIT_MIB > 0 )); then
        command=(
            bash -c '
                set -Eeuo pipefail
                limit_mib=$1
                shift
                ulimit -v "$((limit_mib * 1024))" || {
                    printf "Error: this platform cannot apply the requested virtual-memory ceiling.\\n" >&2
                    exit 2
                }
                exec "$@"
            ' _ "$MEMORY_LIMIT_MIB" "${command[@]}"
        )
    fi
    python3 "$MEASURE" --output "$metric" -- "${command[@]}"
    IFS=$'\t' read -r wall peak user system cpu < "$metric"
    [[ $wall =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf 'Error: invalid wall metric: %s\n' "$wall" >&2; exit 1; }
    [[ $peak =~ ^[0-9]+$ ]] || { printf 'Error: invalid memory metric: %s\n' "$peak" >&2; exit 1; }
    key="$profile:$case_name:$phase"
    PHASE_WALL[$key]=$wall
    PHASE_PEAK[$key]=$peak
    PHASE_USER[$key]=$user
    PHASE_SYSTEM[$key]=$system
    PHASE_CPU[$key]=$cpu
    size=$(archive_bytes "$archive")
    ratio=$(ratio_percent "$size" "$source_size")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$profile" "$case_name" "$phase" "$wall" "$peak" "$user" "$system" "$cpu" \
        "$size" "$source_size" "$ratio" >> "$RESULTS"
}

write_summary() {
    local profile=$1 case_name=$2 source_files=$3 source_size=$4 archive=$5 verification_kind=$6
    local prefix create verify extract create_peak verify_peak extract_peak peak size ratio
    prefix="$profile:$case_name"
    create=${PHASE_WALL["$prefix:create"]}
    verify=${PHASE_WALL["$prefix:verify"]}
    extract=${PHASE_WALL["$prefix:extract"]}
    create_peak=${PHASE_PEAK["$prefix:create"]}
    verify_peak=${PHASE_PEAK["$prefix:verify"]}
    extract_peak=${PHASE_PEAK["$prefix:extract"]}
    peak=$create_peak
    (( verify_peak > peak )) && peak=$verify_peak
    (( extract_peak > peak )) && peak=$extract_peak
    size=$(archive_bytes "$archive")
    ratio=$(ratio_percent "$size" "$source_size")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$profile" "$case_name" "$source_files" "$source_size" "$size" "$ratio" \
        "$create" "$verify" "$extract" "${PHASE_CPU["$prefix:create"]}" \
        "${PHASE_USER["$prefix:create"]}" "${PHASE_SYSTEM["$prefix:create"]}" "$peak" "$verification_kind" >> "$SUMMARY"
}

sync_if_available() {
    command -v sync >/dev/null 2>&1 && sync || true
}

record_environment() {
    local cpu='unknown' cpus='unknown' memory_kib='unknown' commit='unknown' sevenzip_version='unknown' gpu='none'
    if [[ $(uname -s 2>/dev/null || true) == Darwin ]]; then
        cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || sysctl -n hw.model 2>/dev/null || printf unknown)
        cpus=$(sysctl -n hw.logicalcpu 2>/dev/null || printf unknown)
        memory_kib=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1024}' || printf unknown)
    else
        cpu=$(awk -F: '/model name|Hardware|Processor/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || printf unknown)
        cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf unknown)
        memory_kib=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || printf unknown)
    fi
    if command -v git >/dev/null 2>&1; then
        commit=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf unknown)
    fi
    sevenzip_version=$("$SEVEN_ZIP" 2>/dev/null | head -n2 | tail -n1 || printf unknown)
    if command -v nvidia-smi >/dev/null 2>&1; then
        gpu=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | paste -sd ';' - || printf none)
    fi
    {
        printf 'key\tvalue\n'
        printf 'timestamp_utc\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'platform\t%s\n' "$(uname -s 2>/dev/null || printf unknown)"
        printf 'kernel\t%s\n' "$(uname -r 2>/dev/null || printf unknown)"
        printf 'cpu\t%s\n' "$cpu"
        printf 'logical_cpus\t%s\n' "$cpus"
        printf 'memory_kib\t%s\n' "$memory_kib"
        printf 'memory_limit_mib\t%s\n' "$MEMORY_LIMIT_MIB"
        printf 'gpu\t%s\n' "$gpu"
        printf 'hardcore_commit\t%s\n' "$commit"
        printf 'sevenzip\t%s\n' "$sevenzip_version"
        printf 'profile_filter\t%s\n' "$PROFILE_FILTER"
        printf 'case_filter\t%s\n' "$CASE_FILTER"
    } > "$ENVIRONMENT"
}

run_profile_case() {
    local profile=$1 case_name=$2 source=$3 source_files=$4 source_size=$5
    local archive="$RESULT_ROOT/${profile}.${case_name}.7z"
    local verify_metric="$RESULT_ROOT/${profile}.${case_name}.verify.time"
    local extract_metric="$RESULT_ROOT/${profile}.${case_name}.extract.time"
    local create_metric="$RESULT_ROOT/${profile}.${case_name}.create.time"
    local extract_dir="$RESULT_ROOT/${profile}.${case_name}.extract"
    local parent source_name verification_kind
    parent=$(dirname -- "$source")
    source_name=$(basename -- "$source")
    rm -f -- "$archive"
    rm -rf -- "$extract_dir"

    printf '\n=== %s / %s ===\n' "$profile" "$case_name"
    if (( MEMORY_LIMIT_MIB > 0 )); then
        printf 'Memory-pressure ceiling: %s MiB virtual memory\n' "$MEMORY_LIMIT_MIB"
    fi
    case $case_name in
        hardcore-full)
            # Strong hash verification of the final archived payload is part of
            # the production create command, including transformed media.
            measure_phase "$profile" "$case_name" create "$create_metric" "$archive" "$source_size" \
                "$HARDCORE_BIN" --force --yes --allow-sleep --no-report --verify hashes "$source" "$archive"
            verification_kind='integrity-recheck; strong-hash-in-create'
            measure_phase "$profile" "$case_name" verify "$verify_metric" "$archive" "$source_size" \
                "$HARDCORE_BIN" --inspect "$archive"
            ;;
        sevenzip-byte-preserving)
            measure_phase "$profile" "$case_name" create "$create_metric" "$archive" "$source_size" \
                bash -c '
                    set -Eeuo pipefail
                    cd -- "$1"
                    "$2" a "$3" "$4" -t7z -mx=9 -m0=LZMA2 -ms=on -mmt=2 -y
                    "$2" t "$3" >/dev/null
                ' _ "$parent" "$SEVEN_ZIP" "$archive" "$source_name"
            verification_kind='archive-integrity'
            measure_phase "$profile" "$case_name" verify "$verify_metric" "$archive" "$source_size" \
                "$SEVEN_ZIP" t "$archive"
            ;;
        *)
            printf 'Error: unknown benchmark case: %s\n' "$case_name" >&2
            exit 2
            ;;
    esac

    sync_if_available
    mkdir -p -- "$extract_dir"
    measure_phase "$profile" "$case_name" extract "$extract_metric" "$archive" "$source_size" \
        "$SEVEN_ZIP" x -y -o"$extract_dir" "$archive"
    [[ -d $extract_dir/$source_name ]] || {
        printf 'Error: extraction did not create expected top-level directory: %s\n' "$extract_dir/$source_name" >&2
        exit 1
    }
    rm -rf -- "$extract_dir"
    write_summary "$profile" "$case_name" "$source_files" "$source_size" "$archive" "$verification_kind"
}

record_environment

found=0
for source in "$WORKLOAD_ROOT"/*; do
    [[ -d $source ]] || continue
    profile=$(basename -- "$source")
    csv_contains "$PROFILE_FILTER" "$profile" || continue
    manifest="$WORKLOAD_ROOT/$profile.sha256"
    [[ -s $manifest ]] || { printf 'Error: workload manifest is missing: %s\n' "$manifest" >&2; exit 2; }
    printf 'Validating workload: %s\n' "$profile"
    verify_manifest "$source" "$manifest"
    found=1
    IFS=$'\t' read -r source_files source_size < <(source_stats "$source")
    for case_name in hardcore-full sevenzip-byte-preserving; do
        csv_contains "$CASE_FILTER" "$case_name" || continue
        run_profile_case "$profile" "$case_name" "$source" "$source_files" "$source_size"
    done
done
(( found == 1 )) || { printf 'Error: no benchmark profiles matched %s\n' "$PROFILE_FILTER" >&2; exit 2; }

printf '\nReal-world benchmark summary:\n'
column -t -s $'\t' "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
printf '\nDetailed phases: %s\n' "$RESULTS"
printf 'Summary:         %s\n' "$SUMMARY"
printf 'Environment:     %s\n' "$ENVIRONMENT"
