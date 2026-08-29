#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-archive-config-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/app" "$TMP/home/.config/hardcore-archive"
cp "$ROOT/hardcore-archive.sh" "$TMP/app/hardcore-archive.sh"
cp "$ROOT/config" "$TMP/app/config"

cat > "$TMP/app/hardcore-archive-runner.sh" <<'FAKE_RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail
cfg=''
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    case ${args[i]} in
        --config)
            cfg=${args[i+1]}
            i=$((i+1))
            ;;
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
printf 'VIDEO_MODE=%s\n' "$(value VIDEO_MODE)"
printf 'ARG=%s\n' "$@"
FAKE_RUNNER
chmod +x "$TMP/app/hardcore-archive.sh" "$TMP/app/hardcore-archive-runner.sh"

run_launcher() {
    HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" \
        bash "$TMP/app/hardcore-archive.sh" "$@"
}
assert_contains() {
    local out=$1 text=$2
    grep -Fq -- "$text" <<< "$out" || { printf 'Expected: %s\nOutput:\n%s\n' "$text" "$out" >&2; exit 1; }
}
assert_lacks() {
    local out=$1 text=$2
    ! grep -Fq -- "$text" <<< "$out" || { printf 'Unexpected: %s\nOutput:\n%s\n' "$text" "$out" >&2; exit 1; }
}

# Shipped config is the real base defaults.
out=$(run_launcher source)
assert_contains "$out" 'VIDEO_TRANSCODE=false'
assert_contains "$out" 'IMAGE_OPTIMIZE=false'
assert_contains "$out" 'VIDEO_MODE=balanced'

# Editing ./config changes the installation defaults.
sed -i 's/^VIDEO_TRANSCODE=false$/VIDEO_TRANSCODE=true/' "$TMP/app/config"
sed -i 's/^VIDEO_MODE=balanced$/VIDEO_MODE=maximum/' "$TMP/app/config"
out=$(run_launcher source)
assert_contains "$out" 'VIDEO_TRANSCODE=true'
assert_contains "$out" 'VIDEO_MODE=maximum'

# User config overrides shipped defaults.
printf 'VIDEO_TRANSCODE=false\nIMAGE_OPTIMIZE=true\n' > "$TMP/home/.config/hardcore-archive/config"
out=$(run_launcher source)
assert_contains "$out" 'VIDEO_TRANSCODE=false'
assert_contains "$out" 'IMAGE_OPTIMIZE=true'

# Explicit --config overrides user config.
printf 'VIDEO_TRANSCODE=true\nVIDEO_MODE=fast\n' > "$TMP/custom.conf"
out=$(run_launcher --config "$TMP/custom.conf" source)
assert_contains "$out" 'VIDEO_TRANSCODE=true'
assert_contains "$out" 'IMAGE_OPTIMIZE=true'
assert_contains "$out" 'VIDEO_MODE=fast'
assert_lacks "$out" "ARG=$TMP/custom.conf"

# CLI is forwarded unchanged and therefore remains highest precedence in the
# real runner. The external config selector itself is consumed by this layer.
out=$(run_launcher --config "$TMP/custom.conf" --no-video-transcode source)
assert_contains "$out" 'ARG=--no-video-transcode'
assert_contains "$out" 'ARG=source'

# --no-config ignores user/custom layers but never disables shipped defaults.
out=$(run_launcher --no-config --config "$TMP/custom.conf" source)
assert_contains "$out" 'VIDEO_TRANSCODE=true'
assert_contains "$out" 'IMAGE_OPTIMIZE=false'
assert_contains "$out" 'VIDEO_MODE=maximum'

# Missing explicit config is reported, never silently ignored.
set +e
out=$(run_launcher --config "$TMP/missing.conf" source 2>&1); rc=$?
set -e
(( rc == 2 )) || { printf 'Expected rc=2 for missing config, got %s\n%s\n' "$rc" "$out" >&2; exit 1; }
assert_contains "$out" 'requested config is missing or unreadable'

printf 'Config layering tests passed.\n'
