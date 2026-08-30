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
bash "$ROOT/tests/config-layer.sh"
bash "$ROOT/tests/copy-lane-policy.sh"
bash "$ROOT/tests/ffmpeg-detection.sh"
bash "$ROOT/tests/video-quality-nested-policy.sh"
bash "$ROOT/tests/video-codec-auto-policy.sh"
bash "$ROOT/tests/video-calibration-nested-diagnostics.sh"
bash "$ROOT/tests/container-repack-policy.sh"
bash "$ROOT/tests/hardware-video-diagnostics.sh"
bash "$ROOT/tests/poweroff-policy.sh"
printf 'All frontend policy tests passed.\n'
