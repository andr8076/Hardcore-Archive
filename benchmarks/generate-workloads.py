#!/usr/bin/env python3
"""Generate reproducible real-world workload corpora for Hardcore Archive."""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tarfile
import zipfile
import zlib

FIXED_ZIP_TIME = (2020, 1, 1, 0, 0, 0)
FIXED_MTIME = 1_577_836_800
MIB = 1024 * 1024
ALL_PROFILES = (
    "documents",
    "small-files",
    "images",
    "archives",
    "containers",
    "mixed",
    "everything",
)


def deterministic_noise(size: int, namespace: str = "noise") -> bytes:
    output = bytearray()
    counter = 0
    while len(output) < size:
        output.extend(hashlib.sha256(f"hardcore:{namespace}:{counter}".encode()).digest())
        counter += 1
    return bytes(output[:size])


def write_to_size(path: Path, block: bytes, size: int) -> None:
    if not block:
        raise ValueError("write_to_size requires a non-empty block")
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        remaining = size
        while remaining:
            chunk = block[:remaining]
            handle.write(chunk)
            remaining -= len(chunk)


def zip_write(archive: zipfile.ZipFile, name: str, data: bytes | str, level: int = 4) -> None:
    info = zipfile.ZipInfo(name, FIXED_ZIP_TIME)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o100644 << 16
    info._compresslevel = level
    archive.writestr(info, data)


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    body = kind + payload
    return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def make_png(path: Path, width: int, height: int, variant: int) -> None:
    """Write a valid, intentionally lightly-compressed RGB PNG."""
    path.parent.mkdir(parents=True, exist_ok=True)
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # no row filter: intentionally leaves optimization work
        for x in range(width):
            tile = ((x // 32) ^ (y // 32) ^ variant) & 7
            raw.extend(
                (
                    (x + variant * 17 + tile * 23) & 255,
                    (y + variant * 29 + tile * 11) & 255,
                    ((x + y) // 2 + tile * 31) & 255,
                )
            )
    data = bytearray(b"\x89PNG\r\n\x1a\n")
    data += png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    data += png_chunk(b"IDAT", zlib.compress(bytes(raw), level=1))
    data += png_chunk(b"IEND", b"")
    path.write_bytes(data)


def make_docx(path: Path, paragraphs: int = 4000) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    document = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body>"
    document += "".join(
        f"<w:p><w:r><w:t>Archive benchmark paragraph {i:05d} group {i % 37}</w:t></w:r></w:p>"
        for i in range(paragraphs)
    )
    document += "</w:body></w:document>"
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=3) as archive:
        zip_write(archive, "[Content_Types].xml", "<Types xmlns='http://schemas.openxmlformats.org/package/2006/content-types'/>", 3)
        zip_write(archive, "_rels/.rels", "<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'/>", 3)
        zip_write(archive, "word/document.xml", document, 3)


def make_xlsx(path: Path, rows: int = 12000) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet = "<worksheet xmlns='http://schemas.openxmlformats.org/spreadsheetml/2006/main'><sheetData>"
    sheet += "".join(
        f"<row r='{row}'><c r='A{row}' t='inlineStr'><is><t>group-{row % 50}</t></is></c>"
        f"<c r='B{row}'><v>{row}</v></c><c r='C{row}'><v>{row % 997}</v></c></row>"
        for row in range(1, rows + 1)
    )
    sheet += "</sheetData></worksheet>"
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=3) as archive:
        zip_write(archive, "[Content_Types].xml", "<Types xmlns='http://schemas.openxmlformats.org/package/2006/content-types'/>", 3)
        zip_write(archive, "xl/worksheets/sheet1.xml", sheet, 3)
        zip_write(archive, "xl/workbook.xml", "<workbook xmlns='http://schemas.openxmlformats.org/spreadsheetml/2006/main'/>", 3)


def make_tar_gz(path: Path, entries: dict[str, bytes], compresslevel: int = 4) -> None:
    """Create TAR+GZIP with fixed member metadata and gzip mtime."""
    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w", format=tarfile.PAX_FORMAT) as archive:
        for name in sorted(entries):
            payload = entries[name]
            info = tarfile.TarInfo(name)
            info.size = len(payload)
            info.mtime = FIXED_MTIME
            info.mode = 0o644
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            archive.addfile(info, io.BytesIO(payload))
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, compresslevel=compresslevel, mtime=0) as compressed:
            compressed.write(tar_buffer.getvalue())


def add_documents(root: Path, budget: int) -> None:
    block = (
        "Hardcore Archive workload. Repeated prose, timestamps, identifiers and UTF-8 æøå. "
        "The purpose is realistic compressible document/log data.\n"
    ).encode() * 256
    write_to_size(root / "documents" / "notes.txt", block, max(MIB, budget // 3))
    log = root / "documents" / "events.jsonl"
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w", encoding="utf-8") as handle:
        i = 0
        target = max(MIB, budget // 4)
        while handle.tell() < target:
            handle.write(json.dumps({"id": i, "group": i % 41, "state": "stored", "message": f"event-{i % 250}"}, separators=(",", ":")) + "\n")
            i += 1
    write_to_size(root / "documents" / "database-page-pattern.bin", bytes(range(256)) * 1024, max(MIB, budget // 5))
    packed = gzip.compress(block * 8, compresslevel=9, mtime=0)
    (root / "documents" / "already-packed.bin.gz").write_bytes(packed)


def add_small_files(root: Path, size_mib: int) -> None:
    target = root / "small-files"
    target.mkdir(parents=True, exist_ok=True)
    count = min(20_000, max(1_000, size_mib * 100))
    for i in range(count):
        group = target / f"group-{i % 32:02d}"
        group.mkdir(exist_ok=True)
        (group / f"item-{i:05d}.txt").write_text(
            f"id={i}\ngroup={i % 32}\nstatus=archived\nvalue={i % 997}\n" * 5,
            encoding="utf-8",
        )


def add_images(root: Path, size_mib: int) -> None:
    count = min(16, max(4, size_mib // 4))
    for i in range(count):
        make_png(root / "images" / f"scene-{i:02d}.png", 1024, 768, i)


def add_archives(root: Path, budget: int) -> None:
    target = root / "archives"
    target.mkdir(parents=True, exist_ok=True)
    text = b"Nested archive benchmark payload line. " * 4096
    pattern = bytes(range(256)) * 4096
    with zipfile.ZipFile(target / "nested.zip", "w", compression=zipfile.ZIP_DEFLATED, compresslevel=3) as archive:
        zip_write(archive, "docs/readme.txt", text, 3)
        zip_write(archive, "data/pattern.bin", pattern, 3)
        zip_write(archive, "data/noise.bin", deterministic_noise(max(MIB, budget // 16), "nested"), 3)
    repeated_size = max(MIB, budget // 8)
    pattern_size = max(MIB, budget // 8)
    repeated = (text * ((repeated_size + len(text) - 1) // len(text)))[:repeated_size]
    patterned = (pattern * ((pattern_size + len(pattern) - 1) // len(pattern)))[:pattern_size]
    make_tar_gz(target / "payload.tar.gz", {"payload/repeated.log": repeated, "payload/pattern.bin": patterned})


def add_containers(root: Path) -> None:
    make_docx(root / "containers" / "report.docx")
    make_xlsx(root / "containers" / "records.xlsx")
    jar = root / "containers" / "sample.jar"
    jar.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(jar, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=3) as archive:
        zip_write(archive, "META-INF/MANIFEST.MF", "Manifest-Version: 1.0\nCreated-By: Hardcore benchmark\n", 3)
        for i in range(50):
            zip_write(archive, f"data/record-{i:03d}.txt", f"record={i}\n" * 400, 3)


def add_media(root: Path) -> None:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("media workload requested but ffmpeg is not installed")
    target = root / "media"
    target.mkdir(parents=True, exist_ok=True)
    specs = (
        ("motion", "testsrc2=size=1280x720:rate=30", 700),
        ("bars", "smptebars=size=1280x720:rate=30", 1100),
    )
    for name, source, tone in specs:
        subprocess.run(
            [
                ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", source,
                "-f", "lavfi", "-i", f"sine=frequency={tone}:sample_rate=48000",
                "-t", "6", "-c:v", "libx264", "-crf", "16", "-preset", "medium",
                "-c:a", "flac", str(target / f"{name}.mkv"),
            ],
            check=True,
        )


def add_mixed(root: Path, size_mib: int, include_media: bool, everything: bool = False) -> None:
    budget = size_mib * MIB
    add_documents(root, budget // 2)
    add_images(root, max(8, size_mib // 2))
    add_archives(root, budget // 2)
    add_containers(root)
    noise_size = max(MIB, budget // 6)
    write_to_size(root / "binary" / "incompressible.bin", deterministic_noise(noise_size, "mixed"), noise_size)
    if everything:
        add_small_files(root, max(8, size_mib // 2))
    if include_media:
        add_media(root)


def normalize_times(root: Path) -> None:
    for path in sorted(root.rglob("*"), reverse=True):
        if path.is_symlink():
            continue
        path.chmod(0o755 if path.is_dir() else 0o644)
        os.utime(path, (FIXED_MTIME, FIXED_MTIME), follow_symlinks=False)
    root.chmod(0o755)
    os.utime(root, (FIXED_MTIME, FIXED_MTIME), follow_symlinks=False)


def write_manifest(profile: Path) -> Path:
    manifest = profile.parent / f"{profile.name}.sha256"
    with manifest.open("w", encoding="utf-8") as handle:
        for path in sorted(p for p in profile.rglob("*") if p.is_file()):
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            handle.write(f"{digest}  {path.relative_to(profile)}\n")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", nargs="?", default="benchmarks/workloads")
    parser.add_argument("--size-mib", type=int, default=64, help="approximate scale for data-heavy profiles")
    parser.add_argument("--profiles", default=",".join(ALL_PROFILES), help="comma-separated profile names")
    parser.add_argument("--with-media", action="store_true", help="include media in mixed/everything and create the media profile")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    if args.size_mib < 4:
        parser.error("--size-mib must be at least 4")

    requested = [item.strip() for item in args.profiles.split(",") if item.strip()]
    allowed = set(ALL_PROFILES) | {"media"}
    unknown = [item for item in requested if item not in allowed]
    if unknown:
        parser.error("unknown profile(s): " + ", ".join(unknown))
    if "media" in requested and not args.with_media:
        parser.error("the media profile requires --with-media")

    output = Path(args.output).resolve()
    marker = output / ".hardcore-benchmark-workloads-v1"
    if output.exists():
        if not args.force:
            raise SystemExit(f"workload root already exists: {output}; use --force")
        if not marker.is_file():
            raise SystemExit(f"refusing --force because this is not a marked workload root: {output}")
        shutil.rmtree(output)
    output.mkdir(parents=True)
    marker.write_text("Generated by benchmarks/generate-workloads.py\n", encoding="utf-8")

    for name in requested:
        profile = output / name
        profile.mkdir()
        budget = args.size_mib * MIB
        if name == "documents":
            add_documents(profile, budget)
        elif name == "small-files":
            add_small_files(profile, args.size_mib)
        elif name == "images":
            add_images(profile, args.size_mib)
        elif name == "media":
            add_media(profile)
        elif name == "archives":
            add_archives(profile, budget)
        elif name == "containers":
            add_containers(profile)
        elif name == "mixed":
            add_mixed(profile, args.size_mib, args.with_media, False)
        elif name == "everything":
            add_mixed(profile, args.size_mib, args.with_media, True)
        normalize_times(profile)
        manifest = write_manifest(profile)
        print(f"{name}: {profile} ({manifest.name})")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
