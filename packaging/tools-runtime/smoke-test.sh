#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

RUNTIME=${1:-}
[[ -d $RUNTIME/bin && -r $RUNTIME/tools-runtime-manifest.txt ]] || {
    printf 'Usage: %s RUNTIME_DIRECTORY\n' "$0" >&2
    exit 2
}
RUNTIME=$(cd -- "$RUNTIME" && pwd -P)
# Bash must be able to start before the application has exported its bundled
# library path.
env -i PATH=/usr/bin:/bin "$RUNTIME/bin/bash" --version >/dev/null
PATH="$RUNTIME/bin:/usr/bin:/bin"
export PATH
case $(uname -s) in
    Darwin) DYLD_LIBRARY_PATH="$RUNTIME/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"; export DYLD_LIBRARY_PATH ;;
    *) LD_LIBRARY_PATH="$RUNTIME/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"; export LD_LIBRARY_PATH ;;
esac
if [[ -r $RUNTIME/share/misc/magic.mgc ]]; then MAGIC="$RUNTIME/share/misc/magic.mgc"; export MAGIC; fi

bash --version >/dev/null
python3 --version >/dev/null
stat -c '%s' -- /dev/null >/dev/null
realpath -m -- . >/dev/null
numfmt --to=iec-i 1024 >/dev/null
printf 'b\0a\0' | sort -z >/dev/null
find . -maxdepth 0 -printf '%p\0' >/dev/null
flock --version >/dev/null
ARCHIVE_TEST=$(mktemp -d "${TMPDIR:-/tmp}/hca-7zip-smoke.XXXXXX")
trap 'rm -rf -- "$ARCHIVE_TEST"' EXIT
printf 'portable runtime\n' > "$ARCHIVE_TEST/input.txt"
7z a "$ARCHIVE_TEST/test.7z" "$ARCHIVE_TEST/input.txt" >/dev/null
7z t "$ARCHIVE_TEST/test.7z" >/dev/null
jpegtran -version >/dev/null 2>&1
djpeg -version >/dev/null 2>&1
oxipng --version >/dev/null
file --version >/dev/null

if [[ $(uname -s) == Linux ]]; then
    getfacl --version >/dev/null
    findmnt --version >/dev/null
    lsblk --version >/dev/null
    setsid --version >/dev/null
fi
printf 'Portable tools runtime smoke test passed.\n'
