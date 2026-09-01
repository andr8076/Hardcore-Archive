#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
CORE="$ROOT/lib/hardcore-archive-core.sh"

bash -n "$CORE"
python3 - "$CORE" "$ROOT/config" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
config = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")

assert re.search(r"if \[\[ \$VERIFY_MODE == auto \]\]; then\s+VERIFY_MODE_EFFECTIVE=hashes", text)
start = text.index("verify_archive_hashes_single_pass() {")
end = text.index("\n}\n\nverify_archive_by_extraction", start) + 2
body = text[start:end]
assert body.count('"$SEVEN_ZIP" x ') == 1, "hash verification must extract once"
assert "sha256sum -c --quiet" in body
assert " -so " not in body
assert "while " not in body
assert "[[ -s $HASH_MANIFEST ]] || return 0" not in body
assert "if [[ $VERIFY_MODE_EFFECTIVE == integrity ]]; then" in text
assert "one extraction pass" in config
PY

printf 'Default and single-pass hash verification policy tests passed.\n'
