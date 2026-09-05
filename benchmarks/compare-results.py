#!/usr/bin/env python3
"""Compare two real-world benchmark summaries and flag material regressions."""
from __future__ import annotations

import argparse
import csv
from pathlib import Path
import sys


METRICS = (
    ("archive_bytes", "size", False),
    ("creation_seconds", "create", False),
    ("verification_seconds", "verify", False),
    ("extraction_seconds", "extract", False),
    ("peak_memory_kib", "memory", False),
)


def load(path: Path) -> dict[tuple[str, str], dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    required = {"profile", "case"} | {item[0] for item in METRICS}
    if not rows:
        raise ValueError(f"empty benchmark summary: {path}")
    missing = required - set(rows[0])
    if missing:
        raise ValueError(f"{path} is missing columns: {', '.join(sorted(missing))}")
    return {(row["profile"], row["case"]): row for row in rows}


def percent_change(old: float, new: float) -> float:
    if old == 0:
        return 0.0 if new == 0 else float("inf")
    return (new - old) / old * 100.0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("baseline")
    parser.add_argument("current")
    parser.add_argument("--size-regression", type=float, default=0.5, help="allowed archive-size increase percent")
    parser.add_argument("--time-regression", type=float, default=10.0, help="allowed phase-time increase percent")
    parser.add_argument("--memory-regression", type=float, default=15.0, help="allowed peak-memory increase percent")
    parser.add_argument("--fail-on-regression", action="store_true")
    args = parser.parse_args()
    if min(args.size_regression, args.time_regression, args.memory_regression) < 0:
        parser.error("regression thresholds cannot be negative")

    try:
        baseline = load(Path(args.baseline))
        current = load(Path(args.current))
    except (OSError, ValueError) as exc:
        print(f"comparison error: {exc}", file=sys.stderr)
        return 2

    common = sorted(set(baseline) & set(current))
    if not common:
        print("comparison error: summaries contain no matching profile/case rows", file=sys.stderr)
        return 2

    thresholds = {
        "archive_bytes": args.size_regression,
        "creation_seconds": args.time_regression,
        "verification_seconds": args.time_regression,
        "extraction_seconds": args.time_regression,
        "peak_memory_kib": args.memory_regression,
    }
    regressions = 0
    print("profile\tcase\tmetric\tbaseline\tcurrent\tchange_percent\tstatus")
    for key in common:
        old_row = baseline[key]
        new_row = current[key]
        for column, label, _ in METRICS:
            try:
                old = float(old_row[column])
                new = float(new_row[column])
            except ValueError:
                print(f"comparison error: non-numeric {column} for {key}", file=sys.stderr)
                return 2
            change = percent_change(old, new)
            threshold = thresholds[column]
            status = "REGRESSION" if change > threshold else "ok"
            if status == "REGRESSION":
                regressions += 1
            change_text = "inf" if change == float("inf") else f"{change:+.2f}"
            print(f"{key[0]}\t{key[1]}\t{label}\t{old:g}\t{new:g}\t{change_text}\t{status}")

    missing_current = sorted(set(baseline) - set(current))
    for profile, case in missing_current:
        print(f"warning: current summary is missing {profile}/{case}", file=sys.stderr)

    if regressions:
        print(f"\n{regressions} benchmark regression(s) exceeded the configured thresholds.", file=sys.stderr)
        return 1 if args.fail_on_regression else 0
    print("\nNo benchmark regressions exceeded the configured thresholds.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
