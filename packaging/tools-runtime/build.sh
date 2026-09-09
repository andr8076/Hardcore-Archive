#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd -- "$HERE/../.." && pwd -P)
# shellcheck source=/dev/null
source "$HERE/versions.env"

PREFIX=${HCA_TOOLS_PREFIX:-}
OUT=${HCA_TOOLS_OUT:-$ROOT/dist/tools-runtime}
TARGET=${HCA_TOOLS_TARGET:-}
[[ -n $PREFIX && -d $PREFIX ]] || {
    printf 'HCA_TOOLS_PREFIX must name a prepared package environment.\n' >&2
    exit 2
}
[[ $TARGET =~ ^(linux|macos)-(x86_64|arm64)$ ]] || {
    printf 'HCA_TOOLS_TARGET must be linux-x86_64, linux-arm64, macos-x86_64, or macos-arm64.\n' >&2
    exit 2
}

canonical_path() {
    python3 - "$1" <<'PY'
import os, sys
print(os.path.realpath(os.path.abspath(sys.argv[1])))
PY
}

PREFIX=$(canonical_path "$PREFIX")
OUT=$(canonical_path "$OUT")
ROOT=$(canonical_path "$ROOT")
DEFAULT_OUT=$(canonical_path "$ROOT/dist/tools-runtime")
case $OUT in
    /|"${HOME:-/nonexistent}"|"$ROOT")
        printf 'Refusing unsafe tools-runtime output directory: %s\n' "$OUT" >&2
        exit 2
        ;;
esac
if [[ $ROOT == "$OUT/"* ]]; then
    printf 'Refusing output directory that contains the repository: %s\n' "$OUT" >&2
    exit 2
fi
if [[ $PREFIX == "$OUT" || $PREFIX == "$OUT/"* || $OUT == "$PREFIX/"* ]]; then
    printf 'Tools-runtime input and output directories must not overlap.\n' >&2
    exit 2
fi
MARKER="$OUT/.hardcore-archive-tools-runtime-output"
if [[ -d $OUT && $OUT != "$DEFAULT_OUT" && ! -f $MARKER ]] && \
   [[ -n $(find "$OUT" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    printf 'Refusing to clean unmarked non-empty tools-runtime output: %s\n' "$OUT" >&2
    exit 2
fi

rm -rf -- "$OUT"
mkdir -p -- "$OUT/runtime"
: > "$OUT/.hardcore-archive-tools-runtime-output"
cp -a -- "$PREFIX/." "$OUT/runtime/"
rm -rf -- "$OUT/runtime/pkgs"

# Preserve package identity and license material beside the distributed
# binaries. The conda metadata records the package-cache source for each item.
python3 - "$OUT/runtime" <<'PY'
import json, pathlib, shutil, sys

runtime = pathlib.Path(sys.argv[1])
licenses = runtime / "licenses" / "packages"
for record_path in sorted((runtime / "conda-meta").glob("*.json")):
    record = json.loads(record_path.read_text(encoding="utf-8"))
    identity = "-".join(str(record.get(key, "unknown")) for key in ("name", "version", "build"))
    destination = licenses / identity
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "PACKAGE.txt").write_text(
        "\n".join(
            [
                f"name={record.get('name', 'unknown')}",
                f"version={record.get('version', 'unknown')}",
                f"build={record.get('build', 'unknown')}",
                f"license={record.get('license', 'unknown')}",
                f"source={record.get('url', record.get('channel', 'unknown'))}",
                "",
            ]
        ),
        encoding="utf-8",
    )
    package_source = pathlib.Path(record.get("link", {}).get("source", ""))
    source_licenses = package_source / "info" / "licenses"
    if source_licenses.is_dir():
        shutil.copytree(source_licenses, destination / "license-texts", dirs_exist_ok=True)
PY

# Convert internal absolute symlinks to relative links before relocation.
python3 - "$OUT/runtime" "$PREFIX" <<'PY'
import os, pathlib, sys

runtime = pathlib.Path(sys.argv[1])
source_prefix = os.path.realpath(sys.argv[2])
for path in runtime.rglob("*"):
    if not path.is_symlink():
        continue
    target = os.readlink(path)
    if not os.path.isabs(target):
        continue
    real_target = os.path.realpath(target)
    if real_target == source_prefix or real_target.startswith(source_prefix + os.sep):
        mapped = runtime / os.path.relpath(real_target, source_prefix)
        path.unlink()
        path.symlink_to(os.path.relpath(mapped, path.parent))
PY

# Some p7zip packages install a prefix-bearing shell wrapper. Replace it with
# a runtime-relative launcher when the underlying executable is available.
if [[ -x $OUT/runtime/lib/p7zip/7z ]]; then
    cat > "$OUT/runtime/bin/7z" <<'EOF_7Z'
#!/bin/sh
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
exec "$HERE/../lib/p7zip/7z" "$@"
EOF_7Z
    chmod 755 "$OUT/runtime/bin/7z"
fi

# conda-forge provides util-linux on Linux. macOS has no native flock or
# setsid, so portable Python implementations provide the exact contracts HCA
# uses while relying on the bundled Python interpreter.
if [[ ! -x $OUT/runtime/bin/flock ]]; then
    install -m 755 "$HERE/shims/flock.py" "$OUT/runtime/bin/flock"
fi
if [[ ! -x $OUT/runtime/bin/setsid ]]; then
    install -m 755 "$HERE/shims/setsid.py" "$OUT/runtime/bin/setsid"
fi

cat > "$OUT/runtime/tools-runtime-manifest.txt" <<EOF_MANIFEST
target=$TARGET
channel=$TOOLS_CHANNEL
bash=$BASH_VERSION_PIN
python=$PYTHON_VERSION
package_lock=explicit-spec.txt
EOF_MANIFEST
if [[ -r ${HCA_TOOLS_EXPLICIT_SPEC:-} ]]; then
    cp -- "$HCA_TOOLS_EXPLICIT_SPEC" "$OUT/runtime/explicit-spec.txt"
else
    printf 'unavailable\n' > "$OUT/runtime/explicit-spec.txt"
fi

required=(bash python3 awk grep sed find sort stat realpath numfmt sha256sum xargs flock 7z jpegtran djpeg oxipng file)
for command_name in "${required[@]}"; do
    [[ -x $OUT/runtime/bin/$command_name ]] || {
        printf 'Prepared runtime is missing required command: %s\n' "$command_name" >&2
        exit 3
    }
done
if [[ $TARGET == linux-* ]]; then
    for command_name in getfacl findmnt lsblk setsid; do
        [[ -x $OUT/runtime/bin/$command_name ]] || {
            printf 'Prepared Linux runtime is missing required command: %s\n' "$command_name" >&2
            exit 3
        }
    done
fi

printf 'Tools runtime created at %s/runtime\n' "$OUT"
