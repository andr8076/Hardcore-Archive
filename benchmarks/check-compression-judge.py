#!/usr/bin/env python3
"""Report whether a long-running Compression Judge process is healthy."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
import time


def resolve_status(path: Path) -> Path:
    if path.is_file():
        return path
    direct = path / "run-status.json"
    if direct.is_file():
        return direct
    candidates = sorted(
        path.glob("**/run-status.json"),
        key=lambda item: item.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        raise SystemExit(f"No run-status.json found beneath: {path}")
    return candidates[0]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", help="A run-status.json file, result directory, or results parent")
    parser.add_argument(
        "--stale-seconds",
        type=int,
        default=300,
        help="A running heartbeat older than this is unhealthy",
    )
    args = parser.parse_args()
    status_path = resolve_status(Path(args.path).expanduser().resolve())
    data = json.loads(status_path.read_text(encoding="utf-8"))
    age = max(0, int(time.time() - status_path.stat().st_mtime))
    state = str(data.get("state", "unknown"))
    pid = data.get("pid")
    current = data.get("current_method") or "-"
    completed = data.get("completed_methods") or []
    process_alive = isinstance(pid, int) and Path(f"/proc/{pid}").exists()

    print(f"Status file : {status_path}")
    print(f"State       : {state}")
    print(f"Current     : {current}")
    print(f"Completed   : {len(completed)}/{len(data.get('requested_methods') or [])}")
    print(f"Heartbeat   : {age}s ago")
    if sys.platform.startswith("linux"):
        print(f"Process     : {'alive' if process_alive else 'not running'} (PID {pid})")
    if data.get("last_result"):
        result = data["last_result"]
        print(
            "Last result : "
            f"{result.get('method')} / {result.get('status')} / {result.get('verification')}"
        )
    if data.get("report"):
        print(f"Report      : {data['report']}")

    if state == "complete":
        return 0
    if state in {"failed", "interrupted"}:
        return 1
    if age > args.stale_seconds:
        print("Health      : STALE", file=sys.stderr)
        return 2
    if sys.platform.startswith("linux") and not process_alive:
        print("Health      : PROCESS EXITED", file=sys.stderr)
        return 2
    print("Health      : RUNNING")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
