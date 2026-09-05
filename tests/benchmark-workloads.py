#!/usr/bin/env python3
from __future__ import annotations

import csv
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "benchmarks" / "generate-workloads.py"
COMPARATOR = ROOT / "benchmarks" / "compare-results.py"
MEASURE = ROOT / "benchmarks" / "measure-extended.py"


def digest_tree(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        digest.update(str(path.relative_to(root)).encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def write_summary(path: Path, creation: float, archive_bytes: int, peak: int) -> None:
    fields = [
        "profile", "case", "source_files", "source_bytes", "archive_bytes", "ratio_percent",
        "creation_seconds", "verification_seconds", "extraction_seconds",
        "create_average_cpu_percent", "create_user_seconds", "create_system_seconds",
        "peak_memory_kib", "verification_kind",
    ]
    row = {
        "profile": "documents", "case": "hardcore-full", "source_files": "4", "source_bytes": "1000000",
        "archive_bytes": str(archive_bytes), "ratio_percent": "50", "creation_seconds": str(creation),
        "verification_seconds": "2", "extraction_seconds": "3", "create_average_cpu_percent": "150",
        "create_user_seconds": "5", "create_system_seconds": "1", "peak_memory_kib": str(peak),
        "verification_kind": "test",
    }
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t")
        writer.writeheader()
        writer.writerow(row)


def main() -> int:
    subprocess.run([sys.executable, "-m", "py_compile", str(GENERATOR), str(COMPARATOR), str(MEASURE)], check=True)
    with tempfile.TemporaryDirectory(prefix="hardcore-bench-test-") as temp:
        temp_path = Path(temp)
        first = temp_path / "first"
        second = temp_path / "second"
        profiles = "documents,images,containers"
        for output in (first, second):
            subprocess.run(
                [sys.executable, str(GENERATOR), str(output), "--size-mib", "4", "--profiles", profiles],
                check=True,
            )
            for name in profiles.split(","):
                assert (output / name).is_dir(), name
                assert (output / f"{name}.sha256").is_file(), name
        assert digest_tree(first / "documents") == digest_tree(second / "documents")
        assert digest_tree(first / "images") == digest_tree(second / "images")
        assert digest_tree(first / "containers") == digest_tree(second / "containers")

        metric = temp_path / "metric.tsv"
        subprocess.run(
            [sys.executable, str(MEASURE), "--output", str(metric), "--", sys.executable, "-c", "sum(range(10000))"],
            check=True,
        )
        values = metric.read_text(encoding="utf-8").strip().split("\t")
        assert len(values) == 5
        assert float(values[0]) >= 0
        assert int(values[1]) >= 0
        assert float(values[4]) >= 0

        baseline = temp_path / "baseline.tsv"
        good = temp_path / "good.tsv"
        bad = temp_path / "bad.tsv"
        write_summary(baseline, 10.0, 500000, 100000)
        write_summary(good, 10.5, 501000, 105000)
        write_summary(bad, 13.0, 510000, 130000)
        subprocess.run(
            [sys.executable, str(COMPARATOR), str(baseline), str(good), "--fail-on-regression"],
            check=True,
        )
        failed = subprocess.run(
            [sys.executable, str(COMPARATOR), str(baseline), str(bad), "--fail-on-regression"],
            check=False,
        )
        assert failed.returncode == 1

    print("Real-world benchmark workload tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
