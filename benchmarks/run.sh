#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
CORPUS=${1:-$ROOT/benchmarks/corpus}
RESULT_ROOT=${2:-$ROOT/benchmarks/results/$(date '+%Y%m%d-%H%M%S')}
MANIFEST="$(dirname -- "$CORPUS")/$(basename -- "$CORPUS").sha256"
SEVEN_ZIP=''
for candidate in 7zz 7z 7za; do
    if command -v "$candidate" >/dev/null 2>&1; then SEVEN_ZIP=$(command -v "$candidate"); break; fi
done
[[ -n $SEVEN_ZIP ]] || { printf 'Error: 7-Zip is required.\n' >&2; exit 2; }
[[ -d $CORPUS ]] || { printf 'Generating benchmark corpus...\n'; python3 "$ROOT/benchmarks/generate-corpus.py" "$CORPUS"; }
[[ -s $MANIFEST ]] || { printf 'Error: corpus hash manifest is missing: %s\n' "$MANIFEST" >&2; exit 2; }

mkdir -p -- "$RESULT_ROOT"
RESULTS="$RESULT_ROOT/results.tsv"
printf 'case\tphase\twall_seconds\tpeak_rss_kib\tarchive_bytes\tsource_bytes\tratio_percent\n' > "$RESULTS"
SOURCE_BYTES=$(python3 - "$CORPUS" <<'PY'
import os, pathlib, sys
print(sum(os.stat(path, follow_symlinks=False).st_size for path in pathlib.Path(sys.argv[1]).rglob('*') if path.is_file()))
PY
)

measure() {
    local case_name=$1 phase=$2 metric=$3 archive=$4
    shift 4
    local wall peak started size=0 ratio=0
    if [[ -x /usr/bin/time ]]; then
        if /usr/bin/time --version >/dev/null 2>&1; then
            /usr/bin/time -f '%e\t%M' -o "$metric" -- "$@"
            IFS=$'\t' read -r wall peak < "$metric"
        else
            started=$(date +%s)
            /usr/bin/time -l -o "$metric" "$@"
            wall=$(($(date +%s) - started))
            peak=$(awk '/maximum resident set size/{print $1; exit}' "$metric")
            peak=$((${peak:-0} / 1024))
        fi
    else
        started=$(date +%s)
        "$@"
        wall=$(($(date +%s) - started))
        peak=0
    fi
    [[ -f $archive ]] && size=$(stat -c '%s' -- "$archive" 2>/dev/null || stat -f '%z' -- "$archive")
    ratio=$(LC_NUMERIC=C awk -v a="$size" -v s="$SOURCE_BYTES" 'BEGIN {if(s>0) printf "%.4f",a*100/s; else print 0}')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$case_name" "$phase" "$wall" "${peak:-0}" "$size" "$SOURCE_BYTES" "$ratio" >> "$RESULTS"
}

run_case() {
    local name=$1
    local archive="$RESULT_ROOT/$name.7z" verify_dir="$RESULT_ROOT/$name.verify" extract_dir="$RESULT_ROOT/$name.extract"
    local extracted_corpus="$verify_dir/$(basename -- "$CORPUS")"
    case $name in
        hardcore)
            measure "$name" create "$RESULT_ROOT/$name.create.time" "$archive" \
                "$ROOT/hardcore-archive" --force --yes --allow-sleep --no-report \
                --no-video-transcode --no-image-optimize --no-nested-repack --no-container-repack \
                --verify integrity "$CORPUS" "$archive"
            ;;
        sevenzip)
            (
                cd -- "$(dirname -- "$CORPUS")"
                measure "$name" create "$RESULT_ROOT/$name.create.time" "$archive" \
                    "$SEVEN_ZIP" a "$archive" "$(basename -- "$CORPUS")" \
                        -t7z -mx=9 -m0=LZMA2 -ms=on -mmt=2 -y
            )
            ;;
    esac
    mkdir -p -- "$verify_dir"
    measure "$name" verify "$RESULT_ROOT/$name.verify.time" "$archive" \
        bash "$ROOT/benchmarks/verify-archive.sh" \
            "$SEVEN_ZIP" "$archive" "$verify_dir" "$extracted_corpus" "$MANIFEST"
    mkdir -p -- "$extract_dir"
    measure "$name" extract "$RESULT_ROOT/$name.extract.time" "$archive" \
        "$SEVEN_ZIP" x -y -o"$extract_dir" "$archive"
}

run_case hardcore
run_case sevenzip
printf 'Benchmark results: %s\n' "$RESULTS"
