#!/usr/bin/env python3
"""Persist nested-child logs and keep recoverable child video failures from aborting repack."""
from __future__ import annotations

import os
import pathlib
import re
import sys

MARKER = "# HARDCORE_NESTED_CHILD_DIAGNOSTICS_V1"


def fail(label: str, count: int) -> None:
    print(
        f"Error: nested diagnostics patch failed: {label}: expected one anchor, found {count}",
        file=sys.stderr,
    )
    raise SystemExit(1)


def repl(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        fail(label, count)
    return text.replace(old, new, 1)


def regex_repl(text: str, pattern: str, replacement: str, label: str) -> str:
    new, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
    if count != 1:
        fail(label, count)
    return new


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} INPUT_CORE OUTPUT_CORE", file=sys.stderr)
        return 2

    src, dst = map(pathlib.Path, sys.argv[1:])
    text = src.read_text(encoding="utf-8")
    if MARKER in text:
        dst.write_text(text, encoding="utf-8")
        os.chmod(dst, 0o700)
        return 0

    text = repl(
        text,
        "\nprepare_and_add_nested_archives() {",
        "\n" + MARKER + "\nprepare_and_add_nested_archives() {",
        "nested marker",
    )

    text = repl(
        text,
        '''    local relative input extracted child_archive normalized output_rel full_output original_size output_size candidate_size depth rc reason
    local expanded files encrypted free max_expanded candidate_display''',
        '''    local relative input extracted child_archive normalized output_rel full_output original_size output_size candidate_size depth rc reason child_log
    local expanded files encrypted free max_expanded candidate_display''',
        "nested child-log local",
    )

    old_child = r'''                env HARDCORE_ARCHIVE_INHIBITED=1 HARDCORE_ARCHIVE_DEPENDENCIES_APPROVED=1 HARDCORE_ARCHIVE_NESTED_DEPTH=$((depth + 1)) \
                    bash "$(resolve_current_script)" "${inherited[@]}" "$extracted" "$child_archive" >>"$SEVEN_ZIP_LOG" 2>&1 || rc=$?'''
    new_child = r'''                if [[ -n ${HARDCORE_ARCHIVE_DIAGNOSTIC_DIR:-} ]]; then
                    child_log="$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/nested/depth-$((depth + 1))/${relative}.child.log"
                    mkdir -p -- "$(dirname -- "$child_log")"
                else
                    child_log="$NESTED_STAGE_PARENT/.child-$RANDOM-$$.log"
                fi
                {
                    printf 'Nested archive: %s\n' "$relative"
                    printf 'Depth: %s\n' "$((depth + 1))"
                    printf 'Started: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
                    printf 'Hardware encoder inherited: %s\n\n' "${VIDEO_ENCODER:-none}"
                } > "$child_log"
                env HARDCORE_ARCHIVE_INHIBITED=1 \
                    HARDCORE_ARCHIVE_DEPENDENCIES_APPROVED=1 \
                    HARDCORE_ARCHIVE_NESTED_CHILD=1 \
                    HARDCORE_ARCHIVE_HARDWARE_ENCODER_LOCKED="${VIDEO_ENCODER:-}" \
                    HARDCORE_ARCHIVE_NESTED_DEPTH=$((depth + 1)) \
                    bash "$(resolve_current_script)" "${inherited[@]}" "$extracted" "$child_archive" >>"$child_log" 2>&1 || rc=$?
                printf '\nFinished: %s\nExit status: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$rc" >> "$child_log" 2>/dev/null || true
                cat -- "$child_log" >> "$SEVEN_ZIP_LOG" 2>/dev/null || true
                printf 'Nested child log: %s\n' "$child_log"'''
    text = repl(text, old_child, new_child, "persistent nested child log")

    text = repl(
        text,
        '''            test_real_encode "$force_encoder" "$expected_codec" "${encoder_args[@]}" || die "Forced encoder '$force_encoder' crashed on the real file test."''',
        '''            if [[ ${HARDCORE_ARCHIVE_HARDWARE_ENCODER_LOCKED:-} == "$force_encoder" ]]; then
                printf "  Inherited hardware encoder %s already validated by parent.\\n" "$force_encoder"
            else
                test_real_encode "$force_encoder" "$expected_codec" "${encoder_args[@]}" || die "Forced encoder '$force_encoder' crashed on the real file test."
            fi''',
        "trusted nested hardware encoder",
    )

    old_video_failure = r'''            if (( rc == 3 )); then
                ((unchanged++))
            else
                ((failed++))
                printf 'Batch item failed with exit code %s; continuing.\
' "$rc" >&2
            fi'''
    new_video_failure = r'''            if (( rc == 3 )); then
                ((unchanged++))
            elif [[ ${HARDCORE_ARCHIVE_NESTED_CHILD:-0} == 1 ]]; then
                ((unchanged++))
                printf 'Nested child video item failed with exit code %s; original preserved and recursion continues.\
' "$rc" >&2
            else
                ((failed++))
                printf 'Batch item failed with exit code %s; continuing.\
' "$rc" >&2
            fi'''
    text = repl(text, old_video_failure, new_video_failure, "nested child video preservation")

    dst.write_text(text, encoding="utf-8")
    os.chmod(dst, 0o700)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
