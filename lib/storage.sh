#!/usr/bin/env bash
# Shared post-LZMA storage staging. Transform lanes remain parallel; their
# validated outputs are hard-linked into one deterministic Copy update.
[[ ${HARDCORE_STORAGE_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_STORAGE_SH_LOADED=1

STORAGE_BATCH_REQUESTED=${HARDCORE_ARCHIVE_BATCH_STORAGE:-true}
case $STORAGE_BATCH_REQUESTED in
    true|false) ;;
    *) STORAGE_BATCH_REQUESTED=true ;;
esac

hardcore_storage_prepare_policy() {
    STORAGE_BATCH_ENABLED=false
    if [[ $STORAGE_BATCH_REQUESTED != true ]]; then
        printf 'Batched Copy storage: disabled by configuration; using per-lane updates.\n'
        return 0
    fi
    local source_device work_device
    source_device=$(df -P -- "$SOURCE_PARENT" 2>/dev/null | awk 'NR==2 {print $1}')
    work_device=$(df -P -- "$JOB_WORK_DIR" 2>/dev/null | awk 'NR==2 {print $1}')
    if [[ -n $source_device && $source_device == "$work_device" ]]; then
        STORAGE_BATCH_ENABLED=true
        printf 'Batched Copy storage: enabled on the shared source/work filesystem.\n'
    else
        printf 'Batched Copy storage: disabled across filesystems; using per-lane updates.\n'
    fi
}

hardcore_storage_stage_init() {
    [[ ${STORAGE_BATCH_ENABLED:-false} == true ]] || return 0
    STORAGE_STAGE_PARENT=$(mktemp -d -p "$JOB_WORK_DIR" ".hardcore-storage-stage.XXXXXX")
    STORAGE_BATCH_LIST="$STORAGE_STAGE_PARENT/list.txt"
    STORAGE_BATCH_COUNT=0
    : > "$STORAGE_BATCH_LIST"
}

hardcore_storage_stage_add_list() {
    [[ ${STORAGE_BATCH_ENABLED:-false} == true ]] || return 0
    local source_root=$1 list_file=$2 label=${3:-storage}
    [[ -s $list_file ]] || return 0
    local source_real relative source_path destination
    source_real=$(realpath -e -- "$source_root") || die "Storage source root disappeared: $label"
    while IFS= read -r relative; do
        [[ -n $relative ]] || continue
        [[ $relative != /* && $relative != ../* && $relative != */../* && $relative != *$'\n'* && $relative != *$'\t'* ]] || \
            die "Unsafe storage path from $label: $relative"
        source_path=$(realpath -e -- "$source_root/$relative") || \
            die "Storage candidate disappeared from $label: $relative"
        case $source_path in
            "$source_real/"*) ;;
            *) die "Storage candidate escapes its lane root: $relative" ;;
        esac
        [[ -f $source_root/$relative && ! -L $source_root/$relative ]] || \
            die "Storage candidate is not a regular file: $relative"
        destination="$STORAGE_STAGE_PARENT/$relative"
        if [[ -e $destination || -L $destination ]]; then
            die "Batched storage path collision: $relative"
        fi
        mkdir -p -- "$(dirname -- "$destination")"
        if ! ln -- "$source_path" "$destination" 2>/dev/null; then
            cp -p -- "$source_path" "$destination" || \
                die "Could not stage storage candidate: $relative"
        fi
        printf '%s\n' "$relative" >> "$STORAGE_BATCH_LIST"
        STORAGE_BATCH_COUNT=$((STORAGE_BATCH_COUNT + 1))
    done < "$list_file"
}

hardcore_storage_stage_commit() {
    [[ ${STORAGE_BATCH_ENABLED:-false} == true ]] || return 0
    hardcore_storage_stage_add_list "${CONTAINER_STAGE_PARENT:-}" "${CONTAINER_REPACKED_LIST:-}" container-repacked
    hardcore_storage_stage_add_list "${SOURCE_PARENT:-}" "${CONTAINER_FALLBACK_LIST:-}" container-fallback
    hardcore_storage_stage_add_list "${SOURCE_PARENT:-}" "${COPY_LIST:-}" copy
    hardcore_storage_stage_add_list "${VIDEO_STAGE_PARENT:-}" "${VIDEO_COMPRESSED_LIST:-}" video-transcoded
    hardcore_storage_stage_add_list "${SOURCE_PARENT:-}" "${VIDEO_FALLBACK_LIST:-}" video-fallback
    hardcore_storage_stage_add_list "${IMAGE_STAGE_PARENT:-}" "${IMAGE_OPTIMIZED_LIST:-}" image-optimized
    hardcore_storage_stage_add_list "${SOURCE_PARENT:-}" "${IMAGE_FALLBACK_LIST:-}" image-fallback
    hardcore_storage_stage_add_list "${NESTED_STAGE_PARENT:-}" "${NESTED_REPACKED_LIST:-}" nested-repacked
    hardcore_storage_stage_add_list "${SOURCE_PARENT:-}" "${NESTED_FALLBACK_LIST:-}" nested-fallback
    (( STORAGE_BATCH_COUNT > 0 )) || return 0
    (
        cd -- "$STORAGE_STAGE_PARENT"
        run_logged_stage "batched Copy storage" "$SEVEN_ZIP_LOG" \
            "$SEVEN_ZIP" a "$TEMP_ARCHIVE" -t7z -mx=0 -m0=Copy -ms=off -mmt=1 \
                -snl -snh -spd -scsUTF-8 -bsp1 -y "@$STORAGE_BATCH_LIST"
    )
    printf 'Batched Copy storage: %s validated file(s) added in one archive update.\n' "$STORAGE_BATCH_COUNT"
}
