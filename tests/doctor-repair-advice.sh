#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export HARDCORE_ARCHIVE_PACKAGE_MANAGER=apt
PLATFORM=Linux
# shellcheck source=/dev/null
source "$ROOT/lib/hardcore-archive-doctor-base.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/hardcore-archive-doctor-report.sh"

assert_has() {
    local text=$1 wanted=$2
    grep -Fq -- "$wanted" <<< "$text" || {
        printf 'Expected doctor repair output to contain: %s\n' "$wanted" >&2
        printf '%s\n' "$text" >&2
        exit 1
    }
}
assert_lacks() {
    local text=$1 unwanted=$2
    ! grep -Fq -- "$unwanted" <<< "$text" || {
        printf 'Doctor repair output unexpectedly contained: %s\n' "$unwanted" >&2
        printf '%s\n' "$text" >&2
        exit 1
    }
}
reset_failures() {
    FAIL_TYPES=()
    FAIL_CAPS=()
    FAIL_DETAILS=()
    FAIL_REPAIR_KEYS=()
    FAIL_REPAIR_CMDS=()
    REPAIR_KEY_SEEN=()
}

# Truly missing dependencies still receive a package-manager suggestion.
add_failure MISSING '7-Zip' '7-Zip is required.' 7zip
out=$(print_repair_commands)
assert_has "$out" 'Suggested install command for missing dependencies'
assert_has "$out" 'sudo apt-get update && sudo apt-get install -y'
assert_has "$out" '7zip'

# A detected FFmpeg hardware backend that fails its runtime probe must never be
# misreported as an absent FFmpeg package.
reset_failures
add_failure BROKEN 'Hardware AV1 encode' \
    'FFmpeg advertises av1_vaapi, but a real hardware encode probe failed: Device creation failed.' \
    ffmpeg-gpu
out=$(print_repair_commands)
assert_lacks "$out" 'apt-get install'
assert_lacks "$out" ' ffmpeg'
assert_has "$out" 'Automatic install commands were intentionally omitted for BROKEN/UNSUPPORTED capabilities.'

# Mixed failures install only the dependency that is genuinely missing.
reset_failures
add_failure MISSING 'Python' 'Python is required.' python
add_failure UNSUPPORTED 'FFmpeg libvmaf filter' \
    'FFmpeg is installed but this build lacks libvmaf.' ffmpeg-vmaf
out=$(print_repair_commands)
assert_has "$out" 'python3'
assert_lacks "$out" 'ffmpeg'
assert_lacks "$out" 'libvmaf'
assert_has "$out" 'Automatic install commands were intentionally omitted for BROKEN/UNSUPPORTED capabilities.'

printf 'Doctor repair-advice tests passed.\n'
