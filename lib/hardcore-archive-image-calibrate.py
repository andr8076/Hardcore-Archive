#!/usr/bin/env python3
"""Calibrate OxiPNG process/thread fan-out for this machine.

The benchmark uses a deterministic synthetic PNG so calibration is repeatable,
does not touch source files, and can be cached by CPU/tool identity. stdout is
reserved for one tab-separated scheduler result:

    jobs<TAB>threads-per-worker<TAB>cpu-budget<TAB>source
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform as host_platform
import shutil
import statistics
import struct
import subprocess
import tempfile
import time
import zlib

SCHEMA_VERSION = 1
CACHE_MAX_AGE_SECONDS = 30 * 24 * 60 * 60
DEFAULT_TIME_BUDGET_SECONDS = 30.0
DEFAULT_REPEATS = 2
FIXTURE_WIDTH = 640
FIXTURE_HEIGHT = 640


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--oxipng", required=True)
    parser.add_argument("--cpu-threads", type=int, required=True)
    parser.add_argument("--max-workers", type=int, required=True)
    parser.add_argument("--cache-dir", required=True)
    parser.add_argument("--cpu-model", default="unknown")
    parser.add_argument("--platform", default="unknown")
    parser.add_argument("--time-budget", type=float, default=DEFAULT_TIME_BUDGET_SECONDS)
    parser.add_argument("--repeats", type=int, default=DEFAULT_REPEATS)
    parser.add_argument("--cache-only", action="store_true")
    parser.add_argument("--refresh", action="store_true")
    return parser.parse_args()


def run_text(command: list[str]) -> str:
    try:
        completed = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return completed.stdout.strip()


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    body = kind + payload
    crc = zlib.crc32(body) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + body + struct.pack(">I", crc)


def write_fixture(path: Path) -> None:
    """Write a deterministic, deliberately non-optimal true-color PNG."""
    raw = bytearray()
    width = FIXTURE_WIDTH
    height = FIXTURE_HEIGHT
    for y in range(height):
        raw.append(0)  # filter type None: intentionally leaves optimizer work.
        for x in range(width):
            # Mix broad repeating regions with fine structure so the fixture is
            # neither a trivial solid image nor incompressible random noise.
            block_x = x // 16
            block_y = y // 16
            raw.extend(
                (
                    (block_x * 19 + y * 3) & 0xFF,
                    (block_y * 23 + x * 5) & 0xFF,
                    ((x ^ y) + (block_x * block_y)) & 0xFF,
                )
            )
    payload = zlib.compress(bytes(raw), level=1)
    png = bytearray(b"\x89PNG\r\n\x1a\n")
    png.extend(
        png_chunk(
            b"IHDR",
            struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0),
        )
    )
    png.extend(png_chunk(b"IDAT", payload))
    png.extend(png_chunk(b"IEND", b""))
    path.write_bytes(png)


def candidate_jobs(max_workers: int) -> list[int]:
    values = {1, max_workers}
    jobs = 2
    while jobs < max_workers:
        values.add(jobs)
        jobs *= 2
    return sorted(value for value in values if 1 <= value <= max_workers)


def terminate_processes(processes: list[subprocess.Popen[bytes]]) -> None:
    for process in processes:
        if process.poll() is None:
            try:
                process.terminate()
            except OSError:
                pass
    deadline = time.monotonic() + 1.0
    while time.monotonic() < deadline and any(p.poll() is None for p in processes):
        time.sleep(0.02)
    for process in processes:
        if process.poll() is None:
            try:
                process.kill()
            except OSError:
                pass
    for process in processes:
        try:
            process.wait(timeout=1)
        except (OSError, subprocess.TimeoutExpired):
            pass


def run_wave(
    oxipng: str,
    fixture: Path,
    parent: Path,
    jobs: int,
    threads: int,
    supports_threads: bool,
    timeout_seconds: float,
) -> float | None:
    wave = parent / f"wave-{jobs}-{threads}-{time.monotonic_ns()}"
    wave.mkdir()
    targets: list[Path] = []
    for index in range(jobs):
        target = wave / f"fixture-{index}.png"
        shutil.copyfile(fixture, target)
        targets.append(target)

    command_prefix = [oxipng, "-q", "-o", "2", "--preserve"]
    if supports_threads:
        command_prefix += ["--threads", str(threads)]
    environment = os.environ.copy()
    if not supports_threads:
        environment["RAYON_NUM_THREADS"] = str(threads)

    processes: list[subprocess.Popen[bytes]] = []
    started = time.monotonic()
    try:
        for target in targets:
            processes.append(
                subprocess.Popen(
                    command_prefix + [str(target)],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    env=environment,
                )
            )
    except OSError:
        terminate_processes(processes)
        shutil.rmtree(wave, ignore_errors=True)
        return None

    deadline = started + max(1.0, timeout_seconds)
    while True:
        if all(process.poll() is not None for process in processes):
            break
        if time.monotonic() >= deadline:
            terminate_processes(processes)
            shutil.rmtree(wave, ignore_errors=True)
            return None
        time.sleep(0.01)

    elapsed = time.monotonic() - started
    success = all(process.returncode == 0 for process in processes)
    shutil.rmtree(wave, ignore_errors=True)
    if not success or elapsed <= 0:
        return None
    return elapsed


def cache_key(args: argparse.Namespace, oxipng_version: str, max_workers: int) -> dict[str, object]:
    return {
        "schema": SCHEMA_VERSION,
        "platform": args.platform,
        "machine": host_platform.machine(),
        "cpu_model": args.cpu_model,
        "cpu_threads": args.cpu_threads,
        "max_workers": max_workers,
        "oxipng_path": os.path.realpath(args.oxipng),
        "oxipng_version": oxipng_version,
        "fixture": [FIXTURE_WIDTH, FIXTURE_HEIGHT, "rgb-pattern-v1"],
    }


def cache_path(cache_dir: Path, key: dict[str, object]) -> Path:
    encoded = json.dumps(key, sort_keys=True, separators=(",", ":")).encode("utf-8")
    digest = hashlib.sha256(encoded).hexdigest()
    return cache_dir / f"{digest}.json"


def load_cache(path: Path, key: dict[str, object]) -> dict[str, object] | None:
    try:
        if time.time() - path.stat().st_mtime > CACHE_MAX_AGE_SECONDS:
            return None
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return None
    if payload.get("key") != key:
        return None
    result = payload.get("result")
    if not isinstance(result, dict):
        return None
    jobs = result.get("jobs")
    threads = result.get("threads")
    if not isinstance(jobs, int) or not isinstance(threads, int) or jobs < 1 or threads < 1:
        return None
    return payload


def save_cache(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    temporary = Path(temporary_name)
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


def emit(jobs: int, threads: int, cpu_threads: int, source: str) -> None:
    print(f"{jobs}\t{threads}\t{cpu_threads}\t{source}")


def main() -> int:
    args = parse_args()
    if args.cpu_threads < 1 or args.max_workers < 1 or args.time_budget <= 0 or args.repeats < 1:
        return 2

    oxipng_version = run_text([args.oxipng, "--version"])
    help_text = run_text([args.oxipng, "--help"])
    if not oxipng_version and not help_text:
        return 2
    supports_threads = "--threads" in help_text

    max_workers = min(args.max_workers, args.cpu_threads, 32)
    key = cache_key(args, oxipng_version, max_workers)
    directory = Path(args.cache_dir)
    path = cache_path(directory, key)

    if not args.refresh:
        cached = load_cache(path, key)
        if cached is not None:
            result = cached["result"]
            emit(int(result["jobs"]), int(result["threads"]), args.cpu_threads, "calibrated-cache")
            return 0
    if args.cache_only:
        return 3

    started_all = time.monotonic()
    measurements: list[dict[str, object]] = []
    with tempfile.TemporaryDirectory(prefix="hardcore-image-calibration-") as temporary:
        root = Path(temporary)
        fixture = root / "fixture.png"
        write_fixture(fixture)

        # Warm the executable, dynamic linker and filesystem cache. The warm-up
        # is deliberately not scored.
        warm = root / "warm.png"
        shutil.copyfile(fixture, warm)
        warm_command = [args.oxipng, "-q", "-o", "2", "--preserve"]
        warm_threads = min(args.cpu_threads, 4)
        warm_environment = os.environ.copy()
        if supports_threads:
            warm_command += ["--threads", str(warm_threads)]
        else:
            warm_environment["RAYON_NUM_THREADS"] = str(warm_threads)
        try:
            subprocess.run(
                warm_command + [str(warm)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=warm_environment,
                timeout=min(8.0, args.time_budget),
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            pass

        for jobs in candidate_jobs(max_workers):
            if time.monotonic() - started_all >= args.time_budget:
                break
            threads = max(1, math.ceil(args.cpu_threads / jobs))
            elapsed_samples: list[float] = []
            for _ in range(args.repeats):
                remaining = args.time_budget - (time.monotonic() - started_all)
                if remaining <= 1.0:
                    break
                elapsed = run_wave(
                    args.oxipng,
                    fixture,
                    root,
                    jobs,
                    threads,
                    supports_threads,
                    min(12.0, remaining),
                )
                if elapsed is None:
                    break
                elapsed_samples.append(elapsed)
            if not elapsed_samples:
                continue
            elapsed_median = statistics.median(elapsed_samples)
            throughput = jobs / elapsed_median
            measurements.append(
                {
                    "jobs": jobs,
                    "threads": threads,
                    "elapsed_seconds": elapsed_median,
                    "throughput_images_per_second": throughput,
                    "samples": elapsed_samples,
                }
            )

    if len(measurements) < 2:
        return 4

    best_throughput = max(float(row["throughput_images_per_second"]) for row in measurements)
    # Prefer the lower-process candidate when it is essentially tied. This keeps
    # memory/process overhead down without sacrificing meaningful throughput.
    eligible = [
        row
        for row in measurements
        if float(row["throughput_images_per_second"]) >= best_throughput * 0.98
    ]
    winner = min(eligible, key=lambda row: int(row["jobs"]))
    jobs = int(winner["jobs"])
    threads = int(winner["threads"])

    payload: dict[str, object] = {
        "key": key,
        "created_unix": int(time.time()),
        "result": {"jobs": jobs, "threads": threads},
        "measurements": measurements,
    }
    try:
        save_cache(path, payload)
    except OSError:
        # Calibration is an optimization only; inability to persist the result
        # must not make archive creation fail.
        pass

    emit(jobs, threads, args.cpu_threads, "calibrated-new")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
