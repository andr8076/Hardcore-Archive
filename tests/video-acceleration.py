#!/usr/bin/env python3
"""Exercise production preprocessing, calibration competition and retries."""
import os
from pathlib import Path
import runpy
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CALIBRATION = runpy.run_path(str(ROOT / "tests/video-calibration-cache.py"))
FIXTURE = CALIBRATION["FIXTURE"].replace("ffmpeg()", "base_ffmpeg()").replace(
    "ffprobe()", "base_ffprobe()").replace("measure_preflight_quality()", "base_measure()")
PROBES = r'''
has_filter() { [[ ${MISSING_FILTERS:-0} != 1 ]]; }
ffprobe() {
    case "$*" in
        *stream=pix_fmt*) printf '%s\n' "${PIXEL_FORMAT:-yuv420p}" ;;
        *format=duration*.speed-*) printf '%s\n' "${SPEED_DURATION:-12}" ;;
        *) base_ffprobe "$@" ;;
    esac
}
ffmpeg() {
    [[ $1 != -version ]] || { base_ffmpeg "$@"; return; }
    local encoder=hevc_vaapi previous='' arg mode
    for arg in "$@"; do
        [[ $previous != -c:v ]] || encoder=$arg
        previous=$arg
    done
    mode=$(hardcore_video_accel_mode "$encoder")
    LAST_SAMPLE_MODE=$mode
    if [[ ${FAIL_MODE:-none} == "$mode" || (${FAIL_MODE:-none} == hardware && $mode != cpu) ]]; then
        { printf '%q ' "$@"; printf '\n'; } >> "$TEST_ROOT/encodes"
        return 1
    fi
    local SAMPLE_BYTES=${SAMPLE_BYTES:-10000}
    if [[ $mode == gpu ]]; then
        SAMPLE_BYTES=$((SAMPLE_BYTES * ${GPU_SIZE_PERCENT:-100} / 100))
    fi
    base_ffmpeg "$@"
}
measure_preflight_quality() {
    base_measure "$@" || return
    [[ ${GPU_BAD_QUALITY:-0} != 1 || $LAST_SAMPLE_MODE != gpu ]] || MEASURED_QUALITY_SCORE=74
    return 0
}
hardcore_video_speed_probe() {
    local mode
    mode=$(hardcore_video_accel_mode "$2")
    printf '%s\n' "$mode" >> "$TEST_ROOT/speed-probes"
    [[ ${FAIL_SPEED:-none} != "$mode" && ${FAIL_SPEED:-none} != all ]] || return 1
    case "$mode" in
        gpu) HARDCORE_VIDEO_PROBE_NS=${GPU_NS:-3000000000} ;;
        hybrid) HARDCORE_VIDEO_PROBE_NS=${HYBRID_NS:-1000000000} ;;
        cpu) HARDCORE_VIDEO_PROBE_NS=${CPU_NS:-2000000000} ;;
    esac
}
'''


class AccelerationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "source.mov").write_bytes(b"unchanged video")
        self.functions = self.root / "functions.sh"
        self.functions.write_text(CALIBRATION["FUNCTIONS"])

    def run_shell(self, body=None, expected=0, **changes):
        for name in ("encodes", "measures", "speed-probes"):
            (self.root / name).write_text("")
        env = dict(os.environ, TEST_ROOT=str(self.root), HARDCORE_ARCHIVE_VIDEO_ACCELERATION="auto",
                   HARDCORE_ARCHIVE_VIDEO_GPU_FILTERS="auto", HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE="0",
                   HARDCORE_ARCHIVE_CALIBRATION_CACHE="true", HARDCORE_ARCHIVE_CALIBRATION_EARLY_ABORT="true",
                   HARDCORE_ARCHIVE_CALIBRATION_CACHE_DIR=str(self.root / "cache"),
                   HARDCORE_ARCHIVE_CALIBRATION_POLICY_INHERITED="0")
        env.update({k: str(v) for k, v in changes.items()})
        if body is None:
            body = r'''
rc=0
calibrate_hardware_candidate hevc "${ENCODER:-hevc_vaapi}" || rc=$?
printf 'RESULT:%s:%s:%s\n' "$rc" "$CAL_BEST_QUALITY" "$(hardcore_video_accel_mode "${ENCODER:-hevc_vaapi}")"
'''
        script = "set -euo pipefail\nIFS=$'\\n\\t'\nsource " + shlex.quote(str(self.functions))
        result = subprocess.run(["bash", "-c", script + "\n" + FIXTURE + PROBES + body],
                                text=True, capture_output=True, env=env)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        commands = [shlex.split(line) for line in (self.root / "encodes").read_text().splitlines()]
        self.assertFalse(list(self.root.glob(".*.calibrate-*.mkv")), "sample leak")
        return result.stdout, commands

    def test_amd_and_nvidia_sample_and_full_commands_use_same_pipeline(self):
        for encoder, backend, scaler in (("hevc_vaapi", "vaapi", "scale_vaapi"),
                                         ("hevc_nvenc", "cuda", "scale_cuda")):
            with self.subTest(encoder=encoder):
                output, _ = self.run_shell(r'''
hardcore_video_accel_prepare "$ENCODER"
calibration_candidate_command "$ENCODER" 18 3 3 "$TEST_ROOT/sample.mkv"
printf 'SAMPLE:'; printf '%q ' "${CAL_COMMAND[@]}"; printf '\n'
video_encoder=$ENCODER
encoder_args=(-global_quality:v 18)
audio_args=(-c:a copy)
temporary="$TEST_ROOT/output.mkv"
hardcore_video_build_full_command
printf 'FULL:'; printf '%q ' "${command[@]}"; printf '\n'
''', ENCODER=encoder, SCALING="true", HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE=2,
                                          HARDCORE_ARCHIVE_VAAPI_DEVICE="/dev/dri/renderD129")
                sample = shlex.split(next(x[7:] for x in output.splitlines() if x.startswith("SAMPLE:")))
                full = shlex.split(next(x[5:] for x in output.splitlines() if x.startswith("FULL:")))
                for command in (sample, full):
                    self.assertEqual(command[command.index("-hwaccel") + 1], backend)
                    self.assertLess(command.index("-hwaccel"), command.index("-i"))
                    graph = command[command.index("-vf") + 1]
                    self.assertIn(scaler, graph)
                    self.assertNotIn("hwdownload", graph)
                    self.assertNotIn("-r", command)
                    if backend == "cuda":
                        self.assertIn("cuda=ha:2", command)
                        self.assertEqual(command[command.index("-gpu:v") + 1], "2")
                        self.assertNotIn("-pix_fmt:v", command)
                    else:
                        self.assertIn("vaapi=va:/dev/dri/renderD129", command)
                self.assertEqual(sample[sample.index("-vf") + 1], full[full.index("-vf") + 1])
                for stream in ("0:V:0", "0:a?", "0:s?", "0:t?"):
                    self.assertIn(stream, full)
                self.assertIn("-map_metadata", full)
                self.assertIn("-map_chapters", full)

    def test_gpu_scaler_failure_retries_hardware_decode_with_cpu_filters(self):
        output, commands = self.run_shell(FAIL_MODE="gpu")
        self.assertIn("RESULT:0:18:hybrid", output)
        self.assertEqual(len(commands), 25)
        hybrid = [c for c in commands if "-vf" in c and "hwdownload" in c[c.index("-vf") + 1]]
        self.assertTrue(hybrid)
        self.assertIn("hwdownload,format=nv12", hybrid[-1][hybrid[-1].index("-vf") + 1])
        self.assertNotIn("-hwaccel", commands[-1])

    def test_av1_source_selects_hardware_capable_decoder_only_on_gpu_paths(self):
        for encoder in ("hevc_vaapi", "hevc_nvenc"):
            self.run_shell(r'''
hardcore_video_accel_prepare "$ENCODER"
hardcore_video_accel_arguments "$ENCODER"
[[ " ${HARDCORE_VIDEO_INPUT_ARGS[*]} " == *av1* ]]
hardcore_video_accel_force_cpu "$ENCODER"
hardcore_video_accel_arguments "$ENCODER"
[[ ${#HARDCORE_VIDEO_INPUT_ARGS[@]} == 0 ]]
''', SOURCE_CODEC="av1", ENCODER=encoder)

    def test_unsupported_hardware_decoding_falls_back_to_cpu_for_both_vendors(self):
        for encoder in ("hevc_vaapi", "hevc_nvenc"):
            with self.subTest(encoder=encoder):
                output, commands = self.run_shell(FAIL_MODE="hardware", ENCODER=encoder)
                self.assertIn("RESULT:0:18:cpu", output)
                self.assertEqual(len(commands), 20)
                self.assertNotIn("-hwaccel", commands[-1])
                self.assertEqual(commands[-1][commands[-1].index("-c:v") + 1], encoder)

    def test_unknown_pixel_formats_and_other_encoders_keep_cpu_preprocessing(self):
        for changes in ({"PIXEL_FORMAT": "yuv444p10le"}, {"ENCODER": "hevc_qsv"},
                        {"HARDCORE_ARCHIVE_VIDEO_ACCELERATION": "cpu"}):
            with self.subTest(changes=changes):
                output, commands = self.run_shell(**changes)
                self.assertIn("RESULT:0:18:cpu", output)
                self.assertNotIn("-hwaccel", commands[-1])

    def test_missing_gpu_filter_and_denoising_retain_software_filters(self):
        for changes in ({"MISSING_FILTERS": 1}, {"DENOISE": "true"},
                        {"HARDCORE_ARCHIVE_VIDEO_GPU_FILTERS": "off"}):
            with self.subTest(changes=changes):
                output, commands = self.run_shell(PIXEL_FORMAT="yuv420p10le", SCALING="true", **changes)
                self.assertIn("RESULT:0:18:hybrid", output)
                hybrid = [c for c in commands if "-vf" in c and "hwdownload" in c[c.index("-vf") + 1]]
                graph = hybrid[-1][hybrid[-1].index("-vf") + 1]
                self.assertIn("hwdownload,format=p010le", graph)
                self.assertIn("scale=-2:1080:flags=lanczos", graph)
                if "DENOISE" in changes:
                    self.assertLess(graph.index("hqdn3d"), graph.index("scale="))

    def test_gpu_and_cpu_scaling_compete_and_reuse_separate_boundaries(self):
        for cost, winner in ((50, "gpu"), (200, "hybrid")):
            with self.subTest(cost=cost):
                # Different source identity isolates the two scenarios.
                (self.root / "source.mov").write_bytes(str(cost).encode())
                output, commands = self.run_shell(SCALING="true", GPU_SIZE_PERCENT=cost)
                self.assertIn(f"RESULT:0:18:{winner}", output)
                self.assertIn("Comparing GPU scaling", output)
                self.assertLessEqual(len(commands), 30)
                output, commands = self.run_shell(SCALING="true", GPU_SIZE_PERCENT=cost)
                self.assertIn(f"RESULT:0:18:{winner}", output)
                self.assertEqual(len(commands), 1)
                self.assertEqual(output.count("Calibration cache source: video"), 1)
                self.assertEqual((self.root / "speed-probes").read_text(), "")

    def test_gpu_quality_failure_cannot_hide_passing_cpu_filter_candidate(self):
        output, _ = self.run_shell(SCALING="true", GPU_BAD_QUALITY=1, GPU_SIZE_PERCENT=1)
        self.assertIn("RESULT:0:18:hybrid", output)
        output, commands = self.run_shell(SCALING="true", GPU_BAD_QUALITY=1, GPU_SIZE_PERCENT=1)
        self.assertIn("Reusing per-video preprocessing decision: hybrid", output)
        self.assertIn("RESULT:0:18:hybrid", output)
        self.assertEqual(len(commands), 1)

    def test_no_usable_measurement_fails_all_paths_without_caching_acceptance(self):
        output, commands = self.run_shell(CURVE="unavailable")
        self.assertIn("RESULT:1::cpu", output)
        self.assertEqual(len(commands), 3)
        self.assertEqual(list((self.root / "cache").iterdir()), [])

    def test_equal_compression_prefers_faster_cpu_or_gpu_decoding(self):
        for cpu_ns, winner in ((500000000, "cpu"), (2000000000, "hybrid")):
            (self.root / "source.mov").write_bytes(str(cpu_ns).encode())
            output, _ = self.run_shell(SCALING="true", GPU_SIZE_PERCENT=200, CPU_NS=cpu_ns)
            self.assertIn(f"RESULT:0:18:{winner}", output)
            self.assertEqual((self.root / "speed-probes").read_text().splitlines(), ["hybrid", "cpu"])
            output, commands = self.run_shell(SCALING="true", GPU_SIZE_PERCENT=200, CPU_NS=cpu_ns)
            self.assertIn(f"Reusing per-video preprocessing decision: {winner}", output)
            self.assertEqual(len(commands), 1)
            self.assertEqual((self.root / "speed-probes").read_text(), "")

    def test_smaller_gpu_candidate_wins_even_if_cpu_is_faster(self):
        output, _ = self.run_shell(SCALING="true", GPU_SIZE_PERCENT=50, CPU_NS=1)
        self.assertIn("RESULT:0:18:gpu", output)
        self.assertEqual((self.root / "speed-probes").read_text(), "")

    def test_all_path_rejections_need_only_one_fresh_check_on_repeat(self):
        output, commands = self.run_shell(CURVE="flat", SCALING="true")
        self.assertIn("RESULT:2::cpu", output)
        self.assertEqual(len(commands), 12)  # ten for first plateau; one per alternative
        self.assertEqual(output.count("highest-quality endpoint first"), 2)
        output, commands = self.run_shell(CURVE="flat", SCALING="true")
        self.assertIn("Reusing per-video preprocessing decision: cpu (rejected)", output)
        self.assertEqual(len(commands), 1)

    def test_rejection_recovery_reopens_other_preprocessing_paths(self):
        self.run_shell(CURVE="flat", SCALING="true")
        output, commands = self.run_shell(SCALING="true", GPU_SIZE_PERCENT=50)
        self.assertIn("reopening available paths", output)
        self.assertIn("RESULT:0:18:gpu", output)
        self.assertGreater(len(commands), 3)

    def test_cached_winner_quality_failure_reopens_comparison(self):
        self.run_shell(SCALING="true", GPU_SIZE_PERCENT=50)
        output, commands = self.run_shell(SCALING="true", GPU_SIZE_PERCENT=50, GPU_BAD_QUALITY=1)
        self.assertIn("reopening available paths", output)
        self.assertIn("RESULT:0:18:hybrid", output)
        self.assertGreater(len(commands), 1)

    def test_changed_audio_size_policy_and_source_reopen_selection(self):
        self.run_shell(SCALING="true", GPU_SIZE_PERCENT=200)
        output, commands = self.run_shell(SCALING="true", GPU_SIZE_PERCENT=200, AUDIO_BPS=1234)
        self.assertNotIn("Reusing per-video preprocessing decision", output)
        self.assertEqual(len(commands), 3)  # reuse existing path boundaries, not routing
        (self.root / "source.mov").write_bytes(b"different video")
        output, commands = self.run_shell(SCALING="true", GPU_SIZE_PERCENT=200)
        self.assertNotIn("Reusing per-video preprocessing decision", output)
        self.assertGreater(len(commands), 3)

    def test_expired_future_malformed_and_symlink_routing_records_are_misses(self):
        self.run_shell(SCALING="true", GPU_SIZE_PERCENT=200)
        path = next((self.root / "cache").glob("selection-*"))
        now = int(time.time())
        for bad in (f"v1\tboundary\thybrid\t{now-2592001}\n",
                    f"v1\tboundary\thybrid\t{now+60}\n",
                    f"v1\tboundary\tinvalid\t{now}\n",
                    f"v1\trejected\tgpu\t{now}\n",
                    f"v1\tboundary\thybrid\t{now}\nextra\n", "x" * 129):
            path.write_text(bad)
            output, commands = self.run_shell(SCALING="true", GPU_SIZE_PERCENT=200)
            self.assertNotIn("Reusing per-video preprocessing decision", output)
            self.assertEqual(len(commands), 3)
        outside = self.root / "outside"
        outside.write_text(path.read_text())
        original = outside.read_text()
        path.unlink()
        path.symlink_to(outside)
        output, commands = self.run_shell(SCALING="true", GPU_SIZE_PERCENT=200)
        self.assertNotIn("Reusing per-video preprocessing decision", output)
        self.assertEqual(len(commands), 3)
        self.assertTrue(path.is_symlink())
        self.assertEqual(outside.read_text(), original)

    def test_routing_alone_cannot_replace_missing_quality_records(self):
        self.run_shell(SCALING="true", GPU_SIZE_PERCENT=200)
        for path in (self.root / "cache").glob("video-*"):
            path.unlink()
        output, commands = self.run_shell(SCALING="true", GPU_SIZE_PERCENT=200)
        self.assertIn("reopening available paths", output)
        self.assertGreater(len(commands), 3)

    def test_routing_expiry_is_not_extended_by_one_shot_success(self):
        self.run_shell(SCALING="true", GPU_SIZE_PERCENT=200)
        path = next((self.root / "cache").glob("selection-*"))
        old = f"v1\tboundary\thybrid\t{int(time.time())-100}\n"
        path.write_text(old)
        _, commands = self.run_shell(SCALING="true", GPU_SIZE_PERCENT=200)
        self.assertEqual(len(commands), 1)
        self.assertEqual(path.read_text(), old)

    def test_forced_cpu_retry_cannot_reload_gpu_winner(self):
        self.run_shell(SCALING="true", GPU_SIZE_PERCENT=50)
        self.run_shell(r'''
hardcore_video_accel_prepare hevc_vaapi
hardcore_video_accel_force_cpu hevc_vaapi
calibrate_hardware_candidate hevc hevc_vaapi
[[ $(hardcore_video_accel_mode hevc_vaapi) == cpu ]]
''', SCALING="true", GPU_SIZE_PERCENT=50)

    def test_speed_probe_failures_cannot_cache_routing_or_accept_bad_quality(self):
        output, _ = self.run_shell(SCALING="true", GPU_SIZE_PERCENT=200, FAIL_SPEED="all")
        self.assertIn("RESULT:0:18:hybrid", output)
        self.assertEqual(list((self.root / "cache").glob("selection-*")), [])
        output, _ = self.run_shell(SCALING="true", CURVE="unavailable", CPU_NS=1)
        self.assertIn("RESULT:1::cpu", output)
        self.assertEqual((self.root / "speed-probes").read_text(), "")

    def test_disabled_cache_never_reuses_preprocessing_decisions(self):
        self.run_shell(SCALING="true", GPU_SIZE_PERCENT=200)
        output, commands = self.run_shell(SCALING="true", GPU_SIZE_PERCENT=200,
                                          HARDCORE_ARCHIVE_CALIBRATION_CACHE="false")
        self.assertNotIn("Reusing per-video preprocessing decision", output)
        self.assertGreater(len(commands), 3)

    def test_actual_speed_probe_is_bounded_uses_selected_path_and_cleans_up(self):
        # Restore the production probe instead of the deterministic selector timer.
        setup = "source " + shlex.quote(str(ROOT / "lib/video-acceleration.sh")) + r'''
hardcore_video_accel_prepare hevc_vaapi
HARDCORE_VIDEO_PIPELINES[hevc_vaapi]=hybrid
hardcore_video_speed_probe hevc hevc_vaapi 18
[[ $HARDCORE_VIDEO_PROBE_NS -gt 0 ]]
'''
        _, commands = self.run_shell(setup, SCALING="true")
        self.assertEqual(len(commands), 1)
        self.assertEqual(commands[0][commands[0].index("-t") + 1], "12.000")
        self.assertEqual(commands[0][commands[0].index("-ss") + 1], "54.000")
        self.assertIn("hwdownload", commands[0][commands[0].index("-vf") + 1])
        self.assertEqual((self.root / "measures").read_text(), "")
        self.assertFalse(list(self.root.glob(".*.speed-*.mkv")))
        self.run_shell(setup, SCALING="true", SPEED_DURATION=0, expected=1)
        self.assertFalse(list(self.root.glob(".*.speed-*.mkv")))

    def test_four_video_mixed_corpus_returns_to_eight_checks_on_repeat(self):
        paths = []
        for index in range(4):
            path = self.root / f"video-{index}.mov"
            path.write_bytes(f"video {index}".encode())
            paths.append(path)
        for repeat in range(2):
            total = 0
            for index, path in enumerate(paths):
                for codec in ("av1", "hevc"):
                    rejected = index == 3 or (index in (1, 2) and codec == "av1")
                    output, commands = self.run_shell(r'''
rc=0
calibrate_hardware_candidate "$CODEC" "${CODEC}_vaapi" || rc=$?
printf 'RC:%s\n' "$rc"
''', CODEC=codec, INPUT_PATH=path, CURVE="flat" if rejected else "normal",
                        SCALING="true" if index else "false", GPU_SIZE_PERCENT=200, CPU_NS=500000000)
                    self.assertIn(f"RC:{2 if rejected else 0}", output)
                    total += len(commands)
                    if repeat:
                        self.assertEqual(len(commands), 1)
                        self.assertEqual((self.root / "speed-probes").read_text(), "")
            if repeat:
                self.assertEqual(total, 8)

    def test_nvidia_selection_retains_nvenc_when_cpu_preprocessing_wins(self):
        args = dict(ENCODER="hevc_nvenc", SCALING="true", GPU_SIZE_PERCENT=200, CPU_NS=1)
        output, _ = self.run_shell(**args)
        self.assertIn("RESULT:0:18:cpu", output)
        output, commands = self.run_shell(**args)
        self.assertEqual(len(commands), 1)
        self.assertNotIn("-hwaccel", commands[0])
        self.assertEqual(commands[0][commands[0].index("-c:v") + 1], "hevc_nvenc")

    def test_selection_keys_include_devices_build_filters_and_raw_profile(self):
        self.run_shell(SCALING="true", GPU_SIZE_PERCENT=200)
        for change in ({"TARGET": 93}, {"BUILD": "new-build"},
                       {"HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE": 2},
                       {"HARDCORE_ARCHIVE_VAAPI_DEVICE": "/dev/dri/renderD129"},
                       {"DENOISE": "true"}, {"HARDCORE_ARCHIVE_VIDEO_GPU_FILTERS": "off"},
                       {"PROFILE": "codec_name=h264|width=1920|height=1080|avg_frame_rate=30/1"}):
            output, _ = self.run_shell(SCALING="true", GPU_SIZE_PERCENT=200, **change)
            self.assertNotIn("Reusing per-video preprocessing decision", output)

    def test_endpoint_probe_error_is_not_a_cached_all_path_rejection(self):
        output, _ = self.run_shell(SCALING="true", CURVE="flat", FAIL_ENDPOINT=1)
        self.assertIn("RESULT:1::cpu", output)
        self.assertEqual(list((self.root / "cache").glob("selection-*")), [])

    def test_invalid_old_winner_is_removed_if_new_comparison_has_probe_errors(self):
        self.run_shell(SCALING="true", GPU_SIZE_PERCENT=50)
        output, _ = self.run_shell(SCALING="true", GPU_SIZE_PERCENT=50, CURVE="unavailable")
        self.assertIn("reopening available paths", output)
        self.assertEqual(list((self.root / "cache").glob("selection-*")), [])

    def test_cache_keys_separate_decoding_paths_and_cuda_devices(self):
        output, _ = self.run_shell(r'''
hardcore_video_accel_prepare hevc_nvenc
for mode in gpu hybrid cpu; do
    HARDCORE_VIDEO_PIPELINES[hevc_nvenc]=$mode
    calibration_cache_prepare hevc hevc_nvenc
    printf 'KEY:%s\n' "$CAL_FILE_CACHE_FILE"
done
HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE=2
calibration_cache_prepare hevc hevc_nvenc
printf 'KEY:%s\n' "$CAL_FILE_CACHE_FILE"
''')
        keys = [x for x in output.splitlines() if x.startswith("KEY:")]
        self.assertEqual(len(set(keys)), 4)

    def test_nvenc_capability_probe_uses_selected_cuda_device(self):
        probe_module = ROOT / "lib/hardcore-archive-doctor-encoder-runtime.sh"
        _, commands = self.run_shell("source " + shlex.quote(str(probe_module)) + r'''
ffprobe() { printf 'hevc\n'; }
probe_hardware_encoder hevc hevc_nvenc
''', HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE=2)
        self.assertEqual(len(commands), 1)
        self.assertEqual(commands[0][commands[0].index("-gpu:v") + 1], "2")

    def test_resume_keys_change_with_preprocessing_policy_and_cuda_device(self):
        core = (ROOT / "lib/hardcore-archive-core.sh").read_text()
        function = "video_cache_key() {" + core.split("\nvideo_cache_key() {", 1)[1].split("\ncache_completed_video_results()", 1)[0]
        output, _ = self.run_shell(function + r'''
SOURCE_PARENT=$TEST_ROOT
SCRIPT_VERSION=test
VIDEO_CODEC=hevc VIDEO_ENCODER=hevc_nvenc VIDEO_MODE=maximum
VIDEO_MIN_VMAF=92 VIDEO_MIN_SAVINGS_PERCENT=3
VIDEO_NO_SCALE=false VIDEO_NO_DENOISE=false VIDEO_AUDIO_COPY=false QUALITY_CHECK=required
ffprobe() { printf signature; }
for policy in auto cpu; do
    HARDCORE_ARCHIVE_VIDEO_ACCELERATION=$policy
    printf 'KEY:%s\n' "$(video_cache_key source.mov)"
done
HARDCORE_ARCHIVE_VIDEO_ACCELERATION=auto
HARDCORE_ARCHIVE_VIDEO_GPU_FILTERS=off
printf 'KEY:%s\n' "$(video_cache_key source.mov)"
HARDCORE_ARCHIVE_VIDEO_GPU_FILTERS=auto
HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE=2
printf 'KEY:%s\n' "$(video_cache_key source.mov)"
''')
        keys = [line for line in output.splitlines() if line.startswith("KEY:")]
        self.assertEqual(len(set(keys)), 4)
        self.assertTrue(all(len(key) == 68 for key in keys))

    def test_hardware_decode_quality_failure_retries_software_decoding(self):
        output, _ = self.run_shell(r'''
measure_preflight_quality() {
    base_measure "$@" || return
    [[ $LAST_SAMPLE_MODE == cpu ]] || MEASURED_QUALITY_SCORE=74
    return 0
}
calibrate_hardware_candidate hevc hevc_vaapi
[[ $CAL_BEST_QUALITY == 18 && $(hardcore_video_accel_mode hevc_vaapi) == cpu ]]
''')
        self.assertIn("CPU decoding and filtering", output)

    def test_functions_survive_child_shell_boundary_without_parent_video_state(self):
        output, _ = self.run_shell(r'''
hardcore_video_accel_init
HARDCORE_VIDEO_PIPELINES[hevc_vaapi]=gpu
bash -c 'hardcore_video_accel_init; [[ $(hardcore_video_accel_mode hevc_vaapi) == cpu ]]'
''')

    def test_full_encode_failure_recalibrates_before_cpu_preprocessing_retry(self):
        output, _ = self.run_shell(r'''
hardcore_video_accel_prepare hevc_vaapi
temporary="$TEST_ROOT/full.mkv"
full_calls=0
hardcore_video_encode_attempt() {
    full_calls=$((full_calls + 1))
    if (( full_calls == 1 )); then printf broken > "$temporary"; return 1; fi
    [[ ! -e $temporary && $(hardcore_video_accel_mode hevc_vaapi) == cpu && $recalibrated == yes ]]
}
calibrate_and_choose_video_codec() { recalibrated=yes; }
run_video_preflight() { [[ $recalibrated == yes ]]; }
hardcore_video_encode_full
[[ $full_calls == 2 ]]
''')
        self.assertIn("fresh calibration", output)

    def test_cpu_full_encode_failure_stops_and_removes_partial_output(self):
        self.run_shell(r'''
temporary="$TEST_ROOT/full.mkv"
full_calls=0
hardcore_video_encode_attempt() { full_calls=$((full_calls + 1)); printf broken > "$temporary"; return 1; }
calibrate_and_choose_video_codec() { return 99; }
if hardcore_video_encode_full; then exit 99; fi
[[ $full_calls == 1 && ! -e $temporary ]]
''', HARDCORE_ARCHIVE_VIDEO_ACCELERATION="cpu")

    def test_quality_disabled_size_preflight_uses_selected_nvidia_device(self):
        _, commands = self.run_shell(r'''
video_encoder=hevc_nvenc
video_pix_fmt=p010le
encoder_args=(-cq:v 33 -preset:v p4)
filter_chain=''
CAL_SELECTED_VALIDATED=false
run_video_preflight || exit $?
''', QUALITY_MODE="off", HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE=2)
        self.assertEqual(len(commands), 3)
        for command in commands:
            self.assertEqual(command[command.index("-gpu:v") + 1], "2")

    def test_retry_does_not_encode_if_cpu_recalibration_rejects_candidate(self):
        self.run_shell(r'''
temporary="$TEST_ROOT/full.mkv"
full_calls=0
hardcore_video_encode_attempt() { full_calls=$((full_calls + 1)); return 1; }
calibrate_and_choose_video_codec() { return 3; }
run_video_preflight() { exit 99; }
if hardcore_video_encode_full; then exit 99; fi
[[ $full_calls == 1 ]]
''')

    def test_full_validation_is_independent_cpu_decode_and_errors_propagate(self):
        self.run_shell(r'''
temporary="$TEST_ROOT/full.mkv"
encoder_args=(-global_quality:v 18)
audio_args=(-c:a copy)
ffprobe() {
    case "$*" in *stream=codec_name*) printf hevc ;; *format=duration*) printf 120 ;; esac
}
ffmpeg() {
    if [[ " $* " == *"-xerror"* ]]; then
        for arg in "$@"; do [[ $arg != -hwaccel ]] || exit 99; done
        return 7
    fi
    return 0
}
if hardcore_video_encode_attempt; then exit 99; fi
''')

    def test_config_validation_and_nested_inheritance(self):
        core = (ROOT / "lib/hardcore-archive-core.sh").read_text()
        functions = "trim_config_value() {" + core.split("\ntrim_config_value() {", 1)[1].split("\nsafe_slug() {", 1)[0]
        path = self.root / "config-functions.sh"
        path.write_text(functions)
        (self.root / "config").write_text("VIDEO_ACCELERATION=cpu\nVIDEO_GPU_FILTERS=off\nVIDEO_CUDA_DEVICE=2\n")
        (self.root / "child").write_text("VIDEO_ACCELERATION=auto\nVIDEO_GPU_FILTERS=auto\nVIDEO_CUDA_DEVICE=0\n")
        setup = "source " + shlex.quote(str(path)) + r'''
die() { printf '%s\n' "$*" >&2; exit 2; }
load_config_file "$TEST_ROOT/config"
'''
        self.run_shell(setup + r'''
[[ $HARDCORE_ARCHIVE_VIDEO_ACCELERATION == cpu && $HARDCORE_ARCHIVE_VIDEO_GPU_FILTERS == off && $HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE == 2 ]]
export HARDCORE_ARCHIVE_CALIBRATION_POLICY_INHERITED=1
load_config_file "$TEST_ROOT/child"
[[ $HARDCORE_ARCHIVE_VIDEO_ACCELERATION == cpu && $HARDCORE_ARCHIVE_VIDEO_GPU_FILTERS == off && $HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE == 2 ]]
''')
        for bad in ("VIDEO_ACCELERATION=fast", "VIDEO_GPU_FILTERS=true", "VIDEO_CUDA_DEVICE=-1", "VIDEO_CUDA_DEVICE=$(touch bad)"):
            (self.root / "config").write_text(bad + "\n")
            self.run_shell(setup, expected=2)

    @unittest.skipUnless(shutil.which("ffmpeg"), "FFmpeg unavailable")
    def test_real_software_decode_audit_rejects_invalid_video(self):
        broken = self.root / "broken.mkv"
        broken.write_bytes(b"not a video")
        result = subprocess.run(["ffmpeg", "-v", "error", "-xerror", "-nostdin", "-i", str(broken),
                                 "-map", "0:V:0", "-map", "0:a?", "-f", "null", "-"], capture_output=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
