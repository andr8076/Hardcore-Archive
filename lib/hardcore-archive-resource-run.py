#!/usr/bin/env python3
"""Crash-safe CPU/RAM token pool for Hardcore Archive lane processes.

The pool is intentionally local to one archive run. CPU and RAM capacity are
represented by advisory fcntl locks on token files. Locks survive exec() and are
released automatically by the kernel when the owning process exits, including
on crashes or signals.

Commands:
  init    Create a pool with an initial capacity and a larger maximum capacity.
  expand  Expose more of the predeclared maximum capacity.
  run     Acquire a CPU range and exact RAM claim, then exec a command.

A flexible CPU claim lets an image worker use whatever CPU is currently free,
up to its calibrated per-image maximum. Exact claims are used for lanes whose
internal thread count cannot change dynamically.
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import glob
import json
import math
import os
from pathlib import Path
import random
import shutil
import sys
import tempfile
import time
from typing import Iterable

SCHEMA_VERSION = 1
DEFAULT_RAM_CHUNK_MIB = 256


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be >= 1")
    return parsed


def nonnegative_int(value: str) -> int:
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be >= 0")
    return parsed


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    sub = root.add_subparsers(dest="command_name", required=True)

    init = sub.add_parser("init")
    init.add_argument("--pool", required=True)
    init.add_argument("--cpu-initial", type=nonnegative_int, required=True)
    init.add_argument("--cpu-max", type=positive_int, required=True)
    init.add_argument("--ram-initial-mib", type=nonnegative_int, required=True)
    init.add_argument("--ram-max-mib", type=positive_int, required=True)
    init.add_argument("--ram-chunk-mib", type=positive_int, default=DEFAULT_RAM_CHUNK_MIB)

    expand = sub.add_parser("expand")
    expand.add_argument("--pool", required=True)
    expand.add_argument("--cpu-total", type=nonnegative_int, required=True)
    expand.add_argument("--ram-total-mib", type=nonnegative_int, required=True)

    run = sub.add_parser("run")
    run.add_argument("--pool", required=True)
    run.add_argument("--cpu-min", type=positive_int, required=True)
    run.add_argument("--cpu-max", type=positive_int, required=True)
    run.add_argument("--ram-mib", type=nonnegative_int, default=0)
    run.add_argument("--label", default="resource-user")
    run.add_argument("--priority", choices=("high", "normal", "low"), default="normal")
    run.add_argument("--wait-timeout", type=float, default=0.0)
    run.add_argument("command", nargs=argparse.REMAINDER)
    return root


def token_name(index: int) -> str:
    return f"{index:06d}.token"


def atomic_json(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    temporary = Path(temp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, sort_keys=True, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def create_tokens(directory: Path, count: int) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    for index in range(count):
        path = directory / token_name(index)
        try:
            fd = os.open(path, os.O_CREAT | os.O_WRONLY, 0o600)
            os.close(fd)
        except OSError as exc:
            raise RuntimeError(f"cannot create token {path}: {exc}") from exc


def read_meta(pool: Path) -> dict[str, int]:
    try:
        raw = json.loads((pool / "meta.json").read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError) as exc:
        raise RuntimeError(f"invalid resource pool metadata: {exc}") from exc
    required = ("schema", "cpu_max", "ram_max_mib", "ram_chunk_mib", "ram_max_slots")
    if any(not isinstance(raw.get(key), int) for key in required):
        raise RuntimeError("resource pool metadata is incomplete")
    if raw["schema"] != SCHEMA_VERSION:
        raise RuntimeError("unsupported resource pool schema")
    if raw["cpu_max"] < 1 or raw["ram_max_mib"] < 1 or raw["ram_chunk_mib"] < 1:
        raise RuntimeError("resource pool metadata contains invalid limits")
    return {key: int(raw[key]) for key in required}


def initialize(args: argparse.Namespace) -> int:
    if args.cpu_initial > args.cpu_max:
        raise RuntimeError("initial CPU capacity exceeds maximum")
    if args.ram_initial_mib > args.ram_max_mib:
        raise RuntimeError("initial RAM capacity exceeds maximum")

    pool = Path(args.pool)
    # Callers use a per-run directory. Refuse to reuse an existing initialized
    # pool so two archive instances can never silently share accounting state.
    if (pool / "meta.json").exists():
        raise RuntimeError(f"resource pool already initialized: {pool}")
    pool.mkdir(parents=True, exist_ok=True)
    cpu_dir = pool / "cpu"
    ram_dir = pool / "ram"
    cpu_dir.mkdir(exist_ok=True)
    ram_dir.mkdir(exist_ok=True)

    ram_max_slots = math.ceil(args.ram_max_mib / args.ram_chunk_mib)
    ram_initial_slots = math.ceil(args.ram_initial_mib / args.ram_chunk_mib) if args.ram_initial_mib else 0
    create_tokens(cpu_dir, args.cpu_initial)
    create_tokens(ram_dir, ram_initial_slots)
    atomic_json(
        pool / "meta.json",
        {
            "schema": SCHEMA_VERSION,
            "cpu_max": args.cpu_max,
            "ram_max_mib": args.ram_max_mib,
            "ram_chunk_mib": args.ram_chunk_mib,
            "ram_max_slots": ram_max_slots,
            "created_pid": os.getpid(),
        },
    )
    return 0


def expand(args: argparse.Namespace) -> int:
    pool = Path(args.pool)
    meta = read_meta(pool)
    if args.cpu_total > meta["cpu_max"]:
        raise RuntimeError("requested CPU expansion exceeds pool maximum")
    if args.ram_total_mib > meta["ram_max_mib"]:
        raise RuntimeError("requested RAM expansion exceeds pool maximum")
    ram_slots = math.ceil(args.ram_total_mib / meta["ram_chunk_mib"]) if args.ram_total_mib else 0
    create_tokens(pool / "cpu", args.cpu_total)
    create_tokens(pool / "ram", ram_slots)
    return 0


def token_paths(directory: Path) -> list[Path]:
    return [Path(item) for item in sorted(glob.glob(str(directory / "*.token")))]


def lock_one(path: Path) -> int | None:
    fd = os.open(path, os.O_RDONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        os.close(fd)
        if exc.errno in (errno.EACCES, errno.EAGAIN):
            return None
        raise
    return fd


def release(fds: Iterable[int]) -> None:
    for fd in fds:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        try:
            os.close(fd)
        except OSError:
            pass


def acquire_up_to(paths: list[Path], maximum: int) -> list[int]:
    acquired: list[int] = []
    for path in paths:
        if len(acquired) >= maximum:
            break
        try:
            fd = lock_one(path)
        except OSError:
            release(acquired)
            raise
        if fd is not None:
            acquired.append(fd)
    return acquired


def sleep_interval(priority: str) -> float:
    base = {"high": 0.012, "normal": 0.030, "low": 0.055}[priority]
    return base + random.random() * base * 0.35


def run_with_tokens(args: argparse.Namespace) -> int:
    if args.cpu_min > args.cpu_max:
        raise RuntimeError("cpu-min cannot exceed cpu-max")
    if args.wait_timeout < 0:
        raise RuntimeError("wait-timeout cannot be negative")

    command = list(args.command)
    if command and command[0] == "--":
        command.pop(0)
    if not command:
        raise RuntimeError("no command supplied after --")

    pool = Path(args.pool)
    meta = read_meta(pool)
    if args.cpu_min > meta["cpu_max"]:
        raise RuntimeError(
            f"CPU claim for {args.label} requires {args.cpu_min}, pool maximum is {meta['cpu_max']}"
        )
    ram_slots_needed = math.ceil(args.ram_mib / meta["ram_chunk_mib"]) if args.ram_mib else 0
    if ram_slots_needed > meta["ram_max_slots"]:
        raise RuntimeError(
            f"RAM claim for {args.label} requires {args.ram_mib} MiB, "
            f"pool maximum is {meta['ram_max_mib']} MiB"
        )

    started = time.monotonic()
    while True:
        cpu = acquire_up_to(token_paths(pool / "cpu"), args.cpu_max)
        if len(cpu) < args.cpu_min:
            release(cpu)
            cpu = []
        if cpu:
            ram = acquire_up_to(token_paths(pool / "ram"), ram_slots_needed) if ram_slots_needed else []
            if len(ram) == ram_slots_needed:
                all_fds = cpu + ram
                for fd in all_fds:
                    os.set_inheritable(fd, True)
                environment = os.environ.copy()
                environment["HARDCORE_RESOURCE_GRANTED_CPU"] = str(len(cpu))
                environment["HARDCORE_RESOURCE_GRANTED_RAM_MIB"] = str(
                    ram_slots_needed * meta["ram_chunk_mib"]
                )
                environment["HARDCORE_RESOURCE_LABEL"] = args.label
                environment["HARDCORE_RESOURCE_POOL"] = str(pool)
                try:
                    os.execvpe(command[0], command, environment)
                except OSError:
                    release(all_fds)
                    raise
            release(cpu)
            release(ram)

        if args.wait_timeout and time.monotonic() - started >= args.wait_timeout:
            raise RuntimeError(f"timed out waiting for resource tokens: {args.label}")
        time.sleep(sleep_interval(args.priority))


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command_name == "init":
            return initialize(args)
        if args.command_name == "expand":
            return expand(args)
        if args.command_name == "run":
            return run_with_tokens(args)
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"resource scheduler error: {exc}", file=sys.stderr)
        return 2
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
