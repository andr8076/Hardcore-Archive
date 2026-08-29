#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

FRONTEND="$ROOT/hardcore-archive-runner.sh" \
DOCTOR_LOADER="$ROOT/lib/hardcore-archive-doctor.sh" \
DOCTOR_BASE="$ROOT/lib/hardcore-archive-doctor-base.sh" \
DOCTOR_CHECKS="$ROOT/lib/hardcore-archive-doctor-checks.sh" \
DOCTOR_REPORT="$ROOT/lib/hardcore-archive-doctor-report.sh" \
    bash "$ROOT/tests/runner-policy.sh"

bash "$ROOT/tests/config-layer.sh"
printf 'All frontend policy tests passed.\n'
