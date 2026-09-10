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
import sys
sys.modules[spec.name] = quality
spec.loader.exec_module(quality)


def write_log(path: Path, scores: list[float], pooled: float | None = None) -> None:
    if pooled is None:
        pooled = sum(scores) / len(scores)
    path.write_text(json.dumps({
        "pooled_metrics": {"vmaf": {"mean": pooled}},
        "frames": [
            {"frameNum": index, "metrics": {"vmaf": value}}
            for index, value in enumerate(scores)
        ],
    }))


def cfr_provider(rate: float = 30.0):
    def provide(_path: str, window: quality.Window, _ffprobe: str):
        count = max(1, int(round(window.length * rate)))
        step = window.length / count
        return [
            quality.FrameObservation(window.start + index * step, step)
            for index in range(count)
        ]
    return provide


def vfr_300_first_ten_span_two_seconds() -> list[quality.FrameObservation]:
    observations = [quality.FrameObservation(index * 0.2) for index in range(10)]
    fast_step = 8.0 / 290.0
    observations.extend(
        quality.FrameObservation(2.0 + index * fast_step)
        for index in range(290)
    )
    observations[-1] = quality.FrameObservation(observations[-1].pts, fast_step)
    return observations


def vfr_300_first_hundred_span_half_second() -> list[quality.FrameObservation]:
    observations = [quality.FrameObservation(index * 0.005) for index in range(100)]
    slow_step = 9.5 / 200.0
    observations.extend(
        quality.FrameObservation(0.5 + index * slow_step)
        for index in range(200)
    )
    observations[-1] = quality.FrameObservation(observations[-1].pts, slow_step)
    return observations


class PlanningTests(unittest.TestCase):
    def test_default_five_windows_cover_positions_missing_from_old_policy(self):
        windows = quality.plan_uniform_windows(60.0)
        centers = [(window.start + window.length / 2) / 60.0 for window in windows]
        self.assertEqual(len(windows), 5)
        for actual, expected in zip(centers, (0.10, 0.30, 0.50, 0.70, 0.90)):
            self.assertAlmostEqual(actual, expected, places=6)

    def test_coverage_increases_with_duration_but_is_bounded(self):
        one_minute = quality.plan_uniform_windows(60.0)
        one_hour = quality.plan_uniform_windows(3600.0)
        very_long = quality.plan_uniform_windows(24 * 3600.0)
        self.assertEqual(len(one_minute), 5)
        self.assertGreater(len(one_hour), len(one_minute))
        self.assertLessEqual(len(one_hour), 14)
        self.assertLessEqual(len(very_long), 14)

    def test_short_clip_is_completely_planned(self):
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

    def test_full_mode_plan_requests_complete_timeline(self):
        process = subprocess.run([
            sys.executable, str(HELPER_PATH), "plan",
            "--input", str(ROOT / "unused-full-mode-input.mkv"),
            "--duration", "123.5", "--mode", "full",
        ], capture_output=True, text=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        fields = process.stdout.strip().split("\t")
        self.assertEqual(fields[0], "full")
        self.assertAlmostEqual(float(fields[1]), 0.0, places=6)
        self.assertAlmostEqual(float(fields[2]), 123.5, places=6)


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

    def evaluate(self, manifest: Path, duration: float, *, provider=None, **kwargs):
        return quality.evaluate_manifest(
            str(manifest), duration, kwargs.pop("threshold", 92),
            reference_path="reference.mkv", candidate_path="candidate.mkv",
            evidence_provider=provider or cfr_provider(), **kwargs,
        )

    def test_unchanged_quality_passes_with_confirmed_coverage(self):
        manifest = self.manifest([
            ("uniform", 4, 4, [99.5] * 120),
            ("uniform", 16, 4, [99.5] * 120),
            ("uniform", 28, 4, [99.5] * 120),
            ("uniform", 40, 4, [99.5] * 120),
            ("uniform", 52, 4, [99.5] * 120),
        ])
        result = self.evaluate(manifest, 60)
        self.assertEqual(result["status"], "pass", result)
        self.assertEqual(result["requested_coverage_seconds"], 20)
        self.assertEqual(result["coverage_seconds"], 20)
        self.assertEqual(result["timed_frames"], 600)

    def test_one_frame_hour_measurement_cannot_authorize_or_claim_coverage(self):
        manifest = self.manifest([("full", 0, 3600, [99.0])])
        result = self.evaluate(manifest, 3600, provider=cfr_provider(1.0))
        self.assertEqual(result["status"], "error", result)
        self.assertEqual(result["requested_coverage_seconds"], 3600)
        self.assertEqual(result["coverage_seconds"], 0)
        self.assertTrue(any("VMAF scored 1 frame" in reason for reason in result["reasons"]))

    def test_incomplete_vmaf_window_reports_no_confirmed_measurement_coverage(self):
        manifest = self.manifest([("uniform", 10, 4, [99.0] * 60)])
        result = self.evaluate(manifest, 30, provider=cfr_provider(30.0))
        self.assertEqual(result["status"], "error", result)
        self.assertEqual(result["coverage_seconds"], 0)
        self.assertEqual(result["window_evidence"][0]["timeline_overlap_seconds"], 4)
        self.assertEqual(result["window_evidence"][0]["confirmed_seconds"], 0)

    def test_early_candidate_termination_is_detected(self):
        manifest = self.manifest([("uniform", 0, 4, [99.0] * 120)])
        source = cfr_provider(30.0)("reference", quality.Window("uniform", 0, 4), "ffprobe")
        candidate = [
            quality.FrameObservation(index / 30.0, 1 / 30.0)
            for index in range(60)
        ]

        def provider(path: str, _window: quality.Window, _ffprobe: str):
            return source if "reference" in path else candidate

        result = self.evaluate(manifest, 4, provider=provider)
        self.assertEqual(result["status"], "error", result)
        self.assertEqual(result["coverage_seconds"], 0)
        self.assertTrue(any("candidate timeline incomplete" in reason for reason in result["reasons"]))

    def test_valid_short_low_frame_rate_clip_passes(self):
        manifest = self.manifest([("short-full", 0, 4, [99.0, 99.0])])
        observations = [
            quality.FrameObservation(0.0, 2.0),
            quality.FrameObservation(2.0, 2.0),
        ]
        result = self.evaluate(
            manifest, 4,
            provider=lambda _path, _window, _ffprobe: observations,
        )
        self.assertEqual(result["status"], "pass", result)
        self.assertEqual(result["coverage_seconds"], 4)
        self.assertEqual(result["window_evidence"][0]["candidate_frames"], 2)
        self.assertEqual(result["window_evidence"][0]["timed_vmaf_frames"], 2)

    def test_probe_context_frames_outside_window_do_not_inflate_vmaf_population(self):
        manifest = self.manifest([("uniform", 10, 4, [99.0] * 120)])
        step = 1 / 30.0
        observations = [quality.FrameObservation(10 - step, step)]
        observations.extend(
            quality.FrameObservation(10 + index * step, step)
            for index in range(120)
        )
        observations.append(quality.FrameObservation(14.0, step))
        result = self.evaluate(
            manifest, 30,
            provider=lambda _path, _window, _ffprobe: observations,
        )
        self.assertEqual(result["status"], "pass", result)
        self.assertEqual(result["coverage_seconds"], 4)
        self.assertEqual(result["window_evidence"][0]["candidate_frames"], 120)
        self.assertEqual(result["window_evidence"][0]["vmaf_frames"], 120)

    def test_vfr_300_frames_first_ten_bad_frames_span_two_seconds(self):
        scores = [80.0] * 10 + [100.0] * 290
        manifest = self.manifest([("full", 0, 10, scores)])
        observations = vfr_300_first_ten_span_two_seconds()
        result = self.evaluate(
            manifest, 10,
            provider=lambda _path, _window, _ffprobe: observations,
        )
        self.assertGreater(result["mean_vmaf"], 92)
        self.assertAlmostEqual(result["longest_sustained_seconds"], 2.0, places=6)
        self.assertEqual(result["status"], "reject", result)
        self.assertTrue(any("sustained-low-quality" in reason for reason in result["reasons"]))

    def test_many_rapid_bad_frames_under_duration_do_not_reject(self):
        scores = [80.0] * 100 + [100.0] * 200
        manifest = self.manifest([("full", 0, 10, scores)])
        observations = vfr_300_first_hundred_span_half_second()
        result = self.evaluate(
            manifest, 10,
            provider=lambda _path, _window, _ffprobe: observations,
            percentile_delta=20,
        )
        self.assertGreater(result["mean_vmaf"], 92)
        self.assertAlmostEqual(result["longest_sustained_seconds"], 0.5, places=6)
        self.assertEqual(result["status"], "pass", result)

    def test_constant_frame_rate_sustained_duration_is_preserved(self):
        scores = [80.0] * 30 + [100.0] * 270
        manifest = self.manifest([("full", 0, 10, scores)])
        result = self.evaluate(manifest, 10, provider=cfr_provider(30.0))
        self.assertAlmostEqual(result["longest_sustained_seconds"], 1.0, places=6)
        self.assertEqual(result["status"], "reject", result)
        self.assertTrue(any("sustained-low-quality" in reason for reason in result["reasons"]))

    def test_degradation_continues_across_adjacent_sample_boundary(self):
        first = [100.0] * 132 + [80.0] * 18
        second = [80.0] * 18 + [100.0] * 132
        manifest = self.manifest([
            ("uniform", 0, 5, first),
            ("uniform", 5, 5, second),
        ])
        result = self.evaluate(
            manifest, 10, provider=cfr_provider(30.0), percentile_delta=20
        )
        self.assertAlmostEqual(result["longest_sustained_seconds"], 1.2, places=6)
        self.assertEqual(result["status"], "reject", result)

    def test_unsampled_gap_breaks_sustained_continuity(self):
        first = [100.0] * 132 + [80.0] * 18
        second = [80.0] * 18 + [100.0] * 132
        manifest = self.manifest([
            ("uniform", 0, 5, first),
            ("uniform", 6, 5, second),
        ])
        result = self.evaluate(
            manifest, 11, provider=cfr_provider(30.0), percentile_delta=20
        )
        self.assertAlmostEqual(result["longest_sustained_seconds"], 0.6, places=6)
        self.assertEqual(result["status"], "pass", result)

    def test_overlapping_samples_do_not_double_count_low_quality_time(self):
        first = [100.0] * 12 + [80.0] * 6 + [100.0] * 2
        second = [100.0] * 2 + [80.0] * 6 + [100.0] * 12
        manifest = self.manifest([
            ("uniform", 0, 2, first),
            ("complexity", 1, 2, second),
        ])
        result = self.evaluate(
            manifest, 3, provider=cfr_provider(10.0), percentile_delta=20
        )
        self.assertAlmostEqual(result["longest_sustained_seconds"], 0.6, places=6)
        self.assertEqual(result["status"], "pass", result)

    def test_boundary_frame_count_tolerance_cannot_invent_timing_mapping(self):
        manifest = self.manifest([("uniform", 10, 4, [99.0] * 119)])
        result = self.evaluate(manifest, 30, provider=cfr_provider(30.0))
        self.assertEqual(result["status"], "error", result)
        self.assertEqual(result["coverage_seconds"], 0)
        self.assertTrue(any("exact VMAF/timeline mapping unavailable" in reason
                            for reason in result["reasons"]))

    def test_fractional_seek_maps_frame_overlapping_window_start(self):
        step = 1001 / 24000
        window = quality.Window("uniform", 0.002, 4.0)
        observations = [
            quality.FrameObservation(index * step, step)
            for index in range(98)
        ]
        manifest = self.manifest([("uniform", window.start, window.length, [99.0] * 96)])
        result = self.evaluate(
            manifest, 10,
            provider=lambda _path, _window, _ffprobe: observations,
        )
        self.assertEqual(result["status"], "pass", result)
        self.assertEqual(result["window_evidence"][0]["candidate_frames"], 96)
        self.assertEqual(result["window_evidence"][0]["timed_vmaf_frames"], 96)

    def test_missing_frame_display_duration_fails_closed(self):
        scores = [99.0] * 300
        manifest = self.manifest([("full", 0, 10, scores)])
        observations = [quality.FrameObservation(index / 30.0) for index in range(300)]
        result = self.evaluate(
            manifest, 10,
            provider=lambda _path, _window, _ffprobe: observations,
        )
        self.assertEqual(result["status"], "error", result)
        self.assertEqual(result["coverage_seconds"], 0)
        self.assertTrue(any("missing display timing" in reason for reason in result["reasons"]))

    def test_variable_frame_rate_timestamps_drive_coverage_and_sustained_time(self):
        scores = [100.0] * 7 + [80.0] * 3
        manifest = self.manifest([("full", 0, 4, scores)])
        observations = [
            quality.FrameObservation(0.0),
            quality.FrameObservation(0.1),
            quality.FrameObservation(0.2),
            quality.FrameObservation(0.3),
            quality.FrameObservation(0.4),
            quality.FrameObservation(0.5),
            quality.FrameObservation(0.6),
            quality.FrameObservation(1.0),
            quality.FrameObservation(2.0),
            quality.FrameObservation(3.0, 1.0),
        ]
        result = self.evaluate(
            manifest, 4,
            provider=lambda _path, _window, _ffprobe: observations,
            low_percentile=10, percentile_delta=40,
            sustained_delta=6, sustained_seconds=1,
        )
        self.assertEqual(result["coverage_seconds"], 4)
        self.assertGreaterEqual(result["longest_sustained_seconds"], 2.99)
        self.assertEqual(result["status"], "reject", result)
        self.assertTrue(any("sustained-low-quality" in reason for reason in result["reasons"]))

    def test_localized_window_below_target_is_rejected(self):
        manifest = self.manifest([
            ("uniform", 4, 4, [97] * 120),
            ("uniform", 16, 4, [89] * 120),
            ("uniform", 28, 4, [97] * 120),
            ("uniform", 40, 4, [97] * 120),
            ("uniform", 52, 4, [97] * 120),
        ])
        result = self.evaluate(manifest, 60)
        self.assertEqual(result["status"], "reject")
        self.assertTrue(any("window-mean" in reason for reason in result["reasons"]))

    def test_one_isolated_noisy_frame_does_not_reject_good_video(self):
        scores = [98.0] * 120
        scores[57] = 20.0
        manifest = self.manifest([("full", 0, 4, scores)])
        result = self.evaluate(manifest, 4)
        self.assertEqual(result["status"], "pass", result)
        self.assertLess(result["longest_sustained_seconds"], 1.0)

    def test_sustained_local_loss_rejects_even_when_mean_is_good(self):
        scores = [100.0] * 120
        scores[45:75] = [80.0] * 30
        manifest = self.manifest([("uniform", 12, 4, scores)])
        result = self.evaluate(
            manifest, 20, low_percentile=10,
            percentile_delta=20, sustained_delta=6, sustained_seconds=1,
        )
        self.assertGreater(result["mean_vmaf"], 92)
        self.assertEqual(result["status"], "reject")
        self.assertTrue(any("sustained-low-quality" in reason for reason in result["reasons"]))

    def test_missing_or_malformed_measurements_never_pass(self):
        empty = self.root / "empty.tsv"
        empty.write_text("")
        with self.assertRaises(ValueError):
            self.evaluate(empty, 60)

        log = self.root / "bad.json"
        log.write_text('{"pooled_metrics":{}}')
        manifest = self.root / "bad.tsv"
        manifest.write_text(f"uniform\t1\t4\t{log}\n")
        with self.assertRaises((ValueError, KeyError)):
            self.evaluate(manifest, 60)

    def test_nonfinite_and_inconsistent_measurements_never_pass(self):
        log = self.root / "nonfinite.json"
        log.write_text(json.dumps({
            "pooled_metrics": {"vmaf": {"mean": math.nan}},
            "frames": [{"frameNum": 0, "metrics": {"vmaf": 99.0}}],
        }))
        manifest = self.root / "nonfinite.tsv"
        manifest.write_text(f"uniform\t1\t4\t{log}\n")
        with self.assertRaises(ValueError):
            self.evaluate(manifest, 60)

        bad_numbers = self.root / "bad-numbers.json"
        bad_numbers.write_text(json.dumps({
            "pooled_metrics": {"vmaf": {"mean": 99.0}},
            "frames": [
                {"frameNum": 0, "metrics": {"vmaf": 99.0}},
                {"frameNum": 2, "metrics": {"vmaf": 99.0}},
            ],
        }))
        manifest.write_text(f"uniform\t1\t4\t{bad_numbers}\n")
        with self.assertRaises(ValueError):
            self.evaluate(manifest, 60)

    def test_higher_quality_retry_is_bounded_and_directional(self):
        self.assertEqual(quality.higher_quality("av1_nvenc", 28, 2), 26)
        self.assertEqual(quality.higher_quality("hevc_vaapi", 3, 2), 1)
        self.assertIsNone(quality.higher_quality("hevc_vaapi", 1, 2))
        self.assertEqual(quality.higher_quality("hevc_videotoolbox", 65, 5), 70)
        self.assertIsNone(quality.higher_quality("unknown-hardware", 20, 2))


class StaticIntegrationTests(unittest.TestCase):
    def test_core_wires_completed_output_policy_and_cache_identity(self):
        core_path = ROOT / "lib/hardcore-archive-core.sh"
        if not core_path.exists():
            self.skipTest("full repository checkout unavailable")
        core = core_path.read_text()
        self.assertIn("video-quality-final.sh", core)
        acceleration = (ROOT / "lib/video-acceleration.sh").read_text()
        self.assertIn("hardcore_video_validate_completed_quality", acceleration)
        self.assertIn("VIDEO_QUALITY_VALIDATION", core)
        self.assertIn("video-acceptance-v1-duration-scaled", core)
        self.assertIn("VIDEO_QUALITY_LOW_PERCENTILE", core)
        self.assertIn("VIDEO_QUALITY_SUSTAINED_SECONDS", core)
        self.assertIn("VIDEO_QUALITY_RETRIES", core)

    def test_every_validation_setting_participates_in_resume_identities(self):
        core_path = ROOT / "lib/hardcore-archive-core.sh"
        if not core_path.exists():
            self.skipTest("full repository checkout unavailable")
        core = core_path.read_text()
        identity_blocks = re.findall(
            r'"video-acceptance-v1-duration-scaled".*?sha256sum', core, re.S
        )
        self.assertGreaterEqual(len(identity_blocks), 2)
        settings = (
            "VIDEO_QUALITY_VALIDATION",
            "VIDEO_QUALITY_SAMPLE_SECONDS",
            "VIDEO_QUALITY_INTERVAL_SECONDS",
            "VIDEO_QUALITY_MIN_SAMPLES",
            "VIDEO_QUALITY_MAX_SAMPLES",
            "VIDEO_QUALITY_COMPLEXITY_SAMPLES",
            "VIDEO_QUALITY_LOW_PERCENTILE",
            "VIDEO_QUALITY_PERCENTILE_DELTA",
            "VIDEO_QUALITY_SUSTAINED_DELTA",
            "VIDEO_QUALITY_SUSTAINED_SECONDS",
            "VIDEO_QUALITY_RETRIES",
            "VIDEO_QUALITY_RETRY_STEP",
        )
        for block in identity_blocks[:2]:
            for setting in settings:
                self.assertIn(setting, block, f"{setting} missing from resume/cache identity")

    def test_calibration_remains_separate_and_inexpensive(self):
        helper_path = ROOT / "lib/hardcore-archive-video-helper.sh"
        if not helper_path.exists():
            self.skipTest("full repository checkout unavailable")
        helper = helper_path.read_text()
        match = re.search(r"evaluate_hardware_quality\(\) \{(.*?)\n\}", helper, re.S)
        self.assertIsNotNone(match)
        body = match.group(1)
        self.assertIn("local sample_length=3", body)
        self.assertIn("local -a positions=(0.10 0.50 0.90)", body)
        self.assertNotIn("hardcore_video_validate_completed_quality", body)

    def test_runtime_reporting_separates_requested_and_confirmed_coverage(self):
        final = (ROOT / "lib/video-quality-final.sh").read_text()
        self.assertIn("Requested coverage:", final)
        self.assertIn("Confirmed quality coverage:", final)
        self.assertIn("only windows with complete timestamp/frame evidence", final)
        self.assertIn("must have complete timestamp/frame evidence", final)

    def test_readme_still_distinguishes_sampled_assurance_from_full_validation(self):
        readme_path = ROOT / "README.md"
        if not readme_path.exists():
            self.skipTest("full repository checkout unavailable")
        readme = readme_path.read_text()
        self.assertIn("Sampled validation is sampled assurance, not a whole-video guarantee.", readme)
        self.assertIn("--video-quality-validation full", readme)
        self.assertIn("Full mode is much slower", readme)

    def test_coverage_policy_documents_score_timing_alignment(self):
        documentation = ROOT / "docs/video-quality-validation.md"
        if not documentation.exists():
            self.skipTest("coverage documentation not present in local fixture")
        text = documentation.read_text()
        self.assertIn("50 ms", text)
        self.assertIn("100 ms", text)
        self.assertIn("sequence index", text.lower())
        self.assertIn("presentation interval", text.lower())
        self.assertIn("no average frame rate", text.lower())
        self.assertIn("unsampled gap", text.lower())
        self.assertIn("overlapping", text.lower())


class RealMediaTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"),
                         "FFmpeg/ffprobe unavailable")
    def test_real_ffprobe_timeline_evidence_handles_vfr(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            media = root / "vfr.mkv"
            process = subprocess.run([
                "ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=10:duration=2",
                "-vf", "setpts='if(lt(N,10),N/(10*TB),(1+(N-10)/5)/TB)'",
                "-fps_mode", "vfr", "-c:v", "ffv1", str(media),
            ], capture_output=True, text=True, timeout=30)
            self.assertEqual(process.returncode, 0, process.stderr)
            window = quality.Window("uniform", 0.2, 2.0)
            observations = quality.probe_frame_timeline(str(media), window)
            evidence = quality.analyze_timeline_evidence(observations, window)
            self.assertTrue(evidence["complete"], evidence)
            self.assertAlmostEqual(evidence["coverage_seconds"], 2.0, places=6)
            deltas = [
                round(observations[i + 1].pts - observations[i].pts, 3)
                for i in range(len(observations) - 1)
                if observations[i].pts >= 0.2 and observations[i + 1].pts <= 2.2
            ]
            self.assertGreater(len(set(deltas)), 1, deltas)

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"),
                         "FFmpeg/ffprobe unavailable")
    def test_real_vfr_media_drives_sustained_score_timing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            media = root / "timed-vfr.mkv"
            process = subprocess.run([
                "ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=10:duration=2",
                "-vf", "settb=AVTB,setpts='if(lt(N,4),N/(2.5*TB),(1.6+(N-4)*0.15)/TB)'",
                "-fps_mode", "vfr", "-c:v", "ffv1", str(media),
            ], capture_output=True, text=True, timeout=30)
            self.assertEqual(process.returncode, 0, process.stderr)

            duration_process = subprocess.run([
                "ffprobe", "-v", "error", "-select_streams", "V:0",
                "-show_entries", "stream=duration", "-of", "default=nw=1:nk=1", str(media),
            ], capture_output=True, text=True)
            duration_text = duration_process.stdout.strip()
            duration = float(duration_text) if duration_text not in ("", "N/A") else 4.0
            duration = max(3.9, min(4.1, duration))
            window = quality.Window("full", 0.0, duration)
            observations = quality.probe_frame_timeline(str(media), window)
            evidence = quality.analyze_timeline_evidence(
                observations, window, stream_endpoint=True
            )
            self.assertTrue(evidence["complete"], evidence)
            frame_count = int(evidence["frame_count"])
            self.assertGreaterEqual(frame_count, 10)
            low_count = min(4, frame_count)
            scores = [80.0] * low_count + [100.0] * (frame_count - low_count)
            log = root / "vmaf.json"
            write_log(log, scores)
            manifest = root / "manifest.tsv"
            manifest.write_text(f"full\t0\t{duration}\t{log}\n")
            result = quality.evaluate_manifest(
                str(manifest), duration, 92,
                reference_path=str(media), candidate_path=str(media),
                percentile_delta=20,
            )
            intervals = evidence["frame_intervals"]
            expected_low = sum(intervals[i][1] - intervals[i][0] for i in range(low_count))
            self.assertAlmostEqual(
                result["longest_sustained_seconds"], expected_low, places=3
            )
            self.assertGreater(result["longest_sustained_seconds"], 1.0)
            self.assertEqual(result["status"], "reject", result)

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
            result = quality.evaluate_manifest(
                str(manifest), 60, 92,
                reference_path=str(source), candidate_path=str(candidate),
            )
            self.assertEqual(result["status"], "reject", result)
            self.assertTrue(result["evidence_complete"], result)
            self.assertTrue(any("window-mean" in reason for reason in result["reasons"]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
