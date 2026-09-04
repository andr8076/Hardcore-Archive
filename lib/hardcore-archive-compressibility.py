#!/usr/bin/env python3
"""Classify ordinary files as LZMA2-worthy or already effectively incompressible.

The classifier is deliberately conservative: only files that are large enough
and whose representative samples show negligible LZMA2 savings are sent to the
7-Zip Copy lane. Everything else stays in the solid LZMA2 lane.
"""
from __future__ import annotations

import argparse
import lzma
import os
import statistics
from dataclasses import dataclass

MIN_ANALYZE_BYTES = 256 * 1024
WINDOW_BYTES = 128 * 1024
COPY_MEAN_RATIO = 0.995
COPY_MIN_RATIO = 0.980


@dataclass(frozen=True)
class Decision:
    action: str
    sampled_bytes: int
    mean_ratio: float | None
    min_ratio: float | None
    reason: str


def _compress_ratio(data: bytes) -> float:
    if not data:
        return 0.0
    compressor = lzma.LZMACompressor(
        format=lzma.FORMAT_RAW,
        filters=[{"id": lzma.FILTER_LZMA2, "preset": 0}],
    )
    compressed = compressor.compress(data) + compressor.flush()
    return len(compressed) / len(data)


def _sample_offsets(size: int, window: int) -> list[int]:
    if size <= window:
        return [0]
    centers = (0.10, 0.50, 0.90)
    max_offset = max(0, size - window)
    offsets = []
    for fraction in centers:
        center = int(size * fraction)
        offset = max(0, min(max_offset, center - window // 2))
        if offset not in offsets:
            offsets.append(offset)
    return offsets


def classify_file(path: str, expected_size: int) -> Decision:
    if expected_size < MIN_ANALYZE_BYTES:
        return Decision("lzma", 0, None, None, "small-file")

    st = os.stat(path, follow_symlinks=False)
    if not os.path.isfile(path):
        raise ValueError(f"not a regular file: {path}")
    if st.st_size != expected_size:
        raise ValueError(
            f"size changed during classification: {path} "
            f"(inventory={expected_size}, current={st.st_size})"
        )

    window = min(WINDOW_BYTES, expected_size)
    ratios: list[float] = []
    sampled = 0
    with open(path, "rb", buffering=0) as handle:
        for offset in _sample_offsets(expected_size, window):
            handle.seek(offset)
            data = handle.read(window)
            if len(data) != window:
                raise IOError(
                    f"short read while classifying {path}: "
                    f"wanted {window} bytes at {offset}, got {len(data)}"
                )
            sampled += len(data)
            ratios.append(_compress_ratio(data))

    mean_ratio = statistics.fmean(ratios)
    min_ratio = min(ratios)
    if mean_ratio >= COPY_MEAN_RATIO and min_ratio >= COPY_MIN_RATIO:
        return Decision("copy", sampled, mean_ratio, min_ratio, "sample-incompressible")
    return Decision("lzma", sampled, mean_ratio, min_ratio, "sample-compressible-or-uncertain")


def _read_inventory(path: str) -> list[tuple[int, str]]:
    data = open(path, "rb").read().split(b"\0")
    if data and data[-1] == b"":
        data.pop()
    if len(data) % 2:
        raise ValueError("candidate inventory is not size/path NUL pairs")
    items: list[tuple[int, str]] = []
    for index in range(0, len(data), 2):
        size_text, path_bytes = data[index], data[index + 1]
        if not size_text.isascii() or not size_text.isdigit():
            raise ValueError("candidate inventory contains an invalid byte size")
        relative = os.fsdecode(path_bytes)
        if not relative:
            raise ValueError("candidate inventory contains an empty path")
        items.append((int(size_text), relative))
    return items


def classify_inventory(source_parent: str, inventory: str, result: str) -> None:
    source_parent = os.path.realpath(source_parent)
    tmp = f"{result}.tmp.{os.getpid()}"
    try:
        with open(tmp, "w", encoding="utf-8", errors="surrogateescape", newline="\n") as handle:
            for expected_size, relative in _read_inventory(inventory):
                path = os.path.realpath(os.path.join(source_parent, relative))
                if not (path == source_parent or path.startswith(source_parent + os.sep)):
                    raise ValueError(f"candidate path escapes source parent: {relative!r}")
                decision = classify_file(path, expected_size)
                mean = "-" if decision.mean_ratio is None else f"{decision.mean_ratio:.6f}"
                minimum = "-" if decision.min_ratio is None else f"{decision.min_ratio:.6f}"
                handle.write(
                    "\t".join(
                        (
                            decision.action,
                            str(expected_size),
                            str(decision.sampled_bytes),
                            mean,
                            minimum,
                            decision.reason,
                            relative,
                        )
                    )
                    + "\n"
                )
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, result)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-parent", required=True)
    parser.add_argument("--inventory", required=True)
    parser.add_argument("--result", required=True)
    args = parser.parse_args(argv)
    classify_inventory(args.source_parent, args.inventory, args.result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
