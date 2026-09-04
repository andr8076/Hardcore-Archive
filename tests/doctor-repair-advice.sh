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
        printf 'Expected doctor guidance output to contain: %s\n' "$wanted" >&2
        printf '%s\n' "$text" >&2
        exit 1
    }
}
assert_lacks() {
    local text=$1 unwanted=$2
    ! grep -Fq -- "$unwanted" <<< "$text" || {
        printf 'Doctor guidance output unexpectedly contained: %s\n' "$unwanted" >&2
        printf '%s\n' "$text" >&2
        exit 1
    }
}
assert_no_repair_commands() {
    local text=$1 forbidden
    for forbidden in \
        'sudo ' \
        'apt-get ' \
        'pacman -S' \
        'dnf install' \
        'zypper install' \
        'brew install' \
        'usermod '
    do
        assert_lacks "$text" "$forbidden"
    done
}
reset_failures() {
    FAIL_TYPES=()
    FAIL_CAPS=()
    FAIL_DETAILS=()
    FAIL_REPAIR_KEYS=()
    REPAIR_KEY_SEEN=()
}

# Missing dependencies get package-name hints, never shell commands.
add_failure MISSING '7-Zip' '7-Zip is required.' 7zip
out=$(print_repair_guidance)
assert_has "$out" 'Suggested package names (informational only; verify for your system):'
assert_has "$out" 'Package family detected: apt'
assert_has "$out" '- 7zip'
assert_no_repair_commands "$out"

# A detected FFmpeg hardware backend that fails its runtime probe receives
# diagnostic guidance only and must not be presented as a package problem.
reset_failures
add_failure BROKEN 'Hardware AV1 encode' \
    'FFmpeg advertises av1_vaapi, but a real hardware encode probe failed: Device creation failed.' \
    ffmpeg-gpu
out=$(print_repair_guidance)
assert_has "$out" 'Further diagnosis:'
assert_has "$out" 'package installation is not assumed to be the fix'
assert_lacks "$out" 'Suggested package names'
assert_lacks "$out" 'ffmpeg'
assert_no_repair_commands "$out"

# Permission failures may suggest what to inspect, but never print a user/group
# mutation command.
reset_failures
add_failure BROKEN 'Hardware HEVC encode' \
    'Hardware device permission denied while opening the render node.' \
    ffmpeg-gpu
out=$(print_repair_guidance)
assert_has "$out" 'Configuration check:'
assert_has "$out" 'render/video group membership and device permissions'
assert_no_repair_commands "$out"

# Mixed failures name only packages associated with genuinely missing items;
# detected-but-unsupported components stay in diagnostic guidance.
reset_failures
add_failure MISSING 'Python' 'Python is required.' python
add_failure UNSUPPORTED 'FFmpeg libvmaf filter' \
    'FFmpeg is installed but this build lacks libvmaf.' ffmpeg-vmaf
out=$(print_repair_guidance)
assert_has "$out" '- python3'
assert_lacks "$out" 'ffmpeg'
assert_lacks "$out" 'libvmaf'
assert_has "$out" 'Further diagnosis:'
assert_no_repair_commands "$out"

# Neither the reporting module nor the failure-recording layer may retain a
# repair-command output/template channel.
report_source=$(<"$ROOT/lib/hardcore-archive-doctor-report.sh")
base_source=$(<"$ROOT/lib/hardcore-archive-doctor-base.sh")
assert_no_repair_commands "$report_source"
assert_lacks "$report_source" 'print_repair_commands'
assert_has "$report_source" 'print_repair_guidance'
assert_lacks "$base_source" 'FAIL_REPAIR_CMDS'

printf 'Doctor informational-guidance tests passed.\n'
