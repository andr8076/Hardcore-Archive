#!/usr/bin/env python3
"""Exercise the actual static engine functions with deterministic media probes."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = (ROOT / "lib/hardcore-archive-core.sh").read_text()
FUNCTIONS = CORE.split("\nHARDCORE_AUTO_CODEC_MODE=", 1)[1].split(
    "\ncalibrate_and_choose_video_codec\n", 1
)[0]
FUNCTIONS = "HARDCORE_AUTO_CODEC_MODE=" + FUNCTIONS

FIXTURE = r'''
input="$TEST_ROOT/source.mov"
output_dir="$TEST_ROOT"
output_name=source
duration=${DURATION:-120}
original_size=100000000
source_video_codec=${SOURCE_CODEC:-h264}
quality_vmaf_threshold=${TARGET:-92}
quality_check=${QUALITY_MODE:-required}
min_savings_percent=3
estimated_output_audio_bps=${AUDIO_BPS:-0}
apply_scaling=${SCALING:-false}
apply_denoise=${DENOISE:-false}
TARGET_HEIGHT=1080
DENOISE_FILTER='hqdn3d=1.2:1.0:3.0:2.5'
video_encoder=hevc_vaapi
expected_codec=hevc
video_preflight=true
preflight_min_duration=60
preflight_min_size=134217728
preflight_sample_seconds=12
preflight_files=()
measure_count=0

ffmpeg() {
    if [[ $1 == -version ]]; then
        printf '%s\n' "${BUILD:-ffmpeg-test-build}"
        return 0
    fi
    local output=${!#} sample_bytes=${SAMPLE_BYTES:-10000}
    { printf '%q ' "$@"; printf '\n'; } >> "$TEST_ROOT/encodes"
    [[ $output == *calibrate-av1-* ]] && sample_bytes=$((sample_bytes * 8 / 10))
    truncate -s "$sample_bytes" "$output"
}
ffprobe() {
    case "$*" in
        *stream=codec_name,profile*)
            printf '%s\n' "${PROFILE:-codec_name=h264|profile=High|width=1920|height=1080|pix_fmt=yuv420p|avg_frame_rate=30/1}"
            ;;
        *format=duration*) printf '%s\n' "${SAMPLE_DURATION:-3}" ;;
        *) return 1 ;;
    esac
}
measure_preflight_quality() {
    local start=$1 length=$2 file=$3 quality mode=${CURVE:-normal}
    measure_count=$((measure_count + 1))
    printf '%s\t%s\n' "$start" "$length" >> "$TEST_ROOT/measures"
    if [[ ${FAIL_FIRST:-0} == 1 && $measure_count == 1 ]]; then return 1; fi
    [[ $file =~ calibrate-(av1|hevc)-([0-9]+) ]] || return 1
    quality=${BASH_REMATCH[2]}
    [[ ${BASH_REMATCH[1]} == av1 ]] && quality=$(((quality + 4) / 5))
    [[ $mode == av1-plateau && ${BASH_REMATCH[1]} == av1 ]] && mode=flat
    MEASURED_QUALITY_KIND=VMAF
    case "$mode" in
        flat) MEASURED_QUALITY_SCORE=74 ;;
        dji)
            case "$quality" in
                26) MEASURED_QUALITY_SCORE=71.87 ;;
                13) MEASURED_QUALITY_SCORE=73.93 ;;
                6) MEASURED_QUALITY_SCORE=74.05 ;;
                3) MEASURED_QUALITY_SCORE=74.12 ;;
                *) MEASURED_QUALITY_SCORE=74.13 ;;
            esac
            ;;
        near) MEASURED_QUALITY_SCORE=91.9 ;;
        hard) MEASURED_QUALITY_SCORE=$((quality < 5 ? 100 : 105-quality)) ;;
        unavailable) return 1 ;;
        nan) MEASURED_QUALITY_SCORE=nan ;;
        infinity) MEASURED_QUALITY_SCORE=inf ;;
        over100) MEASURED_QUALITY_SCORE=101 ;;
        negative) MEASURED_QUALITY_SCORE=-1 ;;
        ssim) MEASURED_QUALITY_KIND=SSIM; MEASURED_QUALITY_SCORE=0.99 ;;
        *) MEASURED_QUALITY_SCORE=$((quality < 10 ? 100 : 110-quality)) ;;
    esac
}
apply_encoder() { video_encoder=$1; }
'''


class CalibrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cache = self.root / "cache"
        self.functions = self.root / "functions.sh"
        self.functions.write_text(FUNCTIONS)
        # Also parse the emitted helper: bash -n on the core alone does not
        # check the shell program inside its quoted heredoc.
        helper = CORE.split("<<'__HARDCORE_ARCHIVE_VIDEO_HELPER__'\n", 1)[1].split(
            "\n__HARDCORE_ARCHIVE_VIDEO_HELPER__", 1
        )[0]
        subprocess.run(["bash", "-n"], input=helper, text=True, check=True)

    def run_calibration(self, body=None, **changes):
        for name in ("encodes", "measures"):
            (self.root / name).write_text("")
        env = dict(os.environ)
        env.update(TEST_ROOT=str(self.root),
                   HARDCORE_ARCHIVE_CALIBRATION_CACHE_DIR=str(self.cache),
                   HARDCORE_ARCHIVE_CALIBRATION_CACHE="true",
                   HARDCORE_ARCHIVE_CALIBRATION_POLICY_INHERITED="0",
                   HARDCORE_ARCHIVE_CALIBRATION_EARLY_ABORT="true")
        env.update({key: str(value) for key, value in changes.items()})
        if body is None:
            body = r'''
rc=0
calibrate_hardware_candidate hevc hevc_vaapi || rc=$?
printf 'RESULT:%s:%s:%s\n' "$rc" "$CAL_BEST_QUALITY" "$CAL_REASON"
'''
        script = "set -euo pipefail\nIFS=$'\\n\\t'\nsource " + shlex.quote(str(self.functions))
        result = subprocess.run(["bash", "-c", script + "\n" + FIXTURE + "\n" + body],
                                env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        encodes = (self.root / "encodes").read_text().splitlines()
        measures = (self.root / "measures").read_text().splitlines()
        self.assertFalse(list(self.root.glob(".*.calibrate-*.mkv")), "sample leak")
        return result.stdout, encodes, measures

    def seed(self):
        output, encodes, measures = self.run_calibration()
        self.assertIn("RESULT:0:18:candidate-valid", output)
        self.assertEqual(len(encodes), 18)
        self.assertEqual(len(measures), 18)
        self.assertEqual(len(list(self.cache.iterdir())), 1)
        return next(self.cache.iterdir())

    def test_cold_search_then_one_shot_across_processes(self):
        self.seed()
        output, encodes, measures = self.run_calibration()
        self.assertIn("RESULT:0:18:cache-validated", output)
        self.assertEqual(len(encodes), 1)
        self.assertEqual(measures, ["58.500\t3"])

    def test_failed_cached_quality_recalibrates_and_updates(self):
        self.seed()
        output, encodes, _ = self.run_calibration(CURVE="hard")
        self.assertIn("RESULT:0:13:candidate-valid", output)
        self.assertGreater(len(encodes), 1)
        output, encodes, _ = self.run_calibration(CURVE="hard")
        self.assertIn("RESULT:0:13:cache-validated", output)
        self.assertEqual(len(encodes), 1)

    def test_failed_cache_measurement_retries_full_search(self):
        self.seed()
        output, encodes, _ = self.run_calibration(FAIL_FIRST=1)
        self.assertIn("RESULT:0:18:candidate-valid", output)
        self.assertEqual(len(encodes), 19)

    def test_unavailable_or_invalid_vmaf_never_accepts(self):
        entry = self.seed()
        original = entry.read_text()
        for curve in ("unavailable", "nan", "infinity", "over100", "negative", "ssim"):
            with self.subTest(curve=curve):
                output, encodes, _ = self.run_calibration(CURVE=curve)
                self.assertIn("RESULT:1::sample-probe-failed-at-26", output)
                self.assertEqual(len(encodes), 2)
                self.assertEqual(entry.read_text(), original)

    def test_zero_duration_sample_fails(self):
        output, _, _ = self.run_calibration(SAMPLE_DURATION=0)
        self.assertIn("RESULT:1::sample-probe-failed-at-26", output)

    def test_current_file_savings_checked_even_on_cache_hit(self):
        entry = self.seed()
        original = entry.read_text()
        # Audio alone makes this candidate too large despite passing VMAF.
        output, encodes, _ = self.run_calibration(AUDIO_BPS=10000000)
        self.assertIn("RESULT:3:18:minimum-saving-not-met", output)
        self.assertEqual(len(encodes), 19)
        self.assertEqual(entry.read_text(), original)

    def test_cache_isolated_by_target_profile_build_device_and_filters(self):
        self.seed()
        for changes in ({"TARGET": 99}, {"PROFILE": "pix_fmt=yuv420p10le"},
                        {"BUILD": "another-ffmpeg-build"},
                        {"HARDCORE_ARCHIVE_VAAPI_DEVICE": "/dev/dri/renderD129"},
                        {"SCALING": "true"}, {"DENOISE": "true"}):
            with self.subTest(changes=changes):
                output, encodes, _ = self.run_calibration(**changes)
                self.assertIn("candidate-valid", output)
                self.assertNotIn("cache-validated", output)
                self.assertGreater(len(encodes), 1)
        self.assertEqual(len(list(self.cache.iterdir())), 7)

    def test_malformed_expired_future_and_out_of_range_entries_are_misses(self):
        entry = self.seed()
        now = int(time.time())
        for data in ("not a cache\n", f"v1\t999\t{now}\n", f"v1\t0\t{now}\n",
                     f"v1\t18\t{now-2592001}\n", f"v1\t18\t{now+3600}\n",
                     f"v2\t18\t{now}\n", f"v1\t$(touch injected)\t{now}\n"):
            with self.subTest(data=data):
                entry.write_text(data)
                output, encodes, _ = self.run_calibration()
                self.assertIn("RESULT:0:18:candidate-valid", output)
                self.assertEqual(len(encodes), 18)

    def test_cache_disabled_or_unavailable_does_not_break_calibration(self):
        output, encodes, _ = self.run_calibration(HARDCORE_ARCHIVE_CALIBRATION_CACHE="false")
        self.assertIn("RESULT:0:18:candidate-valid", output)
        self.assertEqual(len(encodes), 18)
        self.assertFalse(self.cache.exists())
        self.cache.write_text("not a directory")
        output, _, _ = self.run_calibration()
        self.assertIn("RESULT:0:18:candidate-valid", output)

    def test_symlink_entry_is_not_trusted_or_written_through(self):
        entry = self.seed()
        outside = self.root / "outside"
        outside.write_text(f"v1\t1\t{int(time.time())}\n")
        original = outside.read_text()
        entry.unlink()
        entry.symlink_to(outside)
        output, _, _ = self.run_calibration()
        self.assertIn("RESULT:0:18:candidate-valid", output)
        self.assertEqual(outside.read_text(), original)
        self.assertFalse(entry.is_symlink())

    def test_symlink_to_directory_is_not_written_through(self):
        entry = self.seed()
        outside = self.root / "outside-dir"
        outside.mkdir()
        entry.unlink()
        entry.symlink_to(outside, target_is_directory=True)
        output, _, _ = self.run_calibration()
        self.assertIn("RESULT:0:18:candidate-valid", output)
        self.assertEqual(list(outside.iterdir()), [])

    def test_nvenc_and_qsv_cache_without_filters(self):
        for encoder in ("hevc_nvenc", "hevc_qsv"):
            with self.subTest(encoder=encoder):
                body = f'calibrate_hardware_candidate hevc {encoder}\n' + r'''
apply_calibrated_candidate hevc "$ENCODER" "$CAL_BEST_QUALITY" "$CAL_QUALITY_LABEL"
run_video_preflight
'''
                output, encodes, _ = self.run_calibration(body, ENCODER=encoder)
                self.assertEqual(len(encodes), 18)
                output, encodes, _ = self.run_calibration(body, ENCODER=encoder)
                self.assertIn("Cached setting passed", output)
                self.assertEqual(len(encodes), 1)

    def test_plateau_aborts_without_caching_failure(self):
        output, encodes, _ = self.run_calibration(CURVE="dji")
        self.assertIn("RESULT:2::quality-plateau-below-floor", output)
        self.assertEqual(len(encodes), 12)  # QP 26, 13, 6, 3; omit QP 1.
        self.assertEqual(list(self.cache.iterdir()), [])
        output, encodes, _ = self.run_calibration(CURVE="flat")
        self.assertIn("quality-plateau-below-floor", output)
        self.assertEqual(len(encodes), 9)

    def test_near_target_or_disabled_plateau_searches_to_endpoint(self):
        for changes in ({"CURVE": "near"}, {"CURVE": "flat", "TARGET": 75},
                        {"CURVE": "flat", "HARDCORE_ARCHIVE_CALIBRATION_EARLY_ABORT": "false"}):
            with self.subTest(changes=changes):
                output, encodes, _ = self.run_calibration(**changes)
                self.assertIn("RESULT:2::quality-floor-not-met", output)
                self.assertEqual(len(encodes), 15)

    def test_short_clip_full_search_uses_single_segment(self):
        output, encodes, _ = self.run_calibration(DURATION=5)
        self.assertIn("RESULT:0:18:candidate-valid", output)
        self.assertEqual(len(encodes), 6)

    def test_selected_candidate_skips_duplicate_preflight(self):
        body = r'''
calibrate_and_choose_video_codec
[[ $CAL_SELECTED_VALIDATED == true ]]
run_video_preflight
'''
        output, encodes, _ = self.run_calibration(body)
        self.assertIn("reusing this file", output)
        self.assertEqual(len(encodes), 18)
        output, encodes, _ = self.run_calibration(body)
        self.assertIn("Cached setting passed", output)
        self.assertEqual(len(encodes), 1)

    def test_codec_competition_keeps_independent_results(self):
        body = r'''
HARDCORE_AUTO_CODEC_MODE=1
HARDCORE_AUTO_AV1_ENCODER=av1_vaapi
HARDCORE_AUTO_HEVC_ENCODER=hevc_vaapi
calibrate_and_choose_video_codec
run_video_preflight
printf 'SELECTED:%s\n' "$video_encoder"
'''
        output, _, _ = self.run_calibration(body)
        self.assertIn("SELECTED:av1_vaapi", output)
        self.assertEqual(len(list(self.cache.iterdir())), 2)
        output, encodes, _ = self.run_calibration(body)
        self.assertIn("SELECTED:av1_vaapi", output)
        self.assertEqual(len(encodes), 2)
        output, _, _ = self.run_calibration(body, CURVE="av1-plateau")
        self.assertIn("SELECTED:hevc_vaapi", output)

    def test_quality_off_and_unsupported_encoder_keep_existing_paths(self):
        self.run_calibration(r'''
calibrate_and_choose_video_codec
[[ $CAL_SELECTED_VALIDATED == false ]]
[[ ! -e $HARDCORE_ARCHIVE_CALIBRATION_CACHE_DIR ]]
''', QUALITY_MODE="off")
        self.run_calibration(r'''
video_encoder=libx265
calibrate_and_choose_video_codec
[[ $CAL_SELECTED_VALIDATED == false ]]
''')

    def test_config_values_export_to_children(self):
        functions = CORE.split("\ntrim_config_value() {", 1)[1].split("\nsafe_slug() {", 1)[0]
        config_functions = self.root / "config-functions.sh"
        config_functions.write_text("trim_config_value() {" + functions)
        config = self.root / "config"
        config.write_text("VIDEO_CALIBRATION_CACHE=false\nVIDEO_CALIBRATION_EARLY_ABORT=false\n"
                          f"VIDEO_CALIBRATION_CACHE_DIR={self.root}/shared cache\n")
        self.run_calibration("source " + shlex.quote(str(config_functions)) + "\nload_config_file "
                             + shlex.quote(str(config)) + r'''
bash -c '[[ $HARDCORE_ARCHIVE_CALIBRATION_CACHE == false &&
            $HARDCORE_ARCHIVE_CALIBRATION_EARLY_ABORT == false &&
            $HARDCORE_ARCHIVE_CALIBRATION_CACHE_DIR == "$TEST_ROOT/shared cache" ]]'
''')
        freeze = CORE.split("# Children may read a different config;", 1)[1].split(
            "# Read enough flags before argument parsing", 1
        )[0]
        freeze = "# Children may read a different config;" + freeze
        child_config = self.root / "child-config"
        child_config.write_text("VIDEO_CALIBRATION_CACHE=true\nVIDEO_CALIBRATION_EARLY_ABORT=true\n"
                                "VIDEO_CALIBRATION_CACHE_DIR=/wrong/directory\n")
        self.run_calibration("source " + shlex.quote(str(config_functions)) + "\nload_config_file "
                             + shlex.quote(str(config)) + "\n" + freeze + "\n"
                             + "bash -c " + shlex.quote("source " + shlex.quote(str(config_functions))
                             + "\nload_config_file " + shlex.quote(str(child_config)) + r'''
[[ $HARDCORE_ARCHIVE_CALIBRATION_CACHE == false &&
   $HARDCORE_ARCHIVE_CALIBRATION_EARLY_ABORT == false &&
   $HARDCORE_ARCHIVE_CALIBRATION_CACHE_DIR == "$TEST_ROOT/shared cache" ]]
'''))


if __name__ == "__main__":
    unittest.main(verbosity=2)
