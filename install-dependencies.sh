#!/usr/bin/env bash
# Install Hardcore Archive runtime dependencies using the host package manager.
# This script is intentionally separate from the archive engine: it never runs
# unless a person invokes it directly or accepts the doctor's install prompt.

set -eu
(set -o pipefail) 2>/dev/null && set -o pipefail
# Logical keys and package names are fixed, whitespace-free tokens.
IFS=' 	
'

PROGRAM_NAME=${0##*/}
ASSUME_YES=false
DRY_RUN=false
REQUESTED_KEYS=''
PACKAGE_MANAGER=${HARDCORE_ARCHIVE_PACKAGE_MANAGER:-}

usage() {
    cat <<EOF
Usage:
  $PROGRAM_NAME [--yes] [--dry-run] [--all]
  $PROGRAM_NAME [--yes] [--dry-run] --keys KEY [KEY ...]

Without --keys, the complete portable runtime set is installed.

Options:
  --all       Install the complete dependency set.
  --keys      Install only doctor-selected logical capabilities.
  --yes       The caller already confirmed the displayed plan.
  --dry-run   Print the detected manager, logical keys, and packages only.
  -h, --help  Show this help.

Supported package managers:
  apt, dnf, yum, pacman, zypper, apk, and Homebrew on macOS.
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

detect_package_manager() {
    if [ -n "$PACKAGE_MANAGER" ]; then
        return
    fi
    case $(uname -s 2>/dev/null || printf unknown) in
        Darwin)
            if command -v brew >/dev/null 2>&1; then
                PACKAGE_MANAGER=brew
            elif [ -x /opt/homebrew/bin/brew ]; then
                PATH="/opt/homebrew/bin:$PATH"; export PATH; PACKAGE_MANAGER=brew
            elif [ -x /usr/local/bin/brew ]; then
                PATH="/usr/local/bin:$PATH"; export PATH; PACKAGE_MANAGER=brew
            else
                die 'Homebrew is required on macOS. Install it from https://brew.sh, then rerun this script.'
            fi
            ;;
        Linux)
            if command -v apt-get >/dev/null 2>&1; then PACKAGE_MANAGER=apt
            elif command -v dnf >/dev/null 2>&1; then PACKAGE_MANAGER=dnf
            elif command -v yum >/dev/null 2>&1; then PACKAGE_MANAGER=yum
            elif command -v pacman >/dev/null 2>&1; then PACKAGE_MANAGER=pacman
            elif command -v zypper >/dev/null 2>&1; then PACKAGE_MANAGER=zypper
            elif command -v apk >/dev/null 2>&1; then PACKAGE_MANAGER=apk
            else die 'No supported Linux package manager was detected.'
            fi
            ;;
        *) die "Unsupported operating system: $(uname -s 2>/dev/null || printf unknown)" ;;
    esac
}

apt_has_package() {
    apt-cache show "$1" >/dev/null 2>&1
}

png_package() {
    case $PACKAGE_MANAGER in
        apt)
            if apt_has_package oxipng; then printf '%s\n' oxipng; else printf '%s\n' optipng; fi
            ;;
        pacman|brew) printf '%s\n' oxipng ;;
        dnf|yum|zypper|apk) printf '%s\n' optipng ;;
    esac
}

sevenzip_packages() {
    case $PACKAGE_MANAGER in
        apt)
            if apt_has_package 7zip; then printf '%s\n' 7zip; else printf '%s\n' p7zip-full; fi
            ;;
        dnf)
            printf '%s\n' 7zip
            ;;
        yum)
            printf '%s\n' p7zip p7zip-plugins
            ;;
        pacman) printf '%s\n' 7zip ;;
        zypper) printf '%s\n' 7zip ;;
        apk) printf '%s\n' 7zip ;;
        brew) printf '%s\n' sevenzip ;;
    esac
}

packages_for_key() {
    key=$1
    case "$PACKAGE_MANAGER:$key" in
        apt:bash) printf '%s\n' bash ;;
        apt:coreutils) printf '%s\n' coreutils ;;
        apt:findutils) printf '%s\n' findutils ;;
        apt:util-linux) printf '%s\n' util-linux ;;
        apt:gawk) printf '%s\n' gawk ;;
        apt:grep) printf '%s\n' grep ;;
        apt:sed) printf '%s\n' sed ;;
        apt:python) printf '%s\n' python3 ;;
        apt:jpeg) printf '%s\n' libjpeg-turbo-progs ;;
        apt:acl) printf '%s\n' acl ;;
        apt:ffmpeg|apt:ffmpeg-vmaf|apt:ffmpeg-gpu) printf '%s\n' ffmpeg ;;
        apt:file) printf '%s\n' file ;;
        apt:git) printf '%s\n' git ca-certificates ;;
        apt:systemd) printf '%s\n' systemd ;;

        dnf:bash|yum:bash) printf '%s\n' bash ;;
        dnf:coreutils|yum:coreutils) printf '%s\n' coreutils ;;
        dnf:findutils|yum:findutils) printf '%s\n' findutils ;;
        dnf:util-linux|yum:util-linux) printf '%s\n' util-linux ;;
        dnf:gawk|yum:gawk) printf '%s\n' gawk ;;
        dnf:grep|yum:grep) printf '%s\n' grep ;;
        dnf:sed|yum:sed) printf '%s\n' sed ;;
        dnf:python|yum:python) printf '%s\n' python3 ;;
        dnf:jpeg|yum:jpeg) printf '%s\n' libjpeg-turbo-utils ;;
        dnf:acl|yum:acl) printf '%s\n' acl ;;
        dnf:ffmpeg|dnf:ffmpeg-vmaf|dnf:ffmpeg-gpu|yum:ffmpeg|yum:ffmpeg-vmaf|yum:ffmpeg-gpu) printf '%s\n' ffmpeg ;;
        dnf:file|yum:file) printf '%s\n' file ;;
        dnf:git|yum:git) printf '%s\n' git ca-certificates ;;
        dnf:systemd|yum:systemd) printf '%s\n' systemd ;;

        pacman:bash) printf '%s\n' bash ;;
        pacman:coreutils) printf '%s\n' coreutils ;;
        pacman:findutils) printf '%s\n' findutils ;;
        pacman:util-linux) printf '%s\n' util-linux ;;
        pacman:gawk) printf '%s\n' gawk ;;
        pacman:grep) printf '%s\n' grep ;;
        pacman:sed) printf '%s\n' sed ;;
        pacman:python) printf '%s\n' python ;;
        pacman:jpeg) printf '%s\n' libjpeg-turbo ;;
        pacman:acl) printf '%s\n' acl ;;
        pacman:ffmpeg|pacman:ffmpeg-vmaf|pacman:ffmpeg-gpu) printf '%s\n' ffmpeg ;;
        pacman:file) printf '%s\n' file ;;
        pacman:git) printf '%s\n' git ca-certificates ;;
        pacman:systemd) printf '%s\n' systemd ;;

        zypper:bash) printf '%s\n' bash ;;
        zypper:coreutils) printf '%s\n' coreutils ;;
        zypper:findutils) printf '%s\n' findutils ;;
        zypper:util-linux) printf '%s\n' util-linux ;;
        zypper:gawk) printf '%s\n' gawk ;;
        zypper:grep) printf '%s\n' grep ;;
        zypper:sed) printf '%s\n' sed ;;
        zypper:python) printf '%s\n' python3 ;;
        zypper:jpeg) printf '%s\n' libjpeg-turbo ;;
        zypper:acl) printf '%s\n' acl ;;
        zypper:ffmpeg|zypper:ffmpeg-vmaf|zypper:ffmpeg-gpu) printf '%s\n' ffmpeg ;;
        zypper:file) printf '%s\n' file ;;
        zypper:git) printf '%s\n' git ca-certificates ;;
        zypper:systemd) printf '%s\n' systemd ;;

        apk:bash) printf '%s\n' bash ;;
        apk:coreutils) printf '%s\n' coreutils ;;
        apk:findutils) printf '%s\n' findutils ;;
        apk:util-linux) printf '%s\n' util-linux ;;
        apk:gawk) printf '%s\n' gawk ;;
        apk:grep) printf '%s\n' grep ;;
        apk:sed) printf '%s\n' sed ;;
        apk:python) printf '%s\n' python3 ;;
        apk:jpeg) printf '%s\n' libjpeg-turbo-utils ;;
        apk:acl) printf '%s\n' acl ;;
        apk:ffmpeg|apk:ffmpeg-vmaf|apk:ffmpeg-gpu) printf '%s\n' ffmpeg ;;
        apk:file) printf '%s\n' file ;;
        apk:git) printf '%s\n' git ca-certificates ;;
        apk:systemd) printf '%s\n' '' ;;

        brew:bash) printf '%s\n' bash ;;
        brew:coreutils) printf '%s\n' coreutils ;;
        brew:findutils) printf '%s\n' findutils ;;
        brew:util-linux) printf '%s\n' util-linux ;;
        brew:gawk) printf '%s\n' gawk ;;
        brew:grep) printf '%s\n' grep ;;
        brew:sed) printf '%s\n' gnu-sed ;;
        brew:python) printf '%s\n' python ;;
        brew:jpeg) printf '%s\n' jpeg-turbo ;;
        brew:acl|brew:systemd|brew:macos-system) printf '%s\n' '' ;;
        brew:ffmpeg|brew:ffmpeg-vmaf|brew:ffmpeg-gpu) printf '%s\n' ffmpeg ;;
        brew:file) printf '%s\n' '' ;;
        brew:git) printf '%s\n' git ;;

        *:7zip) sevenzip_packages ;;
        *:oxipng|*:optipng|*:png) png_package ;;
        *) die "Unsupported dependency key '$key' for package manager '$PACKAGE_MANAGER'." ;;
    esac
}

append_package() {
    package=$1
    [ -n "$package" ] || return 0
    case " $PACKAGES " in
        *" $package "*) ;;
        *) PACKAGES="$PACKAGES $package" ;;
    esac
}

while [ $# -gt 0 ]; do
    case $1 in
        --yes|-y) ASSUME_YES=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --all) REQUESTED_KEYS=''; shift ;;
        --keys)
            shift
            [ $# -gt 0 ] || die '--keys requires at least one logical capability.'
            while [ $# -gt 0 ]; do
                REQUESTED_KEYS="$REQUESTED_KEYS $1"
                shift
            done
            ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

detect_package_manager
if [ -z "$REQUESTED_KEYS" ]; then
    REQUESTED_KEYS='bash coreutils findutils util-linux gawk grep sed 7zip python jpeg oxipng acl ffmpeg file git'
fi

PACKAGES=''
for key in $REQUESTED_KEYS; do
    for package in $(packages_for_key "$key"); do
        append_package "$package"
    done
done
PACKAGES=${PACKAGES# }

printf 'Hardcore Archive dependency installer\n'
printf 'Package manager: %s\n' "$PACKAGE_MANAGER"
printf 'Logical requirements:%s\n' "$REQUESTED_KEYS"
printf 'Packages: %s\n' "${PACKAGES:-none required on this platform}"

[ -n "$PACKAGES" ] || {
    printf 'No package installation is required for the selected capabilities on this platform.\n'
    exit 0
}
$DRY_RUN && exit 0

if ! $ASSUME_YES; then
    [ -t 0 ] || die 'Installation requires an interactive terminal, or --yes after explicit approval.'
    printf 'Install these packages now? [y/N] '
    IFS= read -r answer
    case $answer in y|Y|yes|YES|Yes) ;; *) printf 'Cancelled.\n'; exit 2 ;; esac
fi

run_privileged() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        die 'Root privileges are required and sudo is unavailable.'
    fi
}

# Package names are selected only from the fixed mappings above. Word splitting
# here intentionally turns the validated package list into argv entries.
case $PACKAGE_MANAGER in
    apt)
        run_privileged apt-get update
        # shellcheck disable=SC2086
        run_privileged apt-get install -y -- $PACKAGES
        ;;
    dnf)
        # shellcheck disable=SC2086
        run_privileged dnf install -y -- $PACKAGES
        ;;
    yum)
        # shellcheck disable=SC2086
        run_privileged yum install -y -- $PACKAGES
        ;;
    pacman)
        # Arch-family systems require a complete repository/system transaction.
        # shellcheck disable=SC2086
        run_privileged pacman -Syu --needed --noconfirm $PACKAGES
        ;;
    zypper)
        # shellcheck disable=SC2086
        run_privileged zypper --non-interactive install -- $PACKAGES
        ;;
    apk)
        # shellcheck disable=SC2086
        run_privileged apk add -- $PACKAGES
        ;;
    brew)
        # shellcheck disable=SC2086
        brew install $PACKAGES
        ;;
esac

printf 'Dependency installation completed. Rerun Hardcore Archive --doctor to verify runtime capabilities.\n'
