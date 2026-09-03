#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-runtime-build-safety.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

if HCA_RUNTIME_WORK=/ HCA_RUNTIME_OUT="$TMP/output" \
    bash "$ROOT/packaging/media-runtime/build.sh" >"$TMP/root.out" 2>&1; then
    printf 'Runtime builder accepted the filesystem root as its work directory.\n' >&2
    exit 1
fi
grep -Fq 'Refusing unsafe work directory: /' "$TMP/root.out"

mkdir -p "$TMP/user-data"
printf 'must survive\n' > "$TMP/user-data/important.txt"
if HCA_RUNTIME_WORK="$TMP/user-data" HCA_RUNTIME_OUT="$TMP/output" \
    bash "$ROOT/packaging/media-runtime/build.sh" >"$TMP/nonempty.out" 2>&1; then
    printf 'Runtime builder accepted an unmarked non-empty work directory.\n' >&2
    exit 1
fi
grep -Fq 'Refusing to clean unmarked non-empty runtime work directory' "$TMP/nonempty.out"
[[ $(cat "$TMP/user-data/important.txt") == 'must survive' ]]

if HCA_RUNTIME_WORK="$TMP/overlap" HCA_RUNTIME_OUT="$TMP/overlap/output" \
    bash "$ROOT/packaging/media-runtime/build.sh" >"$TMP/overlap.out" 2>&1; then
    printf 'Runtime builder accepted overlapping work and output directories.\n' >&2
    exit 1
fi
grep -Fq 'must not overlap' "$TMP/overlap.out"

printf 'Runtime build path safety tests passed.\n'
