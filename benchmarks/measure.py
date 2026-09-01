#!/usr/bin/env python3
"""Run one benchmark phase and record wall time plus peak resident memory."""
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

    started = time.monotonic()
    completed = subprocess.run(command, check=False)
    elapsed = time.monotonic() - started
    peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    # Linux reports KiB. Darwin reports bytes.
    if sys.platform == "darwin":
        peak = peak / 1024.0
    peak_kib = max(0, int(round(peak)))

    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(f"{elapsed:.6f}\t{peak_kib}\n", encoding="utf-8")
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
