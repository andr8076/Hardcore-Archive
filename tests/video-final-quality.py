#!/usr/bin/env python3
"""Regression tests for completed-output video quality acceptance."""
from __future__ import annotations

import importlib.util
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER_PATH = ROOT / "lib/hardcore-archive-video-quality.py"
spec = importlib.util.spec_from_file_location("hardcore_video_quality", HELPER_PATH)
assert spec and spec.loader
quality = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quality)


def write_log(path: Path, scores: list[float], pooled: float | None = None) -> None:
    if pooled is None:
        pooled = sum(scores) / len(scores)
    path.write_text(json.dumps({
        "pooled_metrics": {"vmaf": {"mean": pooled}},
        "frames": [{"metrics": {"vmaf": value}} for value in scores],
    }))


class PlanningTests(unittest.TestCase):
    def test_default_five_windows_cover_positions_missing_from_old_policy(self):
        windows = quality.plan_uniform_windows(60.0)
        centers = [(window.start + window.length / 2) / 60.0 for window in windows]
        self.assertEqual(len(windows), 5)
        for actual, expected in zip(centers, (0.10, 0.30, 0.50, 0.70, 0.90)):
            self.assertAlmostEqual(actual, expected, places=6)
        self.assertTrue(any(abs(center - 0.30) < 1e-6 for center in centers))
        self.assertTrue(any(abs(center - 0.70) < 1e-6 for center in centers))

    def test_coverage_increases_with_duration_but_is_bounded(self):
        one_minute = quality.plan_uniform_windows(60.0)
        one_hour = quality.plan_uniform_windows(3600.0)
        very_long = quality.plan_uniform_windows(24 * 3600.0)
        self.assertEqual(len(one_minute), 5)
        self.assertGreater(len(one_hour), len(one_minute))
        self.assertLessEqual(len(one_hour), 14)  # two default complexity slots are reserved
        self.assertLessEqual(len(very_long), 14)

    def test_short_clip_is_completely_covered(self):
        windows = quality.plan_uniform_windows(17.0)
        self.assertEqual(windows[0].start, 0.0)
        self.assertAlmostEqual(quality.union_coverage(windows), 17.0, places=6)
        self.assertTrue(all(window.kind == "short-full" for window in windows))

    def test_complexity_windows_are_reproducible_and_do_not_replace_uniform_coverage(self):
        uniform = quality.plan_uniform_windows(600.0)
        candidates = [
            quality.Window("complexity", 101.0, 4.0),
            quality.Window("complexity", 401.0, 4.0),
        ]
        first = quality.add_complexity_windows(uniform, candidates, 16)
        second = quality.add_complexity_windows(uniform, candidates, 16)
        self.assertEqual(first, second)
        self.assertTrue(all(window in first for window in uniform))


class EvaluationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def manifest(self, entries: list[tuple[str, float, float, list[float]]]) -> Path:
        manifest = self.root / "measurements.tsv"
        rows = []
        for index, (kind, start, length, scores) in enumerate(entries):
            log = self.root / f"{index}.json"
            write_log(log, scores)
            rows.append(f"{kind}\t{start}\t{length}\t{log}\n")
        manifest.write_text("".join(rows))
        return manifest

    def test_unchanged_quality_passes(self):
        manifest = self.manifest([
            ("uniform", 4, 4, [99.5] * 120),
            ("uniform", 16, 4, [99.5] * 120),
            ("uniform", 28, 4, [99.5] * 120),
            ("uniform", 40, 4, [99.5] * 120),
            ("uniform", 52, 4, [99.5] * 120),
        ])
        result = quality.evaluate_manifest(str(manifest), 60, 92)
        self.assertEqual(result["status"], "pass")
        self.assertGreater(result["coverage_percent"], 30)

    def test_localized_window_below_target_is_rejected(self):
        manifest = self.manifest([
            ("uniform", 4, 4, [97] * 120),
            # A substantial bad scene at the new 30% sample position.
            ("uniform", 16, 4, [89] * 120),
            ("uniform", 28, 4, [97] * 120),
            ("uniform", 40, 4, [97] * 120),
            ("uniform", 52, 4, [97] * 120),
        ])
        result = quality.evaluate_manifest(str(manifest), 60, 92)
        self.assertEqual(result["status"], "reject")
        self.assertTrue(any("window-mean" in reason for reason in result["reasons"]))

    def test_one_isolated_noisy_frame_does_not_reject_good_video(self):
        scores = [98.0] * 120
        scores[57] = 20.0
        manifest = self.manifest([("full", 0, 4, scores)])
        result = quality.evaluate_manifest(str(manifest), 4, 92)
        self.assertEqual(result["status"], "pass", result)
        self.assertLess(result["longest_sustained_seconds"], 1.0)

    def test_sustained_local_loss_rejects_even_when_mean_is_good(self):
        # Thirty bad frames in a 120-frame/4-second sample is one continuous
        # second. Overall mean remains comfortably above the target.
        scores = [100.0] * 120
        scores[45:75] = [80.0] * 30
        manifest = self.manifest([("uniform", 12, 4, scores)])
        result = quality.evaluate_manifest(
            str(manifest), 20, 92, low_percentile=10,
            percentile_delta=20, sustained_delta=6, sustained_seconds=1,
        )
        self.assertGreater(result["mean_vmaf"], 92)
        self.assertEqual(result["status"], "reject")
        self.assertTrue(any("sustained-low-quality" in reason for reason in result["reasons"]))

    def test_variable_frame_rate_sustained_time_uses_measured_population(self):
        # Ten frames over four seconds: three consecutive low frames represent
        # 1.2 seconds. A fixed 30-fps assumption would incorrectly call this 0.1s.
        scores = [100.0] * 7 + [80.0] * 3
        manifest = self.manifest([("uniform", 0, 4, scores)])
        result = quality.evaluate_manifest(
            str(manifest), 4, 92, low_percentile=10,
            percentile_delta=40, sustained_delta=6, sustained_seconds=1,
        )
        self.assertGreaterEqual(result["longest_sustained_seconds"], 1.19)
        self.assertTrue(any("sustained-low-quality" in reason for reason in result["reasons"]))

    def test_missing_or_malformed_measurements_never_pass(self):
        empty = self.root / "empty.tsv"
        empty.write_text("")
        with self.assertRaises(ValueError):
            quality.evaluate_manifest(str(empty), 60, 92)

        log = self.root / "bad.json"
        log.write_text('{"pooled_metrics":{}}')
        manifest = self.root / "bad.tsv"
        manifest.write_text(f"uniform\t1\t4\t{log}\n")
        with self.assertRaises((ValueError, KeyError)):
            quality.evaluate_manifest(str(manifest), 60, 92)

    def test_higher_quality_retry_is_bounded_and_directional(self):
        self.assertEqual(quality.higher_quality("av1_nvenc", 28, 2), 26)
        self.assertEqual(quality.higher_quality("hevc_vaapi", 3, 2), 1)
        self.assertIsNone(quality.higher_quality("hevc_vaapi", 1, 2))
        self.assertEqual(quality.higher_quality("hevc_videotoolbox", 65, 5), 70)
        self.assertIsNone(quality.higher_quality("unknown-hardware", 20, 2))


class StaticIntegrationTests(unittest.TestCase):
    def test_core_wires_completed_output_policy_and_cache_identity(self):
        core = (ROOT / "lib/hardcore-archive-core.sh").read_text()
        self.assertIn("hardcore_video_validate_completed_quality", core)
        self.assertIn("VIDEO_QUALITY_VALIDATION", core)
        self.assertIn("completed-video-quality-v1", core)
        self.assertIn("VIDEO_QUALITY_LOW_PERCENTILE", core)
        self.assertIn("VIDEO_QUALITY_SUSTAINED_SECONDS", core)
        self.assertIn("VIDEO_QUALITY_RETRIES", core)
        self.assertIn("video-acceptance-v1-duration-scaled", core)
        self.assertNotIn("video-preprocessing-v3-source-display-vmaf\"", core)

    def test_calibration_remains_separate_and_inexpensive(self):
        core = (ROOT / "lib/hardcore-archive-core.sh").read_text()
        match = re.search(r"evaluate_hardware_quality\(\) \{(.*?)\n\}", core, re.S)
        self.assertIsNotNone(match)
        body = match.group(1)
        self.assertIn("local sample_length=3", body)
        self.assertIn("local -a positions=(0.10 0.50 0.90)", body)
        self.assertNotIn("hardcore_video_validate_completed_quality", body)


class RealMediaTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"),
                         "FFmpeg/ffprobe unavailable")
    def test_real_libvmaf_rejects_degradation_at_new_30_percent_window(self):
        filters = subprocess.check_output(
            ["ffmpeg", "-hide_banner", "-filters"], stderr=subprocess.STDOUT, text=True
        )
        if not re.search(r"\blibvmaf\b", filters):
            self.skipTest("FFmpeg lacks libvmaf")
        encoders = subprocess.check_output(
            ["ffmpeg", "-hide_banner", "-encoders"], stderr=subprocess.DEVNULL, text=True
        )
        if "ffv1" not in encoders:
            self.skipTest("FFmpeg lacks FFV1")
        model = subprocess.run([
            "ffmpeg", "-hide_banner", "-v", "error",
            "-f", "lavfi", "-i", "testsrc2=s=64x64:r=2:d=1",
            "-f", "lavfi", "-i", "testsrc2=s=64x64:r=2:d=1",
            "-lavfi", "libvmaf=model='version=vmaf_v0.6.1'", "-f", "null", "-",
        ], capture_output=True, text=True, timeout=30)
        if model.returncode != 0:
            self.skipTest("vmaf_v0.6.1 model unavailable")

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source.mkv"
            candidate = root / "candidate.mkv"

            def ffmpeg(*args: object) -> None:
                process = subprocess.run(
                    ["ffmpeg", "-hide_banner", "-nostdin", "-y", *map(str, args)],
                    capture_output=True, text=True, timeout=60,
                )
                self.assertEqual(process.returncode, 0, process.stderr[-4000:])

            # Low fps/resolution keeps the optional integration test cheap. The
            # candidate is damaged only around 30% (16-20s), away from old
            # 10/50/90 calibration positions.
            ffmpeg("-v", "error", "-f", "lavfi", "-i",
                   "testsrc2=size=160x90:rate=5:duration=60", "-pix_fmt", "yuv420p",
                   "-c:v", "ffv1", "-threads", "2", source)
            ffmpeg("-v", "error", "-i", source,
                   "-vf", "drawbox=x=0:y=0:w=iw:h=ih:color=black:t=fill:enable='between(t,16,20)'",
                   "-c:v", "ffv1", "-threads", "2", candidate)

            windows = quality.plan_uniform_windows(60.0)
            manifest = root / "logs.tsv"
            rows = []
            for index, window in enumerate(windows):
                log = root / f"{index}.json"
                graph = (
                    "[0:v]settb=AVTB,setpts=PTS-STARTPTS,format=yuv420p[ref];"
                    "[1:v]settb=AVTB,setpts=PTS-STARTPTS,format=yuv420p[dist];"
                    f"[dist][ref]libvmaf=model='version=vmaf_v0.6.1':log_fmt=json:"
                    f"log_path={log}:n_threads=2:n_subsample=1:ts_sync_mode=nearest"
                )
                ffmpeg("-v", "error", "-ss", f"{window.start:.6f}", "-t",
                       f"{window.length:.6f}", "-i", source,
                       "-ss", f"{window.start:.6f}", "-t", f"{window.length:.6f}",
                       "-i", candidate, "-filter_complex", graph, "-an", "-f", "null", "-")
                rows.append(f"{window.kind}\t{window.start}\t{window.length}\t{log}\n")
            manifest.write_text("".join(rows))
            result = quality.evaluate_manifest(str(manifest), 60, 92)
            self.assertEqual(result["status"], "reject", result)
            self.assertTrue(any("window-mean" in reason for reason in result["reasons"]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
