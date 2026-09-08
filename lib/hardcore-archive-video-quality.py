#!/usr/bin/env python3
"""Plan and evaluate completed-video VMAF acceptance checks.

Cheap encoder calibration is deliberately separate from acceptance of the actual
completed output. Sampled mode is bounded and reproducible; full mode scores the
complete requested timeline and is intentionally more expensive.

Coverage is evidence-based. A requested window is not counted as measured merely
because it appears in the sample plan or because FFmpeg produced a non-empty VMAF
log. The evaluator independently inspects decoded frame timestamps/durations from
both the reference and completed output, checks that VMAF scored the expected
candidate frame population, and reports only the timeline overlap confirmed by
that evidence.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import subprocess
import sys
from dataclasses import dataclass
from functools import lru_cache
from typing import Callable, Sequence

POLICY_VERSION = "completed-video-quality-v2-evidence-coverage"
FRAME_BOUNDARY_TOLERANCE_SECONDS = 0.050
STREAM_ENDPOINT_TOLERANCE_SECONDS = 0.100
FRAME_SELECTION_EPSILON_SECONDS = 0.000001
VMAF_FRAME_COUNT_TOLERANCE = 1
VMAF_FRAME_COUNT_TOLERANCE_MIN_FRAMES = 30
INITIAL_PROBE_SEEK_BACK_SECONDS = 2.0
FALLBACK_PROBE_SEEK_BACK_SECONDS = 60.0


@dataclass(frozen=True)
class Window:
    kind: str
    start: float
    length: float

    @property
    def end(self) -> float:
        return self.start + self.length


@dataclass(frozen=True)
class FrameObservation:
    pts: float
    duration: float | None = None


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
    right = min(a.end, b.end)
    if right <= left:
        return 0.0
    return (right - left) / min(a.length, b.length)


def union_intervals(intervals: Sequence[tuple[float, float]]) -> list[tuple[float, float]]:
    clean = sorted((float(start), float(end)) for start, end in intervals if end > start)
    if not clean:
        return []
    merged: list[tuple[float, float]] = []
    left, right = clean[0]
    for start, end in clean[1:]:
        if start <= right:
            right = max(right, end)
        else:
            merged.append((left, right))
            left, right = start, end
    merged.append((left, right))
    return merged


def interval_coverage(intervals: Sequence[tuple[float, float]]) -> float:
    return sum(end - start for start, end in union_intervals(intervals))


def union_coverage(windows: Sequence[Window]) -> float:
    return interval_coverage([(w.start, w.end) for w in windows])


def intersect_intervals(
    first: Sequence[tuple[float, float]], second: Sequence[tuple[float, float]]
) -> list[tuple[float, float]]:
    a = union_intervals(first)
    b = union_intervals(second)
    result: list[tuple[float, float]] = []
    i = j = 0
    while i < len(a) and j < len(b):
        left = max(a[i][0], b[j][0])
        right = min(a[i][1], b[j][1])
        if right > left:
            result.append((left, right))
        if a[i][1] <= b[j][1]:
            i += 1
        else:
            j += 1
    return result


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
    intervals = max(1, math.ceil(duration / interval_seconds))
    desired = min_samples + max(0, intervals - 1)
    count = min(uniform_cap, desired)
    length = min(sample_seconds, duration)
    windows = []
    for index in range(count):
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
    """Return deterministic high-packet-rate windows as inexpensive scene hints."""
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


def read_vmaf_log(path: str) -> tuple[float, list[float], list[int]]:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    pooled = _finite(data["pooled_metrics"]["vmaf"]["mean"])
    raw_frames = data["frames"]
    if not isinstance(raw_frames, list) or not raw_frames:
        raise ValueError("missing VMAF frames")
    frames: list[float] = []
    frame_numbers: list[int] = []
    for index, frame in enumerate(raw_frames):
        if not isinstance(frame, dict):
            raise ValueError("malformed VMAF frame record")
        number = frame.get("frameNum")
        if not isinstance(number, int) or isinstance(number, bool):
            raise ValueError("missing/malformed VMAF frame number")
        if number != index:
            raise ValueError("non-contiguous VMAF frame numbers")
        value = _finite(frame["metrics"]["vmaf"])
        if not 0.0 <= value <= 100.0:
            raise ValueError("VMAF frame outside 0..100")
        frames.append(value)
        frame_numbers.append(number)
    if not 0.0 <= pooled <= 100.0:
        raise ValueError("pooled VMAF outside 0..100")
    arithmetic_mean = sum(frames) / len(frames)
    if abs(pooled - arithmetic_mean) > 0.05:
        raise ValueError(
            f"VMAF pooled mean {pooled:.6f} inconsistent with frame mean {arithmetic_mean:.6f}"
        )
    return pooled, frames, frame_numbers


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


@lru_cache(maxsize=16)
def probe_stream_start(path: str, ffprobe: str = "ffprobe") -> float:
    command = [
        ffprobe, "-v", "error", "-select_streams", "V:0",
        "-show_entries", "stream=start_time", "-of", "default=nw=1:nk=1", path,
    ]
    process = subprocess.run(
        command, capture_output=True, text=True, encoding="utf-8", errors="replace"
    )
    if process.returncode != 0:
        raise ValueError(f"ffprobe stream origin failed: {process.stderr.strip() or process.returncode}")
    value = process.stdout.strip().splitlines()
    if not value or value[0] in ("", "N/A"):
        return 0.0
    try:
        return _finite(value[0])
    except ValueError as exc:
        raise ValueError("invalid video stream start_time") from exc


def _parse_frame_line(line: str) -> FrameObservation | None:
    fields: dict[str, str] = {}
    for part in line.strip().split("|"):
        if "=" not in part:
            continue
        key, value = part.split("=", 1)
        fields[key] = value
    pts_raw = fields.get("best_effort_timestamp_time") or fields.get("pts_time")
    if not pts_raw or pts_raw == "N/A":
        return None
    try:
        pts = _finite(pts_raw)
    except (TypeError, ValueError):
        return None
    duration: float | None = None
    duration_raw = fields.get("duration_time") or fields.get("pkt_duration_time")
    if duration_raw and duration_raw != "N/A":
        try:
            parsed = _finite(duration_raw)
        except (TypeError, ValueError):
            parsed = 0.0
        if parsed > 0:
            duration = parsed
    return FrameObservation(pts=pts, duration=duration)


def _probe_frames_once(
    path: str, window: Window, seek_back: float, ffprobe: str
) -> list[FrameObservation]:
    timestamp_origin = probe_stream_start(path, ffprobe)
    probe_start = timestamp_origin + max(0.0, window.start - max(0.0, seek_back))
    command = [
        ffprobe, "-v", "error", "-select_streams", "V:0",
        "-read_intervals", f"{probe_start:.9f}%",
        "-show_frames",
        "-show_entries", "frame=pts_time,best_effort_timestamp_time,duration_time,pkt_duration_time",
        "-of", "compact=p=0:nk=0", path,
    ]
    try:
        process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="replace",
        )
    except OSError as exc:
        raise ValueError(f"ffprobe frame evidence unavailable: {exc}") from exc

    observations: list[FrameObservation] = []
    deliberately_stopped = False
    assert process.stdout is not None
    try:
        for line in process.stdout:
            observation = _parse_frame_line(line)
            if observation is None:
                continue
            observation = FrameObservation(
                pts=observation.pts - timestamp_origin, duration=observation.duration
            )
            if observations and observation.pts + 1e-9 < observations[-1].pts:
                process.kill()
                process.wait()
                raise ValueError("non-monotonic decoded frame timestamps")
            if observations and abs(observation.pts - observations[-1].pts) <= 1e-9:
                continue
            observations.append(observation)
            # One frame after the requested end is enough to infer the display
            # duration of the preceding VFR frame when frame duration is absent.
            if observation.pts > window.end + FRAME_BOUNDARY_TOLERANCE_SECONDS:
                deliberately_stopped = True
                process.terminate()
                break
    finally:
        process.stdout.close()

    try:
        returncode = process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        returncode = process.wait()
    stderr = ""
    if process.stderr is not None:
        stderr = process.stderr.read().strip()
        process.stderr.close()
    if not deliberately_stopped and returncode != 0:
        raise ValueError(f"ffprobe frame evidence failed: {stderr or returncode}")
    if not observations:
        raise ValueError("no decoded frame timestamp evidence")
    return observations


def frame_spans(observations: Sequence[FrameObservation]) -> list[tuple[float, float]]:
    spans: list[tuple[float, float]] = []
    for index, frame in enumerate(observations):
        end: float | None = None
        if index + 1 < len(observations) and observations[index + 1].pts > frame.pts:
            end = observations[index + 1].pts
        elif frame.duration is not None and frame.duration > 0:
            end = frame.pts + frame.duration
        if end is not None and end > frame.pts:
            spans.append((frame.pts, end))
    return spans


def analyze_timeline_evidence(
    observations: Sequence[FrameObservation], window: Window, *, stream_endpoint: bool = False
) -> dict[str, object]:
    spans = frame_spans(observations)
    clipped = [
        (max(start, window.start), min(end, window.end))
        for start, end in spans
        if end > window.start and start < window.end
    ]
    merged = union_intervals(clipped)
    coverage = interval_coverage(merged)
    if merged:
        start_gap = max(0.0, merged[0][0] - window.start)
        end_gap = max(0.0, window.end - merged[-1][1])
        internal_gap = max(
            (max(0.0, merged[index + 1][0] - merged[index][1])
             for index in range(len(merged) - 1)), default=0.0,
        )
    else:
        start_gap = end_gap = window.length
        internal_gap = 0.0

    display_spans = frame_spans(observations)
    selected: list[FrameObservation] = []
    selected_durations: list[float] = []
    for frame_index, frame in enumerate(observations):
        # Coverage evidence may look slightly outside the requested boundaries so
        # it can prove display continuity. Frame-population matching must not use
        # that wider tolerance: FFmpeg -ss/-t scores frames whose timestamps are
        # in [start,end), with only a tiny floating-point comparison epsilon.
        if (
            frame.pts + FRAME_SELECTION_EPSILON_SECONDS < window.start
            or frame.pts >= window.end - FRAME_SELECTION_EPSILON_SECONDS
        ):
            continue
        selected.append(frame)
        if frame_index < len(display_spans):
            span_start, span_end = display_spans[frame_index]
            selected_durations.append(
                max(0.0, min(span_end, window.end) - max(span_start, window.start))
            )
        else:
            selected_durations.append(0.0)
    endpoint_tolerance = (
        STREAM_ENDPOINT_TOLERANCE_SECONDS if stream_endpoint
        else FRAME_BOUNDARY_TOLERANCE_SECONDS
    )
    reasons: list[str] = []
    if start_gap > FRAME_BOUNDARY_TOLERANCE_SECONDS:
        reasons.append(f"start-gap {start_gap:.6f}s > {FRAME_BOUNDARY_TOLERANCE_SECONDS:.3f}s")
    if internal_gap > FRAME_BOUNDARY_TOLERANCE_SECONDS:
        reasons.append(f"internal-gap {internal_gap:.6f}s > {FRAME_BOUNDARY_TOLERANCE_SECONDS:.3f}s")
    if end_gap > endpoint_tolerance:
        reasons.append(f"end-gap {end_gap:.6f}s > {endpoint_tolerance:.3f}s")
    if not selected:
        reasons.append("no candidate frames in requested interval")
    return {
        "coverage_seconds": coverage,
        "intervals": merged,
        "frame_count": len(selected),
        "frame_durations": selected_durations,
        "observed_frames": len(observations),
        "start_gap": start_gap,
        "end_gap": end_gap,
        "max_internal_gap": internal_gap,
        "complete": not reasons,
        "reasons": reasons,
    }


def probe_frame_timeline(
    path: str, window: Window, ffprobe: str = "ffprobe"
) -> list[FrameObservation]:
    observations = _probe_frames_once(
        path, window, INITIAL_PROBE_SEEK_BACK_SECONDS, ffprobe
    )
    initial = analyze_timeline_evidence(observations, window)
    if initial["start_gap"] <= FRAME_BOUNDARY_TOLERANCE_SECONDS or window.start <= 0:
        return observations
    # Seeking can legitimately land after the desired display frame on sparse
    # or very-low-frame-rate material. Retry once farther back; this is bounded
    # and does not change the acceptance threshold.
    return _probe_frames_once(path, window, FALLBACK_PROBE_SEEK_BACK_SECONDS, ffprobe)


def _evidence_error(prefix: str, reasons: Sequence[str]) -> str:
    return f"{prefix}: " + ", ".join(reasons)


def evaluate_manifest(
    manifest_path: str,
    duration: float,
    threshold: float,
    low_percentile: float = 10.0,
    percentile_delta: float = 4.0,
    sustained_delta: float = 6.0,
    sustained_seconds: float = 1.0,
    *,
    reference_path: str,
    candidate_path: str,
    ffprobe: str = "ffprobe",
    evidence_provider: Callable[[str, Window, str], list[FrameObservation]] | None = None,
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
    if not reference_path or not candidate_path:
        raise ValueError("reference and candidate are required for timeline evidence")

    rows = read_manifest(manifest_path)
    provider = evidence_provider or probe_frame_timeline
    all_frames: list[float] = []
    window_means: list[float] = []
    longest_sustained = 0.0
    sustained_floor = threshold - sustained_delta
    evidence_reasons: list[str] = []
    confirmed_intervals: list[tuple[float, float]] = []
    window_evidence: list[dict[str, object]] = []

    for index, (window, log_path) in enumerate(rows, 1):
        if window.end > duration + STREAM_ENDPOINT_TOLERANCE_SECONDS:
            raise ValueError(f"measurement window {index} exceeds source duration")
        pooled, frames, _frame_numbers = read_vmaf_log(log_path)
        window_means.append(pooled)
        all_frames.extend(frames)

        reference_observations = provider(reference_path, window, ffprobe)
        candidate_observations = provider(candidate_path, window, ffprobe)
        stream_endpoint = window.end >= duration - STREAM_ENDPOINT_TOLERANCE_SECONDS
        reference_evidence = analyze_timeline_evidence(
            reference_observations, window, stream_endpoint=stream_endpoint
        )
        candidate_evidence = analyze_timeline_evidence(
            candidate_observations, window, stream_endpoint=stream_endpoint
        )
        overlap = intersect_intervals(
            reference_evidence["intervals"], candidate_evidence["intervals"]
        )
        timeline_overlap = interval_coverage(overlap)
        expected_frames = int(candidate_evidence["frame_count"])
        scored_frames = len(frames)

        current_reasons: list[str] = []
        if not reference_evidence["complete"]:
            current_reasons.append(
                _evidence_error("reference timeline incomplete", reference_evidence["reasons"])
            )
        if not candidate_evidence["complete"]:
            current_reasons.append(
                _evidence_error("candidate timeline incomplete", candidate_evidence["reasons"])
            )
        frame_count_difference = abs(scored_frames - expected_frames)
        allowed_frame_difference = (
            VMAF_FRAME_COUNT_TOLERANCE
            if expected_frames >= VMAF_FRAME_COUNT_TOLERANCE_MIN_FRAMES else 0
        )
        if frame_count_difference > allowed_frame_difference:
            current_reasons.append(
                f"VMAF scored {scored_frames} frame(s), candidate evidence has {expected_frames} "
                f"frame(s) in the window (allowed difference {allowed_frame_difference})"
            )
        # Even with valid endpoints, a large uncovered overlap would indicate
        # contradictory evidence. Do not convert planned duration into coverage.
        missing_overlap = max(0.0, window.length - timeline_overlap)
        overlap_tolerance = (
            2 * FRAME_BOUNDARY_TOLERANCE_SECONDS
            + (STREAM_ENDPOINT_TOLERANCE_SECONDS if stream_endpoint
               else FRAME_BOUNDARY_TOLERANCE_SECONDS)
        )
        if missing_overlap > overlap_tolerance:
            current_reasons.append(
                f"timeline overlap {timeline_overlap:.6f}s of requested {window.length:.6f}s"
            )
        if current_reasons:
            evidence_reasons.extend(
                f"window {index} ({window.kind} {window.start:.6f}s): {reason}"
                for reason in current_reasons
            )
            confirmed = 0.0
        else:
            confirmed = timeline_overlap
            confirmed_intervals.extend(overlap)

        window_evidence.append({
            "index": index,
            "kind": window.kind,
            "start": window.start,
            "requested_seconds": window.length,
            "timeline_overlap_seconds": timeline_overlap,
            "confirmed_seconds": confirmed,
            "reference_frames": int(reference_evidence["frame_count"]),
            "candidate_frames": expected_frames,
            "vmaf_frames": scored_frames,
            "complete": not current_reasons,
            "reasons": current_reasons,
        })

        # Preserve the existing sustained-low rule while avoiding any fixed-FPS
        # assumption. Exact VMAF/candidate frame populations use actual candidate
        # frame display durations; the allowed boundary mismatch falls back to
        # the evidence-confirmed window duration spread across scored frames.
        candidate_durations = [float(value) for value in candidate_evidence["frame_durations"]]
        if len(candidate_durations) == len(frames) and sum(candidate_durations) > 0:
            score_durations = candidate_durations
        else:
            seconds_per_score = confirmed / len(frames) if frames else 0.0
            score_durations = [seconds_per_score] * len(frames)
        run_seconds = 0.0
        best_seconds = 0.0
        for value, score_duration in zip(frames, score_durations):
            if value < sustained_floor:
                run_seconds += max(0.0, score_duration)
                best_seconds = max(best_seconds, run_seconds)
            else:
                run_seconds = 0.0
        longest_sustained = max(longest_sustained, best_seconds)

    if not all_frames or not window_means:
        raise ValueError("empty VMAF measurements")

    aggregate_mean = sum(all_frames) / len(all_frames)
    low_value = percentile(all_frames, low_percentile)
    minimum_window = min(window_means)
    percentile_floor = threshold - percentile_delta
    quality_reasons: list[str] = []
    if aggregate_mean < threshold:
        quality_reasons.append(f"mean-vmaf {aggregate_mean:.3f} < target {threshold:.3f}")
    if minimum_window < threshold:
        quality_reasons.append(f"window-mean {minimum_window:.3f} < target {threshold:.3f}")
    if low_value < percentile_floor:
        quality_reasons.append(
            f"p{low_percentile:g}-vmaf {low_value:.3f} < floor {percentile_floor:.3f}"
        )
    if longest_sustained + 1e-9 >= sustained_seconds:
        quality_reasons.append(
            f"sustained-low-quality {longest_sustained:.3f}s >= {sustained_seconds:.3f}s "
            f"below {sustained_floor:.3f}"
        )

    windows = [window for window, _ in rows]
    requested_coverage_seconds = min(duration, union_coverage(windows))
    confirmed_coverage_seconds = min(duration, interval_coverage(confirmed_intervals))
    if evidence_reasons:
        status = "error"
        reasons = evidence_reasons
    elif quality_reasons:
        status = "reject"
        reasons = quality_reasons
    else:
        status = "pass"
        reasons = []

    return {
        "policy": POLICY_VERSION,
        "status": status,
        "windows": len(windows),
        "frames": len(all_frames),
        "requested_coverage_seconds": requested_coverage_seconds,
        "requested_coverage_percent": requested_coverage_seconds * 100.0 / duration,
        "coverage_seconds": confirmed_coverage_seconds,
        "coverage_percent": confirmed_coverage_seconds * 100.0 / duration,
        "evidence_complete": not evidence_reasons,
        "boundary_tolerance_seconds": FRAME_BOUNDARY_TOLERANCE_SECONDS,
        "stream_endpoint_tolerance_seconds": STREAM_ENDPOINT_TOLERANCE_SECONDS,
        "frame_selection_epsilon_seconds": FRAME_SELECTION_EPSILON_SECONDS,
        "vmaf_frame_count_tolerance": VMAF_FRAME_COUNT_TOLERANCE,
        "vmaf_frame_count_tolerance_min_frames": VMAF_FRAME_COUNT_TOLERANCE_MIN_FRAMES,
        "mean_vmaf": aggregate_mean,
        "minimum_window_mean": minimum_window,
        "low_percentile": low_percentile,
        "low_percentile_vmaf": low_value,
        "low_percentile_floor": percentile_floor,
        "sustained_floor": sustained_floor,
        "longest_sustained_seconds": longest_sustained,
        "window_evidence": window_evidence,
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
            reference_path=args.reference, candidate_path=args.candidate,
            ffprobe=args.ffprobe,
        )
    except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError) as exc:
        print(json.dumps({"policy": POLICY_VERSION, "status": "error", "error": str(exc)}))
        return 2
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    if result["status"] == "pass":
        return 0
    if result["status"] == "reject":
        return 3
    return 2


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
    evaluate.add_argument("--reference", required=True)
    evaluate.add_argument("--candidate", required=True)
    evaluate.add_argument("--ffprobe", default="ffprobe")
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
