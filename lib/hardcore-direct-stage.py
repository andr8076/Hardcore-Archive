#!/usr/bin/env python3
"""Assemble a single-7z input tree from parallel transform lane decisions.

This module does not change the production archive backend. The caller owns the
stage directory and may build one archive from it after all lanes have joined.
The caller supplies the existing metadata bundle and expected-path list. Final
archive verification remains the responsibility of the production backend.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess


METADATA_FILES = frozenset({
    "files.tsv", "acl.txt", "xattrs.txt", "RESTORE-NOTES.txt",
    "sparse.tsv", "archive-info.txt",
})
OPTIONAL_MANIFESTS = frozenset({
    ".hardcore-archive-video-manifest.txt",
    ".hardcore-archive-image-manifest.txt",
    ".hardcore-archive-container-manifest.txt",
    ".hardcore-archive-nested-manifest.txt",
    ".hardcore-archive-sha256.txt",
})


@dataclass(frozen=True)
class Lane:
    name: str
    manifest: Path
    candidate_root: Path


@dataclass(frozen=True)
class Replacement:
    original: str
    archived: str
    candidate: Path
    size: int


def relative_path(value: str, root_name: str) -> str:
    parts = PurePosixPath(value).parts
    if (not value or value.startswith("/") or "\\" in value or
            any(part in (".", "..") for part in value.split("/")) or
            parts[0] != root_name):
        raise ValueError(f"unsafe or out-of-root archive path: {value!r}")
    return value


def regular_file(path: Path, root: Path) -> bool:
    if not path.is_relative_to(root):
        return False
    current = root
    for part in path.relative_to(root).parts:
        current = current / part
        if current.is_symlink():
            return False
    return path.is_file()


def linked_parent(path: Path, root: Path) -> bool:
    current = root
    for part in path.relative_to(root).parts[:-1]:
        current = current / part
        if current.is_symlink():
            return True
    return False


def decisions(source: Path, lanes: list[Lane]) -> list[Replacement]:
    root_name = source.name
    originals: set[str] = set()
    archived_paths: set[str] = set()
    replacements: list[Replacement] = []
    for lane in lanes:
        if not lane.manifest.is_file() or not lane.candidate_root.is_dir():
            raise ValueError(f"missing {lane.name} manifest or candidate directory")
        for number, line in enumerate(lane.manifest.read_text(encoding="utf-8").splitlines(), 1):
            if not line:
                continue
            fields = line.split("\t")
            if lane.name in ("container", "nested"):
                if len(fields) != 7:
                    raise ValueError(f"{lane.name} row {number}: expected 7 fields")
                action, original, archived, original_size, _, size, _ = fields
                changed = action == "repacked"
                allowed = ("repacked", "original")
            elif lane.name == "image":
                if len(fields) != 6:
                    raise ValueError(f"image row {number}: expected 6 fields")
                action, original, archived, original_size, size, _ = fields
                changed = action == "optimized"
                allowed = ("optimized", "original")
            elif lane.name == "video":
                if len(fields) != 5:
                    raise ValueError(f"video row {number}: expected 5 fields")
                action, original, archived, original_size, size = fields
                changed = action == "transcoded"
                allowed = ("transcoded", "original", "omitted")
            else:
                raise ValueError(f"unknown lane: {lane.name}")
            if action not in allowed:
                raise ValueError(f"{lane.name} row {number}: unknown action {action!r}")
            original = relative_path(original, root_name)
            if original in originals:
                raise ValueError(f"duplicate source decision: {original}")
            originals.add(original)
            source_file = source.parent / original
            if not regular_file(source_file, source.parent):
                raise ValueError(f"missing or linked source file: {original}")
            if not original_size.isdecimal() or source_file.stat().st_size != int(original_size):
                raise ValueError(f"source size changed: {original}")
            if action == "omitted":
                if archived or size != "0":
                    raise ValueError(f"invalid video omission: {original}")
                replacements.append(Replacement(original, "", source_file, 0))
                continue
            archived = relative_path(archived, root_name)
            if archived in archived_paths:
                raise ValueError(f"duplicate archived path: {archived}")
            archived_paths.add(archived)
            if not size.isdecimal():
                raise ValueError(f"invalid archived size: {archived}")
            if not changed:
                if archived != original or int(size) != int(original_size):
                    raise ValueError(f"invalid original fallback: {original}")
                continue
            candidate = lane.candidate_root / archived
            if not regular_file(candidate, lane.candidate_root) or candidate.stat().st_size != int(size):
                raise ValueError(f"missing, linked, or resized candidate: {archived}")
            replacements.append(Replacement(original, archived, candidate, int(size)))

    for item in replacements:
        target = source.parent / item.archived
        if item.archived and linked_parent(target, source.parent):
            raise ValueError(f"archive path has a linked parent: {item.archived}")
        if item.archived and item.archived != item.original and (target.exists() or target.is_symlink()):
            # A rename may never overwrite an unrelated source file or symlink.
            raise ValueError(f"archive path collides with source entry: {item.archived}")
    return replacements


def stage_manifests(manifest_root: Path, stage: Path) -> None:
    """Bring in only the trusted metadata and decision files used by restore."""
    metadata = manifest_root / ".hardcore-archive-metadata"
    if not metadata.is_dir() or metadata.is_symlink():
        raise ValueError("missing or linked metadata directory")
    names = {path.name for path in metadata.iterdir()}
    if names != METADATA_FILES or any(not regular_file(metadata / name, manifest_root) for name in names):
        raise ValueError("metadata bundle has missing, unexpected, or linked files")
    for item in manifest_root.iterdir():
        if item.name != metadata.name and (item.name not in OPTIONAL_MANIFESTS or
                                          not regular_file(item, manifest_root)):
            raise ValueError(f"unexpected or linked internal manifest: {item.name}")
        subprocess.run(["cp", "-a", "--reflink=auto", "--", str(item), str(stage)], check=True)


def verify_staged_paths(stage: Path, expected: Path) -> None:
    """Use the production expected-path contract before an expensive 7z pass."""
    wanted = expected.read_text(encoding="utf-8", errors="surrogateescape").splitlines()
    if not wanted or len(wanted) != len(set(wanted)) or any(
        not path or path.startswith("/") or "\\" in path or
        any(part in (".", "..") for part in path.split("/")) for path in wanted
    ):
        raise ValueError("invalid expected-path manifest")
    present: set[str] = set()
    for directory, dirs, files in os.walk(stage, followlinks=False):
        parent = Path(directory)
        for name in dirs + files:
            present.add(str((parent / name).relative_to(stage)))
    missing, extra = set(wanted) - present, present - set(wanted)
    if missing or extra:
        raise ValueError(f"staged paths differ: {len(missing)} missing, {len(extra)} unexpected"
                         f"; first missing={next(iter(sorted(missing)), '-')}; first unexpected={next(iter(sorted(extra)), '-')}")


def assemble(source: Path, stage: Path, lanes: list[Lane],
             manifest_stage: Path | None = None, expected_paths: Path | None = None) -> int:
    if not source.is_dir() or source.is_symlink() or not source.name:
        raise ValueError("source must be a real directory")
    if manifest_stage and source.name in OPTIONAL_MANIFESTS | {".hardcore-archive-metadata"}:
        raise ValueError("source name collides with internal manifests")
    source = source.resolve()
    stage = stage.resolve(strict=False)
    roots = [source, *(lane.candidate_root.resolve() for lane in lanes)]
    if manifest_stage:
        roots.append(manifest_stage.resolve())
    if any(stage == root or stage.is_relative_to(root) or root.is_relative_to(stage) for root in roots):
        raise ValueError("stage must be separate from source and transform lanes")
    if stage.exists() or stage.is_symlink():
        raise ValueError("stage must not exist; use a fresh directory")
    replacements = decisions(source, lanes)  # Validate everything before touching output.
    stage.mkdir(parents=True)
    try:
        subprocess.run(["cp", "-a", "--reflink=auto", "--", str(source), str(stage)], check=True)
        for item in replacements:
            original = stage / item.original
            original.unlink()
            if not item.archived:
                continue
            target = stage / item.archived
            if target.exists() or target.is_symlink():
                raise ValueError(f"archive path already exists in stage: {item.archived}")
            target.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["cp", "-p", "--reflink=auto", "--", str(item.candidate), str(target)], check=True)
            if target.stat().st_size != item.size:
                raise ValueError(f"candidate changed while staging: {item.archived}")
        if manifest_stage:
            stage_manifests(manifest_stage, stage)
        if expected_paths:
            verify_staged_paths(stage, expected_paths)
        return len(replacements)
    except BaseException:
        shutil.rmtree(stage)
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--stage", type=Path, required=True)
    parser.add_argument("--manifest-stage", type=Path,
                        help="Existing validated metadata and decision manifests")
    parser.add_argument("--expected-paths", type=Path,
                        help="Production expected-path list, checked before 7z compression")
    for name in ("video", "image", "container", "nested"):
        parser.add_argument(f"--{name}-manifest", type=Path)
        parser.add_argument(f"--{name}-stage", type=Path)
    args = parser.parse_args()
    lanes = []
    for name in ("video", "image", "container", "nested"):
        manifest = getattr(args, f"{name}_manifest")
        root = getattr(args, f"{name}_stage")
        if bool(manifest) != bool(root):
            parser.error(f"--{name}-manifest and --{name}-stage must be supplied together")
        if manifest:
            lanes.append(Lane(name, manifest, root))
    if args.manifest_stage and not args.expected_paths:
        parser.error("--manifest-stage requires --expected-paths")
    print(f"Staged {assemble(args.source, args.stage, lanes, args.manifest_stage, args.expected_paths)} transformed or omitted entries")


if __name__ == "__main__":
    main()
