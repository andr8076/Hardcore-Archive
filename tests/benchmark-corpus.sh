#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-benchmark-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

python3 "$ROOT/benchmarks/generate-corpus.py" "$TMP/corpus" --size-mib 4
(cd "$TMP/corpus" && sha256sum -c --quiet "$TMP/corpus.sha256")
cp "$TMP/corpus.sha256" "$TMP/first.sha256"
python3 "$ROOT/benchmarks/generate-corpus.py" "$TMP/corpus" --size-mib 4 --force >/dev/null
(cd "$TMP/corpus" && sha256sum -c --quiet "$TMP/corpus.sha256")
cmp -s "$TMP/first.sha256" "$TMP/corpus.sha256"
mkdir "$TMP/not-a-corpus"
if python3 "$ROOT/benchmarks/generate-corpus.py" "$TMP/not-a-corpus" --size-mib 4 --force >/dev/null 2>&1; then
    printf 'Benchmark generator overwrote an unmarked directory.\n' >&2
    exit 1
fi
[[ -f $TMP/corpus/text/repeated.txt ]]
[[ -f $TMP/corpus/binary/incompressible.bin ]]
[[ -f $TMP/corpus/already-compressed/repeated.txt.gz ]]
[[ -f $TMP/corpus/nested/payload.zip ]]
[[ -f $TMP/corpus/containers/benchmark.docx ]]

# The portable measurement helper must provide sub-second wall time and a
# numeric peak-RSS value without depending on GNU/BSD time output syntax.
python3 "$ROOT/benchmarks/measure.py" --output "$TMP/measure.tsv" -- \
    python3 -c 'import time; payload=bytearray(4*1024*1024); time.sleep(0.02)'
IFS=$'\t' read -r wall peak < "$TMP/measure.tsv"
[[ $wall =~ ^[0-9]+([.][0-9]+)?$ ]]
[[ $peak =~ ^[0-9]+$ ]]
awk -v value="$wall" 'BEGIN {exit !(value > 0)}'
(( peak > 0 ))

# The benchmark output contract exposes the requested five metrics directly,
# while retaining detailed phase rows and reproducibility metadata.
grep -Fq $'case\tarchive_bytes\tcreation_seconds\tverification_seconds\textraction_seconds\tpeak_memory_kib' "$ROOT/benchmarks/run.sh"
grep -Fq 'results.tsv' "$ROOT/benchmarks/run.sh"
grep -Fq 'summary.tsv' "$ROOT/benchmarks/run.sh"
grep -Fq 'environment.tsv' "$ROOT/benchmarks/run.sh"
grep -Fq 'hardcore_hash_jobs' "$ROOT/benchmarks/run.sh"
grep -Fq 'measure.py' "$ROOT/benchmarks/run.sh"

# Strong verification must remain extract-once + SHA-256. The Hardcore case
# deliberately enables the application's adaptive checksum worker policy.
grep -Fq 'sha256sum -c --quiet' "$ROOT/benchmarks/verify-archive.sh"
grep -Fq 'hardcore_enable_adaptive_hash_verifier' "$ROOT/benchmarks/verify-archive.sh"
grep -Fq 'adaptive' "$ROOT/benchmarks/run.sh"

printf 'Benchmark corpus and metrics smoke tests passed.\n'
