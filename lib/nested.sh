#!/usr/bin/env bash

# Nested-archive/media correctness policy boundary. The implementation is part
# of the checked-in static engine.
[[ ${HARDCORE_NESTED_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_NESTED_SH_LOADED=1
