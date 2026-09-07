#!/usr/bin/env python3
"""One-shot finishing patch for completed-output video quality integration."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Wire completed-output quality acceptance into the full encode loop. Keep
# structural preprocessing retries separate from bounded higher-quality retries.
accel_path = ROOT / "lib/video-acceleration.sh"
accel = accel_path.read_text()
old = '''hardcore_video_encode_full() {
    local attempt=0
    hardcore_video_accel_prepare "$video_encoder"
    while (( attempt < 3 )); do
        attempt=$((attempt + 1))
        rm -f -- "$temporary"
        if hardcore_video_encode_attempt; then return 0; fi
        rm -f -- "$temporary"
        # At most one full retry for each of AUTO's two hardware encoders.
        # Never reuse GPU-filter calibration after changing preprocessing.
        (( attempt < 3 )) && hardcore_video_accel_force_cpu "$video_encoder" || return 1
        calibrate_and_choose_video_codec || return 1
        run_video_preflight || return 1
    done
    return 1
}
'''
new = '''hardcore_video_encode_full() {
    local preprocessing_attempt=0 quality_retry=0
    hardcore_video_accel_prepare "$video_encoder"
    while (( preprocessing_attempt < 3 )); do
        preprocessing_attempt=$((preprocessing_attempt + 1))
        quality_retry=0
        while true; do
            rm -f -- "$temporary"
            if hardcore_video_encode_attempt; then
                if hardcore_video_validate_completed_quality "$temporary"; then
                    return 0
                fi
                rm -f -- "$temporary"
                if [[ ${VIDEO_FINAL_QUALITY_RETRYABLE:-false} == true ]] &&
                   (( quality_retry < ${video_quality_retries:-0} )) &&
                   hardcore_video_raise_quality; then
                    quality_retry=$((quality_retry + 1))
                    printf 'Completed-output quality retry %s/%s uses a strictly higher encoder quality.\\n' \
                        "$quality_retry" "$video_quality_retries"
                    continue
                fi
                # A measured quality rejection is distinct from an encode/decode
                # failure: preserve the original rather than changing preprocessing
                # or weakening the configured VMAF target.
                return 3
            fi
            break
        done
        rm -f -- "$temporary"
        # Structural/preprocessing failures retain the existing bounded CPU
        # preprocessing fallback. Hardware encoding remains mandatory.
        (( preprocessing_attempt < 3 )) && hardcore_video_accel_force_cpu "$video_encoder" || return 1
        calibrate_and_choose_video_codec || return 1
        run_video_preflight || return 1
    done
    return 1
}
'''
if old in accel:
    accel = accel.replace(old, new, 1)
elif 'hardcore_video_validate_completed_quality "$temporary"' not in accel:
    raise SystemExit("video encode integration anchor missing")
accel_path.write_text(accel)

# Correct static test expectations to verify the modular integration and current
# cache-policy identity rather than obsolete implementation labels.
test_path = ROOT / "tests/video-final-quality.py"
test = test_path.read_text()
loader_old = "quality = importlib.util.module_from_spec(spec)\nspec.loader.exec_module(quality)\n"
loader_new = "quality = importlib.util.module_from_spec(spec)\nimport sys\nsys.modules[spec.name] = quality\nspec.loader.exec_module(quality)\n"
if loader_old in test:
    test = test.replace(loader_old, loader_new, 1)
elif "sys.modules[spec.name] = quality" not in test:
    raise SystemExit("test loader integration anchor missing")
assert_old = '        self.assertIn("hardcore_video_validate_completed_quality", core)\n'
assert_new = (
    '        self.assertIn("video-quality-final.sh", core)\n'
    '        acceleration = (ROOT / "lib/video-acceleration.sh").read_text()\n'
    '        self.assertIn("hardcore_video_validate_completed_quality", acceleration)\n'
)
if assert_old in test:
    test = test.replace(assert_old, assert_new, 1)
elif 'acceleration = (ROOT / "lib/video-acceleration.sh").read_text()' not in test:
    raise SystemExit("static integration assertion anchor missing")
test = test.replace('"completed-video-quality-v1"', '"video-acceptance-v1-duration-scaled"')
test_path.write_text(test)

performance_path = ROOT / "tests/video-quality-performance.py"
performance = performance_path.read_text()
performance = performance.replace(
    '"calibration-v4-source-display-resolution-bicubic-sar-nearest-vmaf-model"',
    '"calibration-v5-source-display-final-acceptance-policy"')
performance = performance.replace(
    '\'"video-preprocessing-v3-source-display-vmaf"\'',
    '\'"video-acceptance-v1-duration-scaled"\'')
performance_path.write_text(performance)
