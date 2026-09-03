#!/usr/bin/env python3
"""Exercise destination logging and the real cleanup/batch orchestration."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = (ROOT / "lib/hardcore-archive-core.sh").read_text()
REPORTING = f"source {shlex.quote(str(ROOT / 'lib/reporting.sh'))}\n"


def function(name):
    source = CORE.split("preserve_failed_archive() {", 1)[1] if name == "cleanup" else CORE
    return name + "() {" + source.split(name + "() {", 1)[1].split("\n}\n", 1)[0] + "\n}\n"


class DestinationLogsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="destination logs ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source with spaces"
        self.source.mkdir()
        self.destination = self.root / "SSD destination"
        self.destination.mkdir()

    def shell(self, script, *args, expected=0, **env):
        result = subprocess.run(
            ["bash", "-c", "set -Eeuo pipefail\n" + script, "test-runner", *map(str, args)],
            cwd=self.root, text=True, capture_output=True, timeout=30,
            env=dict(os.environ, TEST_ROOT=str(self.root), **env),
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout

    def directory(self, *args):
        return Path(self.shell(REPORTING + 'hardcore_reporting_create_directory "$@"', *args).strip())

    def test_explicit_default_batch_relative_and_unique_paths(self):
        first = self.directory(self.source, self.destination / "test archive")
        second = self.directory(self.source, self.destination / "test archive")
        self.assertEqual(first.parent, self.destination / "hardcore-archive-logs")
        self.assertNotEqual(first, second)
        self.assertTrue(first.name.startswith("test-archive.7z-"))
        self.assertEqual(first.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.directory(self.source).parent, self.root / "hardcore-archive-logs")
        self.assertEqual(self.directory("--batch", self.source).parent,
                         self.root / "source with spaces-archives/hardcore-archive-logs")
        self.assertEqual(self.directory("--batch", self.source, self.destination).parent,
                         self.destination / "hardcore-archive-logs")
        self.assertEqual(self.directory(self.source.name, "SSD destination/../other/out").parent,
                         self.root / "other/hardcore-archive-logs")

    def test_frontend_options_and_dash_paths(self):
        policy = (ROOT / "hardcore-archive-runner-policy.sh").read_text()
        parser = policy.split("while (( $# > 0 )); do", 1)[1].split("\ndone", 1)[0]
        # Discover value-taking cases from the real frontend to catch option drift.
        options = []
        for match in re.finditer(r"^        (--[^\n]+)\)\n            need_value", parser, re.M):
            options.extend(match.group(1).split("|"))
        self.assertGreaterEqual(len(options), 19)
        for option in options:
            with self.subTest(option=option):
                for args in ([option, "--value", self.source, self.destination / "out"],
                             [self.source, option + "=value", self.destination / "out"]):
                    self.assertEqual(self.directory(*args).parent,
                                     self.destination / "hardcore-archive-logs")
        dash_source = self.root / "--source"
        dash_source.mkdir()
        self.assertEqual(self.directory("--", "--source", "--archive").parent,
                         self.root / "hardcore-archive-logs")

    def test_source_overlap_aliases_and_blocked_log_root_fail_before_creation(self):
        alias = self.root / "alias"
        alias.symlink_to(self.source, target_is_directory=True)
        for output in (self.source / "out.7z", alias / "subdir/out.7z"):
            self.shell(REPORTING + 'hardcore_reporting_create_directory "$@"',
                       self.source, output, expected=1)
        self.assertEqual(list(self.source.iterdir()), [])
        log_root = self.destination / "hardcore-archive-logs"
        log_root.symlink_to(self.source, target_is_directory=True)
        self.shell(REPORTING + 'hardcore_reporting_create_directory "$@"',
                   self.source, self.destination / "out.7z", expected=1)
        log_root.unlink()
        log_root.write_text("blocking file")
        self.shell(REPORTING + 'hardcore_reporting_create_directory "$@"',
                   self.source, self.destination / "out.7z", expected=1)
        self.assertEqual(log_root.read_text(), "blocking file")

    def test_transcript_drains_stdout_stderr_and_records_failure(self):
        script = REPORTING + r'''
hardcore_reporting_start "$@"
trap 'rc=$?; hardcore_reporting_finish "$rc"' EXIT
python3 - <<'PY'
import os
for i in range(1000):
    os.write(1, f"OUT-{i:04d}\n".encode())
    os.write(2, f"ERR-{i:04d}\n".encode())
PY
exit 7
'''
        self.shell(script, self.source, self.destination / "out", expected=7)
        logs = list(self.destination.glob("hardcore-archive-logs/*/run.log"))
        self.assertEqual(len(logs), 1)
        contents = logs[0].read_text()
        for i in range(1000):
            self.assertEqual(contents.count(f"OUT-{i:04d}\n"), 1)
            self.assertEqual(contents.count(f"ERR-{i:04d}\n"), 1)
        self.assertTrue(contents.endswith("Exit status: 7\n"))

    def test_component_logs_live_and_preserved_after_success_and_failure(self):
        functions = (f'source {shlex.quote(str(ROOT / "lib/timing.sh"))}\n' +
                     function("component_log_path") + function("archive_report_path") + function("cleanup"))
        for status in (0, 7):
            diagnostic = self.destination / f"run-{status}"
            script = functions + r'''
export HARDCORE_ARCHIVE_DIAGNOSTIC_DIR=$1
hardcore_timing_init
hardcore_timed video_encoding true
VIDEO_LOG=$(component_log_path video.log)
IMAGE_LOG=$(component_log_path image.log)
SEVEN_ZIP_LOG=$(component_log_path 7zip.log)
MC_TUNING_LOG=$(component_log_path match-cycle.log)
HASH_VERIFY_LOG=$(component_log_path hash-verification.log)
for log in "$VIDEO_LOG" "$IMAGE_LOG" "$SEVEN_ZIP_LOG" "$MC_TUNING_LOG" "$HASH_VERIFY_LOG"; do
    printf 'component output\n' > "$log"
    [[ -s $log ]]
done
ARCHIVE="$TEST_ROOT/unused.7z"
[[ $(archive_report_path) == "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/report.txt" ]]
KEEP_WORK=false
RESUME_ENABLED=false
cache_completed_video_results() { :; }
release_output_lock() { :; }
# Unrelated core globals are empty in this focused fixture.
set +u
trap cleanup EXIT
exit "$2"
'''
            self.shell(script, diagnostic, status, expected=status)
            for name in ("video.log", "image.log", "7zip.log", "match-cycle.log", "hash-verification.log"):
                self.assertEqual((diagnostic / name).read_text(), "component output\n")
            self.assertIn(f"exit_status={status}\n", (diagnostic / "state.txt").read_text())
            self.assertIn("Full video encoding:", (diagnostic / "timings.txt").read_text())
            self.assertIn("operations=1", (diagnostic / "timings.txt").read_text())

    def test_runtime_keeps_preflight_failure_and_exit_status(self):
        policy = self.root / "failed-policy.sh"
        policy.write_text("printf 'Missing dependency fixture\\n' >&2\nexit 3\n")
        script = f"source {shlex.quote(str(ROOT / 'lib/scheduler.sh'))}\n" + r'''
hardcore_planner_init_runtime_paths() {
    HARDCORE_POLICY_RUNNER="$TEST_ROOT/failed-policy.sh"
    HARDCORE_CONTAINER_HELPER=unused
    HARDCORE_METADATA_HELPER=unused
}
hardcore_archive_static_engine_ready() { :; }
hardcore_enable_adaptive_hash_verifier() { :; }
hardcore_runtime_main "$@"
'''
        self.shell(script, self.source, self.destination / "out", expected=3)
        logs = list(self.destination.glob("hardcore-archive-logs/*/run.log"))
        self.assertEqual(len(logs), 1)
        self.assertIn("Missing dependency fixture\n", logs[0].read_text())
        self.assertTrue(logs[0].read_text().endswith("Exit status: 3\n"))

    def test_failure_report_stays_in_log_folder_archive_stays_in_destination(self):
        diagnostic = self.destination / "run-failed"
        diagnostic.mkdir()
        script = function("choose_failed_output_paths") + r'''
ARCHIVE=$1
HARDCORE_ARCHIVE_DIAGNOSTIC_DIR=$2
FAILURE_CONTEXT=integrity-test
choose_failed_output_paths
printf '%s\n%s\n' "$FAILED_ARCHIVE_PATH" "$FAILED_LOG_PATH"
'''
        paths = self.shell(script, self.destination / "out.7z", diagnostic).splitlines()
        self.assertEqual(Path(paths[0]).parent, self.destination)
        self.assertEqual(Path(paths[1]).parent, diagnostic)

    def test_batch_serial_and_parallel_keep_distinct_plans_components_and_status(self):
        # These names deliberately collide under safe_slug; ordinal prefixes
        # must keep the child logs separate in both scheduling modes.
        for name in ("a b", "a?b"):
            (self.source / name).mkdir()
        child = self.root / "child.sh"
        child.write_text(r'''#!/usr/bin/env bash
set -eu
printf 'child stdout\n'
printf 'child stderr\n' >&2
source_path=${@: -2:1}
printf '%s\n' "$source_path" > "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/video.log"
[[ $HARDCORE_ARCHIVE_LIVE_LOG == "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/run.log" ]]
for arg in "$@"; do
    if [[ $arg == --analyze-only ]]; then
        printf 'Dictionary: 4\nEstimated compression RAM: 8\nCompression threads: 1\n'
        exit 0
    fi
done
[[ ${source_path##*/} != 'a?b' ]] || exit 7
''')
        script = function("safe_slug") + function("run_batch_mode") + r'''
POSITIONAL=("$1" "$2")
HARDCORE_ARCHIVE_DIAGNOSTIC_DIR=$3
BATCH_JOBS=$4
BATCH_ROOT_FILES=error
OUTPUT_WAS_AUTOMATIC=false
ONE_FILE_SYSTEM=true
NESTED_REPACK=false
QUALITY_CHECK=off
RETRY_FAILED=true
REMOVE_SOURCE=false
ANALYZE_ONLY=false
FORCE=true
DEPENDENCY_PREFLIGHT_SUMMARY=fixture
BATCH_CHILD_PIDS=()
resolve_current_script() { printf '%s/child.sh' "$TEST_ROOT"; }
dependency_preflight_create_optional() { :; }
build_batch_child_arguments() { BATCH_CHILD_ARGS=(); }
platform_memory_kib() { printf '1000000\t1000000\t0\t0\n'; }
platform_cpu_threads() { printf '16\n'; }
storage_lane_key() { printf 'test-device\n'; }
format_duration() { printf '%ss' "$1"; }
warn() { printf '%s\n' "$*" >&2; }
die() { printf '%s\n' "$*" >&2; exit 1; }
is_video_path() { return 1; }
run_batch_mode
'''
        for jobs in (1, 2):
            diagnostic = self.destination / f"batch-run-{jobs}"
            self.shell(script, self.source, self.destination, diagnostic, jobs, expected=1)
            self.assertFalse((self.destination / ".hardcore-batch-logs").exists())
            for index, name, status in ((1, "a b", 0), (2, "a?b", 7)):
                item = diagnostic / f"batch/{index}-a-b"
                self.assertEqual((item / "video.log").read_text().strip(), str(self.source / name))
                self.assertEqual((item / "planning/video.log").read_text().strip(), str(self.source / name))
                for path, expected_status in ((item / "run.log", status), (item / "planning/run.log", 0)):
                    text = path.read_text()
                    self.assertIn("child stdout\n", text)
                    self.assertIn("child stderr\n", text)
                    self.assertTrue(text.endswith(f"Exit status: {expected_status}\n"))


if __name__ == "__main__":
    unittest.main()
