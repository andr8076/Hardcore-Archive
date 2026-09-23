#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
CORE="$ROOT/lib/hardcore-archive-core.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-nested-paths.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

extract_function() {
    local marker=$1
    awk -v marker="$marker" '
        $0 == marker { copy=1 }
        copy { print }
        copy && $0 == "}" { exit }
    ' "$CORE"
}

eval "$(extract_function 'archive_replacement_path() {')"
eval "$(extract_function 'validate_transformed_path_collisions() {')"

[[ $(archive_replacement_path 'tree/valid-inner.tar.gz') == 'tree/valid-inner.tar.gz.7z' ]]
[[ $(archive_replacement_path 'tree/valid-inner.zip') == 'tree/valid-inner.zip.7z' ]]

SNAPSHOT_BEFORE="$TMP/snapshot"
VIDEO_LIST="$TMP/videos"
NESTED_LIST="$TMP/nested"
: > "$VIDEO_LIST"
printf 'f\t10\t1\t1\ttree/valid-inner.tar.gz\0f\t20\t1\t1\ttree/valid-inner.zip\0' > "$SNAPSHOT_BEFORE"
printf 'tree/valid-inner.tar.gz\ntree/valid-inner.zip\n' > "$NESTED_LIST"
validate_transformed_path_collisions
# Two video inputs with the same stem must fail before transform workers start.
printf 'f\t1\t1\t1\ttree/movie.mp4\0f\t1\t1\t1\ttree/movie.mov\0' > "$SNAPSHOT_BEFORE"
printf 'tree/movie.mp4\ntree/movie.mov\n' > "$VIDEO_LIST"
: > "$NESTED_LIST"
if validate_transformed_path_collisions; then
    printf 'Duplicate video output paths were accepted.\n' >&2
    exit 1
fi

# A nested output may not overwrite any existing file, directory, or symlink.
printf 'f\t1\t1\t1\ttree/inner.zip\0f\t1\t1\t1\ttree/inner.zip.7z\0' > "$SNAPSHOT_BEFORE"
: > "$VIDEO_LIST"
printf 'tree/inner.zip\n' > "$NESTED_LIST"
if validate_transformed_path_collisions; then
    printf 'A nested output overwrote an existing source path.\\n' >&2
    exit 1
fi

printf 'Nested output path tests passed.\n'
