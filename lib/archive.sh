#!/usr/bin/env bash

# Static archive-engine boundary. The final engine is checked in and syntax
# checked by the test suite; runtime source patching is deliberately forbidden.
[[ ${HARDCORE_ARCHIVE_MODULE_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_ARCHIVE_MODULE_SH_LOADED=1

hardcore_archive_static_engine_ready() {
    hardcore_require_file "$HARDCORE_CORE_SOURCE" 'static archive engine'
}
