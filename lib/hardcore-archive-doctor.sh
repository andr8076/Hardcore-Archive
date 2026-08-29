#!/usr/bin/env bash
# Loader for the strict source-specific capability doctor.
DOCTOR_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$DOCTOR_LIB_DIR/hardcore-archive-doctor-base.sh"
source "$DOCTOR_LIB_DIR/hardcore-archive-doctor-checks.sh"
source "$DOCTOR_LIB_DIR/hardcore-archive-doctor-report.sh"
unset DOCTOR_LIB_DIR
