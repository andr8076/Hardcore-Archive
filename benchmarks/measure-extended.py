#!/usr/bin/env python3
"""Measure a benchmark phase, including aggregate peak RSS for its process tree."""
from __future__ import annotations

import argparse
import pathlib
import resource
import subprocess
import sys
import threading
import time
from typing import BinaryIO


def usage_delta(before: resource.struct_rusage, after: resource.struct_rusage) -> tuple[float, float]:
    return (
        max(0.0, after.ru_utime - before.ru_utime),
        max(0.0, after.ru_stime - before.ru_stime),
    )


def process_tree_rss_kib(root_pid: int) -> tuple[int, float, float]:
    """Return aggregate RSS for root + live descendants and ps sampler CPU cost."""
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    proc = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,rss="],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
        text=True,
    )
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    sampler_user, sampler_system = usage_delta(before, after)
    if proc.returncode != 0:
        return 0, sampler_user, sampler_system

    parent_of: dict[int, int] = {}
    rss_of: dict[int, int] = {}
    for raw in proc.stdout.splitlines():
        fields = raw.split()
        if len(fields) != 3:
            continue
        try:
            pid, ppid, rss = map(int, fields)
        except ValueError:
            continue
        parent_of[pid] = ppid
        rss_of[pid] = max(0, rss)

    if root_pid not in rss_of:
        return 0, sampler_user, sampler_system

    descendants = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, ppid in parent_of.items():
            if pid not in descendants and ppid in descendants:
                descendants.add(pid)
                changed = True
    return sum(rss_of.get(pid, 0) for pid in descendants), sampler_user, sampler_system


def tee_output(pipe: BinaryIO, log_path: pathlib.Path | None) -> None:
    log = None
    try:
        if log_path is not None:
            log_path.parent.mkdir(parents=True, exist_ok=True)
            log = log_path.open("wb")
        while True:
            chunk = pipe.read(64 * 1024)
            if not chunk:
                break
            if log is not None:
                log.write(chunk)
                log.flush()
            try:
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
            except BrokenPipeError:
                pass
    finally:
        if log is not None:
            log.close()
        pipe.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--log")
    parser.add_argument("--sample-interval", type=float, default=0.50)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not (0.05 <= args.sample_interval <= 5.0):
        parser.error("--sample-interval must be between 0.05 and 5 seconds")

    command = list(args.command)
    if command and command[0] == "--":
        command.pop(0)
    if not command:
        parser.error("a command is required after --")

    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    started = time.monotonic()
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,
    )
    assert process.stdout is not None
    output_thread = threading.Thread(
        target=tee_output,
        args=(process.stdout, pathlib.Path(args.log) if args.log else None),
        daemon=True,
    )
    output_thread.start()

    peak_tree_rss_kib = 0
    sampler_user = 0.0
    sampler_system = 0.0
    while True:
        rss, sample_user, sample_system = process_tree_rss_kib(process.pid)
        peak_tree_rss_kib = max(peak_tree_rss_kib, rss)
        sampler_user += sample_user
        sampler_system += sample_system
        if process.poll() is not None:
            break
        time.sleep(args.sample_interval)

    returncode = process.wait()
    output_thread.join()
    wall = time.monotonic() - started
    after = resource.getrusage(resource.RUSAGE_CHILDREN)

    raw_user, raw_system = usage_delta(before, after)
    # ps is launched by this measurement process, so RUSAGE_CHILDREN includes
    # its cost. Subtract the explicitly measured sampler overhead from the
    # benchmarked command's CPU time.
    user_seconds = max(0.0, raw_user - sampler_user)
    system_seconds = max(0.0, raw_system - sampler_system)
    average_cpu_percent = ((user_seconds + system_seconds) / wall * 100.0) if wall > 0 else 0.0

    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        f"{wall:.6f}\t{peak_tree_rss_kib}\t{user_seconds:.6f}\t{system_seconds:.6f}\t{average_cpu_percent:.2f}\n",
        encoding="utf-8",
    )
    return returncode


if __name__ == "__main__":
    raise SystemExit(main())
