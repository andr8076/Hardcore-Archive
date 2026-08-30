#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

required=(
    common platform config doctor inventory planner scheduler archive video images
    containers nested verify restore reporting
)
for module in "${required[@]}"; do
    [[ -f $ROOT/lib/$module.sh ]] || { printf 'Missing module: lib/%s.sh\n' "$module" >&2; exit 1; }
    bash -n "$ROOT/lib/$module.sh"
done
bash -n "$ROOT/hardcore-archive"
bash -n "$ROOT/hardcore-archive.sh"
bash -n "$ROOT/hardcore-archive-runner.sh"

# Public/compatibility entrypoints stay intentionally thin.
(( $(wc -l < "$ROOT/hardcore-archive") < 40 )) || { printf 'hardcore-archive entrypoint grew too large.\n' >&2; exit 1; }
(( $(wc -l < "$ROOT/hardcore-archive.sh") < 20 )) || { printf 'hardcore-archive.sh compatibility shim grew too large.\n' >&2; exit 1; }
(( $(wc -l < "$ROOT/hardcore-archive-runner.sh") < 40 )) || { printf 'runtime runner grew too large.\n' >&2; exit 1; }

grep -Fq 'source "$HARDCORE_ARCHIVE_ROOT/lib/config.sh"' "$ROOT/hardcore-archive"
grep -Fq 'source "$HARDCORE_ARCHIVE_ROOT/lib/scheduler.sh"' "$ROOT/hardcore-archive-runner.sh"
grep -Fq 'hardcore_archive_build_runtime_core' "$ROOT/lib/archive.sh"
grep -Fq 'hardcore_video_apply_runtime_patch' "$ROOT/lib/video.sh"
grep -Fq 'hardcore_nested_apply_runtime_patch' "$ROOT/lib/nested.sh"
grep -Fq 'hardcore_reporting_start' "$ROOT/lib/reporting.sh"

printf 'Modular layout tests passed.\n'
