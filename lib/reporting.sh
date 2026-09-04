#!/usr/bin/env bash

# Persistent transcripts beside the destination, including early preflight errors.
[[ ${HARDCORE_REPORTING_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_REPORTING_SH_LOADED=1

HARDCORE_LIVE_LOG=''
HARDCORE_DIAGNOSTIC_DIR=''

hardcore_reporting_create_directory() {
    # Match the frontend's value-taking options without executing its doctor.
    # Values (including paths beginning with '-') must never become positionals.
    local batch=false
    local -a positionals=()
    while (( $# )); do
        case $1 in
            --) shift; positionals+=("$@"); break ;;
            --batch) batch=true; shift ;;
            --dictionary|--threads|--effort|--search-cycles|--progress-interval|--nested-max-depth|--verify|--work-dir|--config|--video-mode|--video-special-policy|--video-min-vmaf|--video-min-savings|--image-mode|--image-jobs|--batch-root-files|--batch-jobs|--video-codec|--video-encoder|--quality-check)
                (( $# >= 2 )) || { printf 'Error: %s requires a value.\n' "$1" >&2; return 1; }
                shift 2 ;;
            --*) shift ;;
            *) positionals+=("$1"); shift ;;
        esac
    done
    (( ${#positionals[@]} >= 1 && ${#positionals[@]} <= 2 )) || {
        printf 'Error: expected SOURCE_FOLDER and optional destination.\n' >&2
        return 1
    }
    command -v python3 >/dev/null 2>&1 || {
        printf 'Error: python3 is required to resolve the destination for persistent logs.\n' >&2
        return 3
    }
    python3 - "$batch" "${positionals[0]}" "${positionals[1]:-}" <<'PY'
import datetime
import os
import re
import sys
import tempfile

try:
    batch, source, output = sys.argv[1:]
    source = os.path.realpath(source)
    if not os.path.isdir(source):
        raise ValueError(f"Source is not a directory: {source}")
    name = os.path.basename(source)
    if batch == "true":
        destination = os.path.realpath(output or os.path.join(os.path.dirname(source), name + "-archives"))
        label = name + "-batch"
    else:
        output = output or os.path.join(os.path.dirname(source), name + ".7z")
        if not output.endswith(".7z"):
            output += ".7z"
        output = os.path.realpath(output)
        destination = os.path.dirname(output)
        label = os.path.basename(output)
    # Resolve existing symlinks before creating anything, so the new log folder
    # cannot become part of the input tree, even through a destination alias.
    root = os.path.realpath(os.path.join(destination, "hardcore-archive-logs"))
    if os.path.commonpath([source, destination]) == source or os.path.commonpath([source, root]) == source:
        raise ValueError("Destination and log directory must be outside the source folder.")
    os.makedirs(root, mode=0o700, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    label = re.sub(r"[^A-Za-z0-9._-]", "-", label)[:80].lstrip(".") or "archive"
    print(tempfile.mkdtemp(prefix=f"{label}-{stamp}-", dir=root))
except (OSError, ValueError) as exc:
    print(f"Error: cannot create destination logs: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

hardcore_reporting_start() {
    command -v tee >/dev/null 2>&1 || {
        printf 'Error: tee is required for the persistent run log. Install/restore coreutils and rerun.\n' >&2
        return 3
    }
    HARDCORE_DIAGNOSTIC_DIR=$(hardcore_reporting_create_directory "$@") || return $?
    HARDCORE_LIVE_LOG="$HARDCORE_DIAGNOSTIC_DIR/run.log"
    : > "$HARDCORE_LIVE_LOG" || return 1
    export HARDCORE_ARCHIVE_LIVE_LOG="$HARDCORE_LIVE_LOG"
    export HARDCORE_ARCHIVE_DIAGNOSTIC_DIR="$HARDCORE_DIAGNOSTIC_DIR"
    exec {HARDCORE_REPORT_STDOUT}>&1 {HARDCORE_REPORT_STDERR}>&2
    # One writer preserves the byte stream; two independent appenders can
    # splice stderr into the middle of a buffered stdout line.
    exec > >(tee -a "$HARDCORE_LIVE_LOG") 2>&1
    HARDCORE_REPORT_OUT_PID=$!
    printf 'Persistent run log: %s\n' "$HARDCORE_LIVE_LOG"
    printf 'Run diagnostics:    %s\n' "$HARDCORE_DIAGNOSTIC_DIR"
    printf 'Started:            %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf 'Working directory:  %s\n' "$PWD"
    printf 'Command:'
    printf ' %q' "$0" "$@"
    printf '\n\n'
}

hardcore_reporting_finish() {
    local exit_status=$1
    [[ -n ${HARDCORE_LIVE_LOG:-} ]] || return 0
    # Drain the transcript writer before appending the final status.
    exec >&"$HARDCORE_REPORT_STDOUT" 2>&"$HARDCORE_REPORT_STDERR"
    exec {HARDCORE_REPORT_STDOUT}>&- {HARDCORE_REPORT_STDERR}>&-
    wait "$HARDCORE_REPORT_OUT_PID" || true
    {
        printf '\nFinished: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
        printf 'Exit status: %s\n' "$exit_status"
    } >> "$HARDCORE_LIVE_LOG" 2>/dev/null || true
}
