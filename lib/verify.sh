#!/usr/bin/env bash
[[ ${HARDCORE_VERIFY_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_VERIFY_SH_LOADED=1

hardcore_verify_command_selected() {
    local arg
    for arg in "$@"; do
        [[ $arg == --inspect ]] && return 0
    done
    return 1
}

hardcore_hash_jobs_for_manifest() {
    local manifest=$1 override=${HARDCORE_HASH_JOBS:-auto}
    local lines cpus device rotational jobs

    lines=$(wc -l < "$manifest" 2>/dev/null || printf '0')
    [[ $lines =~ ^[0-9]+$ ]] || lines=0
    (( lines > 1 )) || { printf '1\n'; return 0; }

    if [[ -n $override && $override != auto ]]; then
        if [[ ! $override =~ ^[1-9][0-9]*$ ]]; then
            printf 'Error: HARDCORE_HASH_JOBS must be auto or a positive integer.\n' >&2
            return 2
        fi
        jobs=$override
        (( jobs > lines )) && jobs=$lines
        printf '%s\n' "$jobs"
        return 0
    fi

    # Parallel reads are excellent on SSD/NVMe but can destroy throughput on a
    # rotational disk. Auto mode therefore parallelizes only when Linux can
    # positively identify the backing block device as non-rotational.
    [[ $(uname -s 2>/dev/null || true) == Linux ]] || { printf '1\n'; return 0; }
    command -v lsblk >/dev/null 2>&1 || { printf '1\n'; return 0; }
    command -v split >/dev/null 2>&1 || { printf '1\n'; return 0; }
    device=$(df -P -- "$PWD" 2>/dev/null | awk 'NR == 2 {print $1; exit}')
    [[ -n $device ]] || { printf '1\n'; return 0; }
    rotational=$(lsblk -ndo ROTA -- "$device" 2>/dev/null | head -n1 | tr -d '[:space:]')
    [[ $rotational == 0 ]] || { printf '1\n'; return 0; }

    if command -v nproc >/dev/null 2>&1; then
        cpus=$(nproc 2>/dev/null || printf '1')
    else
        cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')
    fi
    [[ $cpus =~ ^[1-9][0-9]*$ ]] || cpus=1
    jobs=$cpus
    (( jobs > 4 )) && jobs=4
    (( jobs > lines )) && jobs=$lines
    (( jobs < 1 )) && jobs=1
    printf '%s\n' "$jobs"
}

hardcore_parallel_sha256_check() {
    local manifest=$1 quiet=$2 jobs=$3
    local lines chunk temp part pid rc=0 index
    local -a pids=() parts=()

    lines=$(wc -l < "$manifest" 2>/dev/null || printf '0')
    [[ $lines =~ ^[0-9]+$ ]] || lines=0
    if (( jobs <= 1 || lines <= 1 )); then
        local -a serial_args=(-c)
        $quiet && serial_args+=(--quiet)
        serial_args+=("$manifest")
        "$HARDCORE_REAL_SHA256SUM" "${serial_args[@]}"
        return $?
    fi

    (( jobs > lines )) && jobs=$lines
    chunk=$(( (lines + jobs - 1) / jobs ))
    temp=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-hash-check.XXXXXX") || return 1
    if ! split -l "$chunk" -- "$manifest" "$temp/part."; then
        rm -rf -- "$temp"
        return 1
    fi

    for part in "$temp"/part.*; do
        parts+=("$part")
        if $quiet; then
            "$HARDCORE_REAL_SHA256SUM" -c --quiet "$part" >"$part.out" 2>"$part.err" &
        else
            "$HARDCORE_REAL_SHA256SUM" -c "$part" >"$part.out" 2>"$part.err" &
        fi
        pids+=("$!")
    done

    for ((index=0; index<${#pids[@]}; index++)); do
        pid=${pids[index]}
        if ! wait "$pid"; then rc=1; fi
    done
    for part in "${parts[@]}"; do
        cat -- "$part.out" "$part.err"
    done
    rm -rf -- "$temp"
    return "$rc"
}

hardcore_enable_adaptive_hash_verifier() {
    local real_sha=''
    if [[ -n ${HARDCORE_REAL_SHA256SUM:-} && -x ${HARDCORE_REAL_SHA256SUM:-} ]]; then
        real_sha=$HARDCORE_REAL_SHA256SUM
    else
        real_sha=$(type -P sha256sum 2>/dev/null || true)
        if [[ -z $real_sha ]]; then
            for real_sha in \
                /opt/homebrew/opt/coreutils/libexec/gnubin/sha256sum \
                /usr/local/opt/coreutils/libexec/gnubin/sha256sum
            do
                [[ -x $real_sha ]] && break
                real_sha=''
            done
        fi
    fi
    # Never hide the engine's normal missing-dependency error.
    [[ -n $real_sha && -x $real_sha ]] || return 0
    export HARDCORE_REAL_SHA256SUM=$real_sha

    sha256sum() {
        local arg manifest='' check=false quiet=false supported=true jobs
        for arg in "$@"; do
            case $arg in
                -c|--check) check=true ;;
                --quiet) quiet=true ;;
                -*) supported=false ;;
                *)
                    if [[ -n $manifest ]]; then supported=false; else manifest=$arg; fi
                    ;;
            esac
        done

        if $supported && $check && [[ -n $manifest && -r $manifest ]]; then
            jobs=$(hardcore_hash_jobs_for_manifest "$manifest") || return $?
            hardcore_parallel_sha256_check "$manifest" "$quiet" "$jobs"
            return $?
        fi
        "$HARDCORE_REAL_SHA256SUM" "$@"
    }

    export -f sha256sum hardcore_hash_jobs_for_manifest hardcore_parallel_sha256_check
}
