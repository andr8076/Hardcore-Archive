#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# A performance run is invalid if the machine sleeps part-way through it.
# Inhibit sleep around the whole benchmark session, including the 7-Zip
# reference case, verification and extraction. Tests/advanced users can mark an
# already-inhibited parent with HARDCORE_BENCHMARK_INHIBITED=1.
if [[ ${HARDCORE_BENCHMARK_INHIBITED:-0} != 1 && ${HARDCORE_BENCHMARK_ALLOW_SLEEP:-0} != 1 ]]; then
    case $(uname -s 2>/dev/null || true) in
        Darwin)
            command -v caffeinate >/dev/null 2>&1 || {
                printf 'Error: benchmark sleep inhibition requires caffeinate on macOS.\n' >&2
                exit 2
            }
            exec caffeinate -i -m env HARDCORE_BENCHMARK_INHIBITED=1 bash "$0" "$@"
            ;;
        Linux)
            if command -v systemd-inhibit >/dev/null 2>&1 && systemd-inhibit --list >/dev/null 2>&1; then
                exec systemd-inhibit \
                    --what=sleep:idle:handle-lid-switch \
                    --who=hardcore-archive-benchmark \
                    --why='Measuring archive performance' \
                    --mode=block \
                    env HARDCORE_BENCHMARK_INHIBITED=1 bash "$0" "$@"
            fi
            printf 'Error: benchmark sleep inhibition requires a usable systemd-inhibit on Linux.\n' >&2
            printf 'Set HARDCORE_BENCHMARK_ALLOW_SLEEP=1 only if an external inhibitor is already protecting the machine.\n' >&2
            exit 2
            ;;
    esac
fi
if [[ ${HARDCORE_BENCHMARK_ALLOW_SLEEP:-0} != 1 ]]; then
    # Tell nested Hardcore invocations that the benchmark session already owns
    # the platform inhibitor; avoid stacking a second caffeinate/systemd lock.
    export HARDCORE_ARCHIVE_INHIBITED=1
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORKLOAD_ROOT=${1:-$ROOT/benchmarks/workloads}
RESULT_ROOT=${2:-$ROOT/benchmarks/results/workloads-$(date '+%Y%m%d-%H%M%S')}
MEASURE="$ROOT/benchmarks/measure-extended.py"
SOURCE_SNAPSHOT="$ROOT/benchmarks/source-snapshot.py"
HARDCORE_BIN=${HARDCORE_ARCHIVE_BIN:-$ROOT/hardcore-archive}
WITH_MEDIA=${HARDCORE_BENCHMARK_WITH_MEDIA:-0}
PROFILE_FILTER=${HARDCORE_BENCHMARK_PROFILES:-all}
CASE_FILTER=${HARDCORE_BENCHMARK_CASES:-hardcore-full,sevenzip-byte-preserving}
MEMORY_LIMIT_MIB=${HARDCORE_BENCHMARK_MEMORY_LIMIT_MIB:-0}
SAMPLE_INTERVAL=${HARDCORE_BENCHMARK_SAMPLE_INTERVAL:-0.50}
[[ $MEMORY_LIMIT_MIB =~ ^[0-9]+$ ]] || { printf 'Error: HARDCORE_BENCHMARK_MEMORY_LIMIT_MIB must be an integer.\n' >&2; exit 2; }
LC_NUMERIC=C awk -v n="$SAMPLE_INTERVAL" 'BEGIN {exit !(n ~ /^[0-9]+([.][0-9]+)?$/ && n >= 0.05 && n <= 5)}' || {
    printf 'Error: HARDCORE_BENCHMARK_SAMPLE_INTERVAL must be 0.05..5 seconds.\n' >&2
    exit 2
}

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
[[ -f $SOURCE_SNAPSHOT ]] || { printf 'Error: source snapshot helper is missing: %s\n' "$SOURCE_SNAPSHOT" >&2; exit 2; }
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
printf 'profile\tcase\tphase\tstatus\texit_code\twall_seconds\tpeak_rss_kib\tuser_seconds\tsystem_seconds\taverage_cpu_percent\tarchive_bytes\tsource_bytes\tratio_percent\tphase_log\n' > "$RESULTS"
printf 'profile\tcase\tsource_files\tsource_bytes\tarchive_bytes\tratio_percent\tcreation_seconds\tverification_seconds\textraction_seconds\tcreate_average_cpu_percent\tcreate_user_seconds\tcreate_system_seconds\tpeak_memory_kib\tverification_kind\toverall_status\tcreate_status\tverify_status\textract_status\tsource_stable\tsource_change_report\n' > "$SUMMARY"

declare -A PHASE_WALL=() PHASE_PEAK=() PHASE_USER=() PHASE_SYSTEM=() PHASE_CPU=()
declare -A PHASE_STATUS=() PHASE_RC=() PHASE_LOG=()

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
errors = []
for raw in manifest.read_text(encoding='utf-8').splitlines():
    if not raw:
        continue
    try:
        expected, relative = raw.split('  ', 1)
    except ValueError:
        errors.append(f'invalid manifest line: {raw!r}')
        continue
    path = root / relative
    if not path.is_file():
        errors.append(f'missing: {relative}')
        continue
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != expected:
        errors.append(f'content changed: {relative}')
    listed.add(relative)
actual_paths = {str(path.relative_to(root)) for path in root.rglob('*') if path.is_file()}
for relative in sorted(actual_paths - listed):
    errors.append(f'added: {relative}')
for relative in sorted(listed - actual_paths):
    errors.append(f'removed: {relative}')
if errors:
    print('Workload manifest validation failed:', file=sys.stderr)
    for error in errors[:100]:
        print(f'  {error}', file=sys.stderr)
    if len(errors) > 100:
        print(f'  ... {len(errors)-100} more', file=sys.stderr)
    raise SystemExit(1)
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

record_not_run() {
    local profile=$1 case_name=$2 phase=$3 archive=$4 source_size=$5 reason=$6
    local key size ratio
    key="$profile:$case_name:$phase"
    PHASE_WALL[$key]=''
    PHASE_PEAK[$key]=''
    PHASE_USER[$key]=''
    PHASE_SYSTEM[$key]=''
    PHASE_CPU[$key]=''
    PHASE_STATUS[$key]="not-run:$reason"
    PHASE_RC[$key]=''
    PHASE_LOG[$key]=''
    size=$(archive_bytes "$archive")
    ratio=$(ratio_percent "$size" "$source_size")
    printf '%s\t%s\t%s\t%s\t\t\t\t\t\t\t%s\t%s\t%s\t\n' \
        "$profile" "$case_name" "$phase" "not-run:$reason" "$size" "$source_size" "$ratio" >> "$RESULTS"
}

measure_phase() {
    local profile=$1 case_name=$2 phase=$3 metric=$4 archive=$5 source_size=$6
    shift 6
    local wall='' peak='' user='' system='' cpu='' size ratio key rc status phase_log
    local -a command=("$@")
    phase_log="${metric%.time}.log"
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

    set +e
    python3 "$MEASURE" --output "$metric" --log "$phase_log" --sample-interval "$SAMPLE_INTERVAL" -- "${command[@]}"
    rc=$?
    set -e
    if [[ -s $metric ]]; then
        IFS=$'\t' read -r wall peak user system cpu < "$metric" || true
    fi
    if [[ ! $wall =~ ^[0-9]+([.][0-9]+)?$ || ! $peak =~ ^[0-9]+$ ]]; then
        printf 'Warning: phase metric was incomplete for %s/%s/%s.\n' "$profile" "$case_name" "$phase" >&2
        wall=''; peak=''; user=''; system=''; cpu=''
        (( rc != 0 )) || rc=125
    fi
    if (( rc == 0 )); then status=success; else status=failed; fi

    key="$profile:$case_name:$phase"
    PHASE_WALL[$key]=$wall
    PHASE_PEAK[$key]=$peak
    PHASE_USER[$key]=$user
    PHASE_SYSTEM[$key]=$system
    PHASE_CPU[$key]=$cpu
    PHASE_STATUS[$key]=$status
    PHASE_RC[$key]=$rc
    PHASE_LOG[$key]=${phase_log##*/}
    size=$(archive_bytes "$archive")
    ratio=$(ratio_percent "$size" "$source_size")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$profile" "$case_name" "$phase" "$status" "$rc" "$wall" "$peak" "$user" "$system" "$cpu" \
        "$size" "$source_size" "$ratio" "${phase_log##*/}" >> "$RESULTS"
    return 0
}

write_summary() {
    local profile=$1 case_name=$2 source_files=$3 source_size=$4 archive=$5 verification_kind=$6 source_stable=$7 source_change_report=$8
    local prefix create verify extract create_peak verify_peak extract_peak peak=0 size ratio overall status
    prefix="$profile:$case_name"
    create=${PHASE_WALL["$prefix:create"]:-}
    verify=${PHASE_WALL["$prefix:verify"]:-}
    extract=${PHASE_WALL["$prefix:extract"]:-}
    for value in "${PHASE_PEAK["$prefix:create"]:-}" "${PHASE_PEAK["$prefix:verify"]:-}" "${PHASE_PEAK["$prefix:extract"]:-}"; do
        [[ $value =~ ^[0-9]+$ ]] && (( value > peak )) && peak=$value
    done
    status=${PHASE_STATUS["$prefix:create"]:-not-run}
    overall=success
    for phase in create verify extract; do
        case ${PHASE_STATUS["$prefix:$phase"]:-not-run} in
            success) ;;
            *) overall=failed ;;
        esac
    done
    [[ $source_stable == yes ]] || overall=failed
    size=$(archive_bytes "$archive")
    ratio=$(ratio_percent "$size" "$source_size")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$profile" "$case_name" "$source_files" "$source_size" "$size" "$ratio" \
        "$create" "$verify" "$extract" "${PHASE_CPU["$prefix:create"]:-}" \
        "${PHASE_USER["$prefix:create"]:-}" "${PHASE_SYSTEM["$prefix:create"]:-}" "$peak" "$verification_kind" \
        "$overall" "${PHASE_STATUS["$prefix:create"]:-not-run}" "${PHASE_STATUS["$prefix:verify"]:-not-run}" \
        "${PHASE_STATUS["$prefix:extract"]:-not-run}" "$source_stable" "$source_change_report" >> "$SUMMARY"
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
        printf 'memory_metric\taggregate-process-tree-rss\n'
        printf 'memory_sample_interval_seconds\t%s\n' "$SAMPLE_INTERVAL"
        printf 'sleep_inhibition\t%s\n' "$([[ ${HARDCORE_BENCHMARK_ALLOW_SLEEP:-0} == 1 ]] && printf external-or-allowed || printf benchmark-session)"
        printf 'gpu\t%s\n' "$gpu"
        printf 'hardcore_commit\t%s\n' "$commit"
        printf 'sevenzip\t%s\n' "$sevenzip_version"
        printf 'profile_filter\t%s\n' "$PROFILE_FILTER"
        printf 'case_filter\t%s\n' "$CASE_FILTER"
    } > "$ENVIRONMENT"
}

source_snapshot_check() {
    local source=$1 before=$2 after=$3 report=$4 rc
    if ! python3 "$SOURCE_SNAPSHOT" capture "$source" "$after"; then
        {
            printf 'Hardcore Archive benchmark source-change report\n'
            printf 'The source tree could not be captured after the benchmark.\n'
            printf 'Source path: %s\n' "$source"
        } > "$report"
        printf 'no\t%s\n' "${report##*/}"
        return 0
    fi
    set +e
    python3 "$SOURCE_SNAPSHOT" compare "$before" "$after" "$report"
    rc=$?
    set -e
    if (( rc == 0 )); then
        rm -f -- "$report"
        printf 'yes\t\n'
    else
        printf 'no\t%s\n' "${report##*/}"
    fi
}

run_profile_case() {
    local profile=$1 case_name=$2 source=$3 source_files=$4 source_size=$5
    local archive="$RESULT_ROOT/${profile}.${case_name}.7z"
    local verify_metric="$RESULT_ROOT/${profile}.${case_name}.verify.time"
    local extract_metric="$RESULT_ROOT/${profile}.${case_name}.extract.time"
    local create_metric="$RESULT_ROOT/${profile}.${case_name}.create.time"
    local extract_dir="$RESULT_ROOT/${profile}.${case_name}.extract"
    local source_before="$RESULT_ROOT/${profile}.${case_name}.source-before.json"
    local source_after="$RESULT_ROOT/${profile}.${case_name}.source-after.json"
    local source_report="$RESULT_ROOT/${profile}.${case_name}.source-changes.txt"
    local parent source_name verification_kind create_rc verify_rc extract_rc source_stable source_change_report case_failed=0
    parent=$(dirname -- "$source")
    source_name=$(basename -- "$source")
    rm -f -- "$archive" "$source_before" "$source_after" "$source_report"
    rm -rf -- "$extract_dir"

    printf '\n=== %s / %s ===\n' "$profile" "$case_name"
    if (( MEMORY_LIMIT_MIB > 0 )); then
        printf 'Memory-pressure ceiling: %s MiB virtual memory\n' "$MEMORY_LIMIT_MIB"
    fi
    python3 "$SOURCE_SNAPSHOT" capture "$source" "$source_before"

    case $case_name in
        hardcore-full)
            # Do not pass --allow-sleep: a benchmark must retain Hardcore's
            # platform sleep inhibitor for the complete production run.
            measure_phase "$profile" "$case_name" create "$create_metric" "$archive" "$source_size" \
                "$HARDCORE_BIN" --force --yes --no-report --verify hashes "$source" "$archive"
            verification_kind='integrity-recheck; strong-hash-in-create'
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
            ;;
        *)
            printf 'Error: unknown benchmark case: %s\n' "$case_name" >&2
            return 2
            ;;
    esac

    create_rc=${PHASE_RC["$profile:$case_name:create"]:-125}
    if (( create_rc != 0 )) || [[ ! -f $archive ]]; then
        case_failed=1
        record_not_run "$profile" "$case_name" verify "$archive" "$source_size" 'create-failed'
        record_not_run "$profile" "$case_name" extract "$archive" "$source_size" 'create-failed'
    else
        case $case_name in
            hardcore-full)
                measure_phase "$profile" "$case_name" verify "$verify_metric" "$archive" "$source_size" \
                    "$HARDCORE_BIN" --inspect "$archive"
                ;;
            sevenzip-byte-preserving)
                measure_phase "$profile" "$case_name" verify "$verify_metric" "$archive" "$source_size" \
                    "$SEVEN_ZIP" t "$archive"
                ;;
        esac
        verify_rc=${PHASE_RC["$profile:$case_name:verify"]:-125}
        (( verify_rc == 0 )) || case_failed=1

        sync_if_available
        rm -rf -- "$extract_dir"
        mkdir -p -- "$extract_dir"
        measure_phase "$profile" "$case_name" extract "$extract_metric" "$archive" "$source_size" \
            bash -c '
                set -Eeuo pipefail
                seven_zip=$1; archive=$2; extract_dir=$3; source_name=$4
                "$seven_zip" x -y -o"$extract_dir" "$archive"
                [[ -d $extract_dir/$source_name ]] || {
                    printf "Error: extraction did not produce expected top-level directory: %s\\n" "$extract_dir/$source_name" >&2
                    exit 3
                }
            ' _ "$SEVEN_ZIP" "$archive" "$extract_dir" "$source_name"
        extract_rc=${PHASE_RC["$profile:$case_name:extract"]:-125}
        (( extract_rc == 0 )) || case_failed=1
        rm -rf -- "$extract_dir"
    fi

    IFS=$'\t' read -r source_stable source_change_report < <(
        source_snapshot_check "$source" "$source_before" "$source_after" "$source_report"
    )
    rm -f -- "$source_before" "$source_after"
    if [[ $source_stable != yes ]]; then
        case_failed=1
        printf 'Source changed during benchmark; exact paths are in %s\n' "$RESULT_ROOT/$source_change_report" >&2
    fi

    write_summary "$profile" "$case_name" "$source_files" "$source_size" "$archive" "$verification_kind" "$source_stable" "$source_change_report"
    (( case_failed == 0 ))
}

record_environment

found=0
benchmark_failures=0
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
        if ! run_profile_case "$profile" "$case_name" "$source" "$source_files" "$source_size"; then
            benchmark_failures=$((benchmark_failures + 1))
            printf 'Benchmark case failed but its completed measurements were preserved: %s / %s\n' "$profile" "$case_name" >&2
        fi
    done
done
(( found == 1 )) || { printf 'Error: no benchmark profiles matched %s\n' "$PROFILE_FILTER" >&2; exit 2; }

printf '\nReal-world benchmark summary:\n'
column -t -s $'\t' "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
printf '\nDetailed phases: %s\n' "$RESULTS"
printf 'Summary:         %s\n' "$SUMMARY"
printf 'Environment:     %s\n' "$ENVIRONMENT"
if (( benchmark_failures > 0 )); then
    printf 'Completed with %s failed benchmark case(s); successful and failed phase measurements were retained.\n' "$benchmark_failures" >&2
    exit 1
fi
