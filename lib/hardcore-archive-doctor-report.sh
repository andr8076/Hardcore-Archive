PACKAGE_MANAGER=${HARDCORE_ARCHIVE_PACKAGE_MANAGER:-}
detect_package_manager() {
    [[ -n $PACKAGE_MANAGER ]] && return 0
    if [[ $PLATFORM == Darwin ]]; then PACKAGE_MANAGER=brew
    elif command -v pacman >/dev/null 2>&1; then PACKAGE_MANAGER=pacman
    elif command -v apt-get >/dev/null 2>&1; then PACKAGE_MANAGER=apt
    elif command -v dnf >/dev/null 2>&1; then PACKAGE_MANAGER=dnf
    elif command -v zypper >/dev/null 2>&1; then PACKAGE_MANAGER=zypper
    else PACKAGE_MANAGER=unknown; fi
}

packages_for_key() {
    local key=$1
    case "$PACKAGE_MANAGER:$key" in
        pacman:coreutils) printf 'coreutils';; pacman:findutils) printf 'findutils';; pacman:util-linux) printf 'util-linux';;
        pacman:gawk) printf 'gawk';; pacman:grep) printf 'grep';; pacman:sed) printf 'sed';; pacman:7zip) printf '7zip';;
        pacman:python) printf 'python';; pacman:jpeg) printf 'libjpeg-turbo';; pacman:oxipng) printf 'oxipng';; pacman:optipng) printf 'optipng';;
        pacman:acl) printf 'acl';; pacman:systemd) printf 'systemd';; pacman:ffmpeg) printf 'ffmpeg';; pacman:ffmpeg-vmaf) printf 'ffmpeg libvmaf';;
        pacman:ffmpeg-gpu)
            if linux_has_drm_vendor 0x1002; then printf 'ffmpeg mesa libva-mesa-driver'; elif linux_has_drm_vendor 0x8086; then printf 'ffmpeg intel-media-driver'; else printf 'ffmpeg'; fi;;
        apt:coreutils) printf 'coreutils';; apt:findutils) printf 'findutils';; apt:util-linux) printf 'util-linux';; apt:gawk) printf 'gawk';; apt:grep) printf 'grep';; apt:sed) printf 'sed';;
        apt:7zip) printf '7zip p7zip-full';; apt:python) printf 'python3';; apt:jpeg) printf 'libjpeg-turbo-progs';; apt:oxipng) printf 'oxipng';; apt:optipng) printf 'optipng';;
        apt:acl) printf 'acl';; apt:systemd) printf 'systemd';; apt:ffmpeg) printf 'ffmpeg';; apt:ffmpeg-vmaf) printf 'ffmpeg libvmaf1';;
        apt:ffmpeg-gpu) if linux_has_drm_vendor 0x1002; then printf 'ffmpeg mesa-va-drivers'; elif linux_has_drm_vendor 0x8086; then printf 'ffmpeg intel-media-va-driver'; else printf 'ffmpeg'; fi;;
        dnf:coreutils) printf 'coreutils';; dnf:findutils) printf 'findutils';; dnf:util-linux) printf 'util-linux';; dnf:gawk) printf 'gawk';; dnf:grep) printf 'grep';; dnf:sed) printf 'sed';;
        dnf:7zip) printf '7zip';; dnf:python) printf 'python3';; dnf:jpeg) printf 'libjpeg-turbo-utils';; dnf:oxipng) printf 'oxipng';; dnf:optipng) printf 'optipng';;
        dnf:acl) printf 'acl';; dnf:systemd) printf 'systemd';; dnf:ffmpeg) printf 'ffmpeg';; dnf:ffmpeg-vmaf) printf 'ffmpeg libvmaf';;
        dnf:ffmpeg-gpu) if linux_has_drm_vendor 0x1002; then printf 'ffmpeg mesa-va-drivers'; elif linux_has_drm_vendor 0x8086; then printf 'ffmpeg intel-media-driver'; else printf 'ffmpeg'; fi;;
        zypper:coreutils) printf 'coreutils';; zypper:findutils) printf 'findutils';; zypper:util-linux) printf 'util-linux';; zypper:gawk) printf 'gawk';; zypper:grep) printf 'grep';; zypper:sed) printf 'sed';;
        zypper:7zip) printf '7zip';; zypper:python) printf 'python3';; zypper:jpeg) printf 'libjpeg-turbo';; zypper:oxipng) printf 'oxipng';; zypper:optipng) printf 'optipng';;
        zypper:acl) printf 'acl';; zypper:systemd) printf 'systemd';; zypper:ffmpeg) printf 'ffmpeg';; zypper:ffmpeg-vmaf) printf 'ffmpeg libvmaf';;
        zypper:ffmpeg-gpu) if linux_has_drm_vendor 0x1002; then printf 'ffmpeg Mesa-libva'; elif linux_has_drm_vendor 0x8086; then printf 'ffmpeg intel-media-driver'; else printf 'ffmpeg'; fi;;
        brew:coreutils) printf 'coreutils';; brew:findutils) printf 'findutils';; brew:util-linux) printf 'util-linux';; brew:gawk) printf 'gawk';; brew:grep) printf 'grep';; brew:sed) printf 'gnu-sed';;
        brew:7zip) printf 'sevenzip';; brew:python) printf 'python';; brew:jpeg) printf 'jpeg-turbo';; brew:oxipng) printf 'oxipng';; brew:optipng) printf 'optipng';;
        brew:acl|brew:macos-system) printf '';; brew:ffmpeg|brew:ffmpeg-vmaf|brew:ffmpeg-gpu) printf 'ffmpeg';;
        *) printf '%s' "$key";;
    esac
}

print_repair_guidance() {
    detect_package_manager
    local i key packages p detail permission_hint=false nonmissing_failure=false
    declare -A pkgset=()

    # Doctor output is intentionally informational. Package names are hints for
    # genuinely missing dependencies, never executable install instructions.
    # BROKEN and UNSUPPORTED capabilities require diagnosis of the reported
    # runtime/hardware/configuration failure rather than a guessed reinstall.
    for i in "${!FAIL_TYPES[@]}"; do
        key=${FAIL_REPAIR_KEYS[i]}
        if [[ ${FAIL_TYPES[i]} == MISSING && -n $key ]]; then
            packages=$(packages_for_key "$key")
            for p in $packages; do [[ -n $p ]] && pkgset["$p"]=1; done
        else
            nonmissing_failure=true
        fi

        detail=${FAIL_DETAILS[i]}
        if [[ ${FAIL_TYPES[i]} == BROKEN && ${FAIL_CAPS[i]} == Hardware* && $detail == *[Pp]ermission* ]]; then
            permission_hint=true
        fi
    done

    if (( ${#pkgset[@]} > 0 )); then
        printf '\nSuggested package names (informational only; verify for your system):\n'
        [[ $PACKAGE_MANAGER != unknown ]] && printf '  Package family detected: %s\n' "$PACKAGE_MANAGER"
        for p in "${!pkgset[@]}"; do printf '  - %s\n' "$p"; done
    fi

    if $permission_hint; then
        printf '\nConfiguration check:\n'
        printf '  Hardware access may depend on render/video group membership and device permissions. Verify those settings for your OS/session before changing them.\n'
    fi

    if $nonmissing_failure; then
        printf '\nFurther diagnosis:\n'
        printf '  BROKEN/UNSUPPORTED components were detected, so package installation is not assumed to be the fix. Use the failure details above to check runtime, hardware, driver, permission, service, or compatibility state.\n'
    fi

    printf '\nDoctor guidance is informational only; it does not generate repair or installation commands.\n'
}

print_doctor_report() {
    local i type shown
    printf '\nHardcore Archive doctor\n'
    printf '=======================\n'
    printf 'Source: %s\n' "$SOURCE"
    printf 'Inventory: %s files | %s videos | %s JPEG | %s PNG | %s nested archives | %s symlinks\n' "$TOTAL_FILES" "$VIDEO_COUNT" "$JPEG_COUNT" "$PNG_COUNT" "$NESTED_COUNT" "$SYMLINK_COUNT"
    printf 'Active work: archive'
    [[ $VIDEO_ENABLED == true && $VIDEO_RELEVANT == true ]] && printf ' + video(%s)' "${EFFECTIVE_VIDEO_CODEC^^}"
    [[ $IMAGE_ENABLED == true && $IMAGE_RELEVANT == true ]] && printf ' + image'
    [[ $NESTED_ENABLED == true && $NESTED_RELEVANT == true ]] && printf ' + nested-repack'
    printf '\n'

    if $DOCTOR_MODE; then
        printf '\nRequired capabilities that passed:\n'
        for i in "${!READY_LINES[@]}"; do printf '  READY        %s\n' "${READY_LINES[i]}"; done
    fi
    for i in "${!INFO_LINES[@]}"; do printf '  INFO         %s\n' "${INFO_LINES[i]}"; done

    if (( ${#FAIL_TYPES[@]} == 0 )); then
        printf '\nResult: READY. Every capability required for this source/workflow passed.\n'
        return 0
    fi
    for type in MISSING UNSUPPORTED BROKEN; do
        shown=false
        for i in "${!FAIL_TYPES[@]}"; do
            [[ ${FAIL_TYPES[i]} == "$type" ]] || continue
            if ! $shown; then printf '\n%s\n' "$type"; shown=true; fi
            printf '  %-28s %s\n' "${FAIL_CAPS[i]}" "${FAIL_DETAILS[i]}"
        done
    done
    print_repair_guidance
    printf '\nResult: NOT READY. No dependency fallback will be used.\n'
    return 1
}
