#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-container-repack-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

POLICY="$ROOT/hardcore-archive-runner-policy.sh"
CORE="$ROOT/lib/hardcore-archive-core.sh"
HELPER="$ROOT/lib/hardcore-archive-container-repack.py"

for file in "$POLICY" "$CORE" "$HELPER"; do
    [[ -f $file ]] || { printf 'Missing container production dependency: %s\n' "$file" >&2; exit 1; }
done
bash -n "$POLICY"
bash -n "$CORE"
python3 -m py_compile "$HELPER"

# The default-on CLI/config policy is checked in directly; do not reconstruct a
# patched frontend just to assert the live production settings.
grep -Fq 'VIDEO_ENABLED=$(resolve_bool_state "$VIDEO_STATE" "$VIDEO_CONFIG" true)' "$POLICY"
grep -Fq 'IMAGE_ENABLED=$(resolve_bool_state "$IMAGE_STATE" "$IMAGE_CONFIG" true)' "$POLICY"
grep -Fq 'NESTED_ENABLED=$(resolve_bool_state "$NESTED_STATE" "$NESTED_CONFIG" true)' "$POLICY"
grep -Fq 'CONTAINER_ENABLED=$(resolve_bool_state "$CONTAINER_STATE" "$CONTAINER_CONFIG" true)' "$POLICY"
grep -Fq -- '--container-repack' "$POLICY"
grep -Fq -- '--no-container-repack' "$POLICY"

# Container orchestration is already part of the checked-in static engine.
for expected in \
    '# HARDCORE_CONTAINER_REPACK_PATCH_V1' \
    'is_format_preserving_container_path() {' \
    'process_format_preserving_containers() {' \
    '.hardcore-archive-container-manifest.txt' \
    'candidate bytes'
do
    grep -Fq -- "$expected" "$CORE" || { printf 'Static core missing container policy: %s\n' "$expected" >&2; exit 1; }
done

mkdir -p "$TMP/source" "$TMP/stage"
python3 - "$TMP/source" <<'PY'
import pathlib, sys, zipfile
root=pathlib.Path(sys.argv[1])

def docx(path, compression, signed=False):
    with zipfile.ZipFile(path,'w',compression=compression,compresslevel=9 if compression==zipfile.ZIP_DEFLATED else None) as z:
        z.writestr('[Content_Types].xml','<Types>'+('A'*200000)+'</Types>')
        z.writestr('_rels/.rels','<Relationships>'+('B'*50000)+'</Relationships>')
        z.writestr('word/document.xml','<document>'+('hello world '*30000)+'</document>')
        if signed: z.writestr('_xmlsignatures/sig1.xml','signature')

docx(root/'poor.docx',zipfile.ZIP_STORED)
docx(root/'strong.docx',zipfile.ZIP_DEFLATED)
docx(root/'signed.docx',zipfile.ZIP_STORED,True)
with zipfile.ZipFile(root/'book.epub','w',compression=zipfile.ZIP_STORED) as z:
    z.writestr('META-INF/container.xml','<container>'+('X'*10000)+'</container>')
    z.writestr('mimetype','application/epub+zip')
    z.writestr('OEBPS/chapter.xhtml','<html>'+('text '*50000)+'</html>')
PY
printf '%s\n' poor.docx strong.docx signed.docx book.epub > "$TMP/list"
python3 "$HELPER" --source-parent "$TMP/source" --stage-parent "$TMP/stage" --list "$TMP/list" --result "$TMP/result"

grep -Fq $'repacked\tpoor.docx\tpoor.docx' "$TMP/result"
grep -Fq $'original\tstrong.docx\tstrong.docx' "$TMP/result"
grep -Fq $'signed-container-preserved' "$TMP/result"
grep -Fq $'repacked\tbook.epub\tbook.epub' "$TMP/result"

python3 - "$TMP" <<'PY'
import hashlib, pathlib, sys, zipfile
root=pathlib.Path(sys.argv[1])

def payload(path):
    with zipfile.ZipFile(path) as z:
        return sorted((i.filename, hashlib.sha256(z.read(i)).hexdigest()) for i in z.infolist() if not i.is_dir())
assert payload(root/'source'/'poor.docx') == payload(root/'stage'/'poor.docx')
with zipfile.ZipFile(root/'stage'/'book.epub') as z:
    first=z.infolist()[0]
    assert first.filename == 'mimetype'
    assert first.compress_type == zipfile.ZIP_STORED
    assert z.read('mimetype') == b'application/epub+zip'
PY

printf 'Default-on + format-preserving container repack tests passed.\n'
