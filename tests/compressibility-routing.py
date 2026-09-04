#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import os
import random
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "lib" / "hardcore-archive-compressibility.py"

spec = importlib.util.spec_from_file_location("hardcore_compressibility", HELPER)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def deterministic_bytes(size: int, seed: int) -> bytes:
    return random.Random(seed).randbytes(size)


with tempfile.TemporaryDirectory(prefix="hardcore-compressibility-test.") as tmp:
    parent = Path(tmp)
    source = parent / "source"
    source.mkdir()

    # A misleading compressed-looking suffix must not suppress useful compression.
    fake_zip = source / "fake.zip"
    fake_zip.write_bytes((b"highly compressible text payload\n" * 20000))

    # An unknown suffix with high-entropy content should bypass expensive LZMA2.
    opaque = source / "opaque.unknown"
    opaque.write_bytes(deterministic_bytes(700_000, 1))

    # A normal-looking text suffix is still content-routed, not extension-routed.
    random_txt = source / "random.txt"
    random_txt.write_bytes(deterministic_bytes(700_000, 2))

    # Small files stay in the solid LZMA2 lane; separate Copy streams are not worth it.
    small = source / "small.bin"
    small.write_bytes(deterministic_bytes(32_000, 3))

    # Mixed data remains LZMA2-worthy when representative regions compress.
    mixed = source / "mixed.data"
    mixed.write_bytes(
        b"A" * 180_000
        + deterministic_bytes(500_000, 4)
        + b"B" * 180_000
    )

    # A real compressed payload is recognized even with an unknown suffix.
    packed = source / "packed.weird"
    with zipfile.ZipFile(packed, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        archive.writestr("payload.bin", deterministic_bytes(700_000, 5))

    cases = [fake_zip, opaque, random_txt, small, mixed, packed]
    inventory = parent / "inventory.bin"
    fields: list[bytes] = []
    for path in cases:
        fields.extend(
            [
                str(path.stat().st_size).encode("ascii"),
                os.fsencode(path.relative_to(parent)),
            ]
        )
    inventory.write_bytes(b"\0".join(fields) + b"\0")

    result = parent / "result.tsv"
    module.classify_inventory(str(parent), str(inventory), str(result))

    decisions = {}
    for line in result.read_text(encoding="utf-8").splitlines():
        action, size, sampled, mean, minimum, reason, relative = line.split("\t", 6)
        decisions[relative] = (action, reason, int(size), int(sampled), mean, minimum)

    assert decisions["source/fake.zip"][0] == "lzma", decisions
    assert decisions["source/opaque.unknown"][0] == "copy", decisions
    assert decisions["source/random.txt"][0] == "copy", decisions
    assert decisions["source/small.bin"][:2] == ("lzma", "small-file"), decisions
    assert decisions["source/mixed.data"][0] == "lzma", decisions
    assert decisions["source/packed.weird"][0] == "copy", decisions

    # Classification is conservative and bounded: large files sample at most
    # three windows rather than reading/compressing the entire payload.
    max_sample = 3 * module.WINDOW_BYTES
    assert decisions["source/opaque.unknown"][3] <= max_sample
    assert decisions["source/packed.weird"][3] <= max_sample

print("Content-aware Copy/LZMA routing tests passed.")
