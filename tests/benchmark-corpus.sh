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
grep -Fq 'sha256sum -c --quiet' "$ROOT/benchmarks/verify-archive.sh"
grep -Fq 'peak_rss_kib' "$ROOT/benchmarks/run.sh"

printf 'Benchmark corpus smoke tests passed.\n'
