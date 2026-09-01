#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

(( $# == 5 )) || { printf 'Usage: %s 7z archive output-dir corpus-dir manifest\n' "${0##*/}" >&2; exit 2; }
SEVEN_ZIP=$1
ARCHIVE=$2
OUTPUT_DIR=$3
CORPUS_DIR=$4
MANIFEST=$5

"$SEVEN_ZIP" x -y -o"$OUTPUT_DIR" "$ARCHIVE"
[[ -d $CORPUS_DIR ]] || { printf 'Error: archive did not restore expected corpus directory: %s\n' "$CORPUS_DIR" >&2; exit 1; }
(cd -- "$CORPUS_DIR" && sha256sum -c --quiet "$MANIFEST")
