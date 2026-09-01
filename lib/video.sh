#!/usr/bin/env bash

# Hardware-video policy boundary. Video policy is compiled into the checked-in
# static engine; this module remains the ownership boundary for future moves.
[[ ${HARDCORE_VIDEO_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_VIDEO_SH_LOADED=1
