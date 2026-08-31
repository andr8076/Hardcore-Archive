#!/usr/bin/env bash
# Loader for the strict source-specific capability doctor.
DOCTOR_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$DOCTOR_LIB_DIR/hardcore-archive-doctor-base.sh"
source "$DOCTOR_LIB_DIR/hardcore-archive-doctor-checks.sh"
# Compatibility/correctness overrides live separately so the stable doctor
# policy remains easy to audit. Installed releases ship these files.
if [[ -f $DOCTOR_LIB_DIR/hardcore-archive-doctor-video-fix.sh ]]; then
    source "$DOCTOR_LIB_DIR/hardcore-archive-doctor-video-fix.sh"
fi
if [[ -f $DOCTOR_LIB_DIR/hardcore-archive-doctor-video-auto.sh ]]; then
    source "$DOCTOR_LIB_DIR/hardcore-archive-doctor-video-auto.sh"
fi
if [[ -f $DOCTOR_LIB_DIR/hardcore-archive-doctor-encoder-menu.sh ]]; then
    source "$DOCTOR_LIB_DIR/hardcore-archive-doctor-encoder-menu.sh"
fi
source "$DOCTOR_LIB_DIR/hardcore-archive-doctor-report.sh"
unset DOCTOR_LIB_DIR
