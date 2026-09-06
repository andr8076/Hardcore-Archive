#!/usr/bin/env bash

# Parallel nested-archive execution policy. Each candidate is processed in an
# isolated worker; only the parent mutates shared manifests and counters.
[[ ${HARDCORE_NESTED_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_NESTED_SH_LOADED=1

hardcore_nested_runtime_ready() { return 0; }

prepare_and_add_nested_archives() {
    (( NESTED_COUNT > 0 )) || return 0
    $NESTED_REPACK || return 0

    FAILURE_CONTEXT="nested-archive-repack"
    printf '\nProcessing %s independent nested archive(s) through the shared CPU/RAM pool...\n' "$NESTED_COUNT"

    # Nested work happens after the parent LZMA/media lanes. Expand defensively
    # in case an earlier path had no reason to release the reservation itself.
    if $RESOURCE_POOL_ENABLED && ! $RESOURCE_POOL_EXPANDED; then
        resource_pool_release_lzma_reservation
    fi
    $RESOURCE_POOL_ENABLED || die 'Nested archive parallelism requires the shared CPU/RAM resource pool.'
    [[ -f $RESOURCE_POOL_RUNNER ]] || die "Trusted resource scheduler is missing: $RESOURCE_POOL_RUNNER"

    local helper=${HARDCORE_ARCHIVE_NESTED_HELPER_SOURCE:-"$(dirname -- "${BASH_SOURCE[0]}")/hardcore-archive-nested-worker.sh"}
    [[ -f $helper ]] || die "Trusted nested archive worker is missing: $helper"
    command -v python3 >/dev/null 2>&1 || die 'Nested archive scheduling requires Python 3.'

    choose_nested_work_root
    NESTED_STAGE_PARENT=$(mktemp -d -p "$NESTED_WORK_ROOT" nested-archives.XXXXXX)
    local task_root="$NESTED_STAGE_PARENT/tasks"
    local result_root="$NESTED_STAGE_PARENT/results"
    local log_root="$NESTED_STAGE_PARENT/logs"
    mkdir -p -- "$task_root" "$result_root" "$log_root"
    : > "$NESTED_RESULT_MANIFEST"
    : > "$NESTED_REPACKED_LIST"
    : > "$NESTED_FALLBACK_LIST"

    local depth=${HARDCORE_ARCHIVE_NESTED_DEPTH:-0}
    local script_path
    script_path=$(resolve_current_script) || die 'Could not locate the recursive archive engine.'
    local gpu_lock=${HARDCORE_ARCHIVE_PARENT_GPU_LOCK:-$RESOURCE_POOL_DIR/nested-hardware-video.lock}
    local video_transcode_flag=false
    $VIDEO_TRANSCODE && video_transcode_flag=true
    local nested_cpu_max
    nested_cpu_max=$(hardcore_resource_nested_cpu_max "$CPU_THREADS" "$NESTED_COUNT") || \
        die 'Could not calculate nested archive CPU claims.'

    local -a inherited=(
        --force --yes --no-report --allow-sleep --nested-max-depth "$NESTED_MAX_DEPTH"
    )
    $VIDEO_TRANSCODE || inherited+=(--no-video-transcode)
    inherited+=(
        --video-codec "$VIDEO_CODEC"
        --video-mode "$VIDEO_MODE"
        --video-special-policy "${VIDEO_SPECIAL_POLICY:-ask}"
        --quality-check "$QUALITY_CHECK"
        --video-min-vmaf "$VIDEO_MIN_VMAF"
    )
    [[ -n $VIDEO_ENCODER ]] && inherited+=(--video-encoder "$VIDEO_ENCODER")
    $IMAGE_OPTIMIZE || inherited+=(--no-image-optimize)
    inherited+=(--image-mode "$IMAGE_MODE" --verify "$VERIFY_MODE_EFFECTIVE" --effort "$EFFORT")
    $MC_AUTO && inherited+=(--mc-auto) || inherited+=(--no-mc-auto)

    local free_bytes disk_budget max_expanded
    free_bytes=$(df -PB1 -- "$NESTED_STAGE_PARENT" | awk 'NR==2{print $4}')
    [[ $free_bytes =~ ^[0-9]+$ ]] || die 'Could not determine free nested-work space.'
    if (( free_bytes > 512 * MIB )); then
        disk_budget=$((free_bytes - 512 * MIB))
    else
        disk_budget=0
    fi
    max_expanded=$disk_budget

    local -a relatives=() outputs=() originals=() expandeds=() work_estimates=()
    local -a ram_claims=() result_files=() log_files=() task_dirs=() diagnostics=()
    local -a safe=() worker_rc=() calibrations=()
    local relative input output_rel original_size expanded files encrypted reason
    local work_estimate ram_claim result_file log_file task_dir diag calibration index=0

    # Cheap archive-header checks run serially. They establish disk/RAM claims
    # before any extraction starts, and unsafe archives become deterministic
    # fallback rows without consuming worker tokens.
    while IFS= read -r relative; do
        [[ -n $relative ]] || continue
        input="$SOURCE_PARENT/$relative"
        original_size=$(stat -c '%s' -- "$input")
        output_rel=$(archive_replacement_path "$relative")
        result_file=$(printf '%s/%06d.tsv' "$result_root" "$index")
        task_dir=$(printf '%s/%06d' "$task_root" "$index")
        if [[ -n ${HARDCORE_ARCHIVE_DIAGNOSTIC_DIR:-} ]]; then
            diag="$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/nested/depth-$((depth + 1))/$(printf '%06d-%s' "$index" "$(safe_slug "$relative")")"
            mkdir -p -- "$diag"
            log_file="$diag/run.log"
        else
            diag="$task_dir/diagnostics"
            log_file=$(printf '%s/%06d.log' "$log_root" "$index")
        fi
        mkdir -p -- "$task_dir" "$(dirname -- "$log_file")"
        : > "$log_file"

        relatives[index]=$relative
        outputs[index]=$output_rel
        originals[index]=$original_size
        result_files[index]=$result_file
        log_files[index]=$log_file
        task_dirs[index]=$task_dir
        diagnostics[index]=$diag
        worker_rc[index]=0
        safe[index]=false
        expanded=0
        files=0
        encrypted=0
        reason=''

        if (( depth >= NESTED_MAX_DEPTH )); then
            reason=max-depth-reached
        else
            expanded=$("$SEVEN_ZIP" l -slt "$input" 2>/dev/null | \
                awk -F' = ' '/^Size = [0-9]+$/ {s+=$2} END{printf "%.0f",s+0}')
            files=$("$SEVEN_ZIP" l -slt "$input" 2>/dev/null | \
                awk '/^Path = /{n++} END{print n+0}')
            encrypted=$("$SEVEN_ZIP" l -slt "$input" 2>/dev/null | \
                awk -F' = ' '/^Encrypted = \+/{print 1; exit}')
            [[ $expanded =~ ^[0-9]+$ ]] || expanded=0
            [[ $files =~ ^[0-9]+$ ]] || files=0
            [[ $encrypted == 1 ]] || encrypted=0

            if (( encrypted == 1 )); then
                reason=encrypted-archive
            elif (( files > 100000 )); then
                reason=entry-count-limit
            elif (( expanded > max_expanded )); then
                reason=insufficient-safe-extraction-space
            elif (( original_size > 0 && expanded / original_size > 1000 )); then
                reason=unsafe-expansion-ratio
            fi
        fi

        expandeds[index]=$expanded
        if [[ -n $reason ]]; then
            printf 'original\t%s\t%s\t%s\t0\t%s\t%s\n' \
                "$relative" "$relative" "$original_size" "$original_size" "$reason" > "$result_file"
            printf 'Nested preflight preserved original: %s (%s)\n' "$relative" "$reason" >> "$log_file"
        else
            # Conservative peak-disk estimate: source extraction + recursive
            # child work/archive + normalized extraction/candidate. It is only
            # an in-flight disk gate; CPU/RAM authority remains the shared pool.
            work_estimate=$((expanded * 3 + original_size * 2 + 512 * MIB))
            (( work_estimate < 512 * MIB )) && work_estimate=$((512 * MIB))
            work_estimates[index]=$work_estimate
            ram_claim=$(hardcore_resource_nested_ram_claim \
                "$expanded" "$RESOURCE_POOL_MAX_RAM_MIB" "$MAX_FORMAT_DICTIONARY_MIB") || \
                die "Could not calculate nested RAM claim for: $relative"
            ram_claims[index]=$ram_claim
            calibration=$(hardcore_calibration_identity "$input" 2>/dev/null || true)
            calibrations[index]=$calibration
            safe[index]=true
            printf 'Nested preflight: %s | expanded %s | claim 1..%s CPU / %s MiB RAM\n' \
                "$relative" "$(human_bytes "$expanded")" "$nested_cpu_max" "$ram_claim"
        fi
        index=$((index + 1))
    done < "$NESTED_LIST"

    local total=$index max_dispatch=$CPU_THREADS
    (( max_dispatch > total )) && max_dispatch=$total
    (( max_dispatch < 1 )) && max_dispatch=1
    local active=0 active_disk=0 next_idx pid i chosen done_idx rc
    local -a pids=() pid_indexes=()

    # Reap the first completed worker. Resource tokens are automatically
    # released by the pool runner even after a crash; this parent only releases
    # the independent disk-in-flight reservation.
    _hardcore_nested_reap_one() {
        local chosen=-1 i pid done_idx rc=0
        while (( chosen < 0 )); do
            for i in "${!pids[@]}"; do
                pid=${pids[i]}
                if ! kill -0 "$pid" 2>/dev/null; then
                    chosen=$i
                    break
                fi
            done
            (( chosen >= 0 )) || sleep 0.1
        done
        pid=${pids[chosen]}
        done_idx=${pid_indexes[chosen]}
        set +e
        wait "$pid"
        rc=$?
        set -e
        worker_rc[done_idx]=$rc
        active_disk=$((active_disk - work_estimates[done_idx]))
        (( active_disk < 0 )) && active_disk=0
        unset 'pids[chosen]' 'pid_indexes[chosen]'
        pids=("${pids[@]}")
        pid_indexes=("${pid_indexes[@]}")
        active=$((active - 1))
    }

    for ((next_idx=0; next_idx<total; next_idx++)); do
        [[ ${safe[next_idx]} == true ]] || continue
        work_estimate=${work_estimates[next_idx]}
        while (( active >= max_dispatch )) || \
              (( active > 0 && active_disk + work_estimate > disk_budget )); do
            _hardcore_nested_reap_one
        done

        printf 'Launching nested worker: %s | RAM claim %s MiB | disk estimate %s\n' \
            "${relatives[next_idx]}" "${ram_claims[next_idx]}" "$(human_bytes "$work_estimate")"
        env HARDCORE_ARCHIVE_PARENT_GPU_LOCK="$gpu_lock" \
            python3 "$RESOURCE_POOL_RUNNER" run \
                --pool "$RESOURCE_POOL_DIR" \
                --cpu-min 1 \
                --cpu-max "$nested_cpu_max" \
                --ram-mib "${ram_claims[next_idx]}" \
                --label nested-archive \
                --priority normal \
                -- bash "$helper" \
                    --source-parent "$SOURCE_PARENT" \
                    --relative "${relatives[next_idx]}" \
                    --output-rel "${outputs[next_idx]}" \
                    --stage-parent "$NESTED_STAGE_PARENT" \
                    --task-dir "${task_dirs[next_idx]}" \
                    --result "${result_files[next_idx]}" \
                    --log "${log_files[next_idx]}" \
                    --seven-zip "$SEVEN_ZIP" \
                    --script "$script_path" \
                    --depth "$depth" \
                    --max-depth "$NESTED_MAX_DEPTH" \
                    --video-transcode "$video_transcode_flag" \
                    --video-encoder "${VIDEO_ENCODER:-}" \
                    --calibration-namespace "${calibrations[next_idx]}" \
                    --gpu-lock "$gpu_lock" \
                    --diagnostics-dir "${diagnostics[next_idx]}" \
                    -- "${inherited[@]}" &
        pids+=("$!")
        pid_indexes+=("$next_idx")
        active=$((active + 1))
        active_disk=$((active_disk + work_estimate))
        hardcore_visual_open_log "Hardcore Archive - Nested: ${relatives[next_idx]}" \
            "${log_files[next_idx]}" pid "$!"
    done
    while (( active > 0 )); do
        _hardcore_nested_reap_one
    done
    unset -f _hardcore_nested_reap_one

    # Merge worker results in original source order. This is deliberately the
    # only place that mutates shared nested manifests/counters, so completion
    # order can never make accounting nondeterministic.
    NESTED_REPACKED_COUNT=0
    NESTED_FALLBACK_COUNT=0
    NESTED_SAVED_BYTES=0
    local action original archived candidate_size archived_size actual candidate_display
    for ((i=0; i<total; i++)); do
        relative=${relatives[i]}
        output_rel=${outputs[i]}
        original_size=${originals[i]}
        result_file=${result_files[i]}
        log_file=${log_files[i]}
        rc=${worker_rc[i]:-0}

        action=''; original=''; archived=''; candidate_size=0; archived_size=0; reason=''
        if (( rc == 0 )) && [[ -s $result_file ]]; then
            IFS=$'\t' read -r action original archived _original_size candidate_size archived_size reason < "$result_file" || true
        fi
        if (( rc != 0 )); then
            action=original; original=$relative; archived=$relative
            candidate_size=0; archived_size=$original_size; reason="nested-worker-failed-rc-${rc}"
        elif [[ $original != "$relative" || ! $candidate_size =~ ^[0-9]+$ || ! $archived_size =~ ^[0-9]+$ ]]; then
            action=original; original=$relative; archived=$relative
            candidate_size=0; archived_size=$original_size; reason=invalid-worker-result
        fi

        if [[ $action == repacked ]]; then
            if [[ $archived != "$output_rel" || ! -f $NESTED_STAGE_PARENT/$archived ]]; then
                action=original; archived=$relative; archived_size=$original_size; reason=missing-repacked-candidate
            else
                actual=$(stat -c '%s' -- "$NESTED_STAGE_PARENT/$archived")
                if (( actual != candidate_size || actual != archived_size || actual >= original_size )); then
                    rm -f -- "$NESTED_STAGE_PARENT/$archived"
                    action=original; archived=$relative; archived_size=$original_size; reason=invalid-repacked-accounting
                fi
            fi
        elif [[ $action != original || $archived != "$relative" || $archived_size != "$original_size" ]]; then
            action=original; archived=$relative; archived_size=$original_size; reason=invalid-worker-fallback
        fi

        if [[ $action == repacked ]]; then
            printf '%s\n' "$archived" >> "$NESTED_REPACKED_LIST"
            NESTED_REPACKED_COUNT=$((NESTED_REPACKED_COUNT + 1))
            NESTED_SAVED_BYTES=$((NESTED_SAVED_BYTES + original_size - archived_size))
        else
            rm -f -- "$NESTED_STAGE_PARENT/$output_rel"
            printf '%s\n' "$relative" >> "$NESTED_FALLBACK_LIST"
            NESTED_FALLBACK_COUNT=$((NESTED_FALLBACK_COUNT + 1))
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$action" "$relative" "$archived" "$original_size" "$candidate_size" "$archived_size" "$reason" \
            >> "$NESTED_RESULT_MANIFEST"

        [[ -s $log_file ]] && cat -- "$log_file" >> "$SEVEN_ZIP_LOG" 2>/dev/null || true
        if (( candidate_size > 0 )); then candidate_display=$(human_bytes "$candidate_size"); else candidate_display='not produced'; fi
        printf 'Nested decision: %s | original %s | candidate %s | %s (%s)\n' \
            "$relative" "$(human_bytes "$original_size")" "$candidate_display" \
            "$([[ $action == repacked ]] && printf 'REPACKED' || printf 'PRESERVED')" "$reason"
        if [[ -n ${HARDCORE_ARCHIVE_DIAGNOSTIC_DIR:-} ]]; then
            printf 'Nested child log: %s\n' "$log_file"
        fi
    done

    (( NESTED_REPACKED_COUNT + NESTED_FALLBACK_COUNT == NESTED_COUNT )) || \
        die "Nested archive accounting mismatch: detected $NESTED_COUNT but accounted for $((NESTED_REPACKED_COUNT + NESTED_FALLBACK_COUNT))."

    if [[ -s $NESTED_REPACKED_LIST ]]; then
        (cd -- "$NESTED_STAGE_PARENT" && \
            run_logged_stage "nested-archive replacement storage" "$SEVEN_ZIP_LOG" \
                "$SEVEN_ZIP" a "$TEMP_ARCHIVE" -t7z -mx=0 -m0=Copy -ms=off -mmt=1 \
                    -spd -scsUTF-8 -bsp1 -y "@${NESTED_REPACKED_LIST}")
    fi
    if [[ -s $NESTED_FALLBACK_LIST ]]; then
        (cd -- "$SOURCE_PARENT" && \
            run_logged_stage "nested-archive original fallback storage" "$SEVEN_ZIP_LOG" \
                "$SEVEN_ZIP" a "$TEMP_ARCHIVE" -t7z -mx=0 -m0=Copy -ms=off -mmt=1 \
                    -spd -scsUTF-8 -bsp1 -y "@${NESTED_FALLBACK_LIST}")
    fi
    if [[ -s $NESTED_RESULT_MANIFEST ]]; then
        {
            printf 'action\toriginal path\tarchived path\toriginal bytes\tcandidate bytes\tarchived bytes\treason\n'
            cat -- "$NESTED_RESULT_MANIFEST"
        } > "$NESTED_MANIFEST_FILE"
    fi
}
