#!/usr/bin/env python3
"""Check actual VMAF command construction, thread policy and score handling."""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
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
        self.assertIn(":ts_sync_mode=nearest", graph)
        self.assertEqual(graph.count("settb=AVTB,setpts=PTS-STARTPTS"), 2)
        self.assertIn("scale=3840:2160:flags=lanczos:out_range=tv", graph)
        self.assertIn("scale=3840:2160:flags=bilinear:out_range=tv", graph)
        self.assertNotIn("fps=", graph)
        self.assertEqual(args[args.index("-ss") + 1], "12.5")
        self.assertEqual(args[args.index("-t") + 1], "3")
        self.assertEqual((self.root / "filters").read_text().splitlines(), ["probe"])
        self.assertEqual(len((self.root / "probes").read_text().splitlines()), 2)

    @unittest.skipUnless(shutil.which("ffmpeg"), "FFmpeg is unavailable")
    def test_real_lossless_sample_matches_across_container_timebases(self):
        encoders = subprocess.check_output(["ffmpeg", "-hide_banner", "-encoders"],
                                          stderr=subprocess.DEVNULL, text=True)
        if not all(name in encoders for name in ("libx264", "ffv1")):
            self.skipTest("FFmpeg needs libx264 and FFV1 for this fixture")

        # Capture the production filter graph; SSIM uses the same framesync
        # machinery and lets this regression run without a libvmaf build.
        result = self.run_shell('measure_preflight_quality 0.833 3 "$TEST_ROOT/sample.mkv"',
                                SCORE_JSON=json.dumps({"pooled_metrics": {"vmaf": {"mean": 100}}}))
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.root / "args").read_bytes().decode().split("\0")
        graph = args[args.index("-filter_complex") + 1]
        graph = graph.replace("3840:2160", "128:72")
        graph = re.sub(r"libvmaf=log_fmt=json:log_path=[^:;]+:n_threads=[0-9]+:n_subsample=1:",
                       "ssim=", graph)
        source, sample = self.root / "reference.mp4", self.root / "lossless.mkv"

        def ffmpeg(*arguments):
            process = subprocess.run(["ffmpeg", "-hide_banner", "-nostdin", "-y", *map(str, arguments)],
                                     capture_output=True, text=True, timeout=30)
            self.assertEqual(process.returncode, 0, process.stderr[-4000:])
            return process.stderr

        # Rapid frame changes make a one-frame mismatch unambiguous. Both
        # encodes are lossless, but MP4 and Matroska have different timebases.
        ffmpeg("-v", "error", "-f", "lavfi", "-i",
               "nullsrc=s=128x72:r=60000/1001:d=6,geq=lum='mod(N*47+X*Y,220)+16':cb=128:cr=128",
               "-c:v", "libx264", "-threads", "2", "-qp", "0", source)
        ffmpeg("-v", "error", "-ss", "0.833", "-i", source, "-t", "3", "-map", "0:V:0",
               "-an", "-sn", "-dn", "-c:v", "ffv1", "-threads", "2", "-f", "matroska", sample)

        def score(filter_graph):
            output = ffmpeg("-ss", "0.833", "-t", "3", "-i", source, "-i", sample,
                            "-filter_complex", filter_graph, "-an", "-f", "null", "-")
            return float(re.search(r"All:([0-9.]+)", output)[1])

        self.assertAlmostEqual(score(graph), 1.0, places=6)
        old_graph = graph.replace("ssim=ts_sync_mode=nearest", "ssim").replace("settb=AVTB,", "")
        self.assertLess(score(old_graph), 0.9)
        # Nearest matching must not forgive a real frame-content shift.
        shifted = graph.replace("[1:v:0]", "[1:v:0]trim=start_frame=1,")
        self.assertLess(score(shifted), 0.9)

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
