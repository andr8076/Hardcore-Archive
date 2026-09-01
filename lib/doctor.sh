#!/usr/bin/env bash

# Strict source-specific doctor policy boundary. The checked-in policy runner
# sources its doctor modules directly; no temporary runtime tree is assembled.
[[ ${HARDCORE_DOCTOR_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_DOCTOR_SH_LOADED=1
