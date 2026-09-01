#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=${ROOT_OVERRIDE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
CORE="$ROOT/lib/hardcore-archive-core.sh"
VERIFY="$ROOT/lib/verify.sh"
SCHEDULER="$ROOT/lib/scheduler.sh"

bash -n "$CORE"
bash -n "$VERIFY"
bash -n "$SCHEDULER"
python3 - "$CORE" "$ROOT/config" "$VERIFY" "$SCHEDULER" <<'PY'
import pathlib
import re
import sys

core = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
config = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
verify = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
scheduler = pathlib.Path(sys.argv[4]).read_text(encoding="utf-8")

# The shipped/default path must be integrity-only: no payload extraction and no
# SHA-256 content comparison unless the user explicitly requests a strong mode.
assert re.search(r"(?m)^VERIFY_MODE=integrity$", config)
assert not re.search(r"(?m)^VERIFY_MODE=auto$", config)
assert "without extracting payloads again or comparing content hashes" in config
assert "if [[ $VERIFY_MODE_EFFECTIVE == integrity ]]; then" in core

# Explicit strong verification remains one archive extraction. The following
# sha256sum -c is transparently split into concurrent workers only on storage
# that is positively identified as non-rotational.
assert re.search(r"if \[\[ \$VERIFY_MODE == auto \]\]; then\s+VERIFY_MODE_EFFECTIVE=hashes", core)
start = core.index("verify_archive_hashes_single_pass() {")
end = core.index("\n}\n\nverify_archive_by_extraction", start) + 2
body = core[start:end]
assert body.count('"$SEVEN_ZIP" x ') == 1, "explicit hash verification must extract once"
assert "sha256sum -c --quiet" in body
assert " -so " not in body
assert "while " not in body
assert "hardcore_enable_adaptive_hash_verifier" in verify
assert "hardcore_parallel_sha256_check" in verify
assert "lsblk -ndo ROTA" in verify
assert "jobs > 4" in verify
assert "export -f sha256sum" in verify
assert "hardcore_enable_adaptive_hash_verifier" in scheduler
PY

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-hash-policy-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

VERIFY_ROOT="$TMP/verify"
mkdir -p "$VERIFY_ROOT"
for index in 1 2 3 4 5 6 7 8; do
    printf 'hash-policy-payload-%s\n' "$index" > "$VERIFY_ROOT/file-$index.txt"
done
(
    cd "$VERIFY_ROOT"
    sha256sum -- file-*.txt > "$TMP/manifest.sha256"
)

# Build a tiny scheduler environment around the real verify module. The fake
# external sha256sum records each worker invocation and then delegates to the
# real GNU implementation. Four requested workers must produce four manifest
# chunks and preserve the exact success/failure semantics of sha256sum -c.
FAKELIB="$TMP/lib"
FAKEBIN="$TMP/bin"
mkdir -p "$FAKELIB" "$FAKEBIN"
cp -- "$SCHEDULER" "$FAKELIB/scheduler.sh"
cp -- "$VERIFY" "$FAKELIB/verify.sh"
for module in common platform reporting inventory restore planner doctor images video nested containers visual archive; do
    : > "$FAKELIB/$module.sh"
done
REAL_SHA256SUM=$(type -P sha256sum)
cat > "$FAKEBIN/sha256sum" <<'EOF_FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HASH_CALL_LOG"
exec "$REAL_SHA256SUM_UNDER_TEST" "$@"
EOF_FAKE
chmod 700 "$FAKEBIN/sha256sum"

HASH_CALL_LOG="$TMP/hash.calls" \
REAL_SHA256SUM_UNDER_TEST="$REAL_SHA256SUM" \
PATH="$FAKEBIN:$PATH" \
bash -c '
    set -Eeuo pipefail
    source "$1"
    hardcore_enable_adaptive_hash_verifier
    export HARDCORE_HASH_JOBS=4
    cd "$2"
    bash -c '\''sha256sum -c --quiet "$1"'\'' _ "$3"
' _ "$FAKELIB/scheduler.sh" "$VERIFY_ROOT" "$TMP/manifest.sha256"
[[ $(wc -l < "$TMP/hash.calls") == 4 ]]
grep -Fq -- '-c --quiet' "$TMP/hash.calls"

printf 'corruption\n' >> "$VERIFY_ROOT/file-3.txt"
if HASH_CALL_LOG="$TMP/hash-corrupt.calls" \
   REAL_SHA256SUM_UNDER_TEST="$REAL_SHA256SUM" \
   PATH="$FAKEBIN:$PATH" \
   bash -c '
       set -Eeuo pipefail
       source "$1"
       hardcore_enable_adaptive_hash_verifier
       export HARDCORE_HASH_JOBS=4
       cd "$2"
       sha256sum -c --quiet "$3"
   ' _ "$FAKELIB/scheduler.sh" "$VERIFY_ROOT" "$TMP/manifest.sha256" \
   >"$TMP/corrupt.out" 2>&1; then
    printf 'Corrupted payload passed parallel SHA-256 verification.\n' >&2
    exit 1
fi
grep -Fq 'FAILED' "$TMP/corrupt.out"

# Invalid worker overrides fail instead of silently changing verification policy.
if HASH_CALL_LOG="$TMP/hash-invalid.calls" \
   REAL_SHA256SUM_UNDER_TEST="$REAL_SHA256SUM" \
   PATH="$FAKEBIN:$PATH" \
   bash -c '
       set -Eeuo pipefail
       source "$1"
       hardcore_enable_adaptive_hash_verifier
       export HARDCORE_HASH_JOBS=invalid
       cd "$2"
       sha256sum -c --quiet "$3"
   ' _ "$FAKELIB/scheduler.sh" "$VERIFY_ROOT" "$TMP/manifest.sha256" \
   >"$TMP/invalid.out" 2>&1; then
    printf 'Invalid HARDCORE_HASH_JOBS value was accepted.\n' >&2
    exit 1
fi
grep -Fq 'HARDCORE_HASH_JOBS must be auto or a positive integer' "$TMP/invalid.out"

printf 'Default integrity and adaptive strong hash verification policy tests passed.\n'
