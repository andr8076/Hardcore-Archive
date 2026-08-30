#!/usr/bin/env bash
# Loader for the strict source-specific capability doctor.
DOCTOR_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$DOCTOR_LIB_DIR/hardcore-archive-doctor-base.sh"
source "$DOCTOR_LIB_DIR/hardcore-archive-doctor-checks.sh"
# Optional compatibility overrides live separately so the stable doctor policy
# remains easy to audit. Installed releases ship this file.
if [[ -f $DOCTOR_LIB_DIR/hardcore-archive-doctor-video-fix.sh ]]; then
    source "$DOCTOR_LIB_DIR/hardcore-archive-doctor-video-fix.sh"
fi
source "$DOCTOR_LIB_DIR/hardcore-archive-doctor-report.sh"
unset DOCTOR_LIB_DIR
