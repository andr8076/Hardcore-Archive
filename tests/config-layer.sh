#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-archive-config-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/app/lib" "$TMP/home/.config/hardcore-archive"
cp "$ROOT/hardcore-archive" "$ROOT/hardcore-archive.sh" "$ROOT/config" "$TMP/app/"
cp "$ROOT/lib/common.sh" "$ROOT/lib/platform.sh" "$ROOT/lib/config.sh" "$ROOT/lib/visual.sh" "$TMP/app/lib/"

cat > "$TMP/app/hardcore-archive-runner.sh" <<'FAKE_RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail
cfg=''
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    case ${args[i]} in
        --config) cfg=${args[i+1]}; i=$((i+1)) ;;
        --config=*) cfg=${args[i]#*=} ;;
    esac
done
[[ -r $cfg ]] || { printf 'NO_CONFIG\n'; exit 10; }
value() {
    local key=$1
    awk -F= -v key="$key" '
        /^[[:space:]]*#/ || !index($0,"=") {next}
        {k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",k)}
        k==key {v=substr($0,index($0,"=")+1); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); found=v}
        END {print found}
    ' "$cfg"
}
printf 'VIDEO_TRANSCODE=%s\n' "$(value VIDEO_TRANSCODE)"
printf 'IMAGE_OPTIMIZE=%s\n' "$(value IMAGE_OPTIMIZE)"
printf 'NESTED_REPACK=%s\n' "$(value NESTED_REPACK)"
printf 'CONTAINER_REPACK=%s\n' "$(value CONTAINER_REPACK)"
printf 'VIDEO_MODE=%s\n' "$(value VIDEO_MODE)"
printf 'QUALITY_CHECK=%s\n' "$(value QUALITY_CHECK)"
printf 'VIDEO_MIN_VMAF=%s\n' "$(value VIDEO_MIN_VMAF)"
printf 'ARG=%s\n' "$@"
FAKE_RUNNER
chmod +x "$TMP/app/hardcore-archive" "$TMP/app/hardcore-archive.sh" "$TMP/app/hardcore-archive-runner.sh"

run_launcher() {
    HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" bash "$TMP/app/hardcore-archive.sh" "$@"
}
assert_contains() { local out=$1 text=$2; grep -Fq -- "$text" <<< "$out" || { printf 'Expected: %s\nOutput:\n%s\n' "$text" "$out" >&2; exit 1; }; }
assert_lacks() { local out=$1 text=$2; ! grep -Fq -- "$text" <<< "$out" || { printf 'Unexpected: %s\nOutput:\n%s\n' "$text" "$out" >&2; exit 1; }; }

out=$(run_launcher source)
assert_contains "$out" 'VIDEO_TRANSCODE=true'
assert_contains "$out" 'IMAGE_OPTIMIZE=true'
assert_contains "$out" 'NESTED_REPACK=true'
assert_contains "$out" 'CONTAINER_REPACK=true'
assert_contains "$out" 'VIDEO_MODE=balanced'
assert_contains "$out" 'QUALITY_CHECK=auto'
assert_contains "$out" 'VIDEO_MIN_VMAF=92'

grep -Fqx 'QUALITY_CHECK=92' "$TMP/app/config" || { printf 'Expected numeric QUALITY_CHECK in shipped config.\n' >&2; exit 1; }
! grep -q '^VIDEO_MIN_VMAF=' "$TMP/app/config" || { printf 'VIDEO_MIN_VMAF should no longer be a shipped user-facing setting.\n' >&2; exit 1; }

sed -i 's/^VIDEO_TRANSCODE=true$/VIDEO_TRANSCODE=false/' "$TMP/app/config"
sed -i 's/^CONTAINER_REPACK=true$/CONTAINER_REPACK=false/' "$TMP/app/config"
sed -i 's/^VIDEO_MODE=balanced$/VIDEO_MODE=maximum/' "$TMP/app/config"
sed -i 's/^QUALITY_CHECK=92$/QUALITY_CHECK=96/' "$TMP/app/config"
out=$(run_launcher source)
assert_contains "$out" 'VIDEO_TRANSCODE=false'
assert_contains "$out" 'CONTAINER_REPACK=false'
assert_contains "$out" 'VIDEO_MODE=maximum'
assert_contains "$out" 'QUALITY_CHECK=auto'
assert_contains "$out" 'VIDEO_MIN_VMAF=96'

printf 'VIDEO_TRANSCODE=true\nIMAGE_OPTIMIZE=false\nCONTAINER_REPACK=true\nQUALITY_CHECK=94\n' > "$TMP/home/.config/hardcore-archive/config"
out=$(run_launcher source)
assert_contains "$out" 'VIDEO_TRANSCODE=true'
assert_contains "$out" 'IMAGE_OPTIMIZE=false'
assert_contains "$out" 'CONTAINER_REPACK=true'
assert_contains "$out" 'QUALITY_CHECK=auto'
assert_contains "$out" 'VIDEO_MIN_VMAF=94'

printf 'VIDEO_TRANSCODE=false\nIMAGE_OPTIMIZE=true\nVIDEO_MODE=fast\nQUALITY_CHECK=97.5\n' > "$TMP/custom.conf"
out=$(run_launcher --config "$TMP/custom.conf" source)
assert_contains "$out" 'VIDEO_TRANSCODE=false'
assert_contains "$out" 'IMAGE_OPTIMIZE=true'
assert_contains "$out" 'CONTAINER_REPACK=true'
assert_contains "$out" 'VIDEO_MODE=fast'
assert_contains "$out" 'QUALITY_CHECK=auto'
assert_contains "$out" 'VIDEO_MIN_VMAF=97.5'
assert_lacks "$out" "ARG=$TMP/custom.conf"

out=$(run_launcher --config "$TMP/custom.conf" --video-transcode --no-container-repack source)
assert_contains "$out" 'ARG=--video-transcode'
assert_contains "$out" 'ARG=--no-container-repack'
assert_contains "$out" 'ARG=source'

out=$(run_launcher --quality-check 99 source)
assert_contains "$out" 'ARG=--quality-check'
assert_contains "$out" 'ARG=auto'
assert_contains "$out" 'ARG=--video-min-vmaf'
assert_contains "$out" 'ARG=99'

out=$(run_launcher --quality-check=98.5 source)
assert_contains "$out" 'ARG=--quality-check'
assert_contains "$out" 'ARG=auto'
assert_contains "$out" 'ARG=--video-min-vmaf'
assert_contains "$out" 'ARG=98.5'

printf 'QUALITY_CHECK=off\n' > "$TMP/custom-off.conf"
out=$(run_launcher --config "$TMP/custom-off.conf" source)
assert_contains "$out" 'QUALITY_CHECK=off'

out=$(run_launcher --no-config --config "$TMP/custom.conf" source)
assert_contains "$out" 'VIDEO_TRANSCODE=false'
assert_contains "$out" 'IMAGE_OPTIMIZE=true'
assert_contains "$out" 'NESTED_REPACK=true'
assert_contains "$out" 'CONTAINER_REPACK=false'
assert_contains "$out" 'VIDEO_MODE=maximum'
assert_contains "$out" 'VIDEO_MIN_VMAF=96'

set +e
out=$(run_launcher --config "$TMP/missing.conf" source 2>&1); rc=$?
set -e
(( rc == 2 )) || { printf 'Expected rc=2 for missing config, got %s\n%s\n' "$rc" "$out" >&2; exit 1; }
assert_contains "$out" 'requested config is missing or unreadable'

printf 'QUALITY_CHECK=101\n' > "$TMP/bad-quality.conf"
set +e
out=$(run_launcher --config "$TMP/bad-quality.conf" source 2>&1); rc=$?
set -e
(( rc == 2 )) || { printf 'Expected rc=2 for invalid QUALITY_CHECK, got %s\n%s\n' "$rc" "$out" >&2; exit 1; }
assert_contains "$out" 'QUALITY_CHECK must be a VMAF score from 0 to 100, or off'

printf 'Config layering tests passed.\n'
