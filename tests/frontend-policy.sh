#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

# The runtime wrapper prepares the patched engine; the policy suite intentionally
# exercises the preserved doctor/frontend directly with its fake core fixture.
FRONTEND="$ROOT/hardcore-archive-runner-policy.sh" \
DOCTOR_LOADER="$ROOT/lib/hardcore-archive-doctor.sh" \
DOCTOR_BASE="$ROOT/lib/hardcore-archive-doctor-base.sh" \
DOCTOR_CHECKS="$ROOT/lib/hardcore-archive-doctor-checks.sh" \
DOCTOR_REPORT="$ROOT/lib/hardcore-archive-doctor-report.sh" \
    bash "$ROOT/tests/runner-policy.sh"

bash "$ROOT/tests/config-layer.sh"
bash "$ROOT/tests/copy-lane-policy.sh"
printf 'All frontend policy tests passed.\n'
