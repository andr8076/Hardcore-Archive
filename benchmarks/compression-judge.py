#!/usr/bin/env python3
"""
Compression Judge
=================

Benchmarks multiple compressors against one source folder.

Fairness model:
- Generic lossless compressors and BaseCompresser receive the exact same canonical
  TAR byte stream.
- Hardcore-Archive receives the original folder so its file-aware policy can work.
- Hardcore-Archive is also run in an explicitly lossless mode.
- Every result is restored and compared against a SHA-256 manifest of the source.
- Results that changed payload bytes are NEVER allowed to win the exact-lossless
  leaderboard.

No third-party Python packages are required.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import platform
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Callable, Iterable, Optional


DEFAULT_METHODS = (
    "hardcore",
    "hardcore-lossless",
    "base9",
    "7z",
    "zstd",
    "xz",
    "gzip",
    "bzip2",
    "lz4",
    "brotli",
)


@dataclass
class Result:
    method: str
    status: str = "PENDING"
    category: str = "lossless"
    command: str = ""
    restore_command: str = ""
    archive_path: str = ""
    archive_bytes: Optional[int] = None
    payload_bytes: int = 0
    canonical_tar_bytes: int = 0
    ratio_percent: Optional[float] = None
    saving_percent: Optional[float] = None
    compress_seconds: Optional[float] = None
    decompress_seconds: Optional[float] = None
    compress_mib_s: Optional[float] = None
    decompress_mib_s: Optional[float] = None
    exact_payload_roundtrip: Optional[bool] = None
    difference_count: int = 0
    difference_report: str = ""
    verification: str = "not-run"
    note: str = ""
    log_path: str = ""
    score: Optional[float] = None
    size_rank: Optional[int] = None
    score_rank: Optional[int] = None
    executable: str = ""
    version: str = ""


class JudgeError(RuntimeError):
    pass


class StatusWriter:
    """Keep a machine-readable heartbeat beside long-running benchmark output."""

    def __init__(self, path: Path, interval: float, initial: dict):
        self.path = path
        self.interval = interval
        self.data = dict(initial)
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._run, name="judge-heartbeat", daemon=True)

    def _write(self) -> None:
        with self.lock:
            data = dict(self.data)
            data["heartbeat_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            temporary = self.path.with_name(self.path.name + ".tmp")
            temporary.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")
            os.replace(temporary, self.path)

    def _run(self) -> None:
        while not self.stop_event.wait(self.interval):
            self._write()

    def start(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._write()
        self.thread.start()

    def update(self, **values) -> None:
        with self.lock:
            self.data.update(values)
        self._write()

    def finish(self, **values) -> None:
        self.stop_event.set()
        with self.lock:
            self.data.update(values)
        self._write()


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def human_bytes(value: Optional[int]) -> str:
    if value is None:
        return "-"
    n = float(value)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB", "PiB"):
        if abs(n) < 1024.0 or unit == "PiB":
            return f"{n:.2f} {unit}" if unit != "B" else f"{int(n)} B"
        n /= 1024.0
    return f"{value} B"


def human_seconds(value: Optional[float]) -> str:
    if value is None:
        return "-"
    if value < 1:
        return f"{value:.3f}s"
    if value < 60:
        return f"{value:.2f}s"
    minutes, seconds = divmod(value, 60)
    if minutes < 60:
        return f"{int(minutes)}m {seconds:.1f}s"
    hours, minutes = divmod(minutes, 60)
    return f"{int(hours)}h {int(minutes)}m {seconds:.0f}s"


def quote_cmd(cmd: Iterable[str]) -> str:
    return " ".join(shlex.quote(str(x)) for x in cmd)


def sha256_file(path: Path, chunk_size: int = 8 * 1024 * 1024) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def folder_manifest(root: Path) -> dict:
    """
    Manifest payload identity, not timestamps/ownership.

    Records:
      F = regular file, including size + SHA-256
      L = symlink, including link target
      D = directory
      O = other filesystem object
    """
    root = root.resolve()
    if not root.is_dir():
        raise JudgeError(f"Not a directory: {root}")

    entries = {}
    for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        rel_dir = current_path.relative_to(root)

        # os.walk places symlinked directories in dirs. Record them as links and
        # prevent traversal.
        real_dirs = []
        for name in sorted(dirs):
            p = current_path / name
            rel = (rel_dir / name).as_posix()
            if p.is_symlink():
                entries[rel] = {"type": "L", "target": os.readlink(p)}
            else:
                entries[rel] = {"type": "D"}
                real_dirs.append(name)
        dirs[:] = real_dirs

        for name in sorted(files):
            p = current_path / name
            rel = (rel_dir / name).as_posix()
            if p.is_symlink():
                entries[rel] = {"type": "L", "target": os.readlink(p)}
            elif p.is_file():
                st = p.stat()
                entries[rel] = {
                    "type": "F",
                    "size": st.st_size,
                    "sha256": sha256_file(p),
                }
            else:
                entries[rel] = {"type": "O"}

    return entries


def payload_size(manifest: dict) -> int:
    return sum(v.get("size", 0) for v in manifest.values() if v["type"] == "F")


def manifest_diff_entries(expected: dict, actual: dict):
    all_keys = sorted(set(expected) | set(actual))
    for key in all_keys:
        a = expected.get(key)
        b = actual.get(key)
        if a == b:
            continue
        if a is None:
            yield f"extra: {key}"
        elif b is None:
            yield f"missing: {key}"
        elif a.get("type") != b.get("type"):
            yield f"type changed: {key} ({a.get('type')} -> {b.get('type')})"
        elif a.get("type") == "F":
            if a.get("size") != b.get("size"):
                yield f"size changed: {key} ({a.get('size')} -> {b.get('size')})"
            else:
                yield f"content changed: {key}"
        elif a.get("type") == "L":
            yield f"symlink target changed: {key}"
        else:
            yield f"metadata/entry changed: {key}"


def manifest_diff(expected: dict, actual: dict, limit: int = 20) -> list[str]:
    diffs = list(manifest_diff_entries(expected, actual))
    if len(diffs) > limit:
        return [*diffs[:limit], f"... and {len(diffs) - limit} more differences"]
    return diffs


def canonical_tar_filter(info: tarfile.TarInfo) -> tarfile.TarInfo:
    # Normalize volatile metadata so every stream compressor sees reproducible bytes.
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = 0
    info.pax_headers = {}
    return info


def create_canonical_tar(source: Path, out_tar: Path) -> None:
    out_tar.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(out_tar, "w", format=tarfile.PAX_FORMAT) as tf:
        # Python's tarfile recursively traverses directory children in sorted order.
        tf.add(
            source,
            arcname="payload",
            recursive=True,
            filter=canonical_tar_filter,
        )


def extract_owned_tar(tar_path: Path, destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(tar_path, "r") as tf:
        # This TAR was created by this judge from the user's own source folder.
        # fully_trusted preserves symlinks exactly, including absolute targets.
        try:
            tf.extractall(destination, filter="fully_trusted")
        except TypeError:
            tf.extractall(destination)
    payload = destination / "payload"
    if not payload.is_dir():
        raise JudgeError(f"Restored TAR did not contain payload/: {tar_path}")
    return payload


def resolve_executable(
    explicit: Optional[str],
    names: Iterable[str],
    directory_candidates: Iterable[str] = (),
) -> Optional[str]:
    """
    Resolve either:
      - an executable name in PATH,
      - an explicit executable file, or
      - a project directory containing a known executable.

    This lets --hardcore /path/to/Hardcore-Archive and
    --basecompresser /path/to/BaseCompresser work naturally.
    """
    if explicit:
        p = Path(explicit).expanduser()

        if p.is_dir():
            for relative in directory_candidates:
                candidate = p / relative
                if candidate.is_file():
                    # Executable bit is ideal, but scripts can still be launched
                    # directly only when it is present. Give a clear result here;
                    # the caller will report any launch problem in its method log.
                    return str(candidate.resolve())
            return None

        if p.is_file():
            return str(p.resolve())

        found = shutil.which(explicit)
        if found:
            return found
        return None

    for name in names:
        found = shutil.which(name)
        if found:
            return found
    return None


def first_version_line(exe: str, candidates: list[list[str]]) -> str:
    for suffix in candidates:
        try:
            p = subprocess.run(
                [exe, *suffix],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                errors="replace",
                timeout=10,
            )
            text = (p.stdout or "").strip()
            if text:
                return text.splitlines()[0][:240]
        except Exception:
            pass
    return ""


def run_logged(
    cmd: list[str],
    log: Path,
    cwd: Optional[Path] = None,
    stdout_file: Optional[Path] = None,
) -> tuple[int, float]:
    log.parent.mkdir(parents=True, exist_ok=True)
    start = time.perf_counter()
    with log.open("a", encoding="utf-8", errors="replace") as lf:
        lf.write("\n$ " + quote_cmd(cmd) + "\n")
        lf.flush()
        if stdout_file is None:
            proc = subprocess.run(
                cmd,
                cwd=str(cwd) if cwd else None,
                stdout=lf,
                stderr=subprocess.STDOUT,
            )
        else:
            stdout_file.parent.mkdir(parents=True, exist_ok=True)
            with stdout_file.open("wb") as out:
                proc = subprocess.run(
                    cmd,
                    cwd=str(cwd) if cwd else None,
                    stdout=out,
                    stderr=lf,
                )
    return proc.returncode, time.perf_counter() - start


def remove_path(path: Path):
    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
    elif path.is_dir():
        shutil.rmtree(path)


def restored_root_flexible(destination: Path, source_name: str) -> Path:
    """
    Hardcore restore versions may restore directly into DEST or recreate the source
    root beneath it. Try the obvious layouts without hiding extra files.
    """
    candidate = destination / source_name
    if candidate.is_dir():
        # Only choose nested root when the destination contains just that root.
        children = list(destination.iterdir())
        if len(children) == 1:
            return candidate
    return destination


def verify_restored(
    restored_root: Path,
    expected_manifest: dict,
    difference_report: Optional[Path] = None,
) -> tuple[bool, list[str], int]:
    actual = folder_manifest(restored_root)
    all_diffs = list(manifest_diff_entries(expected_manifest, actual))
    if difference_report is not None:
        if all_diffs:
            difference_report.write_text("\n".join(all_diffs) + "\n", encoding="utf-8")
        else:
            difference_report.unlink(missing_ok=True)
    visible = all_diffs[:20]
    if len(all_diffs) > 20:
        visible.append(f"... and {len(all_diffs) - 20} more differences")
    return not all_diffs, visible, len(all_diffs)


def archive_metrics(result: Result):
    if result.archive_bytes is not None and result.payload_bytes > 0:
        result.ratio_percent = result.archive_bytes / result.payload_bytes * 100.0
        result.saving_percent = 100.0 - result.ratio_percent
    if result.compress_seconds and result.compress_seconds > 0:
        result.compress_mib_s = (
            result.payload_bytes / (1024 * 1024) / result.compress_seconds
        )
    if result.decompress_seconds and result.decompress_seconds > 0:
        result.decompress_mib_s = (
            result.payload_bytes / (1024 * 1024) / result.decompress_seconds
        )


def benchmark_stream_method(
    name: str,
    exe: str,
    source_tar: Path,
    source_manifest: dict,
    payload_bytes_value: int,
    out_dir: Path,
    compress_cmd_builder: Callable[[Path], list[str]],
    decompress_cmd_builder: Callable[[Path], list[str]],
    archive_suffix: str,
    compression_stdout: bool = False,
    decompression_stdout: bool = False,
) -> Result:
    result = Result(method=name, category="lossless", executable=exe)
    result.payload_bytes = payload_bytes_value
    result.canonical_tar_bytes = source_tar.stat().st_size
    result.version = first_version_line(exe, [["--version"], ["-V"], ["-h"]])

    method_dir = out_dir / name
    method_dir.mkdir(parents=True, exist_ok=True)
    log = method_dir / "run.log"
    archive = method_dir / f"archive{archive_suffix}"
    restored_tar = method_dir / "restored.tar"
    restored_dir = method_dir / "restored"

    for p in (archive, restored_tar, restored_dir):
        if p.exists():
            remove_path(p)

    compress_cmd = compress_cmd_builder(archive)
    result.command = quote_cmd(compress_cmd)
    result.log_path = str(log)

    rc, elapsed = run_logged(
        compress_cmd,
        log,
        stdout_file=archive if compression_stdout else None,
    )
    result.compress_seconds = elapsed
    if rc != 0 or not archive.is_file():
        result.status = "FAIL"
        result.verification = "compression-failed"
        result.note = f"Compression exited with code {rc}. See {log}"
        return result

    result.archive_path = str(archive)
    result.archive_bytes = archive.stat().st_size

    decompress_cmd = decompress_cmd_builder(archive)
    result.restore_command = quote_cmd(decompress_cmd)
    rc, elapsed = run_logged(
        decompress_cmd,
        log,
        stdout_file=restored_tar if decompression_stdout else None,
    )
    result.decompress_seconds = elapsed
    if rc != 0 or not restored_tar.is_file():
        result.status = "FAIL"
        result.verification = "restore-failed"
        result.note = f"Decompression exited with code {rc}. See {log}"
        archive_metrics(result)
        return result

    try:
        payload_root = extract_owned_tar(restored_tar, restored_dir)
        difference_report = method_dir / "payload-differences.txt"
        exact, diffs, difference_count = verify_restored(
            payload_root, source_manifest, difference_report
        )
    except Exception as exc:
        result.status = "FAIL"
        result.verification = "restore-verify-error"
        result.note = str(exc)
        archive_metrics(result)
        return result

    result.exact_payload_roundtrip = exact
    result.difference_count = difference_count
    if difference_count:
        result.difference_report = str(difference_report)
    if exact:
        result.status = "PASS"
        result.verification = "sha256-manifest"
    else:
        result.status = "FAIL"
        result.verification = "payload-mismatch"
        result.note = "; ".join(diffs)

    archive_metrics(result)
    return result


def benchmark_7z(
    exe: str,
    source_tar: Path,
    source_manifest: dict,
    payload_bytes_value: int,
    out_dir: Path,
) -> Result:
    name = "7z"
    result = Result(method=name, category="lossless", executable=exe)
    result.payload_bytes = payload_bytes_value
    result.canonical_tar_bytes = source_tar.stat().st_size
    result.version = first_version_line(exe, [["i"], ["-h"]])

    method_dir = out_dir / name
    method_dir.mkdir(parents=True, exist_ok=True)
    log = method_dir / "run.log"
    archive = method_dir / "archive.7z"
    unpack = method_dir / "unpack"
    restored_dir = method_dir / "restored"

    for p in (archive, unpack, restored_dir):
        if p.exists():
            remove_path(p)

    cmd = [
        exe, "a", "-t7z", "-mx=9", "-m0=lzma2", "-ms=on",
        str(archive), str(source_tar),
    ]
    result.command = quote_cmd(cmd)
    result.log_path = str(log)
    rc, elapsed = run_logged(cmd, log)
    result.compress_seconds = elapsed
    if rc != 0 or not archive.is_file():
        result.status = "FAIL"
        result.verification = "compression-failed"
        result.note = f"7z exited with code {rc}. See {log}"
        return result

    result.archive_path = str(archive)
    result.archive_bytes = archive.stat().st_size

    unpack.mkdir(parents=True, exist_ok=True)
    cmd = [exe, "x", "-y", f"-o{unpack}", str(archive)]
    result.restore_command = quote_cmd(cmd)
    rc, elapsed = run_logged(cmd, log)
    result.decompress_seconds = elapsed
    if rc != 0:
        result.status = "FAIL"
        result.verification = "restore-failed"
        result.note = f"7z restore exited with code {rc}. See {log}"
        archive_metrics(result)
        return result

    # 7z stores the TAR by basename.
    restored_tar = unpack / source_tar.name
    if not restored_tar.is_file():
        tar_candidates = list(unpack.rglob("*.tar"))
        if len(tar_candidates) == 1:
            restored_tar = tar_candidates[0]
        else:
            result.status = "FAIL"
            result.verification = "restore-failed"
            result.note = "Could not locate restored canonical TAR."
            archive_metrics(result)
            return result

    try:
        payload_root = extract_owned_tar(restored_tar, restored_dir)
        difference_report = method_dir / "payload-differences.txt"
        exact, diffs, difference_count = verify_restored(
            payload_root, source_manifest, difference_report
        )
    except Exception as exc:
        result.status = "FAIL"
        result.verification = "restore-verify-error"
        result.note = str(exc)
        archive_metrics(result)
        return result

    result.exact_payload_roundtrip = exact
    result.difference_count = difference_count
    if difference_count:
        result.difference_report = str(difference_report)
    if exact:
        result.status = "PASS"
        result.verification = "sha256-manifest"
    else:
        result.status = "FAIL"
        result.verification = "payload-mismatch"
        result.note = "; ".join(diffs)

    archive_metrics(result)
    return result


def benchmark_base9(
    exe: str,
    source_tar: Path,
    source_manifest: dict,
    payload_bytes_value: int,
    out_dir: Path,
) -> Result:
    name = "base9"
    result = Result(method=name, category="lossless", executable=exe)
    result.payload_bytes = payload_bytes_value
    result.canonical_tar_bytes = source_tar.stat().st_size
    result.version = first_version_line(exe, [["--version"]])

    method_dir = out_dir / name
    method_dir.mkdir(parents=True, exist_ok=True)
    log = method_dir / "run.log"
    archive = method_dir / "archive.base9"
    restored_tar = method_dir / "restored.tar"
    restored_dir = method_dir / "restored"

    for p in (archive, restored_tar, restored_dir):
        if p.exists():
            remove_path(p)

    cmd = [exe, "encode", str(source_tar), "-o", str(archive)]
    result.command = quote_cmd(cmd)
    result.log_path = str(log)
    rc, elapsed = run_logged(cmd, log)
    result.compress_seconds = elapsed
    if rc != 0 or not archive.is_file():
        result.status = "FAIL"
        result.verification = "compression-failed"
        result.note = f"BaseCompresser exited with code {rc}. See {log}"
        return result

    result.archive_path = str(archive)
    result.archive_bytes = archive.stat().st_size

    cmd = [exe, "decode", str(archive), "-o", str(restored_tar)]
    result.restore_command = quote_cmd(cmd)
    rc, elapsed = run_logged(cmd, log)
    result.decompress_seconds = elapsed
    if rc != 0 or not restored_tar.is_file():
        result.status = "FAIL"
        result.verification = "restore-failed"
        result.note = f"BaseCompresser decode exited with code {rc}. See {log}"
        archive_metrics(result)
        return result

    try:
        payload_root = extract_owned_tar(restored_tar, restored_dir)
        difference_report = method_dir / "payload-differences.txt"
        exact, diffs, difference_count = verify_restored(
            payload_root, source_manifest, difference_report
        )
    except Exception as exc:
        result.status = "FAIL"
        result.verification = "restore-verify-error"
        result.note = str(exc)
        archive_metrics(result)
        return result

    result.exact_payload_roundtrip = exact
    result.difference_count = difference_count
    if difference_count:
        result.difference_report = str(difference_report)
    if exact:
        result.status = "PASS"
        result.verification = "sha256-manifest"
    else:
        result.status = "FAIL"
        result.verification = "payload-mismatch"
        result.note = "; ".join(diffs)

    archive_metrics(result)
    return result


def benchmark_hardcore(
    exe: str,
    source: Path,
    source_manifest: dict,
    payload_bytes_value: int,
    canonical_tar_bytes: int,
    out_dir: Path,
    lossless: bool,
) -> Result:
    name = "hardcore-lossless" if lossless else "hardcore"
    category = "lossless" if lossless else "transform-capable"
    result = Result(method=name, category=category, executable=exe)
    result.payload_bytes = payload_bytes_value
    result.canonical_tar_bytes = canonical_tar_bytes
    result.version = first_version_line(exe, [["--version"]])

    method_dir = out_dir / name
    method_dir.mkdir(parents=True, exist_ok=True)
    log = method_dir / "run.log"
    archive = method_dir / "archive.7z"
    restored_dir = method_dir / "restored"

    for p in (archive, restored_dir):
        if p.exists():
            remove_path(p)

    cmd = [
        exe,
        "-y",
        "--no-poweroff",
        "--video-special-policy", "preserve",
    ]
    if lossless:
        cmd += [
            "--no-video-transcode",
            "--no-image-optimize",
            "--no-nested-repack",
            "--no-container-repack",
        ]
    cmd += [str(source), str(archive)]

    result.command = quote_cmd(cmd)
    result.log_path = str(log)
    rc, elapsed = run_logged(cmd, log)
    result.compress_seconds = elapsed
    if rc != 0 or not archive.is_file():
        result.status = "FAIL"
        result.verification = "compression-failed"
        result.note = f"Hardcore-Archive exited with code {rc}. See {log}"
        return result

    result.archive_path = str(archive)
    result.archive_bytes = archive.stat().st_size

    restored_dir.mkdir(parents=True, exist_ok=True)
    cmd = [exe, "-y", "--restore", str(archive), str(restored_dir)]
    result.restore_command = quote_cmd(cmd)
    rc, elapsed = run_logged(cmd, log)
    result.decompress_seconds = elapsed
    if rc != 0:
        result.status = "FAIL"
        result.verification = "restore-failed"
        result.note = f"Hardcore-Archive restore exited with code {rc}. See {log}"
        archive_metrics(result)
        return result

    try:
        root = restored_root_flexible(restored_dir, source.name)
        difference_report = method_dir / "payload-differences.txt"
        exact, diffs, difference_count = verify_restored(
            root, source_manifest, difference_report
        )
    except Exception as exc:
        result.status = "FAIL"
        result.verification = "restore-verify-error"
        result.note = str(exc)
        archive_metrics(result)
        return result

    result.exact_payload_roundtrip = exact
    result.difference_count = difference_count
    if difference_count:
        result.difference_report = str(difference_report)
    if exact:
        result.status = "PASS"
        result.verification = "sha256-manifest"
        if not lossless:
            result.note = "No payload-changing transform was observed for this corpus."
    elif lossless:
        result.status = "FAIL"
        result.verification = "payload-mismatch"
        result.note = "; ".join(diffs)
    else:
        # A successful Hardcore create/restore may intentionally transform media
        # or safe containers. Do not pretend this is byte-identical.
        result.status = "TRANSFORMED"
        result.verification = "hardcore-internal-validation + restore-success"
        result.note = (
            "Payload bytes changed by Hardcore's transform-capable policy; "
            "excluded from exact-lossless ranking. Differences: "
            + "; ".join(diffs)
        )

    archive_metrics(result)
    return result


def skipped_result(name: str, why: str, payload: int, tar_bytes: int) -> Result:
    return Result(
        method=name,
        status="SKIP",
        category="lossless" if name != "hardcore" else "transform-capable",
        payload_bytes=payload,
        canonical_tar_bytes=tar_bytes,
        verification="not-run",
        note=why,
    )


def compute_rankings(results: list[Result], weights: tuple[float, float, float]):
    eligible = [
        r for r in results
        if r.status == "PASS"
        and r.exact_payload_roundtrip is True
        and r.archive_bytes is not None
        and r.compress_seconds is not None
        and r.decompress_seconds is not None
    ]
    if not eligible:
        return

    for rank, r in enumerate(sorted(eligible, key=lambda x: x.archive_bytes or 2**63), 1):
        r.size_rank = rank

    best_size = min(r.archive_bytes for r in eligible if r.archive_bytes is not None)
    best_comp = min(max(r.compress_seconds or 0.000001, 0.000001) for r in eligible)
    best_decomp = min(max(r.decompress_seconds or 0.000001, 0.000001) for r in eligible)
    ws, wc, wd = weights

    for r in eligible:
        size_factor = best_size / max(r.archive_bytes or best_size, 1)
        comp_factor = best_comp / max(r.compress_seconds or best_comp, 0.000001)
        decomp_factor = best_decomp / max(r.decompress_seconds or best_decomp, 0.000001)
        r.score = 100.0 * (ws * size_factor + wc * comp_factor + wd * decomp_factor)

    for rank, r in enumerate(sorted(eligible, key=lambda x: x.score or 0, reverse=True), 1):
        r.score_rank = rank


def write_csv(results: list[Result], path: Path):
    fields = [
        "method", "status", "category", "archive_bytes", "payload_bytes",
        "canonical_tar_bytes", "ratio_percent", "saving_percent",
        "compress_seconds", "decompress_seconds", "compress_mib_s",
        "decompress_mib_s", "exact_payload_roundtrip", "difference_count",
        "difference_report", "verification",
        "size_rank", "score", "score_rank", "archive_path", "executable",
        "version", "command", "restore_command", "note", "log_path",
    ]
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in results:
            d = asdict(r)
            w.writerow({k: d.get(k) for k in fields})


def markdown_table(results: list[Result]) -> str:
    lines = [
        "| Method | Status | Size | Payload % | Saving | Compress | Restore | Exact | Changes | Size rank | Score |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for r in results:
        ratio = "-" if r.ratio_percent is None else f"{r.ratio_percent:.2f}%"
        saving = "-" if r.saving_percent is None else f"{r.saving_percent:.2f}%"
        score = "-" if r.score is None else f"{r.score:.1f}"
        exact = "-" if r.exact_payload_roundtrip is None else ("yes" if r.exact_payload_roundtrip else "no")
        lines.append(
            f"| {r.method} | {r.status} | {human_bytes(r.archive_bytes)} | {ratio} | "
            f"{saving} | {human_seconds(r.compress_seconds)} | "
            f"{human_seconds(r.decompress_seconds)} | {exact} | "
            f"{r.difference_count} | {r.size_rank or '-'} | {score} |"
        )
    return "\n".join(lines)


def write_markdown_report(
    results: list[Result],
    path: Path,
    source: Path,
    source_manifest: dict,
    tar_path: Path,
    weights: tuple[float, float, float],
    source_stable: bool,
):
    payload = payload_size(source_manifest)
    exact = [r for r in results if r.status == "PASS" and r.exact_payload_roundtrip is True]
    transformed = [r for r in results if r.status == "TRANSFORMED"]

    lines = [
        "# Compression Judge report",
        "",
        f"- Source: `{source}`",
        f"- Payload bytes: {payload} ({human_bytes(payload)})",
        f"- Canonical TAR: `{tar_path}` ({human_bytes(tar_path.stat().st_size)})",
        f"- Source unchanged during benchmark: **{'yes' if source_stable else 'NO — RESULTS INVALID'}**",
        f"- Score weights: size {weights[0]:.0%}, compression time {weights[1]:.0%}, restore time {weights[2]:.0%}",
        "",
        "## All results",
        "",
        markdown_table(results),
        "",
        "## Exact-lossless leaderboard",
        "",
    ]

    if exact:
        for r in sorted(exact, key=lambda x: x.archive_bytes or 2**63):
            lines.append(
                f"{r.size_rank}. **{r.method}** — {human_bytes(r.archive_bytes)} "
                f"({r.ratio_percent:.2f}% of payload), compress {human_seconds(r.compress_seconds)}, "
                f"restore {human_seconds(r.decompress_seconds)}, score {(r.score or 0):.1f}"
            )
    else:
        lines.append("No method completed an exact SHA-256 payload round-trip.")

    if transformed:
        lines += [
            "",
            "## Transform-capable results",
            "",
            "These are shown separately because changed payload bytes are not directly comparable "
            "to exact-lossless compressors.",
            "",
        ]
        for r in transformed:
            lines.append(
                f"- **{r.method}** — {human_bytes(r.archive_bytes)} "
                f"({r.ratio_percent:.2f}% of original payload), "
                f"{r.difference_count} changed entries. {r.note}"
            )
            if r.difference_report:
                lines.append(f"  Full difference list: `{r.difference_report}`")

    lines += [
        "",
        "## Notes",
        "",
        "- Generic compressors and BaseCompresser compressed the exact same canonical TAR bytes.",
        "- Hardcore-Archive compressed the source folder directly so its file-aware logic remained available.",
        "- `hardcore-lossless` disables video, image, nested-archive, and application-container transformations.",
        "- A changed Hardcore result can be useful in practice, but it cannot win the exact-lossless leaderboard.",
        "- Compression methods are run sequentially to avoid CPU/RAM contention between competitors.",
        "",
    ]
    path.write_text("\n".join(lines), encoding="utf-8")


def print_summary(results: list[Result]):
    print()
    print("=" * 100)
    print("COMPRESSION JUDGE")
    print("=" * 100)
    print(f"{'Method':20} {'Status':12} {'Archive':>12} {'Payload %':>10} {'Compress':>11} {'Restore':>11} {'Exact':>7}")
    print("-" * 100)
    for r in results:
        ratio = "-" if r.ratio_percent is None else f"{r.ratio_percent:.2f}%"
        exact = "-" if r.exact_payload_roundtrip is None else ("YES" if r.exact_payload_roundtrip else "NO")
        print(
            f"{r.method:20} {r.status:12} {human_bytes(r.archive_bytes):>12} "
            f"{ratio:>10} {human_seconds(r.compress_seconds):>11} "
            f"{human_seconds(r.decompress_seconds):>11} {exact:>7}"
        )

    exact = [r for r in results if r.status == "PASS" and r.exact_payload_roundtrip is True]
    if exact:
        winner_size = min(exact, key=lambda r: r.archive_bytes or 2**63)
        winner_score = max(exact, key=lambda r: r.score or 0)
        print()
        print(f"Smallest exact archive : {winner_size.method} -> {human_bytes(winner_size.archive_bytes)}")
        print(f"Best weighted score    : {winner_score.method} -> {winner_score.score:.1f}/100")

    transformed = [r for r in results if r.status == "TRANSFORMED"]
    if transformed:
        print()
        print("Transform-capable result(s) are separate from the exact-lossless winners:")
        for r in transformed:
            print(f"  {r.method}: {human_bytes(r.archive_bytes)} ({r.ratio_percent:.2f}% of payload)")


def parse_weights(text: str) -> tuple[float, float, float]:
    try:
        values = tuple(float(x.strip()) for x in text.split(","))
    except ValueError as exc:
        raise argparse.ArgumentTypeError("weights must be three numbers: size,compress,restore") from exc
    if len(values) != 3 or any(v < 0 for v in values) or sum(values) <= 0:
        raise argparse.ArgumentTypeError("weights must be three non-negative numbers with a positive sum")
    total = sum(values)
    return tuple(v / total for v in values)  # type: ignore[return-value]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Benchmark Hardcore-Archive, BaseCompresser, and standard compressors on one folder.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("source", nargs="?", help="Folder to benchmark")
    p.add_argument(
        "-o", "--output-dir",
        help="Result directory. Existing per-method outputs inside it are replaced.",
    )
    p.add_argument(
        "--methods",
        default=",".join(DEFAULT_METHODS),
        help="Comma-separated methods: " + ",".join(DEFAULT_METHODS),
    )
    p.add_argument("--hardcore", help="Path/name of hardcore-archive executable")
    p.add_argument("--basecompresser", help="Path/name of BaseCompresser executable")
    p.add_argument("--sevenzip", help="Path/name of 7z executable")
    p.add_argument(
        "--weights",
        type=parse_weights,
        default=parse_weights("0.70,0.20,0.10"),
        help="Exact leaderboard weights: size,compression-time,restore-time",
    )
    p.add_argument(
        "--keep-restores",
        action="store_true",
        help="Keep restored TARs/folders. By default they are deleted after verification.",
    )
    p.add_argument(
        "--heartbeat-seconds",
        type=float,
        default=60.0,
        help="Refresh run-status.json this often while a compressor is still running",
    )
    p.add_argument("--list-methods", action="store_true", help="Print supported methods and exit")
    args = p.parse_args()
    if args.heartbeat_seconds < 5:
        p.error("--heartbeat-seconds must be at least 5")
    return args


def main() -> int:
    args = parse_args()

    if args.list_methods:
        print("\n".join(DEFAULT_METHODS))
        return 0

    if not args.source:
        eprint("Error: SOURCE folder is required.")
        return 2

    source = Path(args.source).expanduser().resolve()
    if not source.is_dir():
        eprint(f"Error: not a folder: {source}")
        return 2

    requested = []
    seen = set()
    for item in args.methods.split(","):
        item = item.strip().lower()
        if not item:
            continue
        if item not in DEFAULT_METHODS:
            eprint(f"Error: unknown method: {item}")
            return 2
        if item not in seen:
            seen.add(item)
            requested.append(item)

    stamp = time.strftime("%Y%m%d-%H%M%S")
    output = (
        Path(args.output_dir).expanduser().resolve()
        if args.output_dir
        else Path.cwd() / "compression-judge-results" / f"{source.name}-{stamp}"
    )
    output.mkdir(parents=True, exist_ok=True)
    status = StatusWriter(
        output / "run-status.json",
        args.heartbeat_seconds,
        {
            "schema": 1,
            "state": "starting",
            "pid": os.getpid(),
            "source": str(source),
            "output": str(output),
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "requested_methods": requested,
            "completed_methods": [],
            "current_method": None,
        },
    )
    status.start()

    print(f"Source     : {source}")
    print(f"Results    : {output}")
    print(f"Methods    : {', '.join(requested)}")
    print()
    print("[1/4] Hashing source folder...")
    status.update(state="hashing-source")
    initial_manifest = folder_manifest(source)
    payload = payload_size(initial_manifest)
    manifest_path = output / "source-manifest.json"
    manifest_path.write_text(
        json.dumps(initial_manifest, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    print(f"      Payload: {human_bytes(payload)} across {len(initial_manifest)} entries")

    print("[2/4] Creating one canonical TAR for stream compressors...")
    status.update(state="creating-canonical-tar")
    canonical_tar = output / "canonical-input.tar"
    if canonical_tar.exists():
        canonical_tar.unlink()
    create_canonical_tar(source, canonical_tar)
    tar_bytes = canonical_tar.stat().st_size
    print(f"      TAR: {human_bytes(tar_bytes)}")

    free = shutil.disk_usage(output).free
    if payload and free < payload * 2:
        eprint(
            f"Warning: only {human_bytes(free)} free in result filesystem; "
            "large benchmark outputs/restores may run out of space."
        )

    hardcore = resolve_executable(
        args.hardcore,
        ["hardcore-archive", "hardcore-archive.sh"],
        ["hardcore-archive", "hardcore-archive.sh"],
    )
    base9 = resolve_executable(
        args.basecompresser,
        ["basecompresser"],
        ["basecompresser", "build/basecompresser"],
    )
    seven = resolve_executable(args.sevenzip, ["7zz", "7z", "7za"])
    tools = {
        "zstd": resolve_executable(None, ["zstd"]),
        "xz": resolve_executable(None, ["xz"]),
        "gzip": resolve_executable(None, ["gzip"]),
        "bzip2": resolve_executable(None, ["bzip2"]),
        "lz4": resolve_executable(None, ["lz4"]),
        "brotli": resolve_executable(None, ["brotli"]),
    }

    results: list[Result] = []
    print("[3/4] Running competitors sequentially...")

    for index, method in enumerate(requested, 1):
        status.update(
            state="running",
            current_method=method,
            method_index=index,
            method_count=len(requested),
        )
        print(f"      [{index}/{len(requested)}] {method} ...", flush=True)
        try:
            if method == "hardcore":
                if not hardcore:
                    result = skipped_result(method, "hardcore-archive executable not found; pass either the executable or its project directory with --hardcore PATH", payload, tar_bytes)
                else:
                    result = benchmark_hardcore(
                        hardcore, source, initial_manifest, payload, tar_bytes, output, lossless=False
                    )

            elif method == "hardcore-lossless":
                if not hardcore:
                    result = skipped_result(method, "hardcore-archive executable not found; pass either the executable or its project directory with --hardcore PATH", payload, tar_bytes)
                else:
                    result = benchmark_hardcore(
                        hardcore, source, initial_manifest, payload, tar_bytes, output, lossless=True
                    )

            elif method == "base9":
                if not base9:
                    result = skipped_result(method, "basecompresser executable not found; pass either the executable or its project directory with --basecompresser PATH (run make first if needed)", payload, tar_bytes)
                else:
                    result = benchmark_base9(base9, canonical_tar, initial_manifest, payload, output)

            elif method == "7z":
                if not seven:
                    result = skipped_result(method, "7z/7zz/7za not found", payload, tar_bytes)
                else:
                    result = benchmark_7z(seven, canonical_tar, initial_manifest, payload, output)

            elif method == "zstd":
                exe = tools["zstd"]
                if not exe:
                    result = skipped_result(method, "zstd not found", payload, tar_bytes)
                else:
                    result = benchmark_stream_method(
                        "zstd", exe, canonical_tar, initial_manifest, payload, output,
                        lambda out: [exe, "-q", "--ultra", "-22", "-T0", "-f", str(canonical_tar), "-o", str(out)],
                        lambda arc: [exe, "-q", "-d", "-f", str(arc), "-o", str(output / "zstd" / "restored.tar")],
                        ".tar.zst",
                    )

            elif method == "xz":
                exe = tools["xz"]
                if not exe:
                    result = skipped_result(method, "xz not found", payload, tar_bytes)
                else:
                    result = benchmark_stream_method(
                        "xz", exe, canonical_tar, initial_manifest, payload, output,
                        lambda out: [exe, "-9e", "-T0", "-c", str(canonical_tar)],
                        lambda arc: [exe, "-d", "-c", str(arc)],
                        ".tar.xz", compression_stdout=True, decompression_stdout=True,
                    )

            elif method == "gzip":
                exe = tools["gzip"]
                if not exe:
                    result = skipped_result(method, "gzip not found", payload, tar_bytes)
                else:
                    result = benchmark_stream_method(
                        "gzip", exe, canonical_tar, initial_manifest, payload, output,
                        lambda out: [exe, "-9", "-c", str(canonical_tar)],
                        lambda arc: [exe, "-d", "-c", str(arc)],
                        ".tar.gz", compression_stdout=True, decompression_stdout=True,
                    )

            elif method == "bzip2":
                exe = tools["bzip2"]
                if not exe:
                    result = skipped_result(method, "bzip2 not found", payload, tar_bytes)
                else:
                    result = benchmark_stream_method(
                        "bzip2", exe, canonical_tar, initial_manifest, payload, output,
                        lambda out: [exe, "-9", "-c", str(canonical_tar)],
                        lambda arc: [exe, "-d", "-c", str(arc)],
                        ".tar.bz2", compression_stdout=True, decompression_stdout=True,
                    )

            elif method == "lz4":
                exe = tools["lz4"]
                if not exe:
                    result = skipped_result(method, "lz4 not found", payload, tar_bytes)
                else:
                    result = benchmark_stream_method(
                        "lz4", exe, canonical_tar, initial_manifest, payload, output,
                        lambda out: [exe, "-q", "-12", "-c", str(canonical_tar)],
                        lambda arc: [exe, "-q", "-d", "-c", str(arc)],
                        ".tar.lz4", compression_stdout=True, decompression_stdout=True,
                    )

            elif method == "brotli":
                exe = tools["brotli"]
                if not exe:
                    result = skipped_result(method, "brotli not found", payload, tar_bytes)
                else:
                    result = benchmark_stream_method(
                        "brotli", exe, canonical_tar, initial_manifest, payload, output,
                        lambda out: [exe, "-q", "11", "-c", str(canonical_tar)],
                        lambda arc: [exe, "-d", "-c", str(arc)],
                        ".tar.br", compression_stdout=True, decompression_stdout=True,
                    )
            else:
                raise AssertionError(method)

        except KeyboardInterrupt:
            eprint("\nInterrupted.")
            status.finish(state="interrupted", current_method=method, exit_code=130)
            return 130
        except Exception as exc:
            result = Result(
                method=method,
                status="FAIL",
                payload_bytes=payload,
                canonical_tar_bytes=tar_bytes,
                verification="judge-error",
                note=f"{type(exc).__name__}: {exc}",
            )

        results.append(result)
        if result.status == "PASS":
            print(
                f"          PASS  {human_bytes(result.archive_bytes)}  "
                f"{result.ratio_percent:.2f}%  "
                f"{human_seconds(result.compress_seconds)}"
            )
        elif result.status == "TRANSFORMED":
            print(
                f"          TRANSFORMED  {human_bytes(result.archive_bytes)}  "
                f"{result.ratio_percent:.2f}%  (separate ranking)"
            )
        else:
            print(f"          {result.status}: {result.note}")

        # Results are durable even if a later compressor crashes.
        compute_rankings(results, args.weights)
        (output / "results.json").write_text(
            json.dumps([asdict(r) for r in results], indent=2),
            encoding="utf-8",
        )
        write_csv(results, output / "results.csv")
        status.update(
            state="running",
            current_method=None,
            completed_methods=[r.method for r in results],
            last_result={
                "method": result.method,
                "status": result.status,
                "verification": result.verification,
                "exact_payload_roundtrip": result.exact_payload_roundtrip,
            },
        )

    print("[4/4] Re-hashing source to ensure the benchmark input did not change...")
    status.update(state="rehashing-source", current_method=None)
    final_manifest = folder_manifest(source)
    source_stable = initial_manifest == final_manifest
    if not source_stable:
        eprint("WARNING: source folder changed during the benchmark. Results are not a valid same-input comparison.")

    compute_rankings(results, args.weights)
    (output / "results.json").write_text(
        json.dumps(
            {
                "judge_version": 1,
                "platform": platform.platform(),
                "python": sys.version,
                "source": str(source),
                "source_stable": source_stable,
                "payload_bytes": payload,
                "canonical_tar_bytes": tar_bytes,
                "weights": {
                    "size": args.weights[0],
                    "compression_time": args.weights[1],
                    "restore_time": args.weights[2],
                },
                "results": [asdict(r) for r in results],
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    write_csv(results, output / "results.csv")
    write_markdown_report(
        results,
        output / "REPORT.md",
        source,
        initial_manifest,
        canonical_tar,
        args.weights,
        source_stable,
    )

    if not args.keep_restores:
        for r in results:
            method_dir = output / r.method
            for name in ("restored", "restored.tar", "unpack"):
                p = method_dir / name
                if p.exists():
                    remove_path(p)

    print_summary(results)
    print()
    print(f"Report : {output / 'REPORT.md'}")
    print(f"CSV    : {output / 'results.csv'}")
    print(f"JSON   : {output / 'results.json'}")
    print(f"Logs   : one run.log per method")
    print()

    if not source_stable:
        exit_code = 3
    elif any(r.status == "FAIL" for r in results):
        exit_code = 1
    else:
        exit_code = 0
    status.finish(
        state="complete" if exit_code == 0 else "failed",
        current_method=None,
        completed_methods=[r.method for r in results],
        source_stable=source_stable,
        exit_code=exit_code,
        report=str(output / "REPORT.md"),
    )
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
