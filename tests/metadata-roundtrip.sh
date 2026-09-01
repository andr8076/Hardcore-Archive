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

# An extended ACL must be sanitized before setfacl is invoked. Use a fake
# setfacl so this policy test works even on hosts without the ACL package.
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/setfacl" <<'EOF_FAKE_SETFACL'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 1 && $1 == --restore=* ]]
manifest=${1#--restore=}
cp -- "$manifest" "$ACL_CAPTURE"
pwd > "$ACL_CWD_CAPTURE"
EOF_FAKE_SETFACL
chmod 700 "$FAKEBIN/setfacl"
cat > "$META/acl.txt" <<'EOF_SANITIZE_ACL'
# file: tree/file.txt
# owner: root
# group: root
# flags: ---
user::rw-
user:12345:r--
group::r--
mask::r--
other::---
EOF_SANITIZE_ACL
ACL_CAPTURE="$TMP/acl.capture" ACL_CWD_CAPTURE="$TMP/acl.cwd" \
    PATH="$FAKEBIN:$PATH" \
    python3 "$HELPER" --root "$RESTORE" --metadata-dir "$META"
grep -Fq '# file: tree/file.txt' "$TMP/acl.capture"
grep -Fq 'user:12345:r--' "$TMP/acl.capture"
! grep -Eq '^# (owner|group|flags):' "$TMP/acl.capture"
[[ $(cat "$TMP/acl.cwd") == "$RESTORE" ]]

# Parent traversal and symlinks at either the leaf or any parent component must
# be rejected before setfacl sees the path.
printf 'outside\n' > "$TMP/outside"
ln -s "$TMP/outside" "$RESTORE/tree/outside-link"
cat > "$META/acl.txt" <<'EOF_BAD_ACL'
# file: tree/outside-link
user::rw-
user:12345:r--
group::r--
mask::r--
other::---
EOF_BAD_ACL
if PATH="$FAKEBIN:$PATH" python3 "$HELPER" --root "$RESTORE" --metadata-dir "$META" >"$TMP/unsafe.out" 2>&1; then
    printf 'Unsafe ACL symlink was accepted.\n' >&2
    exit 1
fi
grep -Fq 'ACL path is a symlink leaf' "$TMP/unsafe.out"
[[ $(cat "$TMP/outside") == outside ]]

mkdir -p "$RESTORE/tree/real-parent"
printf 'inside\n' > "$RESTORE/tree/real-parent/child.txt"
ln -s real-parent "$RESTORE/tree/alias-parent"
cat > "$META/acl.txt" <<'EOF_PARENT_SYMLINK'
# file: tree/alias-parent/child.txt
user::rw-
user:12345:r--
group::r--
mask::r--
other::---
EOF_PARENT_SYMLINK
if PATH="$FAKEBIN:$PATH" python3 "$HELPER" --root "$RESTORE" --metadata-dir "$META" >"$TMP/parent-symlink.out" 2>&1; then
    printf 'ACL path through a symlinked parent was accepted.\n' >&2
    exit 1
fi
grep -Fq 'ACL path contains a symlink component' "$TMP/parent-symlink.out"

cat > "$META/acl.txt" <<'EOF_TRAVERSAL'
# file: ../outside
user::rw-
group::r--
other::---
EOF_TRAVERSAL
if PATH="$FAKEBIN:$PATH" python3 "$HELPER" --root "$RESTORE" --metadata-dir "$META" >"$TMP/traversal.out" 2>&1; then
    printf 'Traversing ACL path was accepted.\n' >&2
    exit 1
fi
grep -Fq 'unsafe metadata path' "$TMP/traversal.out"

cat > "$META/acl.txt" <<'EOF_UNSUPPORTED_ACL'
# file: tree/file.txt
# command: chmod 777 tree/file.txt
user::rw-
user:12345:r--
group::r--
mask::r--
other::---
EOF_UNSUPPORTED_ACL
if PATH="$FAKEBIN:$PATH" python3 "$HELPER" --root "$RESTORE" --metadata-dir "$META" >"$TMP/unsupported.out" 2>&1; then
    printf 'Unsupported ACL metadata was accepted.\n' >&2
    exit 1
fi
grep -Fq 'unsafe or unsupported ACL entry' "$TMP/unsupported.out"

if [[ -n $CORE ]]; then
    grep -Fq 'getfacl -R -p -n' "$CORE"
    grep -Fq 'restore fails closed rather than silently dropping access controls' "$CORE"
fi

# Exercise real access + default ACL round trips where the host supports them.
if command -v getfacl >/dev/null 2>&1 && command -v setfacl >/dev/null 2>&1 && id nobody >/dev/null 2>&1; then
    nobody_uid=$(id -u nobody)
    mkdir -p "$RESTORE/tree/acl-dir"
    printf 'acl payload\n' > "$RESTORE/tree/acl-dir/child.txt"
    setfacl -m "u:${nobody_uid}:r--" "$RESTORE/tree/file.txt"
    setfacl -m "u:${nobody_uid}:r-x" "$RESTORE/tree/acl-dir"
    setfacl -m "d:u:${nobody_uid}:r-x" "$RESTORE/tree/acl-dir"
    (cd "$RESTORE" && getfacl -R -p -n -- tree/file.txt tree/acl-dir) > "$META/acl.txt"
    setfacl -b "$RESTORE/tree/file.txt"
    setfacl -Rb "$RESTORE/tree/acl-dir"
    python3 "$HELPER" --root "$RESTORE" --metadata-dir "$META"
    getfacl -cpn "$RESTORE/tree/file.txt" | grep -Eq "^user:${nobody_uid}:r--"
    getfacl -cpn "$RESTORE/tree/acl-dir" | grep -Eq "^user:${nobody_uid}:r-x"
    getfacl -cpn "$RESTORE/tree/acl-dir" | grep -Eq "^default:user:${nobody_uid}:r-x"
else
    printf 'Extended ACL round trip skipped: getfacl/setfacl or nobody unavailable.\n'
fi

printf 'Safe metadata round-trip tests passed.\n'
