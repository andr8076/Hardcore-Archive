#!/usr/bin/env bash

# Interactive policy for media that cannot be treated as an ordinary
# single-video-stream movie without an explicit user decision.  The caller
# supplies paths through the globals documented in hardcore_media_resolve.

hardcore_media_list_contains() {
    local list=$1 path=$2
    [[ -s $list ]] && grep -Fqx -- "$path" "$list"
}

hardcore_media_append_unique() {
    local list=$1 path=$2
    hardcore_media_list_contains "$list" "$path" || printf '%s\n' "$path" >> "$list"
}

hardcore_media_mark_all() {
    local destination=$1 relative reason
    while IFS=$'\t' read -r relative reason; do
        [[ -n $relative ]] || continue
        hardcore_media_append_unique "$destination" "$relative"
    done < "$VIDEO_SPECIAL_LIST"
}

hardcore_media_prompt_one() {
    local relative=$1 reason=$2 answer
    while :; do
        printf '\nSpecial video:\n  %s\nReason:\n  %s\n' "$relative" "$reason"
        printf '%s\n' \
            '  1) Preserve the original file unchanged (default)' \
            '  2) Try a compatible FFmpeg conversion' \
            '  3) Preserve this and all remaining special videos' \
            '  4) Omit this file from the archive entirely' \
            '  5) Cancel the archive run'
        printf 'Choose [1-5]: '
        IFS= read -r answer || answer=1
        case ${answer:-1} in
            1|p|P) hardcore_media_append_unique "$VIDEO_SPECIAL_PRESERVE_LIST" "$relative"; return 0 ;;
            2|c|C) return 0 ;;
            3|a|A) hardcore_media_append_unique "$VIDEO_SPECIAL_PRESERVE_LIST" "$relative"; return 10 ;;
            4|o|O) hardcore_media_append_unique "$VIDEO_SPECIAL_OMIT_LIST" "$relative"; return 0 ;;
            5|q|Q) return 2 ;;
            *) printf 'Please enter 1, 2, 3, 4, or 5.\n' ;;
        esac
    done
}

hardcore_media_resolve() {
    # Required caller globals:
    # SOURCE_PARENT, VIDEO_LIST, VIDEO_SPECIAL_LIST,
    # VIDEO_SPECIAL_PRESERVE_LIST, VIDEO_SPECIAL_OMIT_LIST,
    # VIDEO_SPECIAL_POLICY, ASSUME_YES, ANALYZE_ONLY, MEDIA_HELPER.
    local relative source reason answer prompt_rc preserve_remaining=false
    : > "$VIDEO_SPECIAL_LIST"
    : > "$VIDEO_SPECIAL_PRESERVE_LIST"
    : > "$VIDEO_SPECIAL_OMIT_LIST"

    while IFS= read -r relative; do
        [[ -n $relative ]] || continue
        source="$SOURCE_PARENT/$relative"
        if ! reason=$(python3 "$MEDIA_HELPER" classify "$source"); then
            printf 'Error: special-media inspection failed for: %s\n' "$relative" >&2
            return 1
        fi
        [[ -n $reason ]] && printf '%s\t%s\n' "$relative" "$reason" >> "$VIDEO_SPECIAL_LIST"
    done < "$VIDEO_LIST"

    [[ -s $VIDEO_SPECIAL_LIST ]] || return 0

    printf '\nSpecial video handling required\n'
    printf '%s\n' '────────────────────────────────────────────────────────────'
    while IFS=$'\t' read -r relative reason; do
        printf '  %s\n    %s\n' "$relative" "$reason"
    done < "$VIDEO_SPECIAL_LIST"

    case "$VIDEO_SPECIAL_POLICY" in
        preserve)
            hardcore_media_mark_all "$VIDEO_SPECIAL_PRESERVE_LIST"
            ;;
        convert)
            printf 'Policy: attempt conversion; any failed or incomplete conversion falls back to the original.\n'
            ;;
        omit)
            hardcore_media_mark_all "$VIDEO_SPECIAL_OMIT_LIST"
            ;;
        ask)
            if $ASSUME_YES || $ANALYZE_ONLY || [[ ! -t 0 ]]; then
                hardcore_media_mark_all "$VIDEO_SPECIAL_PRESERVE_LIST"
                printf 'No interactive prompt is available; special videos will be preserved unchanged.\n'
                return 0
            fi
            while :; do
                printf '\nChoose how to handle the special videos:\n'
                printf '%s\n' \
                    '  1) Preserve all originals unchanged (default)' \
                    '  2) Try to convert all with FFmpeg' \
                    '  3) Decide separately for each file' \
                    '  4) Omit all special videos from the archive entirely' \
                    '  5) Cancel the archive run'
                printf 'Choose [1-5]: '
                IFS= read -r answer || answer=1
                case ${answer:-1} in
                    1|p|P) hardcore_media_mark_all "$VIDEO_SPECIAL_PRESERVE_LIST"; break ;;
                    2|c|C) break ;;
                    3|e|E)
                        while IFS=$'\t' read -r relative reason; do
                            [[ -n $relative ]] || continue
                            if $preserve_remaining; then
                                hardcore_media_append_unique "$VIDEO_SPECIAL_PRESERVE_LIST" "$relative"
                                continue
                            fi
                            if hardcore_media_prompt_one "$relative" "$reason"; then
                                prompt_rc=0
                            else
                                prompt_rc=$?
                            fi
                            case $prompt_rc in
                                0) ;;
                                10) preserve_remaining=true ;;
                                2) return 2 ;;
                                *) return 1 ;;
                            esac
                        done < "$VIDEO_SPECIAL_LIST"
                        break
                        ;;
                    4|o|O) hardcore_media_mark_all "$VIDEO_SPECIAL_OMIT_LIST"; break ;;
                    5|q|Q) return 2 ;;
                    *) printf 'Please enter 1, 2, 3, 4, or 5.\n' ;;
                esac
            done
            ;;
        *)
            printf 'Error: unknown special-video policy: %s\n' "$VIDEO_SPECIAL_POLICY" >&2
            return 1
            ;;
    esac
}
