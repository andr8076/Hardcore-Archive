#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-container-repack-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

POLICY="$ROOT/hardcore-archive-runner-policy.sh"
POLICY_PATCHER="$ROOT/lib/hardcore-archive-policy-updates.py"
CORE="$ROOT/lib/hardcore-archive-core.sh"
COPY_PATCHER="$ROOT/lib/hardcore-archive-copy-lane.py"
MEDIA_PATCHER="$ROOT/lib/hardcore-archive-media-fixes.py"
CONTAINER_PATCHER="$ROOT/lib/hardcore-archive-container-lane.py"
HELPER="$ROOT/lib/hardcore-archive-container-repack.py"

for file in "$POLICY" "$POLICY_PATCHER" "$CORE" "$COPY_PATCHER" "$MEDIA_PATCHER" "$CONTAINER_PATCHER" "$HELPER"; do
    [[ -f $file ]] || { printf 'Missing test input: %s\n' "$file" >&2; exit 1; }
done

python3 "$POLICY_PATCHER" "$POLICY" "$TMP/policy.sh"
bash -n "$TMP/policy.sh"
python3 "$POLICY_PATCHER" "$TMP/policy.sh" "$TMP/policy-twice.sh"
cmp -s "$TMP/policy.sh" "$TMP/policy-twice.sh" || { printf 'Policy patch is not idempotent.\n' >&2; exit 1; }
grep -Fq 'VIDEO_ENABLED=$(resolve_bool_state "$VIDEO_STATE" "$VIDEO_CONFIG" true)' "$TMP/policy.sh"
grep -Fq 'IMAGE_ENABLED=$(resolve_bool_state "$IMAGE_STATE" "$IMAGE_CONFIG" true)' "$TMP/policy.sh"
grep -Fq 'NESTED_ENABLED=$(resolve_bool_state "$NESTED_STATE" "$NESTED_CONFIG" true)' "$TMP/policy.sh"
grep -Fq 'CONTAINER_ENABLED=$(resolve_bool_state "$CONTAINER_STATE" "$CONTAINER_CONFIG" true)' "$TMP/policy.sh"
grep -Fq -- '--container-repack' "$TMP/policy.sh"
grep -Fq -- '--no-container-repack' "$TMP/policy.sh"

python3 "$COPY_PATCHER" "$CORE" "$TMP/core-copy.sh"
python3 "$MEDIA_PATCHER" "$TMP/core-copy.sh" "$TMP/core-media.sh"
python3 "$CONTAINER_PATCHER" "$TMP/core-media.sh" "$TMP/core-final.sh"
bash -n "$TMP/core-final.sh"
python3 "$CONTAINER_PATCHER" "$TMP/core-final.sh" "$TMP/core-twice.sh"
cmp -s "$TMP/core-final.sh" "$TMP/core-twice.sh" || { printf 'Container engine patch is not idempotent.\n' >&2; exit 1; }
for expected in \
    '# HARDCORE_CONTAINER_REPACK_PATCH_V1' \
    'is_format_preserving_container_path() {' \
    'process_format_preserving_containers() {' \
    '.hardcore-archive-container-manifest.txt' \
    'candidate bytes'
do
    grep -Fq -- "$expected" "$TMP/core-final.sh" || { printf 'Patched core missing: %s\n' "$expected" >&2; exit 1; }
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
