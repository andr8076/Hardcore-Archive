#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fcntl
import math
import os
import shutil
import signal
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

DEFAULT_MIN_BPS = 256.0
DEFAULT_MIN_PPM_PER_SECOND = 25.0


def _probe_budget(total: float) -> float:
    return min(20.0, max(6.0, math.ceil(total / 3.0)))


def _min_rate_bps(baseline_bytes: int, min_bps: float, min_ppm: float) -> float:
    return max(min_bps, baseline_bytes * min_ppm / 1_000_000.0)


def choose_effort(
    baseline_bytes: int,
    probe_bytes: int,
    probe_elapsed_ms: int,
    total_budget: float,
    *,
    min_bps: float = DEFAULT_MIN_BPS,
    min_ppm: float = DEFAULT_MIN_PPM_PER_SECOND,
) -> tuple[str, float, int, int, float, float, float]:
    """Return tier, deep budget, zi, ziwi, bps, ppm/s, threshold-bps."""
    extra = max(0, baseline_bytes - probe_bytes)
    elapsed = max(probe_elapsed_ms / 1000.0, 0.001)
    bps = extra / elapsed
    ppm = (extra / baseline_bytes * 1_000_000.0 / elapsed) if baseline_bytes else 0.0
    threshold = _min_rate_bps(baseline_bytes, min_bps, min_ppm)
    min_extra = max(1024, baseline_bytes // 10_000)

    if extra < min_extra or bps < threshold:
        return "stop", 0.0, 1, 1, bps, ppm, threshold

    used_seconds = math.ceil(probe_elapsed_ms / 1000.0)
    remaining = max(0.0, total_budget - used_seconds)
    if remaining < 3.0:
        return "stop", 0.0, 1, 1, bps, ppm, threshold

    ratio = bps / threshold if threshold > 0 else float("inf")
    if ratio >= 8.0:
        tier, zi, ziwi, desired = "strong", 5, 2, remaining
    elif ratio >= 3.0:
        tier, zi, ziwi, desired = "medium", 3, 1, max(5.0, total_budget * 0.40)
    else:
        tier, zi, ziwi, desired = "light", 2, 1, max(3.0, total_budget * 0.20)
    return tier, min(remaining, desired), zi, ziwi, bps, ppm, threshold


@dataclass
class RunResult:
    status: str
    elapsed_ms: int
    returncode: int


def run_command(command: list[str], budget_seconds: float, log_file: Path, env: dict[str, str]) -> RunResult:
    start = time.monotonic()
    with log_file.open("ab", buffering=0) as log:
        proc = subprocess.Popen(
            command,
            stdout=log,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )
        status = "ok"
        try:
            returncode = proc.wait(timeout=budget_seconds)
            if returncode != 0:
                status = "failed"
        except subprocess.TimeoutExpired:
            status = "expired"
            returncode = 124
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait()
    elapsed_ms = max(1, round((time.monotonic() - start) * 1000))
    return RunResult(status, elapsed_ms, returncode)


def oxipng_help(oxipng: str) -> str:
    try:
        completed = subprocess.run([oxipng, "--help"], text=True, capture_output=True, check=False)
        return completed.stdout + completed.stderr
    except OSError:
        return ""


def build_command(oxipng: str, target: Path, threads: int, help_text: str, zi: int | None, ziwi: int | None) -> tuple[list[str], dict[str, str]]:
    cmd = [oxipng, "-q", "-o", "2", "--zopfli", "--preserve"]
    env = os.environ.copy()
    if "--threads" in help_text:
        cmd += ["--threads", str(threads)]
    else:
        env["RAYON_NUM_THREADS"] = str(threads)
    if zi is not None and "--zi" in help_text:
        cmd += ["--zi", str(zi)]
    if ziwi is not None and "--ziwi" in help_text:
        cmd += ["--ziwi", str(ziwi)]
    cmd.append(str(target))
    return cmd, env


def append_telemetry(path: Path, row: list[str]) -> None:
    header = [
        "path", "status", "decision", "baseline_bytes", "final_bytes", "extra_bytes",
        "total_elapsed_ms", "extra_bytes_per_second", "threads", "total_budget_seconds",
        "probe_budget_seconds", "probe_status", "probe_elapsed_ms", "probe_bytes",
        "probe_extra_bytes", "probe_bytes_per_second", "probe_ppm_per_second",
        "minimum_probe_bytes_per_second", "deep_budget_seconds", "deep_status",
        "deep_elapsed_ms", "zi", "ziwi",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        handle.seek(0, os.SEEK_END)
        if handle.tell() == 0:
            handle.write("\t".join(header) + "\n")
        handle.write("\t".join(row) + "\n")
        handle.flush()
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def log_line(log_file: Path, text: str) -> None:
    with log_file.open("a", encoding="utf-8") as handle:
        handle.write(text.rstrip("\n") + "\n")


def run_adaptive(args: argparse.Namespace) -> int:
    baseline = Path(args.baseline)
    work_dir = Path(args.work_dir)
    log_file = Path(args.log_file)
    telemetry_file = Path(args.telemetry_file)
    baseline_bytes = baseline.stat().st_size
    total_budget = float(args.budget)
    threads = int(args.threads)
    min_bps = float(os.environ.get("HARDCORE_ARCHIVE_ZOPFLI_MIN_BPS", DEFAULT_MIN_BPS))
    min_ppm = float(os.environ.get("HARDCORE_ARCHIVE_ZOPFLI_MIN_PPM_PER_SECOND", DEFAULT_MIN_PPM_PER_SECOND))
    help_text = oxipng_help(args.oxipng)
    supports_iterations = "--zi" in help_text and "--ziwi" in help_text

    probe = work_dir / "zopfli-probe.png"
    shutil.copy2(baseline, probe)
    probe_budget = _probe_budget(total_budget) if supports_iterations else total_budget
    probe_zi = 1 if supports_iterations else None
    probe_ziwi = 1 if supports_iterations else None
    cmd, env = build_command(args.oxipng, probe, threads, help_text, probe_zi, probe_ziwi)
    log_line(log_file, f"Zopfli adaptive probe: {args.relative}, baseline {baseline_bytes} bytes, budget {probe_budget:g}s, threads {threads}")
    probe_run = run_command(cmd, probe_budget, log_file, env)
    probe_bytes = probe.stat().st_size if probe.exists() else baseline_bytes
    probe_extra = max(0, baseline_bytes - probe_bytes) if probe_run.status == "ok" else 0
    probe_bps = probe_extra * 1000.0 / probe_run.elapsed_ms
    probe_ppm = (probe_extra / baseline_bytes * 1_000_000.0 * 1000.0 / probe_run.elapsed_ms) if baseline_bytes else 0.0

    winner = baseline
    winner_bytes = baseline_bytes
    status = probe_run.status
    decision = "legacy" if not supports_iterations else "stop"
    deep_budget = 0.0
    deep_status = "not-run"
    deep_elapsed_ms = 0
    zi = probe_zi or 0
    ziwi = probe_ziwi or 0
    threshold = _min_rate_bps(baseline_bytes, min_bps, min_ppm)

    if probe_run.status == "ok" and probe_bytes < baseline_bytes:
        winner, winner_bytes = probe, probe_bytes
        status = "optimized"
        if supports_iterations:
            decision, deep_budget, zi, ziwi, probe_bps, probe_ppm, threshold = choose_effort(
                baseline_bytes, probe_bytes, probe_run.elapsed_ms, total_budget,
                min_bps=min_bps, min_ppm=min_ppm,
            )
            log_line(
                log_file,
                f"Zopfli probe result: {args.relative}, saved {probe_extra} bytes in {probe_run.elapsed_ms / 1000:.3f}s "
                f"({probe_bps:.1f} B/s, {probe_ppm:.1f} ppm/s); threshold {threshold:.1f} B/s; decision {decision}",
            )
            if decision != "stop" and deep_budget >= 3.0:
                deep = work_dir / f"zopfli-{decision}.png"
                shutil.copy2(probe, deep)
                deep_cmd, deep_env = build_command(args.oxipng, deep, threads, help_text, zi, ziwi)
                log_line(log_file, f"Zopfli adaptive deep pass: {args.relative}, tier {decision}, budget {deep_budget:g}s, zi={zi}, ziwi={ziwi}")
                deep_run = run_command(deep_cmd, deep_budget, log_file, deep_env)
                deep_status = deep_run.status
                deep_elapsed_ms = deep_run.elapsed_ms
                if deep_run.status == "ok" and deep.exists() and deep.stat().st_size < winner_bytes:
                    winner, winner_bytes = deep, deep.stat().st_size
                elif deep_run.status == "expired":
                    log_line(log_file, f"Zopfli deep pass expired; keeping probe result for {args.relative}")
        else:
            log_line(log_file, f"Zopfli legacy measured pass: {args.relative}, saved {probe_extra} bytes in {probe_run.elapsed_ms / 1000:.3f}s ({probe_bps:.1f} B/s)")
    else:
        if probe_run.status == "expired":
            log_line(log_file, f"Zopfli probe expired; keeping baseline candidate for {args.relative}")
        elif probe_run.status != "ok":
            log_line(log_file, f"Zopfli probe failed; keeping baseline candidate for {args.relative}")
        else:
            log_line(log_file, f"Zopfli probe found no extra savings for {args.relative}")

    total_elapsed_ms = probe_run.elapsed_ms + deep_elapsed_ms
    extra = max(0, baseline_bytes - winner_bytes)
    final_bps = extra * 1000.0 / max(total_elapsed_ms, 1)
    tool = "adaptive-zopfli-" + (decision if supports_iterations else "legacy")
    append_telemetry(telemetry_file, [
        args.relative.replace("\t", " ").replace("\n", " "), status, decision,
        str(baseline_bytes), str(winner_bytes), str(extra), str(total_elapsed_ms), f"{final_bps:.3f}",
        str(threads), f"{total_budget:g}", f"{probe_budget:g}", probe_run.status,
        str(probe_run.elapsed_ms), str(probe_bytes), str(probe_extra), f"{probe_bps:.3f}", f"{probe_ppm:.3f}",
        f"{threshold:.3f}", f"{deep_budget:g}", deep_status, str(deep_elapsed_ms), str(zi), str(ziwi),
    ])
    log_line(log_file, f"Zopfli adaptive result: {args.relative}, extra {extra} bytes in {total_elapsed_ms / 1000:.3f}s ({final_bps:.1f} B/s), winner {tool}")
    print("\t".join(["optimized" if winner_bytes < baseline_bytes else "unchanged", str(winner), str(winner_bytes), tool]))
    return 0


def summarize(path: Path) -> str:
    if not path.exists() or path.stat().st_size == 0:
        return "Zopfli adaptive summary: attempts=0"
    import csv
    rows = list(csv.DictReader(path.open(encoding="utf-8"), delimiter="\t"))
    if not rows:
        return "Zopfli adaptive summary: attempts=0"
    attempts = len(rows)
    deep = sum(r["deep_status"] != "not-run" for r in rows)
    expired = sum(r["probe_status"] == "expired" or r["deep_status"] == "expired" for r in rows)
    extra = sum(int(r["extra_bytes"]) for r in rows)
    elapsed_ms = sum(int(r["total_elapsed_ms"]) for r in rows)
    bps = extra * 1000.0 / max(elapsed_ms, 1)
    return f"Zopfli adaptive summary: attempts={attempts}, deep={deep}, expired={expired}, extra_bytes={extra}, zopfli_seconds={elapsed_ms/1000:.3f}, extra_bytes_per_second={bps:.1f}"


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="command", required=True)
    r = sub.add_parser("run")
    r.add_argument("--oxipng", required=True)
    r.add_argument("--baseline", required=True)
    r.add_argument("--work-dir", required=True)
    r.add_argument("--threads", type=int, required=True)
    r.add_argument("--budget", type=float, required=True)
    r.add_argument("--relative", required=True)
    r.add_argument("--log-file", required=True)
    r.add_argument("--telemetry-file", required=True)
    s = sub.add_parser("summary")
    s.add_argument("--telemetry-file", required=True)
    return p


def main() -> int:
    args = parser().parse_args()
    if args.command == "run":
        return run_adaptive(args)
    print(summarize(Path(args.telemetry_file)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
