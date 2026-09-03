#!/usr/bin/env python3
"""Exercise production preprocessing, calibration competition and retries."""
import os
from pathlib import Path
import runpy
import shlex
import shutil
import subprocess
import tempfile
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
        for name in ("encodes", "measures"):
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
        self.assertEqual(len(commands), 19)
        self.assertIn("hwdownload,format=nv12", commands[-1][commands[-1].index("-vf") + 1])
        self.assertTrue(all("-hwaccel" in c for c in commands))

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
                graph = commands[-1][commands[-1].index("-vf") + 1]
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
                self.assertLessEqual(len(commands), 24)
                output, commands = self.run_shell(SCALING="true", GPU_SIZE_PERCENT=cost)
                self.assertIn(f"RESULT:0:18:{winner}", output)
                self.assertEqual(len(commands), 2)
                self.assertEqual(output.count("Calibration cache source: video"), 2)

    def test_gpu_quality_failure_cannot_hide_passing_cpu_filter_candidate(self):
        output, _ = self.run_shell(SCALING="true", GPU_BAD_QUALITY=1, GPU_SIZE_PERCENT=1)
        self.assertIn("RESULT:0:18:hybrid", output)
        output, commands = self.run_shell(SCALING="true", GPU_BAD_QUALITY=1, GPU_SIZE_PERCENT=1)
        self.assertIn("Calibration cache source: video (rejected)", output)
        self.assertIn("RESULT:0:18:hybrid", output)
        self.assertEqual(len(commands), 2)

    def test_no_usable_measurement_fails_all_paths_without_caching_acceptance(self):
        output, commands = self.run_shell(CURVE="unavailable")
        self.assertIn("RESULT:1::cpu", output)
        self.assertEqual(len(commands), 3)
        self.assertEqual(list((self.root / "cache").iterdir()), [])

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
