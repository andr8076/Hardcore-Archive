#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP=${1:-}
[[ -x $APP/hardcore-archive.sh && -d $APP/runtime/bin ]] || {
    printf 'Usage: %s EXTRACTED_APPLICATION_DIRECTORY\n' "$0" >&2
    exit 2
}
APP=$(cd -- "$APP" && pwd -P)

# The portable launcher must start its own Bash before runtime.sh has a chance
# to set any library variables.
env -i HOME="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin \
    "$APP/runtime/bin/bash" --version >/dev/null
HELP=$(env -i HOME="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin \
    HARDCORE_ARCHIVE_AUTO_RUNTIME=0 "$APP/hardcore-archive.sh" --help)
[[ $HELP == *'Hardcore Archive'* ]] || {
    printf 'Portable launcher did not reach the application help screen.\n' >&2
    exit 1
}
printf 'Portable application smoke test passed.\n'
