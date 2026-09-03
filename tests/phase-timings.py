#!/usr/bin/env python3
"""Check persisted timings, failure statuses and the actual report integration."""
import csv
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = (ROOT / "lib/hardcore-archive-core.sh").read_text()
MODULE = ROOT / "lib/timing.sh"


def function(name):
    return name + "() {" + CORE.split(name + "() {", 1)[1].split("\n}\n", 1)[0] + "\n}\n"


class PhaseTimingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="phase timings ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.diagnostic = self.root / "parent"

    def shell(self, body, expected=0, **env):
        script = ("set -Eeuo pipefail\nsource " + shlex.quote(str(MODULE)) +
                  "\nhardcore_timing_init\n" + body)
        result = subprocess.run(["bash", "-c", script], cwd=self.root, capture_output=True,
                                text=True, timeout=30, env=dict(os.environ, TEST_ROOT=str(self.root),
                                HARDCORE_ARCHIVE_DIAGNOSTIC_DIR=str(self.diagnostic), **env))
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout

    def rows(self, directory=None):
        with ((directory or self.diagnostic) / "timings.tsv").open() as source:
            return list(csv.DictReader(source, delimiter="\t"))

    def test_worker_export_concurrent_appends_and_return_codes(self):
        self.shell(r'''
hardcore_timed video_encoding bash -c 'exit 7' && exit 99 || rc=$?
[[ $rc == 7 ]]
for i in {1..8}; do
    bash -c 'hardcore_timed video_calibration true' &
done
wait
''')
        rows = self.rows()
        self.assertEqual(len(rows), 9)
        self.assertEqual(rows[0]["exit_status"], "7")
        self.assertTrue(all(int(row["elapsed_ns"]) > 0 for row in rows))
        self.assertEqual(sum(row["phase"] == "video_calibration" for row in rows), 8)

    def test_child_initialization_preserves_parent_journal(self):
        body = r'''
hardcore_timed archive_write true
HARDCORE_ARCHIVE_DIAGNOSTIC_DIR="$TEST_ROOT/child" bash -c 'source "$1"; hardcore_timing_init; hardcore_timed video_encoding true' bash MODULE
hardcore_timed archive_verification true
'''.replace("MODULE", shlex.quote(str(MODULE)))
        self.shell(body)
        self.assertEqual([r["phase"] for r in self.rows()], ["archive_write", "archive_verification"])
        self.assertEqual([r["phase"] for r in self.rows(self.root / "child")], ["video_encoding"])

    def test_failed_archive_stage_is_recorded_and_successful_stage_accumulates(self):
        body = function("run_logged_stage") + r'''
PROGRESS_INTERVAL=0
format_duration() { printf '%ss' "$1"; }
rc=0
run_logged_stage 'compressed-video storage' "$TEST_ROOT/7zip.log" bash -c 'printf failure; exit 9' || rc=$?
[[ $rc == 9 ]]
run_logged_stage 'safety-manifest storage' "$TEST_ROOT/7zip.log" true
run_logged_stage 'archive integrity test' "$TEST_ROOT/7zip.log" true
'''
        self.shell(body)
        self.assertEqual([(r["phase"], r["exit_status"]) for r in self.rows()],
                         [("archive_write", "9"), ("archive_write", "0"), ("archive_verification", "0")])

    def test_real_verification_routing_counts_strong_extraction_once(self):
        start = CORE.index("if [[ $VERIFY_MODE_EFFECTIVE == integrity ]]; then", CORE.index("NESTED_TIMING_STARTED=$("))
        stop = CORE.index("printf '\\nStage 8/8:", start)
        verify = CORE[start:stop]
        for mode in ("integrity", "hashes", "extract"):
            for failed in (0, 7):
                with self.subTest(mode=mode, failed=failed):
                    body = function("run_logged_stage") + r'''
PROGRESS_INTERVAL=0
SEVEN_ZIP_LOG="$TEST_ROOT/7zip.log"
TEMP_ARCHIVE="$TEST_ROOT/fixture.7z"
SEVEN_ZIP=true
format_duration() { printf '%ss' "$1"; }
die() { printf '%s\n' "$*" >&2; exit 1; }
verify_archive_completeness() { [[ $VERIFY_MODE_EFFECTIVE != integrity ]] || return "$FAIL_RC"; }
verify_archive_hashes_single_pass() {
    run_logged_stage 'single-pass hash extraction' "$TEST_ROOT/hash.log" true || return $?
    return "$FAIL_RC"
}
verify_archive_by_extraction() { verify_archive_hashes_single_pass; }
''' + verify
                    self.shell(body, expected=int(failed != 0), VERIFY_MODE_EFFECTIVE=mode, FAIL_RC=str(failed))
                    rows = self.rows()
                    self.assertEqual(len(rows), 2)
                    self.assertTrue(all(row["phase"] == "archive_verification" for row in rows))
                    self.assertEqual(rows[-1]["exit_status"], str(failed))

    def test_report_contains_exact_summary_without_transcript(self):
        report = function("write_success_report")
        variables = set(re.findall(r"\$(?:\{)?([A-Z][A-Z_]+)", report))
        # Fill unrelated report fields; use the production formatter and writer.
        assignments = "\n".join(name + "=0" for name in sorted(variables))
        body = assignments + "\n" + report + r'''
WRITE_REPORT=true
ARCHIVE="$TEST_ROOT/archive.7z"
REPORT_PATH="$TEST_ROOT/report.txt"
TOTAL_BYTES=100
SCRIPT_START_SECONDS=$SECONDS
HARDCORE_ARCHIVE_TIMING_FILE="$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/timings.tsv"
printf payload > "$ARCHIVE"
printf '\nFinished: fixture\nExit status: 0\n' > "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/run.log"
printf 'phase\telapsed_ns\texit_status\nvideo_calibration\t2000000000\t0\nvideo_calibration\t1500000000\t2\narchive_write\t750000000\t0\narchive_verification\t250000000\t0\n' > "$HARDCORE_ARCHIVE_TIMING_FILE"
platform_os_version() { printf fixture; }
filesystem_type() { printf fixture; }
format_duration() { printf '%ss' "$1"; }
warn() { printf '%s\n' "$*" >&2; }
sync() { :; }
write_success_report
'''
        self.shell(body)
        report_text = (self.root / "report.txt").read_text()
        self.assertIn("Video calibration and sample validation: 3.500 (operations=2, unsuccessful=1)", report_text)
        self.assertIn("Archive writing: 0.750", report_text)
        self.assertIn("Archive verification: 0.250", report_text)
        self.assertIn("Phases can overlap", report_text)
        self.assertIn("Completeness: passed", report_text)

    def test_disabled_timing_keeps_command_exit_status(self):
        self.shell("unset HARDCORE_ARCHIVE_TIMING_FILE\nhardcore_timed video_encoding bash -c 'exit 7'", expected=7)
        self.assertEqual(self.rows(), [])


if __name__ == "__main__":
    unittest.main()
