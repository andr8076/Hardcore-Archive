#!/usr/bin/env python3
"""Strict real-media integration coverage for production video quality validation.

The ordinary unit suites intentionally permit skips on developer machines without
FFmpeg.  This suite is different: hosted CI sets
HARDCORE_ARCHIVE_STRICT_REAL_VIDEO_CI=1 after activating the pinned Hardcore
Archive media runtime.  In strict mode, missing capabilities or any skipped test
make the process fail.

Fixtures use the software FFV1 encoder only to make deterministic source and
candidate media.  The production archive policy remains hardware-encoder-only;
this suite exercises comparison and completed-output acceptance, not production
encoding backend selection.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = (ROOT / "lib/hardcore-archive-core.sh").read_text()
QUALITY_FUNCTIONS = "MEASURED_QUALITY_KIND=''\n" + CORE.split(
    "MEASURED_QUALITY_KIND=''\n", 1
)[1].split("\nHARDCORE_AUTO_CODEC_MODE=", 1)[0]
STRICT = os.environ.get("HARDCORE_ARCHIVE_STRICT_REAL_VIDEO_CI") == "1"


def run_command(args: list[str], *, timeout: int = 90) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def ffmpeg(*args: object, timeout: int = 90) -> None:
    process = run_command(
        ["ffmpeg", "-hide_banner", "-nostdin", "-y", *map(str, args)],
        timeout=timeout,
    )
    if process.returncode != 0:
        raise AssertionError(
            "FFmpeg fixture command failed:\n"
            + " ".join(map(str, args))
            + "\n"
            + process.stderr[-6000:]
        )


def probe_required_runtime() -> list[str]:
    problems: list[str] = []
    for tool in ("ffmpeg", "ffprobe"):
        if not shutil.which(tool):
            problems.append(f"{tool} is not on PATH")
    if problems:
        return problems

    filters = run_command(["ffmpeg", "-hide_banner", "-filters"])
    if filters.returncode != 0:
        problems.append("ffmpeg -filters failed")
    else:
        for name in ("libvmaf", "scale", "drawbox", "setpts", "testsrc2"):
            if not re.search(rf"(^|\s){re.escape(name)}(\s|$)", filters.stdout, re.MULTILINE):
                problems.append(f"required filter {name} is unavailable")

    encoders = run_command(["ffmpeg", "-hide_banner", "-encoders"])
    if encoders.returncode != 0 or not re.search(r"\bffv1\b", encoders.stdout):
        problems.append("FFV1 fixture encoder is unavailable")

    for model in ("vmaf_v0.6.1", "vmaf_4k_v0.6.1"):
        probe = run_command([
            "ffmpeg", "-hide_banner", "-v", "error", "-nostdin",
            "-f", "lavfi", "-i", "testsrc2=s=64x64:r=2:d=1",
            "-f", "lavfi", "-i", "testsrc2=s=64x64:r=2:d=1",
            "-lavfi", f"libvmaf=model='version={model}':n_threads=1:n_subsample=1",
            "-f", "null", "-",
        ], timeout=30)
        if probe.returncode != 0:
            problems.append(f"required VMAF model {model} failed: {probe.stderr[-1000:]}")
    return problems


class ProductionAcceptanceHarness:
    def __init__(self, root: Path):
        self.root = root
        self.functions = root / "quality-functions.sh"
        self.functions.write_text(QUALITY_FUNCTIONS)

    def validate(
        self,
        source: Path,
        candidate: Path,
        duration: float,
        *,
        mode: str = "full",
        min_samples: int = 5,
        max_samples: int = 5,
        complexity_samples: int = 0,
        percentile_delta: float = 4.0,
        sustained_seconds: float = 1.0,
    ) -> tuple[int, str, dict[str, object] | None, str]:
        script = r'''
set -eo pipefail
source "$HCA_QUALITY_FUNCTIONS"
source "$HCA_ROOT/lib/video-quality-final.sh"
set -u
input="$HCA_SOURCE"
duration="$HCA_DURATION"
quality_check=required
quality_vmaf_threshold=92
video_quality_validation="$HCA_MODE"
video_quality_sample_seconds=4
video_quality_interval_seconds=300
video_quality_min_samples="$HCA_MIN_SAMPLES"
video_quality_max_samples="$HCA_MAX_SAMPLES"
video_quality_complexity_samples="$HCA_COMPLEXITY_SAMPLES"
video_quality_low_percentile=10
video_quality_percentile_delta="$HCA_PERCENTILE_DELTA"
video_quality_sustained_delta=6
video_quality_sustained_seconds="$HCA_SUSTAINED_SECONDS"
QUALITY_WORKER_THREADS=2
QUALITY_VMAF_AVAILABLE=true
preflight_files=()
HARDCORE_ARCHIVE_VIDEO_QUALITY_HELPER="$HCA_ROOT/lib/hardcore-archive-video-quality.py"
has_filter() {
    ffmpeg -hide_banner -filters 2>/dev/null | awk -v wanted="$1" \
        'NF >= 2 && $2 == wanted {found=1} END {exit(found ? 0 : 1)}'
}
set +e
hardcore_video_validate_completed_quality "$HCA_CANDIDATE"
validation_rc=$?
set -e
printf '\nHCA_VALIDATION_RC=%s\n' "$validation_rc"
printf 'HCA_VALIDATION_REASON=%s\n' "${VIDEO_FINAL_QUALITY_REASON:-}"
printf 'HCA_VALIDATION_RETRYABLE=%s\n' "${VIDEO_FINAL_QUALITY_RETRYABLE:-false}"
printf 'HCA_VALIDATION_RESULT=%s\n' "${VIDEO_FINAL_QUALITY_RESULT:-}"
'''
        env = dict(
            os.environ,
            HCA_ROOT=str(ROOT),
            HCA_QUALITY_FUNCTIONS=str(self.functions),
            HCA_SOURCE=str(source),
            HCA_CANDIDATE=str(candidate),
            HCA_DURATION=f"{duration:.9f}",
            HCA_MODE=mode,
            HCA_MIN_SAMPLES=str(min_samples),
            HCA_MAX_SAMPLES=str(max_samples),
            HCA_COMPLEXITY_SAMPLES=str(complexity_samples),
            HCA_PERCENTILE_DELTA=str(percentile_delta),
            HCA_SUSTAINED_SECONDS=str(sustained_seconds),
            HARDCORE_ARCHIVE_VIDEO_QUALITY_THREADS="2",
        )
        process = subprocess.run(
            ["bash", "-c", script], env=env, capture_output=True, text=True, timeout=180
        )
        if process.returncode != 0:
            raise AssertionError(process.stdout + process.stderr)

        rc_match = re.search(r"^HCA_VALIDATION_RC=(\d+)$", process.stdout, re.MULTILINE)
        reason_match = re.search(r"^HCA_VALIDATION_REASON=(.*)$", process.stdout, re.MULTILINE)
        result_match = re.search(r"^HCA_VALIDATION_RESULT=(.*)$", process.stdout, re.MULTILINE)
        if not rc_match or not reason_match or not result_match:
            raise AssertionError("production validation markers missing:\n" + process.stdout)
        result_text = result_match.group(1).strip()
        result = json.loads(result_text) if result_text else None
        return int(rc_match.group(1)), reason_match.group(1), result, process.stdout


@unittest.skipUnless(STRICT, "strict real-video integration runs only in the dedicated CI lane")
class RealProductionVideoQualityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        problems = probe_required_runtime()
        if problems:
            raise AssertionError("Required media runtime capability check failed:\n- " + "\n- ".join(problems))

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.harness = ProductionAcceptanceHarness(self.root)

    def make_source(
        self, name: str, *, duration: float, rate: str = "10", size: str = "320x180"
    ) -> Path:
        path = self.root / name
        ffmpeg(
            "-v", "error", "-f", "lavfi", "-i",
            f"testsrc2=size={size}:rate={rate}:duration={duration}",
            "-pix_fmt", "yuv420p", "-c:v", "ffv1", "-threads", "2", path,
        )
        return path

    def assert_reject(self, result: dict[str, object] | None, output: str) -> dict[str, object]:
        self.assertIsNotNone(result, output)
        assert result is not None
        self.assertEqual(result.get("status"), "reject", output)
        self.assertTrue(result.get("evidence_complete"), output)
        return result

    def test_faithful_output_passes_production_completed_acceptance(self) -> None:
        source = self.make_source("faithful-source.mkv", duration=4)
        candidate = self.root / "faithful-candidate.mkv"
        shutil.copyfile(source, candidate)
        rc, reason, result, output = self.harness.validate(source, candidate, 4)
        self.assertEqual(rc, 0, output)
        self.assertEqual(reason, "", output)
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.get("status"), "pass", output)
        self.assertTrue(result.get("evidence_complete"), output)
        self.assertGreater(float(result.get("mean_vmaf", 0)), 99.0)

    def test_resolution_degradation_is_rejected_by_production_policy(self) -> None:
        source = self.make_source("resolution-source.mkv", duration=4)
        candidate = self.root / "resolution-downscaled.mkv"
        ffmpeg(
            "-v", "error", "-i", source,
            "-vf", "scale=64:36:flags=lanczos", "-pix_fmt", "yuv420p",
            "-c:v", "ffv1", "-threads", "2", candidate,
        )
        rc, _reason, result, output = self.harness.validate(source, candidate, 4)
        self.assertNotEqual(rc, 0, output)
        rejected = self.assert_reject(result, output)
        self.assertLess(float(rejected.get("mean_vmaf", 100)), 92.0)

    def test_localized_degradation_outside_calibration_positions_is_sampled_and_rejected(self) -> None:
        source = self.make_source(
            "localized-source.mkv", duration=60, rate="5", size="160x90"
        )
        candidate = self.root / "localized-candidate.mkv"
        ffmpeg(
            "-v", "error", "-i", source,
            "-vf", "drawbox=x=0:y=0:w=iw:h=ih:color=black:t=fill:enable=between(t\\,16\\,20)",
            "-pix_fmt", "yuv420p", "-c:v", "ffv1", "-threads", "2", candidate,
        )
        rc, _reason, result, output = self.harness.validate(
            source, candidate, 60, mode="sampled", min_samples=5, max_samples=5,
            complexity_samples=0, percentile_delta=20,
        )
        self.assertNotEqual(rc, 0, output)
        rejected = self.assert_reject(result, output)
        starts = [round(float(row["start"]), 3) for row in rejected["window_evidence"]]
        self.assertIn(16.0, starts, output)  # 30% sample; calibration uses 10/50/90%.
        self.assertTrue(
            any("window-mean" in str(reason) or "sustained-low-quality" in str(reason)
                for reason in rejected.get("reasons", [])),
            output,
        )

    def test_incomplete_candidate_cannot_authorize_production_acceptance(self) -> None:
        source = self.make_source("incomplete-source.mkv", duration=4)
        candidate = self.root / "incomplete-candidate.mkv"
        ffmpeg(
            "-v", "error", "-i", source, "-t", "2",
            "-c:v", "ffv1", "-threads", "2", candidate,
        )
        rc, reason, result, output = self.harness.validate(source, candidate, 4)
        self.assertNotEqual(rc, 0, output)
        if result is not None:
            self.assertEqual(result.get("status"), "error", output)
            self.assertFalse(result.get("evidence_complete"), output)
        else:
            self.assertRegex(reason, r"measurement-failed|quality-evaluation", output)

    def test_real_vfr_timing_drives_production_sustained_rejection(self) -> None:
        source = self.root / "vfr-source.mkv"
        candidate = self.root / "vfr-candidate.mkv"
        setpts = "setpts=if(lt(N\\,10)\\,N*0.2/TB\\,(2+(N-10)*(8/290))/TB)"
        ffmpeg(
            "-v", "error", "-f", "lavfi", "-i",
            "testsrc2=size=160x90:rate=30:duration=10",
            "-vf", setpts, "-fps_mode", "vfr", "-pix_fmt", "yuv420p",
            "-c:v", "ffv1", "-threads", "2", source,
        )
        ffmpeg(
            "-v", "error", "-i", source,
            "-vf", "drawbox=x=0:y=0:w=iw:h=ih:color=black:t=fill:enable=lt(t\\,2)",
            "-fps_mode", "vfr", "-pix_fmt", "yuv420p",
            "-c:v", "ffv1", "-threads", "2", candidate,
        )
        rc, _reason, result, output = self.harness.validate(
            source, candidate, 10, percentile_delta=20
        )
        self.assertNotEqual(rc, 0, output)
        rejected = self.assert_reject(result, output)
        sustained = float(rejected.get("longest_sustained_seconds", 0))
        self.assertGreaterEqual(sustained, 1.8, output)
        self.assertLessEqual(sustained, 2.2, output)
        self.assertTrue(
            any("sustained-low-quality" in str(reason) for reason in rejected.get("reasons", [])),
            output,
        )


def main() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(RealProductionVideoQualityTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if STRICT and result.skipped:
        print("STRICT CI FAILURE: required real-media tests were skipped:")
        for test, reason in result.skipped:
            print(f"  {test}: {reason}")
        return 2
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
