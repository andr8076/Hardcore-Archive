#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

required=(
    common platform config doctor inventory planner scheduler archive video images resource-pool timing calibration-identity video-acceleration video-quality-final media-policy runtime
    containers nested verify restore reporting visual inspect
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
bash -n "$ROOT/lib/hardcore-archive-image-helper.sh"
bash -n "$ROOT/lib/hardcore-archive-video-helper.sh"
python3 -m py_compile "$ROOT/lib/hardcore-archive-media.py"
python3 -m py_compile "$ROOT/lib/hardcore-archive-compressibility.py"
python3 -m py_compile "$ROOT/lib/hardcore-archive-image-calibrate.py"
python3 -m py_compile "$ROOT/lib/hardcore-archive-resource-run.py"
python3 -m py_compile "$ROOT/lib/hardcore-archive-zopfli-adaptive.py"
python3 -m py_compile "$ROOT/lib/hardcore-archive-video-quality.py"
python3 -m py_compile "$ROOT/lib/hardcore-archive-atomic-commit.py"
bash -n "$ROOT/packaging/media-runtime/build.sh"
bash -n "$ROOT/packaging/media-runtime/smoke-test.sh"
bash -n "$ROOT/packaging/media-runtime/relocate-macos.sh"
bash -n "$ROOT/packaging/intel-legacy-runtime/build.sh"
bash -n "$ROOT/packaging/intel-legacy-runtime/inspect.sh"
bash -n "$ROOT/packaging/intel-legacy-runtime/prove-p530.sh"
bash -n "$ROOT/packaging/intel-legacy-runtime/with-runtime.sh"
bash -n "$ROOT/packaging/tools-runtime/build.sh"
bash -n "$ROOT/packaging/tools-runtime/smoke-test.sh"
bash -n "$ROOT/packaging/portable/assemble.sh"
bash -n "$ROOT/packaging/portable/smoke-test.sh"
bash -n "$ROOT/tests/bundled-runtime.sh"
bash -n "$ROOT/tests/portable-runtime.sh"
bash -n "$ROOT/tests/runtime-bootstrap.sh"
bash -n "$ROOT/tests/runtime-build-safety.sh"
bash -n "$ROOT/tests/intel-legacy-runtime.sh"

# Public/compatibility entrypoints stay intentionally thin.
(( $(wc -l < "$ROOT/hardcore-archive") < 40 )) || { printf 'hardcore-archive entrypoint grew too large.\n' >&2; exit 1; }
(( $(wc -l < "$ROOT/hardcore-archive.sh") < 20 )) || { printf 'hardcore-archive.sh compatibility shim grew too large.\n' >&2; exit 1; }
(( $(wc -l < "$ROOT/hardcore-archive-runner.sh") < 40 )) || { printf 'runtime runner grew too large.\n' >&2; exit 1; }

grep -Fq 'source "$HARDCORE_ARCHIVE_ROOT/lib/config.sh"' "$ROOT/hardcore-archive"
grep -Fq 'hardcore_runtime_prepare_toolchain' "$ROOT/hardcore-archive"
grep -Fq 'source "$HARDCORE_ARCHIVE_ROOT/lib/visual.sh"' "$ROOT/hardcore-archive"
grep -Fq 'source "$HARDCORE_ARCHIVE_ROOT/lib/inspect.sh"' "$ROOT/hardcore-archive"
grep -Fq 'source "$HARDCORE_ARCHIVE_ROOT/lib/scheduler.sh"' "$ROOT/hardcore-archive-runner.sh"
grep -Fq 'hardcore_runtime_prepare_toolchain' "$ROOT/hardcore-archive-runner.sh"
grep -Fq 'hardcore_archive_static_engine_ready' "$ROOT/lib/archive.sh"
grep -Fq 'hardcore_archive_static_engine_ready' "$ROOT/lib/scheduler.sh"
! grep -Fq 'hardcore_runtime_prepare_video_toolchain' "$ROOT/lib/scheduler.sh"
grep -Fq 'hardcore_runtime_prepare_video_toolchain' "$ROOT/lib/hardcore-archive-doctor-checks.sh"
grep -Fq 'HARDCORE_ARCHIVE_MEDIA_HELPER="$HARDCORE_MEDIA_HELPER"' "$ROOT/lib/scheduler.sh"
grep -Fq 'hardcore_run_sourced "$HARDCORE_POLICY_RUNNER"' "$ROOT/lib/scheduler.sh"
grep -Fq 'hardcore-archive-image-helper.sh' "$ROOT/lib/hardcore-archive-core.sh"
grep -Fq 'hardcore_images_choose_cpu_schedule' "$ROOT/lib/hardcore-archive-core.sh"
grep -Fq 'HARDCORE_ARCHIVE_IMAGE_SCHEDULER_CACHE_DIR' "$ROOT/lib/hardcore-archive-core.sh"
grep -Fq 'source "$(dirname -- "${BASH_SOURCE[0]}")/resource-pool.sh"' "$ROOT/lib/hardcore-archive-core.sh"
grep -Fq 'hardcore_resource_pool_init' "$ROOT/lib/hardcore-archive-core.sh"
grep -Fq 'compress_nonvideo_with_resources' "$ROOT/lib/hardcore-archive-core.sh"
grep -Fq 'hardcore_resource_pool_expand_full' "$ROOT/lib/hardcore-archive-core.sh"
grep -Fq -- '--resource-pool "$RESOURCE_POOL_DIR"' "$ROOT/lib/hardcore-archive-core.sh"
grep -Fq 'HARDCORE_RESOURCE_GRANTED_CPU' "$ROOT/lib/hardcore-archive-image-helper.sh"
grep -Fq 'hardcore-archive-zopfli-adaptive.py' "$ROOT/lib/hardcore-archive-image-helper.sh"
grep -Fq -- '--threads-per-worker "$IMAGE_THREADS_PER_WORKER"' "$ROOT/lib/hardcore-archive-core.sh"
! grep -Fq 'RAYON_NUM_THREADS=2 oxipng' "$ROOT/lib/hardcore-archive-image-helper.sh"
! grep -Eq 'apply_runtime_patch|build_runtime_core|HARDCORE_RUNTIME' \
    "$ROOT/lib/archive.sh" "$ROOT/lib/video.sh" "$ROOT/lib/nested.sh" \
    "$ROOT/lib/visual.sh" "$ROOT/lib/containers.sh" "$ROOT/lib/scheduler.sh"
grep -Fq 'hardcore_reporting_start' "$ROOT/lib/reporting.sh"

# Restore owns preparation and delegates only the final kernel/filesystem commit
# to the checked-in no-replace helper; ordinary mv is staging-only.
grep -Fq 'restore_prepare_commit_tree()' "$ROOT/lib/restore.sh"
grep -Fq 'restore_atomic_commit_prepared()' "$ROOT/lib/restore.sh"
grep -Fq 'hardcore-archive-atomic-commit.py' "$ROOT/lib/restore.sh"
grep -Fq 'renameat2' "$ROOT/lib/hardcore-archive-atomic-commit.py"
grep -Fq 'renamex_np' "$ROOT/lib/hardcore-archive-atomic-commit.py"

printf 'Modular layout tests passed.\n'

# Video helper implementation is static, checked in, and staged through its module.
grep -F 'hardcore_video_stage_helper()' "$ROOT/lib/video.sh" >/dev/null
grep -F 'source "$(dirname -- "${BASH_SOURCE[0]}")/video.sh"' "$ROOT/lib/hardcore-archive-core.sh" >/dev/null
! grep -F '__HARDCORE_ARCHIVE_VIDEO_HELPER__' "$ROOT/lib/hardcore-archive-core.sh" >/dev/null
! grep -F 'write_embedded_video_helper' "$ROOT/lib/hardcore-archive-core.sh" >/dev/null
