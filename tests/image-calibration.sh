#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
CALIBRATOR="$ROOT/lib/hardcore-archive-image-calibrate.py"
IMAGES="$ROOT/lib/images.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-image-calibration-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

python3 -m py_compile "$CALIBRATOR"
bash -n "$IMAGES"
mkdir -p "$TMP/bin" "$TMP/cache"
OXI_CALLS="$TMP/oxipng.calls"
export OXI_CALLS

cat > "$TMP/bin/oxipng" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case ${1:-} in
    --version)
        printf 'oxipng 10.1.0-test\n'
        exit 0
        ;;
    --help)
        printf '%s\n' '  -t, --threads <num>'
        exit 0
        ;;
esac
printf 'run\n' >> "$OXI_CALLS"
# Keep process startup insignificant relative to the work so the expected
# throughput ordering is deterministic: more parallel workers win this fixture.
sleep 0.12
exit 0
SH
chmod +x "$TMP/bin/oxipng"

first=$(python3 "$CALIBRATOR" \
    --oxipng "$TMP/bin/oxipng" \
    --cpu-threads 8 \
    --max-workers 4 \
    --cache-dir "$TMP/cache" \
    --cpu-model fixture-cpu \
    --platform test \
    --time-budget 5 \
    --repeats 1)
IFS=$'\t' read -r jobs threads budget source <<< "$first"
[[ $jobs == 4 ]]
[[ $threads == 2 ]]
[[ $budget == 8 ]]
[[ $source == calibrated-new ]]
first_calls=$(wc -l < "$OXI_CALLS")
(( first_calls >= 7 ))

second=$(python3 "$CALIBRATOR" \
    --oxipng "$TMP/bin/oxipng" \
    --cpu-threads 8 \
    --max-workers 4 \
    --cache-dir "$TMP/cache" \
    --cpu-model fixture-cpu \
    --platform test \
    --time-budget 5 \
    --repeats 1)
IFS=$'\t' read -r jobs threads budget source <<< "$second"
[[ $jobs == 4 && $threads == 2 && $budget == 8 ]]
[[ $source == calibrated-cache ]]
[[ $(wc -l < "$OXI_CALLS") == "$first_calls" ]]

set +e
python3 "$CALIBRATOR" \
    --oxipng "$TMP/bin/oxipng" \
    --cpu-threads 8 \
    --max-workers 4 \
    --cache-dir "$TMP/cache" \
    --cpu-model different-cpu \
    --platform test \
    --cache-only >/dev/null
cache_miss_status=$?
set -e
[[ $cache_miss_status == 3 ]]

# Exercise the shell integration independently of benchmark timing.
cat > "$TMP/stub-calibrator.py" <<'PY'
#!/usr/bin/env python3
print("4\t2\t8\tcalibrated-cache")
PY
chmod +x "$TMP/stub-calibrator.py"
PATH="$TMP/bin:$PATH"
export PATH
export PLATFORM_ID=test
export HARDCORE_ARCHIVE_IMAGE_CALIBRATOR="$TMP/stub-calibrator.py"
export HARDCORE_ARCHIVE_IMAGE_SCHEDULER_CACHE_DIR="$TMP/cache"
source "$IMAGES"

chosen=$(hardcore_images_choose_cpu_schedule 8 10 10 auto 8192 fixture false)
[[ $chosen == $'4\t2\t8\tcalibrated-cache' ]]

clamped=$(hardcore_images_choose_cpu_schedule 8 2 2 auto 8192 fixture false)
[[ $clamped == $'2\t4\t8\tcalibrated-cache-clamped' ]]

jpeg_dominant=$(hardcore_images_choose_cpu_schedule 8 100 10 auto 8192 fixture false)
[[ $jpeg_dominant == $'8\t1\t8\theuristic-jpeg-dominant' ]]

explicit=$(hardcore_images_choose_cpu_schedule 8 100 10 3 8192 fixture false)
[[ $explicit == $'3\t3\t8\texplicit' ]]

export HARDCORE_ARCHIVE_IMAGE_CALIBRATION_DISABLE=1
disabled=$(hardcore_images_choose_cpu_schedule 8 10 10 auto 8192 fixture false)
[[ $disabled == $'8\t1\t8\theuristic-disabled' ]]
unset HARDCORE_ARCHIVE_IMAGE_CALIBRATION_DISABLE

printf 'Image scheduler calibration tests passed.\n'
