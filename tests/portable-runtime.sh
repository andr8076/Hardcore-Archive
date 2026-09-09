#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-portable-runtime.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/tool-root/runtime/bin" "$TMP/tool-root/runtime/lib"
ln -s "$(command -v bash)" "$TMP/tool-root/runtime/bin/bash"
ln -s "$(command -v python3)" "$TMP/tool-root/runtime/bin/python3"
cat > "$TMP/tool-root/runtime/bin/hca-tool-probe" <<'EOF_PROBE'
#!/usr/bin/env bash
printf 'bundled\n'
EOF_PROBE
chmod +x "$TMP/tool-root/runtime/bin/hca-tool-probe"
printf 'target=test\npackages=test\n' > "$TMP/tool-root/runtime/tools-runtime-manifest.txt"

HARDCORE_ARCHIVE_ROOT="$TMP/tool-root"
export HARDCORE_ARCHIVE_ROOT
# shellcheck source=/dev/null
source "$ROOT/lib/runtime.sh"
hardcore_runtime_prepare_toolchain
[[ ${HARDCORE_ARCHIVE_TOOL_RUNTIME_MODE:-} == bundled ]] || {
    printf 'Packaged tools runtime was not activated.\n' >&2
    exit 1
}
[[ $(command -v bash) == "$TMP/tool-root/runtime/bin/bash" ]] || {
    printf 'Packaged tools did not take PATH precedence.\n' >&2
    exit 1
}
[[ $(hca-tool-probe) == bundled ]] || {
    printf 'A command from the packaged tools runtime could not run.\n' >&2
    exit 1
}
[[ ${HARDCORE_ARCHIVE_TOOL_RUNTIME_ID:-} == hca-tools-* ]] || {
    printf 'Tools runtime identity was not generated.\n' >&2
    exit 1
}

# Verify that the POSIX launcher chooses packaged Bash even when the caller's
# PATH contains only ordinary operating-system commands.
FIXTURE="$TMP/launcher"
mkdir -p "$FIXTURE/runtime/bin"
cp -- "$ROOT/hardcore-archive.sh" "$FIXTURE/hardcore-archive.sh"
cat > "$FIXTURE/hardcore-archive" <<'EOF_APP'
#!/bin/sh
printf 'portable-started:%s\n' "$1"
EOF_APP
cat > "$FIXTURE/runtime/bin/bash" <<'EOF_BASH'
#!/bin/sh
printf '%s\n' "$1" > "$HCA_LAUNCH_LOG"
exec /bin/sh "$@"
EOF_BASH
chmod +x "$FIXTURE/hardcore-archive.sh" "$FIXTURE/hardcore-archive" "$FIXTURE/runtime/bin/bash"
LAUNCH_OUTPUT=$(env -i PATH=/usr/bin:/bin HCA_LAUNCH_LOG="$TMP/launch.log" \
    "$FIXTURE/hardcore-archive.sh" test-value)
[[ $LAUNCH_OUTPUT == 'portable-started:test-value' ]]
[[ $(cat "$TMP/launch.log") == "$FIXTURE/hardcore-archive" ]] || {
    printf 'Portable launcher did not select its bundled Bash.\n' >&2
    exit 1
}

python3 "$ROOT/packaging/tools-runtime/shims/flock.py" --version >/dev/null
exec 9>"$TMP/lock"
python3 "$ROOT/packaging/tools-runtime/shims/flock.py" -n 9
if python3 "$ROOT/packaging/tools-runtime/shims/flock.py" -n "$TMP/lock" /bin/true; then
    printf 'Portable flock did not preserve an inherited descriptor lock.\n' >&2
    exit 1
fi
python3 "$ROOT/packaging/tools-runtime/shims/flock.py" -u 9
python3 "$ROOT/packaging/tools-runtime/shims/flock.py" -n "$TMP/lock" /bin/true
python3 "$ROOT/packaging/tools-runtime/shims/setsid.py" --version >/dev/null

printf 'Portable runtime activation and launcher tests passed.\n'
