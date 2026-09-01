#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
CORPUS=${1:-$ROOT/benchmarks/corpus}
RESULT_ROOT=${2:-$ROOT/benchmarks/results/$(date '+%Y%m%d-%H%M%S')}
MANIFEST="$(dirname -- "$CORPUS")/$(basename -- "$CORPUS").sha256"
MEASURE="$ROOT/benchmarks/measure.py"
HARDCORE_BIN=${HARDCORE_ARCHIVE_BIN:-$ROOT/hardcore-archive}
SEVEN_ZIP=${SEVEN_ZIP_BIN:-}
if [[ -z $SEVEN_ZIP ]]; then
    for candidate in 7zz 7z 7za; do
        if command -v "$candidate" >/dev/null 2>&1; then
            SEVEN_ZIP=$(command -v "$candidate")
            break
        fi
    done
fi

[[ -n $SEVEN_ZIP && -x $SEVEN_ZIP ]] || { printf 'Error: 7-Zip is required.\n' >&2; exit 2; }
[[ -x $HARDCORE_BIN ]] || { printf 'Error: Hardcore Archive entry point is not executable: %s\n' "$HARDCORE_BIN" >&2; exit 2; }
[[ -f $MEASURE ]] || { printf 'Error: benchmark measurement helper is missing: %s\n' "$MEASURE" >&2; exit 2; }
[[ -d $CORPUS ]] || {
    printf 'Generating benchmark corpus...\n'
    python3 "$ROOT/benchmarks/generate-corpus.py" "$CORPUS"
}
[[ -s $MANIFEST ]] || { printf 'Error: corpus hash manifest is missing: %s\n' "$MANIFEST" >&2; exit 2; }
(cd -- "$CORPUS" && sha256sum -c --quiet "$MANIFEST")

mkdir -p -- "$RESULT_ROOT"
RESULTS="$RESULT_ROOT/results.tsv"
SUMMARY="$RESULT_ROOT/summary.tsv"
ENVIRONMENT="$RESULT_ROOT/environment.tsv"
printf 'case\tphase\twall_seconds\tpeak_rss_kib\tarchive_bytes\tsource_bytes\tratio_percent\n' > "$RESULTS"
printf 'case\tarchive_bytes\tcreation_seconds\tverification_seconds\textraction_seconds\tpeak_memory_kib\tsource_bytes\tratio_percent\tcreate_peak_rss_kib\tverify_peak_rss_kib\textract_peak_rss_kib\n' > "$SUMMARY"

IFS=$'\t' read -r SOURCE_BYTES SOURCE_FILES < <(python3 - "$CORPUS" <<'PY'
import os, pathlib, sys
root = pathlib.Path(sys.argv[1])
files = [path for path in root.rglob('*') if path.is_file()]
print(f"{sum(os.stat(path, follow_symlinks=False).st_size for path in files)}\t{len(files)}")
PY
)

declare -A PHASE_WALL=() PHASE_PEAK=()

archive_bytes() {
    local archive=$1
    [[ -f $archive ]] || { printf '0\n'; return 0; }
    stat -c '%s' -- "$archive" 2>/dev/null || stat -f '%z' -- "$archive"
}

ratio_percent() {
    local bytes=$1
    LC_NUMERIC=C awk -v a="$bytes" -v s="$SOURCE_BYTES" 'BEGIN {if(s>0) printf "%.4f",a*100/s; else print 0}'
}

measure() {
    local case_name=$1 phase=$2 metric=$3 archive=$4
    shift 4
    local wall peak size ratio
    python3 "$MEASURE" --output "$metric" -- "$@"
    IFS=$'\t' read -r wall peak < "$metric"
    [[ $wall =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf 'Error: invalid wall-time metric: %s\n' "$wall" >&2; exit 1; }
    [[ $peak =~ ^[0-9]+$ ]] || { printf 'Error: invalid peak-memory metric: %s\n' "$peak" >&2; exit 1; }
    PHASE_WALL["$case_name:$phase"]=$wall
    PHASE_PEAK["$case_name:$phase"]=$peak
    size=$(archive_bytes "$archive")
    ratio=$(ratio_percent "$size")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$case_name" "$phase" "$wall" "$peak" "$size" "$SOURCE_BYTES" "$ratio" >> "$RESULTS"
}

write_summary() {
    local name=$1 archive=$2
    local create verify extract create_peak verify_peak extract_peak peak size ratio
    create=${PHASE_WALL["$name:create"]}
    verify=${PHASE_WALL["$name:verify"]}
    extract=${PHASE_WALL["$name:extract"]}
    create_peak=${PHASE_PEAK["$name:create"]}
    verify_peak=${PHASE_PEAK["$name:verify"]}
    extract_peak=${PHASE_PEAK["$name:extract"]}
    peak=$create_peak
    (( verify_peak > peak )) && peak=$verify_peak
    (( extract_peak > peak )) && peak=$extract_peak
    size=$(archive_bytes "$archive")
    ratio=$(ratio_percent "$size")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$size" "$create" "$verify" "$extract" "$peak" \
        "$SOURCE_BYTES" "$ratio" "$create_peak" "$verify_peak" "$extract_peak" >> "$SUMMARY"
}

record_environment() {
    local cpu='unknown' cpus='unknown' memory_kib='unknown' commit='unknown' sevenzip_version='unknown'
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
    {
        printf 'key\tvalue\n'
        printf 'timestamp_utc\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'platform\t%s\n' "$(uname -s 2>/dev/null || printf unknown)"
        printf 'kernel\t%s\n' "$(uname -r 2>/dev/null || printf unknown)"
        printf 'cpu\t%s\n' "$cpu"
        printf 'logical_cpus\t%s\n' "$cpus"
        printf 'memory_kib\t%s\n' "$memory_kib"
        printf 'hardcore_commit\t%s\n' "$commit"
        printf 'sevenzip\t%s\n' "$sevenzip_version"
        printf 'source_files\t%s\n' "$SOURCE_FILES"
        printf 'source_logical_bytes\t%s\n' "$SOURCE_BYTES"
        printf 'corpus_manifest_sha256\t%s\n' "$(sha256sum -- "$MANIFEST" | awk '{print $1}')"
        printf 'hardcore_hash_jobs\t%s\n' "${HARDCORE_HASH_JOBS:-auto}"
    } | tr '\r\n' '\n\n' > "$ENVIRONMENT"
}

sync_if_available() {
    command -v sync >/dev/null 2>&1 && sync || true
}

run_case() {
    local name=$1
    local archive="$RESULT_ROOT/$name.7z"
    local verify_dir="$RESULT_ROOT/$name.verify"
    local extract_dir="$RESULT_ROOT/$name.extract"
    local corpus_name parent extracted_verify extracted_extract
    corpus_name=$(basename -- "$CORPUS")
    parent=$(dirname -- "$CORPUS")
    extracted_verify="$verify_dir/$corpus_name"
    extracted_extract="$extract_dir/$corpus_name"

    rm -f -- "$archive"
    rm -rf -- "$verify_dir" "$extract_dir"

    case $name in
        hardcore)
            measure "$name" create "$RESULT_ROOT/$name.create.time" "$archive" \
                "$HARDCORE_BIN" --force --yes --allow-sleep --no-report \
                --no-video-transcode --no-image-optimize --no-nested-repack --no-container-repack \
                --verify integrity "$CORPUS" "$archive"
            ;;
        sevenzip)
            measure "$name" create "$RESULT_ROOT/$name.create.time" "$archive" \
                bash -c '
                    set -Eeuo pipefail
                    cd -- "$1"
                    "$2" a "$3" "$4" -t7z -mx=9 -m0=LZMA2 -ms=on -mmt=2 -y
                    "$2" t "$3" >/dev/null
                ' _ "$parent" "$SEVEN_ZIP" "$archive" "$corpus_name"
            ;;
        *)
            printf 'Error: unknown benchmark case: %s\n' "$name" >&2
            exit 2
            ;;
    esac

    sync_if_available
    mkdir -p -- "$verify_dir"
    if [[ $name == hardcore ]]; then
        HARDCORE_VERIFY_MODULE="$ROOT/lib/verify.sh" \
            measure "$name" verify "$RESULT_ROOT/$name.verify.time" "$archive" \
                bash "$ROOT/benchmarks/verify-archive.sh" \
                    "$SEVEN_ZIP" "$archive" "$verify_dir" "$extracted_verify" "$MANIFEST" adaptive
    else
        measure "$name" verify "$RESULT_ROOT/$name.verify.time" "$archive" \
            bash "$ROOT/benchmarks/verify-archive.sh" \
                "$SEVEN_ZIP" "$archive" "$verify_dir" "$extracted_verify" "$MANIFEST" plain
    fi
    rm -rf -- "$verify_dir"

    sync_if_available
    mkdir -p -- "$extract_dir"
    measure "$name" extract "$RESULT_ROOT/$name.extract.time" "$archive" \
        "$SEVEN_ZIP" x -y -o"$extract_dir" "$archive"
    [[ -d $extracted_extract ]] || {
        printf 'Error: extraction did not produce expected corpus directory: %s\n' "$extracted_extract" >&2
        exit 1
    }
    rm -rf -- "$extract_dir"
    write_summary "$name" "$archive"
}

record_environment
run_case hardcore
run_case sevenzip

printf '\nBenchmark summary:\n'
column -t -s $'\t' "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
printf '\nDetailed phase results: %s\n' "$RESULTS"
printf 'Summary:                %s\n' "$SUMMARY"
printf 'Environment:            %s\n' "$ENVIRONMENT"
