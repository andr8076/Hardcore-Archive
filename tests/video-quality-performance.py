#!/usr/bin/env python3
"""Check actual VMAF command construction, thread policy and score handling."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = (ROOT / "lib/hardcore-archive-core.sh").read_text()
FUNCTIONS = "MEASURED_QUALITY_KIND=''\n" + CORE.split(
    "MEASURED_QUALITY_KIND=''\n", 1
)[1].split("\nHARDCORE_AUTO_CODEC_MODE=", 1)[0]


class QualityPerformanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.functions = self.root / "functions.sh"
        self.functions.write_text(FUNCTIONS)

    def run_shell(self, body, **changes):
        env = dict(os.environ, TEST_ROOT=str(self.root),
                   HARDCORE_ARCHIVE_VIDEO_QUALITY_THREADS="auto")
        env.update({k: str(v) for k, v in changes.items()})
        script = "set -euo pipefail\nsource " + shlex.quote(str(self.functions)) + r'''
nproc() { printf '%s' "${AVAILABLE:-16}"; }
input="$TEST_ROOT/original.mov"
quality_check=required
preflight_files=()
has_filter() { printf 'probe\n' >> "$TEST_ROOT/filters"; }
ffprobe() {
    printf '%s\n' "$*" >> "$TEST_ROOT/probes"
    printf '3840x2160\n'
}
ffmpeg() {
    printf '%s\0' "$@" >> "$TEST_ROOT/args"
    [[ ${ENCODE_FAIL:-0} == 0 ]] || return 1
    [[ ${OMIT_SCORE:-0} == 0 ]] || return 0
    printf '%s' "${SCORE_JSON:-}" > "$TEST_ROOT/sample.mkv.vmaf.json"
}
''' + body
        return subprocess.run(["bash", "-c", script], env=env, text=True, capture_output=True)

    def test_thread_selection_bounds_and_override(self):
        for available, requested, expected in ((16, "auto", 8), (4, "auto", 4),
                                                (1, "auto", 1), (16, 12, 12),
                                                (4, 64, 4), (16, 1, 1),
                                                ("unavailable", "auto", 1)):
            with self.subTest(available=available, requested=requested):
                result = self.run_shell("quality_worker_threads", AVAILABLE=available,
                                        HARDCORE_ARCHIVE_VIDEO_QUALITY_THREADS=requested)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, str(expected))

    def test_invalid_threads_rejected(self):
        for requested in (0, -1, 65, "1.5", "bogus", "08", "$(echo 8)"):
            with self.subTest(requested=requested):
                result = self.run_shell("quality_worker_threads",
                                        HARDCORE_ARCHIVE_VIDEO_QUALITY_THREADS=requested)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("VIDEO_QUALITY_THREADS", result.stderr)

    def test_command_uses_workers_without_reducing_quality_work(self):
        result = self.run_shell(r'''
measure_preflight_quality 12.5 3 "$TEST_ROOT/sample.mkv"
printf 'RESULT:%s:%s\n' "$MEASURED_QUALITY_KIND" "$MEASURED_QUALITY_SCORE"
measure_preflight_quality 12.5 3 "$TEST_ROOT/sample.mkv"
''', SCORE_JSON=json.dumps({"pooled_metrics": {"vmaf": {"mean": 94.123456}}}))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("RESULT:VMAF:94.123456", result.stdout)
        self.assertIn("3840x2160, 8 CPU worker(s)", result.stdout)
        self.assertIn("VMAF scoring finished in", result.stdout)
        args = (self.root / "args").read_bytes().decode().split("\0")
        graph = args[args.index("-filter_complex") + 1]
        self.assertIn(":n_threads=8:n_subsample=1", graph)
        self.assertIn("scale=3840:2160:flags=lanczos:out_range=tv", graph)
        self.assertIn("scale=3840:2160:flags=bilinear:out_range=tv", graph)
        self.assertNotIn("fps=", graph)
        self.assertEqual(args[args.index("-ss") + 1], "12.5")
        self.assertEqual(args[args.index("-t") + 1], "3")
        self.assertEqual((self.root / "filters").read_text().splitlines(), ["probe"])
        self.assertEqual(len((self.root / "probes").read_text().splitlines()), 2)

    def test_failed_ffmpeg_or_missing_score_cannot_reuse_old_score(self):
        for changes in ({"ENCODE_FAIL": 1}, {"OMIT_SCORE": 1}):
            with self.subTest(changes=changes):
                scorefile = self.root / "sample.mkv.vmaf.json"
                scorefile.write_text(json.dumps({"pooled_metrics": {"vmaf": {"mean": 100}}}))
                result = self.run_shell(r'''
if measure_preflight_quality 0 3 "$TEST_ROOT/sample.mkv"; then exit 99; fi
[[ -z $MEASURED_QUALITY_SCORE && -z $MEASURED_QUALITY_KIND ]]
''', **changes)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(scorefile.exists())

    def test_invalid_vmaf_score_fails_closed(self):
        for score in (float("nan"), float("inf"), -1, 101):
            with self.subTest(score=score):
                result = self.run_shell(r'''
if measure_preflight_quality 0 3 "$TEST_ROOT/sample.mkv"; then exit 99; fi
[[ -z $MEASURED_QUALITY_SCORE && -z $MEASURED_QUALITY_KIND ]]
''', SCORE_JSON=json.dumps({"pooled_metrics": {"vmaf": {"mean": score}}}))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_quality_off_does_no_probes(self):
        result = self.run_shell(r'''
quality_check=off
if measure_preflight_quality 0 3 "$TEST_ROOT/sample.mkv"; then exit 99; fi
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "probes").exists())
        self.assertFalse((self.root / "args").exists())

    def test_config_and_child_inheritance(self):
        funcs = "trim_config_value() {" + CORE.split("\ntrim_config_value() {", 1)[1].split(
            "\nsafe_slug() {", 1
        )[0]
        config_functions = self.root / "config-functions.sh"
        config_functions.write_text(funcs)
        config = self.root / "config"
        config.write_text("VIDEO_QUALITY_THREADS=12\n")
        child = self.root / "child-config"
        child.write_text("VIDEO_QUALITY_THREADS=2\n")
        result = self.run_shell("source " + shlex.quote(str(config_functions)) + r'''
die() { printf '%s\n' "$*" >&2; exit 2; }
load_config_file "$TEST_ROOT/config"
[[ $HARDCORE_ARCHIVE_VIDEO_QUALITY_THREADS == 12 ]]
export HARDCORE_ARCHIVE_CALIBRATION_POLICY_INHERITED=1
bash -c 'source "$TEST_ROOT/config-functions.sh"
load_config_file "$TEST_ROOT/child-config"
[[ $HARDCORE_ARCHIVE_VIDEO_QUALITY_THREADS == 12 ]]'
''', HARDCORE_ARCHIVE_CALIBRATION_POLICY_INHERITED=0)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
