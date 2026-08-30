#!/usr/bin/env bash

# Strict source-specific doctor wiring.
[[ ${HARDCORE_DOCTOR_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_DOCTOR_SH_LOADED=1

hardcore_doctor_link_runtime_modules() {
    local runtime_dir=$1 module
    for module in \
        hardcore-archive-doctor.sh \
        hardcore-archive-doctor-base.sh \
        hardcore-archive-doctor-checks.sh \
        hardcore-archive-doctor-video-fix.sh \
        hardcore-archive-doctor-video-auto.sh \
        hardcore-archive-doctor-report.sh
    do
        hardcore_require_file "$HARDCORE_ROOT/lib/$module" 'doctor module' || return 1
        ln -s -- "$HARDCORE_ROOT/lib/$module" "$runtime_dir/lib/$module"
    done
}
