#!/usr/bin/env python3
"""Format-preserving repack for ZIP-based application containers.

The file type and logical payload are preserved.  Entries are rewritten with
maximum broadly-compatible ZIP Deflate compression (or Store for data that is
already compressed), then the candidate is accepted only when it is smaller and
passes payload + format validation.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import os
import pathlib
import shutil
import sys
import tempfile
import zipfile
from dataclasses import dataclass

SUPPORTED_SUFFIXES = {
    ".docx", ".xlsx", ".pptx",
    ".odt", ".ods", ".odp",
    ".epub", ".npz", ".whl", ".jar", ".war",
}

# These payloads are normally already entropy-compressed. Storing them avoids
# wasting Deflate CPU and avoids the small expansion possible on incompressible
# streams. Everything else gets Deflate level 9.
STORE_SUFFIXES = {
    ".7z", ".zip", ".rar", ".cab", ".gz", ".bz2", ".xz", ".zst", ".lz4",
    ".jpg", ".jpeg", ".jpe", ".png", ".gif", ".webp", ".avif", ".heic", ".heif",
    ".mp3", ".aac", ".m4a", ".ogg", ".opus", ".flac", ".wma", ".alac", ".ape",
    ".mp4", ".m4v", ".mkv", ".mov", ".avi", ".webm", ".wmv", ".flv", ".m2ts", ".mts",
    ".pdf",
}

ODF_MIMES = {
    ".odt": b"application/vnd.oasis.opendocument.text",
    ".ods": b"application/vnd.oasis.opendocument.spreadsheet",
    ".odp": b"application/vnd.oasis.opendocument.presentation",
}

OOXML_REQUIRED = {
    ".docx": {"[Content_Types].xml", "_rels/.rels", "word/document.xml"},
    ".xlsx": {"[Content_Types].xml", "_rels/.rels", "xl/workbook.xml"},
    ".pptx": {"[Content_Types].xml", "_rels/.rels", "ppt/presentation.xml"},
}

SIGNATURE_SUFFIXES = (".sf", ".rsa", ".dsa", ".ec")


@dataclass
class Decision:
    action: str
    original: str
    archived: str
    original_bytes: int
    candidate_bytes: int
    archived_bytes: int
    reason: str

    def tsv(self) -> str:
        return "\t".join(
            [
                self.action,
                self.original,
                self.archived,
                str(self.original_bytes),
                str(self.candidate_bytes),
                str(self.archived_bytes),
                self.reason,
            ]
        )


def safe_relative(path: str) -> bool:
    p = pathlib.PurePosixPath(path.replace("\\", "/"))
    if p.is_absolute():
        return False
    parts = p.parts
    if any(part == ".." for part in parts):
        return False
    if parts and len(parts[0]) >= 2 and parts[0][1] == ":":
        return False
    return True


def is_signed_container(suffix: str, names: list[str]) -> bool:
    lower = [n.lower() for n in names]
    if suffix in OOXML_REQUIRED:
        if any(n.startswith("_xmlsignatures/") for n in lower):
            return True
        if any(n.endswith("origin.sigs") for n in lower):
            return True
    if suffix in ODF_MIMES:
        signed = {
            "meta-inf/documentsignatures.xml",
            "meta-inf/macrosignatures.xml",
            "meta-inf/xadessignatures.xml",
        }
        if any(n in signed for n in lower):
            return True
    if suffix in {".jar", ".war"}:
        for n in lower:
            if not n.startswith("meta-inf/"):
                continue
            base = n.rsplit("/", 1)[-1]
            if base.startswith("sig-") or base.endswith(SIGNATURE_SUFFIXES):
                return True
    return False


def expected_mimetype(suffix: str) -> bytes | None:
    if suffix == ".epub":
        return b"application/epub+zip"
    return ODF_MIMES.get(suffix)


def validate_structure(zf: zipfile.ZipFile, suffix: str) -> tuple[bool, str]:
    infos = zf.infolist()
    names = [i.filename for i in infos]
    name_set = set(names)

    if any(not safe_relative(name) for name in names):
        return False, "unsafe-entry-path"
    if len(names) != len(name_set):
        # Duplicate names are legal ZIP but rebuilding them can change how
        # applications resolve entries. Preserve the original instead.
        return False, "duplicate-entry-names"
    if any(i.flag_bits & 0x1 for i in infos):
        return False, "encrypted-entry"
    if is_signed_container(suffix, names):
        return False, "signed-container-preserved"

    if suffix in OOXML_REQUIRED:
        missing = OOXML_REQUIRED[suffix] - name_set
        if missing:
            return False, "invalid-ooxml-structure"
    elif suffix in ODF_MIMES:
        if "mimetype" not in name_set:
            return False, "invalid-odf-structure"
        try:
            if zf.read("mimetype") != ODF_MIMES[suffix]:
                return False, "invalid-odf-mimetype"
        except (KeyError, RuntimeError, NotImplementedError):
            return False, "invalid-odf-mimetype"
    elif suffix == ".epub":
        if "mimetype" not in name_set or "META-INF/container.xml" not in name_set:
            return False, "invalid-epub-structure"
        try:
            if zf.read("mimetype") != b"application/epub+zip":
                return False, "invalid-epub-mimetype"
        except (KeyError, RuntimeError, NotImplementedError):
            return False, "invalid-epub-mimetype"
    elif suffix == ".npz":
        if not any(n.lower().endswith(".npy") for n in names if not n.endswith("/")):
            return False, "invalid-npz-structure"
    elif suffix == ".whl":
        lower = [n.lower() for n in names]
        if not any(".dist-info/" in n and n.endswith("wheel") for n in lower):
            return False, "invalid-wheel-structure"
        if not any(".dist-info/" in n and n.endswith("record") for n in lower):
            return False, "invalid-wheel-structure"

    bad = zf.testzip()
    if bad is not None:
        return False, f"crc-failure:{bad}"
    return True, "ok"


def copy_info(info: zipfile.ZipInfo, compression: int) -> zipfile.ZipInfo:
    out = zipfile.ZipInfo(filename=info.filename, date_time=info.date_time)
    out.compress_type = compression
    out.comment = info.comment
    out.extra = info.extra
    out.internal_attr = info.internal_attr
    out.external_attr = info.external_attr
    out.create_system = info.create_system
    out.create_version = info.create_version
    out.extract_version = info.extract_version
    out.volume = getattr(info, "volume", 0)
    out.file_size = info.file_size
    # UTF-8/data-descriptor bits are recalculated by zipfile. Encryption is
    # rejected before this point.
    return out


def compression_for(info: zipfile.ZipInfo, suffix: str) -> int:
    if info.is_dir():
        return zipfile.ZIP_STORED
    if info.filename == "mimetype" and (suffix in ODF_MIMES or suffix == ".epub"):
        return zipfile.ZIP_STORED
    inner_suffix = pathlib.PurePosixPath(info.filename).suffix.lower()
    if inner_suffix in STORE_SUFFIXES:
        return zipfile.ZIP_STORED
    return zipfile.ZIP_DEFLATED


def stream_hash(reader) -> str:
    digest = hashlib.sha256()
    while True:
        chunk = reader.read(1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
    return digest.hexdigest()


def payload_fingerprints(zf: zipfile.ZipFile) -> list[tuple[str, int, str]]:
    result: list[tuple[str, int, str]] = []
    for info in zf.infolist():
        if info.is_dir():
            result.append((info.filename, 0, ""))
            continue
        with zf.open(info, "r") as handle:
            result.append((info.filename, info.file_size, stream_hash(handle)))
    return sorted(result, key=lambda item: item[0])


def write_candidate(source: zipfile.ZipFile, destination: pathlib.Path, suffix: str) -> None:
    infos = source.infolist()
    # EPUB and ODF require mimetype to be first and stored. Keep all other
    # entries in source order.
    if suffix in ODF_MIMES or suffix == ".epub":
        infos = sorted(infos, key=lambda i: 0 if i.filename == "mimetype" else 1)

    with zipfile.ZipFile(
        destination,
        mode="w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
        allowZip64=True,
    ) as target:
        target.comment = source.comment
        for info in infos:
            method = compression_for(info, suffix)
            out_info = copy_info(info, method)
            if info.is_dir():
                target.writestr(out_info, b"")
                continue
            with source.open(info, "r") as src, target.open(out_info, "w", force_zip64=info.file_size >= (1 << 31)) as dst:
                shutil.copyfileobj(src, dst, length=1024 * 1024)


def validate_candidate(original: pathlib.Path, candidate: pathlib.Path, suffix: str) -> tuple[bool, str]:
    try:
        with zipfile.ZipFile(original, "r") as src, zipfile.ZipFile(candidate, "r") as dst:
            ok, reason = validate_structure(dst, suffix)
            if not ok:
                return False, reason
            # Format-specific placement rules.
            if suffix in ODF_MIMES or suffix == ".epub":
                infos = dst.infolist()
                if not infos or infos[0].filename != "mimetype" or infos[0].compress_type != zipfile.ZIP_STORED:
                    return False, "mimetype-not-first-and-stored"
            if payload_fingerprints(src) != payload_fingerprints(dst):
                return False, "payload-mismatch"
    except (OSError, zipfile.BadZipFile, RuntimeError, NotImplementedError, ValueError) as exc:
        return False, f"candidate-validation-failed:{exc.__class__.__name__}"
    return True, "ok"


def process_one(source_parent: pathlib.Path, stage_parent: pathlib.Path, relative: str) -> Decision:
    source = source_parent / relative
    original_bytes = source.stat().st_size
    suffix = source.suffix.lower()
    if suffix not in SUPPORTED_SUFFIXES:
        return Decision("original", relative, relative, original_bytes, 0, original_bytes, "unsupported-container-type")

    try:
        with zipfile.ZipFile(source, "r") as zf:
            ok, reason = validate_structure(zf, suffix)
            if not ok:
                return Decision("original", relative, relative, original_bytes, 0, original_bytes, reason)
    except (OSError, zipfile.BadZipFile, RuntimeError, NotImplementedError, ValueError) as exc:
        return Decision("original", relative, relative, original_bytes, 0, original_bytes, f"invalid-container:{exc.__class__.__name__}")

    stage_file = stage_parent / relative
    stage_file.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=".container-repack-", suffix=suffix, dir=stage_file.parent)
    os.close(fd)
    temp = pathlib.Path(temp_name)
    try:
        with zipfile.ZipFile(source, "r") as src:
            write_candidate(src, temp, suffix)
        candidate_bytes = temp.stat().st_size
        ok, reason = validate_candidate(source, temp, suffix)
        if not ok:
            return Decision("original", relative, relative, original_bytes, candidate_bytes, original_bytes, reason)
        if candidate_bytes >= original_bytes:
            return Decision("original", relative, relative, original_bytes, candidate_bytes, original_bytes, "candidate-not-smaller")
        os.replace(temp, stage_file)
        return Decision("repacked", relative, relative, original_bytes, candidate_bytes, candidate_bytes, "candidate-smaller")
    except (OSError, zipfile.BadZipFile, RuntimeError, NotImplementedError, ValueError) as exc:
        candidate_bytes = temp.stat().st_size if temp.exists() else 0
        return Decision("original", relative, relative, original_bytes, candidate_bytes, original_bytes, f"rebuild-failed:{exc.__class__.__name__}")
    finally:
        try:
            temp.unlink()
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-parent", required=True)
    parser.add_argument("--stage-parent", required=True)
    parser.add_argument("--list", required=True)
    parser.add_argument("--result", required=True)
    args = parser.parse_args()

    source_parent = pathlib.Path(args.source_parent)
    stage_parent = pathlib.Path(args.stage_parent)
    list_path = pathlib.Path(args.list)
    result_path = pathlib.Path(args.result)
    stage_parent.mkdir(parents=True, exist_ok=True)

    had_error = False
    with list_path.open("r", encoding="utf-8", errors="surrogateescape") as listing, result_path.open(
        "w", encoding="utf-8", errors="surrogateescape"
    ) as result:
        for line in listing:
            relative = line.rstrip("\n")
            if not relative:
                continue
            try:
                decision = process_one(source_parent, stage_parent, relative)
            except Exception as exc:  # fail safe per-file; caller preserves original
                had_error = True
                try:
                    size = (source_parent / relative).stat().st_size
                except OSError:
                    size = 0
                decision = Decision(
                    "original", relative, relative, size, 0, size, f"unexpected-error:{exc.__class__.__name__}"
                )
            result.write(decision.tsv() + "\n")
            result.flush()

    return 1 if had_error else 0


if __name__ == "__main__":
    raise SystemExit(main())
