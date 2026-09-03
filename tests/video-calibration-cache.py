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
FUNCTIONS = (f'source {shlex.quote(str(ROOT / "lib/calibration-identity.sh"))}\n'
             f'source {shlex.quote(str(ROOT / "lib/timing.sh"))}\n'
             f'source {shlex.quote(str(ROOT / "lib/video-acceleration.sh"))}\n'
             "HARDCORE_AUTO_CODEC_MODE=" + FUNCTIONS)

FIXTURE = r'''
input="${INPUT_PATH:-$TEST_ROOT/source.mov}"
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
    local output=${!#} sample_bytes=${SAMPLE_BYTES:-10000} quality previous='' argument
    { printf '%q ' "$@"; printf '\n'; } >> "$TEST_ROOT/encodes"
    [[ $output == *calibrate-av1-* ]] && sample_bytes=$((sample_bytes * 8 / 10))
    if [[ ${SIZE_BY_QUALITY:-0} == 1 && $output =~ calibrate-hevc-([0-9]+) ]]; then
        quality=${BASH_REMATCH[1]}
        sample_bytes=$((1000000 / (quality + 1)))
    fi
    if [[ ${SIZE_BY_POSITION:-0} == 1 ]]; then
        for argument in "$@"; do
            [[ $previous == -ss && $argument == 105.300 ]] && sample_bytes=$((sample_bytes * 2))
            previous=$argument
        done
    fi
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
    [[ ${FAIL_ENDPOINT:-0} == 1 && $quality == 1 ]] && return 1
    [[ ${BASH_REMATCH[1]} == av1 ]] && quality=$(((quality + 4) / 5))
    [[ $mode == av1-plateau && ${BASH_REMATCH[1]} == av1 ]] && mode=flat
    MEASURED_QUALITY_KIND=VMAF
    case "$mode" in
        flat) MEASURED_QUALITY_SCORE=74 ;;
        edge-flat) MEASURED_QUALITY_SCORE=100; [[ $start != 105.300 ]] || MEASURED_QUALITY_SCORE=74 ;;
        recovery) MEASURED_QUALITY_SCORE=$((quality <= 2 ? 95 : 74)) ;;
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
    if [[ ${WORST_END:-0} == 1 && $start == 105.300 ]]; then
        MEASURED_QUALITY_SCORE=$((MEASURED_QUALITY_SCORE - 5))
    fi
    return 0
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
                   HARDCORE_ARCHIVE_VIDEO_ACCELERATION="cpu",
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

    def test_group_hint_checks_boundary_on_each_unidentified_video(self):
        self.seed()
        output, encodes, measures = self.run_calibration()
        self.assertIn("RESULT:0:18:candidate-valid", output)
        self.assertEqual(len(encodes), 6)
        self.assertEqual(measures, ["11.700\t3", "58.500\t3", "105.300\t3"] * 2)

    def test_video_keeps_own_setting_after_harder_file_changes_group(self):
        easy = self.root / "easy.mov"
        hard = self.root / "hard.mov"
        easy.write_bytes(b"easy source")
        hard.write_bytes(b"hard source")
        output, _, _ = self.run_calibration(INPUT_PATH=easy)
        self.assertIn("RESULT:0:18:candidate-valid", output)
        output, _, _ = self.run_calibration(INPUT_PATH=hard, CURVE="hard")
        self.assertIn("Calibration cache source: group", output)
        self.assertIn("RESULT:0:13:candidate-valid", output)
        for path, curve, quality in ((easy, "normal", 18), (hard, "hard", 13),
                                     (easy, "normal", 18)):
            output, encodes, _ = self.run_calibration(INPUT_PATH=path, CURVE=curve)
            self.assertIn("Calibration cache source: video", output)
            self.assertIn(f"RESULT:0:{quality}:cache-validated", output)
            self.assertEqual(len(encodes), 1)

    def test_group_hit_is_pinned_and_staging_symlinks_keep_identity(self):
        self.seed()
        original = self.root / "actual.mov"
        original.write_bytes(b"source")
        for name, expected_source in (("stage1.mov", "group"), ("stage2.mov", "video")):
            staged = self.root / name
            staged.symlink_to(original)
            output, encodes, _ = self.run_calibration(INPUT_PATH=staged)
            self.assertIn(f"Calibration cache source: {expected_source}", output)
            self.assertEqual(len(encodes), 6 if expected_source == "group" else 1)

    def test_source_change_and_replacement_invalidate_video_hint(self):
        source = self.root / "actual.mov"
        source.write_bytes(b"before")
        self.run_calibration(INPUT_PATH=source)
        original_time = source.stat().st_mtime_ns
        source.write_bytes(b"after!")  # Same size and restored mtime; ctime still changes.
        os.utime(source, ns=(original_time, original_time))
        output, _, _ = self.run_calibration(INPUT_PATH=source)
        self.assertIn("Calibration cache source: group", output)
        replacement = self.root / "replacement"
        replacement.write_bytes(b"after!")
        os.utime(replacement, ns=(original_time, original_time))
        replacement.replace(source)
        output, _, _ = self.run_calibration(INPUT_PATH=source)
        self.assertIn("Calibration cache source: group", output)

    def test_video_hint_invalidates_for_policy_and_raw_profile_changes(self):
        source = self.root / "actual.mov"
        source.write_bytes(b"source")
        self.run_calibration(INPUT_PATH=source)
        for changes in ({"TARGET": 99}, {"BUILD": "new-build"}, {"SCALING": "true"},
                        {"DENOISE": "true"}, {"HARDCORE_ARCHIVE_VAAPI_DEVICE": "/dev/dri/renderD129"},
                        {"PROFILE": "codec_name=h264|profile=High|width=1920|height=1080|pix_fmt=yuv420p|avg_frame_rate=2999/100"}):
            with self.subTest(changes=changes):
                output, _, _ = self.run_calibration(INPUT_PATH=source, **changes)
                self.assertNotIn("Calibration cache source: video", output)

    def test_bad_video_hint_revalidates_then_recalibrates_without_group_shortcut(self):
        source = self.root / "actual.mov"
        source.write_bytes(b"source")
        self.run_calibration(INPUT_PATH=source)
        output, encodes, _ = self.run_calibration(INPUT_PATH=source, CURVE="hard")
        self.assertIn("Calibration cache source: video", output)
        self.assertIn("RESULT:0:13:candidate-valid", output)
        self.assertNotIn("Calibration cache source: group", output)
        self.assertGreater(len(encodes), 1)
        for curve in ("unavailable", "nan", "flat"):
            output, _, _ = self.run_calibration(INPUT_PATH=source, CURVE=curve)
            self.assertNotIn("RESULT:0:", output)

    def test_video_hint_rechecks_savings_and_malformed_or_symlink_entries(self):
        source = self.root / "actual.mov"
        source.write_bytes(b"source")
        self.run_calibration(INPUT_PATH=source)
        output, _, _ = self.run_calibration(INPUT_PATH=source, AUDIO_BPS=10000000)
        self.assertIn("RESULT:3:18:minimum-saving-not-met", output)
        entry = next(self.cache.glob("video-*"))
        entry.write_text("malformed")
        output, _, _ = self.run_calibration(INPUT_PATH=source)
        self.assertIn("Calibration cache source: group", output)
        outside = self.root / "outside"
        outside.write_text("must not change")
        entry.unlink()
        entry.symlink_to(outside)
        output, _, _ = self.run_calibration(INPUT_PATH=source)
        self.assertIn("Calibration cache source: group", output)
        self.assertEqual(outside.read_text(), "must not change")

    def test_nested_identity_survives_fresh_extraction_and_changes_with_archive(self):
        for name, namespace, expected_source in (("extract-A", "archive-v1", None),
                                                 ("extract-B", "archive-v1", "video"),
                                                 ("extract-C", "archive-v2", "group")):
            root = self.root / name
            source = root / "London/clip.mov"
            source.parent.mkdir(parents=True)
            source.write_bytes(b"same archived video")
            os.utime(source, ns=(1000000000, 1000000000))
            output, encodes, _ = self.run_calibration(
                INPUT_PATH=source, HARDCORE_ARCHIVE_CALIBRATION_NAMESPACE=namespace,
                HARDCORE_ARCHIVE_CALIBRATION_SOURCE_ROOT=root)
            if expected_source:
                self.assertIn(f"Calibration cache source: {expected_source}", output)
                self.assertEqual(len(encodes), 6 if expected_source == "group" else 1)

    def test_both_codecs_keep_video_settings_and_emit_independent_timings(self):
        source = self.root / "actual.mov"
        source.write_bytes(b"source")
        timings = self.root / "timings.tsv"
        timings.write_text("phase\telapsed_ns\texit_status\n")
        body = "calibrate_and_choose_video_codec\n"
        env = dict(INPUT_PATH=source, HARDCORE_ARCHIVE_VIDEO_CODEC_AUTO=1,
                   HARDCORE_ARCHIVE_AUTO_AV1_ENCODER="av1_vaapi",
                   HARDCORE_ARCHIVE_AUTO_HEVC_ENCODER="hevc_vaapi",
                   HARDCORE_ARCHIVE_TIMING_FILE=timings)
        self.run_calibration(body, **env)
        output, encodes, _ = self.run_calibration(body, **env)
        self.assertEqual(output.count("Calibration cache source: video"), 2)
        self.assertEqual(len(encodes), 2)
        rows = [line.split("\t") for line in timings.read_text().splitlines()[1:]]
        self.assertEqual(len(rows), 4)
        self.assertTrue(all(phase == "video_calibration" and int(ns) > 0 and rc == "0"
                            for phase, ns, rc in rows))

    def test_failed_cached_quality_recalibrates_and_updates(self):
        self.seed()
        output, encodes, _ = self.run_calibration(CURVE="hard")
        self.assertIn("RESULT:0:13:candidate-valid", output)
        self.assertGreater(len(encodes), 1)
        output, encodes, _ = self.run_calibration(CURVE="hard")
        self.assertIn("RESULT:0:13:candidate-valid", output)
        self.assertEqual(len(encodes), 6)

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
        self.assertEqual(len(encodes), 6)
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

    def test_camera_rate_jitter_reuses_cache_and_still_rejects_harder_video(self):
        prefix = "codec_name=h264|profile=High|width=3840|height=2160|pix_fmt=yuvj420p|"
        def profile(rate):
            return prefix + f"avg_frame_rate={rate}|r_frame_rate=60000/1001"
        output, encodes, _ = self.run_calibration(PROFILE=profile("170775/2846"))
        self.assertIn("RESULT:0:18:candidate-valid", output)
        self.assertEqual(len(encodes), 18)
        for rate in ("762000/12713", "39575/661", "1176600/19669", "60/1"):
            with self.subTest(rate=rate):
                output, encodes, _ = self.run_calibration(PROFILE=profile(rate))
                self.assertIn("RESULT:0:18:candidate-valid", output)
                self.assertEqual(len(encodes), 6)
        self.assertEqual(len(list(self.cache.iterdir())), 1)
        output, encodes, _ = self.run_calibration(PROFILE=profile("164775/2746"), CURVE="hard")
        self.assertIn("as a search hint", output)
        self.assertIn("RESULT:0:13:candidate-valid", output)
        self.assertGreater(len(encodes), 1)

    def test_nominal_rate_groups_keep_distinct_rates_and_profiles_apart(self):
        base = "codec_name=h264|width=3840|height=2160|pix_fmt=yuv420p|color_range=tv|"
        seed = base + "avg_frame_rate=60/1|r_frame_rate=60/1"
        self.run_calibration(PROFILE=seed)
        for profile in (base + "avg_frame_rate=30/1|r_frame_rate=30/1",
                        base + "avg_frame_rate=50/1|r_frame_rate=50/1",
                        base + "avg_frame_rate=60/1|r_frame_rate=120/1",
                        seed.replace("height=2160", "height=1080"),
                        seed.replace("yuv420p", "yuv420p10le"),
                        seed.replace("color_range=tv", "color_range=pc")):
            with self.subTest(profile=profile):
                output, encodes, _ = self.run_calibration(PROFILE=profile)
                self.assertIn("RESULT:0:18:candidate-valid", output)
                self.assertEqual(len(encodes), 18)
        # An unusual rate more than 1% from a whole number stays exact.
        self.run_calibration(PROFILE=base + "avg_frame_rate=24/1|r_frame_rate=24/1")
        output, encodes, _ = self.run_calibration(PROFILE=base + "avg_frame_rate=122/5|r_frame_rate=24/1")
        self.assertIn("RESULT:0:18:candidate-valid", output)
        self.assertEqual(len(encodes), 18)

    def test_invalid_rate_disables_cache_without_skipping_calibration(self):
        for rate in ("0/0", "0/1", "-1/1", "nan", "6000/1", "$(touch injected)"):
            with self.subTest(rate=rate):
                output, encodes, _ = self.run_calibration(PROFILE=f"avg_frame_rate={rate}")
                self.assertIn("RESULT:0:18:candidate-valid", output)
                self.assertEqual(len(encodes), 18)
        self.assertFalse(self.cache.exists())

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
                self.assertIn("as a search hint", output)
                self.assertEqual(len(encodes), 6)

    def test_plateau_confirms_endpoint_without_identity_cannot_cache_rejection(self):
        output, encodes, _ = self.run_calibration(CURVE="dji")
        self.assertIn("RESULT:2::quality-endpoint-below-floor", output)
        self.assertEqual(len(encodes), 13)  # Four full trials plus one QP 1 witness.
        self.assertEqual(list(self.cache.iterdir()), [])
        output, encodes, _ = self.run_calibration(CURVE="flat")
        self.assertIn("quality-endpoint-below-floor", output)
        self.assertEqual(len(encodes), 10)

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
        self.assertIn("as a search hint", output)
        self.assertEqual(len(encodes), 6)

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
        self.assertEqual(len(encodes), 12)
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

    def test_conservative_hint_improves_compression_to_cold_search_boundary(self):
        # This is the old shortcut's regression: a QP 13 group representative
        # must not pin an easier video below its passing QP 18 boundary.
        self.run_calibration(CURVE="hard")
        source = self.root / "easier.mov"
        source.write_bytes(b"easier source")
        output, encodes, _ = self.run_calibration(INPUT_PATH=source, SIZE_BY_QUALITY=1)
        self.assertIn("RESULT:0:18:candidate-valid", output)
        self.assertLessEqual(len(encodes), 24)  # Bounded hint + neighbor + bisection.
        self.assertIn("hevc_vaapi 19", output)  # The next compression step fails.
        cold, _, _ = self.run_calibration(HARDCORE_ARCHIVE_CALIBRATION_CACHE="false", SIZE_BY_QUALITY=1)
        self.assertIn("RESULT:0:18:candidate-valid", cold)
        output, encodes, _ = self.run_calibration(INPUT_PATH=source, SIZE_BY_QUALITY=1)
        self.assertIn("RESULT:0:18:cache-validated", output)
        self.assertEqual(len(encodes), 1)

    def test_legacy_pinned_group_hit_is_upgraded_by_search(self):
        source = self.root / "legacy.mov"
        source.write_bytes(b"source")
        self.run_calibration(INPUT_PATH=source)
        entry = next(self.cache.glob("video-*"))
        entry.write_text(f"v1\t13\t{int(time.time())}\n")
        output, encodes, _ = self.run_calibration(INPUT_PATH=source)
        self.assertIn("Calibration cache source: legacy-video", output)
        self.assertIn("RESULT:0:18:candidate-valid", output)
        self.assertGreater(len(encodes), 1)
        self.assertTrue(entry.read_text().startswith("v2\tboundary\t18\t"))

    def test_group_hint_checks_hard_scene_and_video_rechecks_worst_position(self):
        self.seed()
        source = self.root / "hard-ending.mov"
        source.write_bytes(b"source")
        output, _, _ = self.run_calibration(INPUT_PATH=source, WORST_END=1, SIZE_BY_POSITION=1)
        self.assertIn("RESULT:0:13:candidate-valid", output)
        cold_prediction = output.split("predicted saving ")[-1].split(";")[0]
        output, encodes, measures = self.run_calibration(INPUT_PATH=source, WORST_END=1, SIZE_BY_POSITION=1)
        self.assertIn("RESULT:0:13:cache-validated", output)
        self.assertEqual(len(encodes), 1)
        self.assertEqual(measures, ["105.300\t3"])
        self.assertIn("predicted saving " + cold_prediction, output)

    def test_rejection_rechecks_actual_failing_scene_at_endpoint(self):
        source = self.root / "bad-ending.mov"
        source.write_bytes(b"source")
        output, encodes, _ = self.run_calibration(INPUT_PATH=source, CURVE="edge-flat")
        self.assertIn("RESULT:2::quality-endpoint-below-floor", output)
        self.assertEqual(len(encodes), 10)
        self.assertIn("-global_quality:v 1 ", encodes[-1])
        output, encodes, measures = self.run_calibration(INPUT_PATH=source, CURVE="edge-flat")
        self.assertIn("RESULT:2::cached-quality-rejection-confirmed", output)
        self.assertEqual(len(encodes), 1)
        self.assertEqual(measures, ["105.300\t3"])
        self.assertFalse([p for p in self.cache.iterdir() if not p.name.startswith("video-")])

    def test_plateau_endpoint_recovery_keeps_searching(self):
        output, encodes, _ = self.run_calibration(CURVE="recovery")
        self.assertIn("Highest-quality sample recovered", output)
        self.assertIn("RESULT:0:2:candidate-valid", output)
        self.assertLessEqual(len(encodes), 19)

    def test_rejected_codec_can_recover_and_compete_again(self):
        source = self.root / "recovered.mov"
        source.write_bytes(b"source")
        self.run_calibration(INPUT_PATH=source, CURVE="flat")
        output, encodes, _ = self.run_calibration(INPUT_PATH=source)
        self.assertIn("video (rejected)", output)
        self.assertIn("RESULT:0:18:candidate-valid", output)
        self.assertEqual(len(encodes), 19)
        self.assertIn("v2\tboundary\t18", next(self.cache.glob("video-*")).read_text())

    def test_rejection_not_shared_and_source_change_invalidates_it(self):
        source = self.root / "source.mov"
        source.write_bytes(b"old source")
        self.run_calibration(INPUT_PATH=source, CURVE="flat")
        source.write_bytes(b"new source")
        output, encodes, _ = self.run_calibration(INPUT_PATH=source)
        self.assertNotIn("video (rejected)", output)
        self.assertIn("RESULT:0:18:candidate-valid", output)
        self.assertEqual(len(encodes), 18)
        other = self.root / "other.mov"
        other.write_bytes(b"other source")
        output, _, _ = self.run_calibration(INPUT_PATH=other)
        self.assertNotIn("video (rejected)", output)

    def test_probe_failures_never_create_rejection_entries(self):
        source = self.root / "source.mov"
        source.write_bytes(b"source")
        for changes in ({"CURVE": "unavailable"}, {"CURVE": "nan"},
                        {"CURVE": "flat", "FAIL_ENDPOINT": 1}):
            with self.subTest(changes=changes):
                output, _, _ = self.run_calibration(INPUT_PATH=source, **changes)
                self.assertIn("RESULT:1::sample-probe-failed", output)
                self.assertEqual(list(self.cache.iterdir()), [])

    def test_bad_rejection_measurement_falls_back_without_acceptance(self):
        source = self.root / "source.mov"
        source.write_bytes(b"source")
        self.run_calibration(INPUT_PATH=source, CURVE="flat")
        output, encodes, _ = self.run_calibration(INPUT_PATH=source, FAIL_FIRST=1)
        self.assertIn("RESULT:0:18:candidate-valid", output)
        self.assertEqual(len(encodes), 19)

    def test_rejection_policy_keys_and_disabled_cache_force_new_search(self):
        source = self.root / "source.mov"
        source.write_bytes(b"source")
        self.run_calibration(INPUT_PATH=source, CURVE="flat")
        for changes in ({"TARGET": 93}, {"BUILD": "changed"}, {"SCALING": "true"},
                        {"HARDCORE_ARCHIVE_VAAPI_DEVICE": "/dev/dri/renderD129"},
                        {"HARDCORE_ARCHIVE_CALIBRATION_CACHE": "false"}):
            with self.subTest(changes=changes):
                output, encodes, _ = self.run_calibration(INPUT_PATH=source, **changes)
                self.assertNotIn("video (rejected)", output)
                self.assertIn("candidate-valid", output)
                self.assertGreater(len(encodes), 1)

    def test_malformed_video_records_cannot_skip_search(self):
        source = self.root / "source.mov"
        source.write_bytes(b"source")
        self.run_calibration(INPUT_PATH=source, CURVE="flat")
        entry = next(self.cache.glob("video-*"))
        now = int(time.time())
        for data in (f"v2\trejected\t18\t{now}\t0.90\t20000\n",
                     f"v2\trejected\t1\t{now}\t$(touch injected)\t20000\n",
                     f"v2\trejected\t1\t{now-2592001}\t0.90\t20000\n",
                     f"v2\trejected\t1\t{now+3600}\t0.90\t20000\n",
                     f"v2\tboundary\t18\t{now}\t0.10\t0\n"):
            with self.subTest(data=data):
                entry.write_text(data)
                output, encodes, _ = self.run_calibration(INPUT_PATH=source)
                self.assertNotIn("Calibration cache source: video", output)
                self.assertIn("RESULT:0:18:candidate-valid", output)
                self.assertGreater(len(encodes), 1)

    def test_auto_rechecks_rejected_codec_and_successful_boundary_once_each(self):
        source = self.root / "source.mov"
        source.write_bytes(b"source")
        body = "calibrate_and_choose_video_codec\nprintf 'SELECTED:%s\\n' \"$video_encoder\"\n"
        changes = dict(INPUT_PATH=source, CURVE="av1-plateau", HARDCORE_ARCHIVE_VIDEO_CODEC_AUTO=1,
                       HARDCORE_ARCHIVE_AUTO_AV1_ENCODER="av1_vaapi", HARDCORE_ARCHIVE_AUTO_HEVC_ENCODER="hevc_vaapi")
        self.run_calibration(body, **changes)
        output, encodes, _ = self.run_calibration(body, **changes)
        self.assertIn("SELECTED:hevc_vaapi", output)
        self.assertIn("cached-quality-rejection-confirmed", output)
        self.assertEqual(len(encodes), 2)

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
