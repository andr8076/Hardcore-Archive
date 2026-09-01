#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

(( $# >= 5 && $# <= 6 )) || {
    printf 'Usage: %s 7z archive output-dir corpus-dir manifest [plain|adaptive]\n' "${0##*/}" >&2
    exit 2
}
SEVEN_ZIP=$1
ARCHIVE=$2
OUTPUT_DIR=$3
CORPUS_DIR=$4
MANIFEST=$5
MODE=${6:-plain}

case $MODE in
    plain) ;;
    adaptive)
        ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
        VERIFY_MODULE=${HARDCORE_VERIFY_MODULE:-$ROOT/lib/verify.sh}
        [[ -f $VERIFY_MODULE ]] || {
            printf 'Error: adaptive verification module is missing: %s\n' "$VERIFY_MODULE" >&2
            exit 2
        }
        # shellcheck source=/dev/null
        source "$VERIFY_MODULE"
        hardcore_enable_adaptive_hash_verifier
        ;;
    *)
        printf 'Error: verification mode must be plain or adaptive.\n' >&2
        exit 2
        ;;
esac

"$SEVEN_ZIP" x -y -o"$OUTPUT_DIR" "$ARCHIVE"
[[ -d $CORPUS_DIR ]] || {
    printf 'Error: archive did not restore expected corpus directory: %s\n' "$CORPUS_DIR" >&2
    exit 1
}
(cd -- "$CORPUS_DIR" && sha256sum -c --quiet "$MANIFEST")
