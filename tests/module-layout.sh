#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

required=(
    common platform media-runtime config doctor inventory planner scheduler archive video images timing calibration-identity video-acceleration
    containers nested verify restore reporting visual
)
for module in "${required[@]}"; do
    [[ -f $ROOT/lib/$module.sh ]] || { printf 'Missing module: lib/%s.sh\n' "$module" >&2; exit 1; }
    bash -n "$ROOT/lib/$module.sh"
done
bash -n "$ROOT/hardcore-archive"
bash -n "$ROOT/hardcore-archive.sh"
bash -n "$ROOT/hardcore-archive-runner.sh"
bash -n "$ROOT/hardcore-archive-runner-policy.sh"
bash -n "$ROOT/lib/hardcore-archive-core.sh"
bash -n "$ROOT/packaging/build-media-runtime.sh"
bash -n "$ROOT/packaging/package-release.sh"
bash -n "$ROOT/tests/media-runtime.sh"
bash -n "$ROOT/tests/media-runtime-release.sh"

# Public/compatibility entrypoints stay intentionally thin.
(( $(wc -l < "$ROOT/hardcore-archive") < 40 )) || { printf 'hardcore-archive entrypoint grew too large.\n' >&2; exit 1; }
(( $(wc -l < "$ROOT/hardcore-archive.sh") < 20 )) || { printf 'hardcore-archive.sh compatibility shim grew too large.\n' >&2; exit 1; }
(( $(wc -l < "$ROOT/hardcore-archive-runner.sh") < 40 )) || { printf 'runtime runner grew too large.\n' >&2; exit 1; }

grep -Fq 'source "$HARDCORE_ARCHIVE_ROOT/lib/config.sh"' "$ROOT/hardcore-archive"
grep -Fq 'source "$HARDCORE_ARCHIVE_ROOT/lib/visual.sh"' "$ROOT/hardcore-archive"
grep -Fq 'source "$HARDCORE_ARCHIVE_ROOT/lib/scheduler.sh"' "$ROOT/hardcore-archive-runner.sh"
grep -Fq 'hardcore_archive_static_engine_ready' "$ROOT/lib/archive.sh"
grep -Fq 'hardcore_archive_static_engine_ready' "$ROOT/lib/scheduler.sh"
grep -Fq 'hardcore_media_runtime_select "$HARDCORE_ROOT"' "$ROOT/lib/scheduler.sh"
grep -Fq 'hardcore_run_sourced "$HARDCORE_POLICY_RUNNER"' "$ROOT/lib/scheduler.sh"
! grep -Eq 'apply_runtime_patch|build_runtime_core|HARDCORE_RUNTIME' \
    "$ROOT/lib/archive.sh" "$ROOT/lib/video.sh" "$ROOT/lib/nested.sh" \
    "$ROOT/lib/visual.sh" "$ROOT/lib/containers.sh" "$ROOT/lib/scheduler.sh"
grep -Fq 'hardcore_reporting_start' "$ROOT/lib/reporting.sh"

printf 'Modular layout tests passed.\n'
