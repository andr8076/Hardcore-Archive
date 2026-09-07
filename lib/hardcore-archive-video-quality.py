#!/usr/bin/env python3
"""Plan and evaluate completed-video VMAF acceptance checks.

This helper deliberately separates cheap encoder calibration from acceptance of the
actual completed output.  Sampled mode is bounded and reproducible; full mode
scores the complete timeline and is intentionally more expensive.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence

POLICY_VERSION = "completed-video-quality-v1"


@dataclass(frozen=True)
class Window:
    kind: str
    start: float
    length: float


def _finite(value: object) -> float:
    number = float(value)
    if not math.isfinite(number):
        raise ValueError("non-finite number")
    return number


def _clamp_window(start: float, length: float, duration: float, kind: str) -> Window:
    if duration <= 0 or length <= 0:
        raise ValueError("invalid duration/window")
    length = min(length, duration)
    start = max(0.0, min(start, max(0.0, duration - length)))
    return Window(kind, start, length)


def _overlap_fraction(a: Window, b: Window) -> float:
    left = max(a.start, b.start)
    right = min(a.start + a.length, b.start + b.length)
    if right <= left:
        return 0.0
    return (right - left) / min(a.length, b.length)


def union_coverage(windows: Sequence[Window]) -> float:
    intervals = sorted((w.start, w.start + w.length) for w in windows)
    if not intervals:
        return 0.0
    covered = 0.0
    left, right = intervals[0]
    for start, end in intervals[1:]:
        if start <= right:
            right = max(right, end)
        else:
            covered += right - left
            left, right = start, end
    return covered + right - left


def plan_uniform_windows(
    duration: float,
    sample_seconds: float = 4.0,
    interval_seconds: float = 300.0,
    min_samples: int = 5,
    max_samples: int = 16,
    complexity_slots: int = 2,
) -> list[Window]:
    duration = _finite(duration)
    sample_seconds = _finite(sample_seconds)
    interval_seconds = _finite(interval_seconds)
    if duration <= 0 or sample_seconds <= 0 or interval_seconds <= 0:
        raise ValueError("duration, sample seconds and interval must be positive")
    if min_samples < 1 or max_samples < 1 or min_samples > max_samples:
        raise ValueError("invalid sample bounds")
    if max_samples > 64:
        raise ValueError("max_samples exceeds hard safety bound")
    complexity_slots = max(0, min(complexity_slots, max_samples - 1))

    # Short clips are cheap enough to cover continuously. With the shipped
    # defaults this fully covers clips up to 20 seconds.
    if duration <= sample_seconds * min_samples:
        count = max(1, min(max_samples, math.ceil(duration / sample_seconds)))
        windows: list[Window] = []
        cursor = 0.0
        for _ in range(count):
            remaining = duration - cursor
            if remaining <= 0:
                break
            length = min(sample_seconds, remaining)
            windows.append(Window("short-full", cursor, length))
            cursor += length
        return windows

    uniform_cap = max(1, max_samples - complexity_slots)
    desired = max(min_samples, math.ceil(duration / interval_seconds) + 2)
    count = min(uniform_cap, desired)
    length = min(sample_seconds, duration)
    windows = []
    for index in range(count):
        # Equal-bin midpoints: with five windows this is 10/30/50/70/90%.
        center = duration * (index + 0.5) / count
        windows.append(_clamp_window(center - length / 2.0, length, duration, "uniform"))
    return windows


def packet_complexity_candidates(
    input_path: str,
    duration: float,
    sample_seconds: float,
    limit: int,
    ffprobe: str = "ffprobe",
) -> list[Window]:
    """Return deterministic high-packet-rate windows as inexpensive scene hints.

    Packet bytes are only a proxy for difficult scenes; this intentionally avoids
    decoding the entire source merely to decide where bounded VMAF samples go.
    """
    if limit <= 0:
        return []
    command = [
        ffprobe, "-v", "error", "-select_streams", "V:0", "-show_packets",
        "-show_entries", "packet=pts_time,size", "-of", "csv=p=0", input_path,
    ]
    try:
        process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, encoding="utf-8", errors="replace",
        )
    except OSError:
        return []

    buckets: dict[int, int] = {}
    assert process.stdout is not None
    try:
        for row in csv.reader(process.stdout):
            if len(row) < 2:
                continue
            try:
                pts = float(row[0])
                size = int(row[1])
            except (ValueError, OverflowError):
                continue
            if not math.isfinite(pts) or pts < 0 or size <= 0:
                continue
            bucket = int(pts // sample_seconds)
            buckets[bucket] = buckets.get(bucket, 0) + size
    finally:
        process.stdout.close()
    if process.wait() != 0:
        return []

    result: list[Window] = []
    for bucket, _bytes in sorted(buckets.items(), key=lambda item: (-item[1], item[0])):
        candidate = _clamp_window(bucket * sample_seconds, sample_seconds, duration, "complexity")
        if any(_overlap_fraction(candidate, existing) >= 0.5 for existing in result):
            continue
        result.append(candidate)
        if len(result) >= limit:
            break
    return result


def add_complexity_windows(
    uniform: Sequence[Window], candidates: Sequence[Window], max_samples: int
) -> list[Window]:
    windows = list(uniform)
    for candidate in candidates:
        if len(windows) >= max_samples:
            break
        if any(_overlap_fraction(candidate, existing) >= 0.5 for existing in windows):
            continue
        windows.append(candidate)
    return sorted(windows, key=lambda w: (w.start, w.kind))


def percentile(values: Sequence[float], percent: float) -> float:
    if not values:
        raise ValueError("no values")
    if not 0 <= percent <= 100:
        raise ValueError("percentile outside 0..100")
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (len(ordered) - 1) * percent / 100.0
    low = math.floor(rank)
    high = math.ceil(rank)
    if low == high:
        return ordered[low]
    fraction = rank - low
    return ordered[low] * (1.0 - fraction) + ordered[high] * fraction


def read_vmaf_log(path: str) -> tuple[float, list[float]]:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    pooled = _finite(data["pooled_metrics"]["vmaf"]["mean"])
    raw_frames = data["frames"]
    if not isinstance(raw_frames, list) or not raw_frames:
        raise ValueError("missing VMAF frames")
    frames: list[float] = []
    for frame in raw_frames:
        value = _finite(frame["metrics"]["vmaf"])
        if not 0.0 <= value <= 100.0:
            raise ValueError("VMAF frame outside 0..100")
        frames.append(value)
    if not 0.0 <= pooled <= 100.0:
        raise ValueError("pooled VMAF outside 0..100")
    return pooled, frames


def read_manifest(path: str) -> list[tuple[Window, str]]:
    rows: list[tuple[Window, str]] = []
    with open(path, "r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            line = line.rstrip("\n")
            if not line:
                continue
            fields = line.split("\t")
            if len(fields) != 4:
                raise ValueError(f"invalid measurement row {line_number}")
            kind, start_raw, length_raw, log_path = fields
            start = _finite(start_raw)
            length = _finite(length_raw)
            if start < 0 or length <= 0 or not log_path:
                raise ValueError(f"invalid measurement row {line_number}")
            rows.append((Window(kind, start, length), log_path))
    if not rows:
        raise ValueError("no completed-video quality measurements")
    return rows


def evaluate_manifest(
    manifest_path: str,
    duration: float,
    threshold: float,
    low_percentile: float = 10.0,
    percentile_delta: float = 4.0,
    sustained_delta: float = 6.0,
    sustained_seconds: float = 1.0,
) -> dict[str, object]:
    duration = _finite(duration)
    threshold = _finite(threshold)
    low_percentile = _finite(low_percentile)
    percentile_delta = _finite(percentile_delta)
    sustained_delta = _finite(sustained_delta)
    sustained_seconds = _finite(sustained_seconds)
    if duration <= 0 or not 0 <= threshold <= 100:
        raise ValueError("invalid duration/threshold")
    if not 0 <= low_percentile <= 50:
        raise ValueError("low percentile must be between 0 and 50")
    if percentile_delta < 0 or sustained_delta < 0 or sustained_seconds <= 0:
        raise ValueError("invalid local-quality settings")

    rows = read_manifest(manifest_path)
    all_frames: list[float] = []
    window_means: list[float] = []
    longest_sustained = 0.0
    sustained_floor = threshold - sustained_delta

    for window, log_path in rows:
        pooled, frames = read_vmaf_log(log_path)
        window_means.append(pooled)
        all_frames.extend(frames)
        # Derive the run duration from this measured window's actual frame
        # population rather than assuming a fixed frame rate, which keeps the
        # criterion meaningful for variable-frame-rate sources.
        seconds_per_frame = window.length / len(frames)
        run = 0
        best = 0
        for value in frames:
            if value < sustained_floor:
                run += 1
                best = max(best, run)
            else:
                run = 0
        longest_sustained = max(longest_sustained, best * seconds_per_frame)

    if not all_frames or not window_means:
        raise ValueError("empty VMAF measurements")

    aggregate_mean = sum(all_frames) / len(all_frames)
    low_value = percentile(all_frames, low_percentile)
    minimum_window = min(window_means)
    percentile_floor = threshold - percentile_delta
    reasons: list[str] = []
    if aggregate_mean < threshold:
        reasons.append(f"mean-vmaf {aggregate_mean:.3f} < target {threshold:.3f}")
    # A complete sampled window below the configured target is substantial local
    # degradation, not an isolated noisy frame. The target itself is not lowered.
    if minimum_window < threshold:
        reasons.append(f"window-mean {minimum_window:.3f} < target {threshold:.3f}")
    if low_value < percentile_floor:
        reasons.append(
            f"p{low_percentile:g}-vmaf {low_value:.3f} < floor {percentile_floor:.3f}"
        )
    if longest_sustained + 1e-9 >= sustained_seconds:
        reasons.append(
            f"sustained-low-quality {longest_sustained:.3f}s >= {sustained_seconds:.3f}s "
            f"below {sustained_floor:.3f}"
        )

    windows = [window for window, _ in rows]
    coverage_seconds = min(duration, union_coverage(windows))
    return {
        "policy": POLICY_VERSION,
        "status": "pass" if not reasons else "reject",
        "windows": len(windows),
        "frames": len(all_frames),
        "coverage_seconds": coverage_seconds,
        "coverage_percent": coverage_seconds * 100.0 / duration,
        "mean_vmaf": aggregate_mean,
        "minimum_window_mean": minimum_window,
        "low_percentile": low_percentile,
        "low_percentile_vmaf": low_value,
        "low_percentile_floor": percentile_floor,
        "sustained_floor": sustained_floor,
        "longest_sustained_seconds": longest_sustained,
        "reasons": reasons,
    }


def higher_quality(encoder: str, quality: int, step: int) -> int | None:
    if step < 1:
        raise ValueError("retry step must be positive")
    lower_is_better = {
        "av1_vaapi", "hevc_vaapi", "av1_nvenc", "hevc_nvenc", "av1_qsv", "hevc_qsv"
    }
    higher_is_better = {"hevc_videotoolbox"}
    if encoder in lower_is_better:
        candidate = max(1, quality - step)
        return candidate if candidate < quality else None
    if encoder in higher_is_better:
        candidate = min(100, quality + step)
        return candidate if candidate > quality else None
    return None


def command_plan(args: argparse.Namespace) -> int:
    if args.mode == "full":
        windows = [Window("full", 0.0, args.duration)]
    else:
        windows = plan_uniform_windows(
            args.duration, args.sample_seconds, args.interval_seconds,
            args.min_samples, args.max_samples, args.complexity_samples,
        )
        short_full = windows and all(w.kind == "short-full" for w in windows)
        if not short_full and args.complexity_samples > 0:
            candidates = packet_complexity_candidates(
                args.input, args.duration, args.sample_seconds,
                args.complexity_samples, args.ffprobe,
            )
            windows = add_complexity_windows(windows, candidates, args.max_samples)
    for window in windows:
        print(f"{window.kind}\t{window.start:.6f}\t{window.length:.6f}")
    return 0


def command_evaluate(args: argparse.Namespace) -> int:
    try:
        result = evaluate_manifest(
            args.manifest, args.duration, args.threshold, args.low_percentile,
            args.percentile_delta, args.sustained_delta, args.sustained_seconds,
        )
    except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError) as exc:
        print(json.dumps({"policy": POLICY_VERSION, "status": "error", "error": str(exc)}))
        return 2
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if result["status"] == "pass" else 3


def command_retry(args: argparse.Namespace) -> int:
    try:
        candidate = higher_quality(args.encoder, args.quality, args.step)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    if candidate is None:
        return 3
    print(candidate)
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    sub = root.add_subparsers(dest="command", required=True)

    plan = sub.add_parser("plan")
    plan.add_argument("--input", required=True)
    plan.add_argument("--duration", type=float, required=True)
    plan.add_argument("--mode", choices=("sampled", "full"), default="sampled")
    plan.add_argument("--sample-seconds", type=float, default=4.0)
    plan.add_argument("--interval-seconds", type=float, default=300.0)
    plan.add_argument("--min-samples", type=int, default=5)
    plan.add_argument("--max-samples", type=int, default=16)
    plan.add_argument("--complexity-samples", type=int, default=2)
    plan.add_argument("--ffprobe", default="ffprobe")
    plan.set_defaults(func=command_plan)

    evaluate = sub.add_parser("evaluate")
    evaluate.add_argument("--manifest", required=True)
    evaluate.add_argument("--duration", type=float, required=True)
    evaluate.add_argument("--threshold", type=float, required=True)
    evaluate.add_argument("--low-percentile", type=float, default=10.0)
    evaluate.add_argument("--percentile-delta", type=float, default=4.0)
    evaluate.add_argument("--sustained-delta", type=float, default=6.0)
    evaluate.add_argument("--sustained-seconds", type=float, default=1.0)
    evaluate.set_defaults(func=command_evaluate)

    retry = sub.add_parser("retry-quality")
    retry.add_argument("--encoder", required=True)
    retry.add_argument("--quality", type=int, required=True)
    retry.add_argument("--step", type=int, default=2)
    retry.set_defaults(func=command_retry)

    version = sub.add_parser("policy-version")
    version.set_defaults(func=lambda _args: (print(POLICY_VERSION), 0)[1])
    return root


def main() -> int:
    args = parser().parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
