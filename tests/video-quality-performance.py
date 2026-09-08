#!/usr/bin/env python3
"""Check source-display VMAF policy, timing, cache versions and real scoring."""
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
VIDEO_HELPER = (ROOT / "lib/hardcore-archive-video-helper.sh").read_text()
FUNCTIONS = "MEASURED_QUALITY_KIND=''\n" + VIDEO_HELPER.split(
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
    case "$*" in
        *stream=width,height*) printf '%s\n' "${SOURCE_DIMENSIONS:-3840x2160}" ;;
        *stream=sample_aspect_ratio*) printf '%s\n' "${SOURCE_SAR:-1:1}" ;;
        *stream_side_data=rotation*) printf '%s\n' "${SOURCE_ROTATION:-0}" ;;
        *) return 1 ;;
    esac
}
ffmpeg() {
    printf '%s\0' "$@" >> "$TEST_ROOT/args"
    [[ ${ENCODE_FAIL:-0} == 0 ]] || return 1
    [[ ${OMIT_SCORE:-0} == 0 ]] || return 0
    printf '%s' "${SCORE_JSON:-}" > "$TEST_ROOT/sample.mkv.vmaf.json"
}
''' + body
        return subprocess.run(["bash", "-c", script], env=env,
                              text=True, capture_output=True)

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

    def test_source_display_canvas_is_independent_of_candidate_dimensions(self):
        result = self.run_shell(r'''
measure_preflight_quality 12.5 3 "$TEST_ROOT/sample.mkv"
printf 'RESULT:%s:%s\n' "$MEASURED_QUALITY_KIND" "$MEASURED_QUALITY_SCORE"
''', SCORE_JSON=json.dumps({"pooled_metrics": {"vmaf": {"mean": 94.123456}}}))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("RESULT:VMAF:94.123456", result.stdout)
        self.assertIn("source-display 3840x2160", result.stdout)
        self.assertIn("vmaf_4k_v0.6.1 (4K/1.5H)", result.stdout)
        self.assertIn("8 CPU worker(s)", result.stdout)
        self.assertIn("VMAF scoring finished in", result.stdout)

        args = (self.root / "args").read_bytes().decode().split("\0")
        graph = args[args.index("-filter_complex") + 1]
        self.assertIn("model='version=vmaf_4k_v0.6.1'", graph)
        self.assertIn(":n_threads=8:n_subsample=1", graph)
        self.assertIn(":ts_sync_mode=nearest", graph)
        self.assertEqual(graph.count("settb=AVTB,setpts=PTS-STARTPTS"), 2)
        self.assertEqual(graph.count("pad=3840:2160"), 2)
        self.assertGreaterEqual(graph.count("flags=bicubic"), 4)
        self.assertEqual(graph.count("format=yuv420p"), 2)
        self.assertIn("in_range=auto:out_range=tv", graph)
        self.assertNotIn("bilinear", graph)
        self.assertNotIn("flags=lanczos", graph)
        self.assertNotIn("fps=", graph)
        self.assertEqual(args[args.index("-ss") + 1], "12.5")
        self.assertEqual(args[args.index("-t") + 1], "3")

        # The candidate is deliberately never probed for its dimensions. Every
        # geometry probe targets the original source, so output resolution
        # cannot redefine the viewing canvas.
        probes = (self.root / "probes").read_text().splitlines()
        self.assertEqual(len(probes), 3)
        self.assertTrue(all(str(self.root / "original.mov") in line for line in probes))
        self.assertTrue(all("sample.mkv" not in line for line in probes))
        self.assertEqual((self.root / "filters").read_text().splitlines(), ["probe"])

    def test_1080p_uses_standard_model_without_changing_timestamp_policy(self):
        result = self.run_shell(r'''
measure_preflight_quality 0 3 "$TEST_ROOT/sample.mkv"
''', SOURCE_DIMENSIONS="1920x1080",
                                SCORE_JSON=json.dumps({"pooled_metrics": {"vmaf": {"mean": 100}}}))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("source-display 1920x1080", result.stdout)
        args = (self.root / "args").read_bytes().decode().split("\0")
        graph = args[args.index("-filter_complex") + 1]
        self.assertIn("model='version=vmaf_v0.6.1'", graph)
        self.assertIn("ts_sync_mode=nearest", graph)
        self.assertIn("n_subsample=1", graph)
        self.assertNotIn("fps=", graph)

    def test_display_geometry_honors_sar_rotation_and_even_canvas(self):
        result = self.run_shell(r'''
printf 'square:%s\n' "$(quality_display_geometry 1920 1080 1:1 0)"
printf 'anamorphic:%s\n' "$(quality_display_geometry 720 576 16:15 0)"
printf 'rotated:%s\n' "$(quality_display_geometry 720 576 16:15 90)"
printf 'odd:%s\n' "$(quality_display_geometry 853 480 1:1 0)"
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("square:1920\t1080", result.stdout)
        self.assertIn("anamorphic:768\t576", result.stdout)
        # Rotation swaps the viewed square-pixel canvas; it must not stretch it.
        self.assertIn("rotated:576\t768", result.stdout)
        self.assertIn("odd:854\t480", result.stdout)

    def test_aspect_mismatch_is_fit_and_padded_not_stretched(self):
        result = self.run_shell(r'''
quality_vmaf_filter_graph 1920 1080 "$TEST_ROOT/a.json" 4 vmaf_v0.6.1
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        graph = result.stdout
        self.assertEqual(graph.count("pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=black"), 2)
        self.assertEqual(graph.count("setsar=1"), 4)
        self.assertIn("if(gt(a,1920/1080),1920,-2)", graph)
        self.assertIn("if(gt(a,1920/1080),-2,1080)", graph)

    def test_quality_cache_policy_versions_invalidate_old_scores_and_outputs(self):
        self.assertIn("calibration-v4-source-display-resolution-bicubic-sar-nearest-vmaf-model", VIDEO_HELPER)
        self.assertNotIn("calibration-v3-nominal-fps-nearest-timestamps-center-validation", VIDEO_HELPER)
        self.assertIn('"video-acceptance-v1-duration-scaled"', CORE)
        self.assertNotIn('"video-preprocessing-v2-selection"', CORE + VIDEO_HELPER)
        self.assertIn("QUALITY_VMAF_POLICY_VERSION='source-display-v1'", VIDEO_HELPER)

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"),
                         "FFmpeg/ffprobe are unavailable")
    def test_real_lossless_sample_matches_across_container_timebases(self):
        encoders = subprocess.check_output(["ffmpeg", "-hide_banner", "-encoders"],
                                           stderr=subprocess.DEVNULL, text=True)
        if not all(name in encoders for name in ("libx264", "ffv1")):
            self.skipTest("FFmpeg needs libx264 and FFV1 for this fixture")

        # Capture the production graph, then substitute SSIM so timestamp
        # framesync remains testable on FFmpeg builds without libvmaf.
        result = self.run_shell('measure_preflight_quality 0.833 3 "$TEST_ROOT/sample.mkv"',
                                SOURCE_DIMENSIONS="128x72",
                                SCORE_JSON=json.dumps({"pooled_metrics": {"vmaf": {"mean": 100}}}))
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.root / "args").read_bytes().decode().split("\0")
        graph = args[args.index("-filter_complex") + 1]
        graph = re.sub(
            r"libvmaf=model='version=[^']+':log_fmt=json:log_path=[^:;]+:n_threads=[0-9]+:n_subsample=1:",
            "ssim=", graph)
        source, sample = self.root / "reference.mp4", self.root / "lossless.mkv"

        def ffmpeg(*arguments):
            process = subprocess.run(["ffmpeg", "-hide_banner", "-nostdin", "-y", *map(str, arguments)],
                                     capture_output=True, text=True, timeout=30)
            self.assertEqual(process.returncode, 0, process.stderr[-4000:])
            return process.stderr

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
        shifted = graph.replace("[1:v:0]", "[1:v:0]trim=start_frame=1,")
        self.assertLess(score(shifted), 0.9)

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"),
                         "FFmpeg/ffprobe are unavailable")
    def test_real_vmaf_penalizes_visible_resolution_loss_when_available(self):
        filters = subprocess.check_output(["ffmpeg", "-hide_banner", "-filters"],
                                          stderr=subprocess.STDOUT, text=True)
        if not re.search(r"\blibvmaf\b", filters):
            self.skipTest("FFmpeg lacks the libvmaf filter")
        encoders = subprocess.check_output(["ffmpeg", "-hide_banner", "-encoders"],
                                           stderr=subprocess.DEVNULL, text=True)
        if "ffv1" not in encoders:
            self.skipTest("FFmpeg lacks FFV1 for the lossless fixture")

        # A libvmaf filter can be compiled without the requested built-in model.
        model_probe = subprocess.run([
            "ffmpeg", "-hide_banner", "-v", "error", "-f", "lavfi", "-i",
            "testsrc2=s=64x64:r=2:d=1", "-f", "lavfi", "-i", "testsrc2=s=64x64:r=2:d=1",
            "-lavfi", "libvmaf=model='version=vmaf_v0.6.1'", "-f", "null", "-"
        ], capture_output=True, text=True, timeout=30)
        if model_probe.returncode != 0:
            self.skipTest("libvmaf is present but vmaf_v0.6.1 is unavailable")

        source = self.root / "detail-source.mkv"
        same = self.root / "detail-same.mkv"
        down = self.root / "detail-downscaled.mkv"

        def run_ffmpeg(*args):
            process = subprocess.run(["ffmpeg", "-hide_banner", "-nostdin", "-y", *map(str, args)],
                                     capture_output=True, text=True, timeout=45)
            self.assertEqual(process.returncode, 0, process.stderr[-4000:])

        run_ffmpeg("-v", "error", "-f", "lavfi", "-i",
                   "testsrc2=size=640x360:rate=30:duration=3", "-pix_fmt", "yuv420p",
                   "-c:v", "ffv1", "-threads", "2", source)
        shutil.copyfile(source, same)
        run_ffmpeg("-v", "error", "-i", source, "-vf", "scale=128:72:flags=lanczos",
                   "-pix_fmt", "yuv420p", "-c:v", "ffv1", "-threads", "2", down)

        def production_score(candidate):
            script = "set -euo pipefail\nsource " + shlex.quote(str(self.functions)) + "\n" + r'''
input="$SOURCE"
quality_check=required
preflight_files=()
has_filter() { ffmpeg -hide_banner -filters 2>/dev/null | awk -v wanted="$1" 'NF >= 2 && $2 == wanted {found=1} END {exit(found ? 0 : 1)}'; }
measure_preflight_quality 0 3 "$CANDIDATE"
printf 'SCORE:%s\n' "$MEASURED_QUALITY_SCORE"
'''
            env = dict(os.environ, SOURCE=str(source), CANDIDATE=str(candidate),
                       HARDCORE_ARCHIVE_VIDEO_QUALITY_THREADS="2")
            result = subprocess.run(["bash", "-c", script], env=env,
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            match = re.search(r"SCORE:([0-9.]+)", result.stdout)
            self.assertIsNotNone(match, result.stdout)
            return float(match.group(1))

        same_score = production_score(same)
        down_score = production_score(down)
        self.assertGreater(same_score, 99.0)
        self.assertLess(down_score, same_score - 5.0,
                        f"downscaled candidate was not penalized: same={same_score}, down={down_score}")

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
