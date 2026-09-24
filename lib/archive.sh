#!/usr/bin/env bash

# Static archive-engine boundary. The final engine is checked in and syntax
# checked by the test suite; runtime source patching is deliberately forbidden.
[[ ${HARDCORE_ARCHIVE_MODULE_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_ARCHIVE_MODULE_SH_LOADED=1

# Keep automatic dictionaries no larger than the data lane, but do not
# reject a caller-pinned dictionary merely because the lane is smaller. 7-Zip
# permits that; memory limits are checked before this policy is reached.
hardcore_archive_lzma_dictionary_candidate_allowed() {
    local candidate=${1:-}
    local lane_mib=${2:-}
    local format_limit_mib=${3:-}
    local overridden=${4:-}

    [[ $candidate =~ ^[0-9]+$ && $lane_mib =~ ^[0-9]+$ && \
       $format_limit_mib =~ ^[0-9]+$ ]] || return 1
    [[ $overridden == true || $overridden == false ]] || return 1
    (( candidate >= 4 && candidate <= format_limit_mib )) || return 1
    if [[ $overridden == false ]] && (( candidate > lane_mib )); then
        return 1
    fi
    return 0
}

hardcore_archive_static_engine_ready() {
    hardcore_require_file "$HARDCORE_CORE_SOURCE" 'static archive engine'
}

hardcore_archive_build_single_pass() {
    local helper empty_stage candidate rc
    local -a helper_args manifest_items attempts
    helper="$(dirname -- "${BASH_SOURCE[0]}")/hardcore-direct-stage.py"
    [[ -f $helper ]] || die "Direct single-pass staging helper is missing: $helper"

    DIRECT_STAGE_PARENT="$JOB_WORK_DIR/direct-archive-stage"
    empty_stage="$JOB_WORK_DIR/direct-empty-lane"
    rm -rf --one-file-system -- "$DIRECT_STAGE_PARENT" "$empty_stage"
    mkdir -p -- "$empty_stage"
    helper_args=(
        --source "$SOURCE"
        --stage "$DIRECT_STAGE_PARENT"
        --manifest-stage "$ARCHIVE_MANIFEST_STAGE"
        --expected-paths "$EXPECTED_PATHS"
    )
    if [[ -s $VIDEO_RESULT_MANIFEST ]]; then
        helper_args+=(--video-manifest "$VIDEO_RESULT_MANIFEST" --video-stage "${VIDEO_STAGE_PARENT:-$empty_stage}")
    fi
    if [[ -s $IMAGE_RESULT_MANIFEST ]]; then
        helper_args+=(--image-manifest "$IMAGE_RESULT_MANIFEST" --image-stage "${IMAGE_STAGE_PARENT:-$empty_stage}")
    fi
    if [[ -s $CONTAINER_RESULT_MANIFEST ]]; then
        helper_args+=(--container-manifest "$CONTAINER_RESULT_MANIFEST" --container-stage "${CONTAINER_STAGE_PARENT:-$empty_stage}")
    fi
    if [[ -s $NESTED_RESULT_MANIFEST ]]; then
        helper_args+=(--nested-manifest "$NESTED_RESULT_MANIFEST" --nested-stage "${NESTED_STAGE_PARENT:-$empty_stage}")
    fi

    FAILURE_CONTEXT="direct-staging"
    python3 "$helper" "${helper_args[@]}" || return $?

    manifest_items=(.hardcore-archive-metadata)
    $VIDEO_WRITE_MANIFEST && (( VIDEO_COUNT > 0 )) && manifest_items+=(.hardcore-archive-video-manifest.txt)
    (( IMAGE_COUNT > 0 )) && manifest_items+=(.hardcore-archive-image-manifest.txt)
    (( CONTAINER_COUNT > 0 )) && manifest_items+=(.hardcore-archive-container-manifest.txt)
    (( NESTED_COUNT > 0 )) && manifest_items+=(.hardcore-archive-nested-manifest.txt)
    [[ -s $ARCHIVE_MANIFEST_STAGE/.hardcore-archive-sha256.txt ]] && manifest_items+=(.hardcore-archive-sha256.txt)

    attempts=("$DICTIONARY_MIB")
    if ! $DICTIONARY_WAS_OVERRIDDEN; then
        for candidate in "${DICTIONARY_CANDIDATES[@]}"; do
            (( candidate < DICTIONARY_MIB )) && attempts+=("$candidate")
        done
    fi
    for candidate in "${attempts[@]}"; do
        (( candidate <= MAX_FORMAT_DICTIONARY_MIB )) || continue
        rm -f -- "$TEMP_ARCHIVE"
        : > "$SEVEN_ZIP_LOG"
        FAILURE_CONTEXT="single-pass-compression"
        printf '\nStage 6/8: Building one solid archive from the validated transformed tree (%s MiB dictionary)...\n\n' "$candidate"
        set +e
        (
            cd -- "$DIRECT_STAGE_PARENT"
            run_logged_stage "single-pass LZMA2 compression" "$SEVEN_ZIP_LOG" \
                "$SEVEN_ZIP" a "$TEMP_ARCHIVE" "$SOURCE_NAME" "${manifest_items[@]}" \
                    -t7z -mx=9 \
                    "-m0=LZMA2:d=${candidate}m:fb=273:mf=bt4:mc=${SEARCH_CYCLES}:a=1" \
                    "-mmt=${THREADS}" -myx=9 -ms=on -mqs=on -mhc=on \
                    -snl -snh -spd -scsUTF-8 -bsp1 -y
        )
        rc=$?
        set -e
        if (( rc == 0 )); then
            DICTIONARY_MIB=$candidate
            ESTIMATED_COMPRESSION_RAM_MIB=$((candidate * 23 / 2 + 512))
            return 0
        fi
        if (( rc == 8 )) || grep -Eqi 'not enough memory|out of memory|cannot allocate memory|memory allocation' "$SEVEN_ZIP_LOG"; then
            $DICTIONARY_WAS_OVERRIDDEN && return "$rc"
            warn "The ${candidate} MiB dictionary could not be allocated. Retrying the single pass with a smaller dictionary."
            continue
        fi
        return "$rc"
    done
    die "No usable LZMA2 dictionary could be allocated for the single-pass archive."
}
