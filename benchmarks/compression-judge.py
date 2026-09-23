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

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hardcore_transform_policy import (  # noqa: E402
    TransformPolicyError,
    check_transform_roundtrip,
    declared_transforms,
)


DEFAULT_METHODS = (
    "hardcore-single-pass",
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
    actual_manifest_out: Optional[dict] = None,
) -> tuple[bool, list[str], int]:
    actual = folder_manifest(restored_root)
    if actual_manifest_out is not None:
        actual_manifest_out.update(actual)
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
    sevenzip: Optional[str] = None,
    single_pass: bool = False,
) -> Result:
    if lossless:
        name = "hardcore-lossless"
    elif single_pass:
        name = "hardcore-single-pass"
    else:
        name = "hardcore"
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
    if single_pass:
        cmd.append("--single-pass")
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
        restored_manifest = {}
        exact, diffs, difference_count = verify_restored(
            root, source_manifest, difference_report, restored_manifest
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
        # Compare one hashed restore manifest to the declared transform lanes.
        # Every other path must match the original SHA-256 manifest exactly.
        try:
            sevenzip = sevenzip or resolve_executable(None, ["7zz", "7z", "7za"])
            if not sevenzip:
                raise TransformPolicyError("7z is needed to read Hardcore's decision manifests")
            decisions = declared_transforms(archive, sevenzip, source.name)
            issues = check_transform_roundtrip(source_manifest, restored_manifest, decisions)
        except (TransformPolicyError, OSError, subprocess.TimeoutExpired) as exc:
            issues = [str(exc)]
        if issues:
            policy_report = method_dir / "unexpected-transform-differences.txt"
            policy_report.write_text("\n".join(issues) + "\n", encoding="utf-8")
            result.status = "FAIL"
            result.verification = "transform-policy-mismatch"
            result.note = f"{len(issues)} undeclared or invalid changes; {policy_report}: " + "; ".join(issues[:3])
        else:
            result.status = "TRANSFORMED"
            result.verification = "sha256-unchanged + declared-transform-sizes"
            result.note = (
                "Changed paths match Hardcore's declared transform decisions; "
                "excluded from exact-lossless ranking. Differences: "
                + "; ".join(diffs)
            )

    archive_metrics(result)
    return result


def skipped_result(name: str, why: str, payload: int, tar_bytes: int) -> Result:
    return Result(
        method=name,
        status="SKIP",
        category="transform-capable" if name in {"hardcore", "hardcore-single-pass"} else "lossless",
        payload_bytes=payload,
        canonical_tar_bytes=tar_bytes,
        verification="not-run",
        note=why,
    )


def cleanup_method_restores(output: Path, method: str) -> None:
    method_dir = output / method
    for name in ("restored", "restored.tar", "unpack"):
        path = method_dir / name
        if path.exists():
            remove_path(path)


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
        "- `hardcore-single-pass` joins validated parallel transform lanes before one solid 7z compression pass.",
        "- `hardcore-lossless` disables video, image, nested-archive, and application-container transformations.",
        "- A changed Hardcore result can be useful in practice, but it cannot win the exact-lossless leaderboard.",
