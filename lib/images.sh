#!/usr/bin/env bash

# Image module boundary. JPEG/PNG transform functions currently live in the
# checked-in static engine; callers should not add policy outside this module.
[[ ${HARDCORE_IMAGES_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_IMAGES_SH_LOADED=1

hardcore_images_runtime_ready() { return 0; }
