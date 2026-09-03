#!/usr/bin/env bash

# Each archive process owns a journal. Workers append individual measurements;
# nested children initialize their own file instead of charging the parent twice.
hardcore_timing_init() {
    export HARDCORE_ARCHIVE_TIMING_FILE=''
    if [[ -n ${HARDCORE_ARCHIVE_DIAGNOSTIC_DIR:-} ]]; then
        mkdir -p -- "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR" || return 1
        export HARDCORE_ARCHIVE_TIMING_FILE="$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/timings.tsv"
        printf 'phase\telapsed_ns\texit_status\n' > "$HARDCORE_ARCHIVE_TIMING_FILE"
    fi
}

hardcore_timing_now() {
    [[ -n ${HARDCORE_ARCHIVE_TIMING_FILE:-} ]] || { printf 0; return; }
    python3 -c 'import time; print(time.monotonic_ns())'
}

hardcore_timing_record() {
    local phase=$1 started=$2 status=$3 ended elapsed
    [[ -n ${HARDCORE_ARCHIVE_TIMING_FILE:-} && $started =~ ^[1-9][0-9]{0,17}$ ]] || return 0
    ended=$(hardcore_timing_now 2>/dev/null) || return 0
    [[ $ended =~ ^[1-9][0-9]{0,17}$ ]] || return 0
    elapsed=$((ended - started))
    (( elapsed >= 0 )) || return 0
    # A single small append supports concurrently finishing worker processes.
    printf '%s\t%s\t%s\n' "$phase" "$elapsed" "$status" >> "$HARDCORE_ARCHIVE_TIMING_FILE" || true
}

hardcore_timed() {
    local phase=$1 started status
    shift
    started=$(hardcore_timing_now 2>/dev/null) || started=0
    if "$@"; then status=0; else status=$?; fi
    hardcore_timing_record "$phase" "$started" "$status"
    return "$status"
}

hardcore_timing_summary() {
    python3 - "${HARDCORE_ARCHIVE_TIMING_FILE:-}" <<'PY'
import collections
import csv
import sys

totals = collections.defaultdict(lambda: [0, 0, 0])
try:
    with open(sys.argv[1], newline="") as source:
        for row in csv.DictReader(source, delimiter="\t"):
            elapsed, status = int(row["elapsed_ns"]), int(row["exit_status"])
            if elapsed < 0:
                continue
            total = totals[row["phase"]]
            total[0] += elapsed
            total[1] += 1
            total[2] += status != 0
except (OSError, ValueError, KeyError, TypeError):
    print("Phase timings: unavailable or incomplete")
    sys.exit(0)

print("Phase timings (seconds; this archive's workers):")
for key, label in (
    ("video_calibration", "Video calibration and sample validation"),
    ("video_encoding", "Full video encoding"),
    ("video_decode_validation", "Full video decode validation"),
    ("archive_write", "Archive writing"),
    ("archive_verification", "Archive verification"),
    ("nested_processing", "Nested processing (including child work)"),
):
    elapsed, calls, failed = totals[key]
    print(f"  {label}: {elapsed / 1e9:.3f} (operations={calls}, unsuccessful={failed})")
print("Phases can overlap; do not add them to calculate elapsed time.")
print("Nested processing includes parent archive updates; child phase details are in the child logs.")
PY
}

export -f hardcore_timing_now hardcore_timing_record hardcore_timed
