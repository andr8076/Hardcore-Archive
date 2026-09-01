#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
HELPER="$ROOT/lib/hardcore-archive-metadata.py"
CORE="$ROOT/lib/hardcore-archive-core.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-metadata-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

RESTORE="$TMP/restore"
META="$RESTORE/.hardcore-archive-metadata"
mkdir -p "$META" "$RESTORE/tree"
printf 'round-trip payload\n' > "$RESTORE/tree/file.txt"
uid=$(id -u)
gid=$(id -g)
mtime=1700000000

printf 'type\tmode\tuid\tgid\tmtime_epoch\tpath\tlink_target\n' > "$META/files.tsv"
printf 'file\t640\t%s\t%s\t%s\ttree/file.txt\t\n' "$uid" "$gid" "$mtime" >> "$META/files.tsv"
cat > "$META/acl.txt" <<'EOF_ACL'
# file: tree/file.txt
# owner: benchmark
# group: benchmark
user::rw-
group::r--
other::---

EOF_ACL

# Build an xattr record only on filesystems where user xattrs work.
xattr_expected=$(python3 - "$RESTORE/tree/file.txt" "$META/xattrs.txt" <<'PY'
import base64, json, os, sys
path, manifest = sys.argv[1:]
record = {"path": "tree/file.txt", "xattrs": {}, "flags": 0}
try:
    os.setxattr(path, "user.hardcore_test", b"before")
    record["xattrs"]["user.hardcore_test"] = base64.b64encode(b"restored-value").decode()
    print("yes")
except OSError:
    print("no")
with open(manifest, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(record) + "\n")
PY
)

chmod 777 "$RESTORE/tree/file.txt"
touch -d '@1800000000' "$RESTORE/tree/file.txt"
python3 "$HELPER" --root "$RESTORE" --metadata-dir "$META"
[[ $(stat -c '%a' "$RESTORE/tree/file.txt") == 640 ]]
[[ $(stat -c '%Y' "$RESTORE/tree/file.txt") == "$mtime" ]]
if [[ $xattr_expected == yes ]]; then
    [[ $(python3 -c 'import os,sys; print(os.getxattr(sys.argv[1], "user.hardcore_test").decode())' "$RESTORE/tree/file.txt") == restored-value ]]
fi

# Parent traversal and leaf symlinks must be rejected before setfacl is called.
printf 'outside\n' > "$TMP/outside"
ln -s "$TMP/outside" "$RESTORE/tree/outside-link"
cat > "$META/acl.txt" <<'EOF_BAD_ACL'
# file: tree/outside-link
user::rw-
user:nobody:r--
group::r--
mask::r--
other::---
EOF_BAD_ACL
if python3 "$HELPER" --root "$RESTORE" --metadata-dir "$META" >"$TMP/unsafe.out" 2>&1; then
    printf 'Unsafe ACL symlink was accepted.\n' >&2
    exit 1
fi
grep -Fq 'ACL path is a symlink leaf' "$TMP/unsafe.out"
[[ $(cat "$TMP/outside") == outside ]]

cat > "$META/acl.txt" <<'EOF_TRAVERSAL'
# file: ../outside
user::rw-
group::r--
other::---
EOF_TRAVERSAL
if python3 "$HELPER" --root "$RESTORE" --metadata-dir "$META" >"$TMP/traversal.out" 2>&1; then
    printf 'Traversing ACL path was accepted.\n' >&2
    exit 1
fi
grep -Fq 'unsafe metadata path' "$TMP/traversal.out"

grep -Fq 'getfacl -R -p -n' "$CORE"
grep -Fq 'restore fails closed rather than silently dropping access controls' "$CORE"

# Exercise a real extended-ACL round trip where the host provides ACL tools.
if command -v getfacl >/dev/null 2>&1 && command -v setfacl >/dev/null 2>&1 && id nobody >/dev/null 2>&1; then
    setfacl -m u:nobody:r-- "$RESTORE/tree/file.txt"
    (cd "$RESTORE" && getfacl -R -p -- tree/file.txt) > "$META/acl.txt"
    setfacl -b "$RESTORE/tree/file.txt"
    python3 "$HELPER" --root "$RESTORE" --metadata-dir "$META"
    getfacl -cp "$RESTORE/tree/file.txt" | grep -Eq '^user:nobody:r--'
else
    printf 'Extended ACL round trip skipped: getfacl/setfacl or nobody unavailable.\n'
fi

printf 'Safe metadata round-trip tests passed.\n'
