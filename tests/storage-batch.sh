#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# storage.sh is intentionally tested in isolation: production policy and the
# archive call are exercised separately from the transform workers.
source "$ROOT/lib/storage.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-storage-batch.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

mkdir -p "$TMP/source/fallback" "$TMP/transformed/optimized" "$TMP/work/stage"
printf 'original\n' > "$TMP/source/fallback/file.bin"
printf 'transformed\n' > "$TMP/transformed/optimized/file.bin"
printf 'fallback/file.bin\n' > "$TMP/fallback.list"
printf 'optimized/file.bin\n' > "$TMP/optimized.list"

SOURCE_PARENT="$TMP/source"
JOB_WORK_DIR="$TMP/work"
STORAGE_BATCH_REQUESTED=true
hardcore_storage_prepare_policy
[[ $STORAGE_BATCH_ENABLED == true ]] || {
    printf 'Expected same-filesystem batching to be enabled.\n' >&2
    exit 1
}
STORAGE_STAGE_PARENT="$TMP/work/stage"
STORAGE_BATCH_LIST="$STORAGE_STAGE_PARENT/list.txt"
STORAGE_BATCH_COUNT=0
: > "$STORAGE_BATCH_LIST"

hardcore_storage_stage_add_list "$TMP/source" "$TMP/fallback.list" fallback
hardcore_storage_stage_add_list "$TMP/transformed" "$TMP/optimized.list" optimized
[[ $STORAGE_BATCH_COUNT == 2 ]]
[[ $(cat -- "$STORAGE_STAGE_PARENT/fallback/file.bin") == original ]]
[[ $(cat -- "$STORAGE_STAGE_PARENT/optimized/file.bin") == transformed ]]
[[ $(cat -- "$STORAGE_BATCH_LIST") == $'fallback/file.bin\noptimized/file.bin' ]]

printf 'fallback/file.bin\n' > "$TMP/duplicate.list"
if (hardcore_storage_stage_add_list "$TMP/source" "$TMP/duplicate.list" duplicate); then
    printf 'Expected duplicate path rejection.\n' >&2
    exit 1
fi

printf 'Batched storage staging tests passed.\n'
