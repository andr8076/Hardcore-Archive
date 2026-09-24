#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

source "$ROOT/lib/archive.sh"

allow() {
    hardcore_archive_lzma_dictionary_candidate_allowed "$@"
}
reject() {
    if hardcore_archive_lzma_dictionary_candidate_allowed "$@"; then
        printf 'Unexpectedly accepted dictionary policy: %s\n' "$*" >&2
        exit 1
    fi
}

# Nested workers receive a parent-assigned, RAM-preflighted 8 MiB dictionary.
# A smaller LZMA lane must not prevent trying that explicit grant.
allow 8 4 1536 true

# Automatic candidates remain input-sized, and format ceilings still apply
# even when the user or parent explicitly selected the dictionary.
reject 8 4 1536 false
allow 4 4 1536 false
reject 2048 4 1536 true
reject invalid 4 1536 true

printf 'Archive LZMA dictionary policy tests passed.\n'
