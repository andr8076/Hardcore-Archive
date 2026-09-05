#!/usr/bin/env python3
"""Run one benchmark phase and record wall/CPU time plus peak resident memory."""
from __future__ import annotations

import argparse
import pathlib
import resource
import subprocess
import sys
import time


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = list(args.command)
    if command and command[0] == "--":
        command.pop(0)
    if not command:
        parser.error("a command is required after --")

    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    started = time.monotonic()
    completed = subprocess.run(command, check=False)
    wall = time.monotonic() - started
    after = resource.getrusage(resource.RUSAGE_CHILDREN)

    user_seconds = max(0.0, after.ru_utime - before.ru_utime)
    system_seconds = max(0.0, after.ru_stime - before.ru_stime)
    peak = after.ru_maxrss
    # Linux reports KiB. Darwin reports bytes.
    if sys.platform == "darwin":
        peak = peak / 1024.0
    peak_kib = max(0, int(round(peak)))
    average_cpu_percent = ((user_seconds + system_seconds) / wall * 100.0) if wall > 0 else 0.0

    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        f"{wall:.6f}\t{peak_kib}\t{user_seconds:.6f}\t{system_seconds:.6f}\t{average_cpu_percent:.2f}\n",
        encoding="utf-8",
    )
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
