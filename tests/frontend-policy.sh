#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

FRONTEND="$ROOT/hardcore-archive-runner-policy.sh" \
DOCTOR_LOADER="$ROOT/lib/hardcore-archive-doctor.sh" \
DOCTOR_BASE="$ROOT/lib/hardcore-archive-doctor-base.sh" \
DOCTOR_CHECKS="$ROOT/lib/hardcore-archive-doctor-checks.sh" \
DOCTOR_REPORT="$ROOT/lib/hardcore-archive-doctor-report.sh" \
    bash "$ROOT/tests/runner-policy.sh"

bash "$ROOT/tests/module-layout.sh"
bash "$ROOT/tests/bundled-runtime.sh"
bash "$ROOT/tests/lazy-video-runtime.sh"
bash "$ROOT/tests/video-content-routing.sh"
bash "$ROOT/tests/runtime-bootstrap.sh"
bash "$ROOT/tests/runtime-build-safety.sh"
python3 "$ROOT/tests/destination-logs.py"
python3 "$ROOT/tests/phase-timings.py"
bash "$ROOT/tests/config-layer.sh"
bash "$ROOT/tests/hash-verification-policy.sh"
bash "$ROOT/tests/metadata-roundtrip.sh"
python3 "$ROOT/tests/acl-platform.py"
python3 "$ROOT/tests/restore-roundtrip.py"
bash "$ROOT/tests/resource-utilization.sh"
bash "$ROOT/tests/benchmark-corpus.sh"
bash "$ROOT/tests/copy-lane-policy.sh"
bash "$ROOT/tests/ffmpeg-detection.sh"
bash "$ROOT/tests/doctor-repair-advice.sh"
bash "$ROOT/tests/video-quality-nested-policy.sh"
bash "$ROOT/tests/video-codec-auto-policy.sh"
bash "$ROOT/tests/video-encoder-menu-policy.sh"
bash "$ROOT/tests/video-encoder-runtime-policy.sh"
bash "$ROOT/tests/video-calibration-nested-diagnostics.sh"
python3 "$ROOT/tests/nested-work-space.py"
python3 "$ROOT/tests/manifest-batching.py"
bash "$ROOT/tests/video-calibration-cache.sh"
python3 "$ROOT/tests/video-acceleration.py"
bash "$ROOT/tests/media-special-policy.sh"
python3 "$ROOT/tests/media-special-policy.py"
bash "$ROOT/tests/video-quality-performance.sh"
bash "$ROOT/tests/visual-policy.sh"
bash "$ROOT/tests/container-repack-policy.sh"
bash "$ROOT/tests/hardware-video-diagnostics.sh"
bash "$ROOT/tests/poweroff-policy.sh"
printf 'All frontend policy tests passed.\n'
