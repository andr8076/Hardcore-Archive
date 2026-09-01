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

# The shipped/default path must be integrity-only: no payload extraction and no
# SHA-256 content comparison unless the user explicitly requests a strong mode.
assert re.search(r"(?m)^VERIFY_MODE=integrity$", config)
assert not re.search(r"(?m)^VERIFY_MODE=auto$", config)
assert "without extracting payloads again or comparing content hashes" in config
assert "if [[ $VERIFY_MODE_EFFECTIVE == integrity ]]; then" in text

# Explicit strong verification remains available and must stay single-pass.
assert re.search(r"if \[\[ \$VERIFY_MODE == auto \]\]; then\s+VERIFY_MODE_EFFECTIVE=hashes", text)
start = text.index("verify_archive_hashes_single_pass() {")
end = text.index("\n}\n\nverify_archive_by_extraction", start) + 2
body = text[start:end]
assert body.count('"$SEVEN_ZIP" x ') == 1, "explicit hash verification must extract once"
assert "sha256sum -c --quiet" in body
assert " -so " not in body
assert "while " not in body
assert "[[ -s $HASH_MANIFEST ]] || return 0" not in body
PY

printf 'Default integrity and explicit single-pass hash verification policy tests passed.\n'
