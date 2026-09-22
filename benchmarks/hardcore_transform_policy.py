"""Validate the boundary between intentional Hardcore transforms and corruption.

This module consumes the SHA-256 manifests already produced by the judge. It
never re-hashes the corpus, so the verification adds no second data scan.
"""
from __future__ import annotations

import subprocess
from pathlib import Path


MANIFESTS = {
    "image": ("optimized", 6),
    "container": ("repacked", 7),
    "nested": ("repacked", 7),
    "video": ("transcoded", 5),
}


class TransformPolicyError(ValueError):
    pass


def declared_transforms(archive: Path, sevenzip: str, source_name: str) -> dict:
    """Read only the small, data-only decision manifests inside a 7z archive."""
    decisions = {}
    targets = set()
    prefix = source_name + "/"
    for lane, (changed_action, columns) in MANIFESTS.items():
        member = f".hardcore-archive-{lane}-manifest.txt"
        output = subprocess.run(
            [sevenzip, "x", "-so", str(archive), member],
            capture_output=True, timeout=60, check=False,
        )
        if output.returncode != 0:
            raise TransformPolicyError(f"cannot read {member}: {output.stderr.decode('utf-8', 'replace')[:300]}")
        if not output.stdout:
            continue
        text = output.stdout.decode("utf-8", "surrogateescape")
        for line in text.splitlines():
            fields = line.split("\t")
            if not fields or fields[0] != changed_action:
                continue
            if len(fields) != columns:
                raise TransformPolicyError(f"malformed {member} decision")
            original, archived, original_bytes = fields[1:4]
            archived_bytes = fields[4] if lane in ("image", "video") else fields[5]
            if not original.startswith(prefix) or not archived.startswith(prefix):
                raise TransformPolicyError(f"decision escapes source folder in {member}")
            before, after = original[len(prefix):], archived[len(prefix):]
            if not before or not after or before in decisions or after in targets:
                raise TransformPolicyError(f"duplicate or empty transform path in {member}")
            if any(part in ("", ".", "..") for path in (before, after) for part in path.split("/")):
                raise TransformPolicyError(f"unsafe transform path in {member}")
            try:
                sizes = int(original_bytes), int(archived_bytes)
            except ValueError as exc:
                raise TransformPolicyError(f"invalid sizes in {member}") from exc
            if any(size < 0 for size in sizes):
                raise TransformPolicyError(f"negative size in {member}")
            decisions[before] = (after, *sizes)
            targets.add(after)
    return decisions


def check_transform_roundtrip(before: dict, after: dict, decisions: dict) -> list[str]:
    """Every undeclared path must match its original type, size, and SHA-256."""
    issues = []
    allowed_targets = {}
    for original, (archived, source_size, archive_size) in decisions.items():
        entry = before.get(original)
        if not entry or entry.get("type") != "F" or entry.get("size") != source_size:
            issues.append(f"invalid source declaration: {original}")
            continue
        if archived != original and archived in before:
            issues.append(f"renamed transform collides with source: {archived}")
            continue
        allowed_targets[archived] = (original, archive_size)

    for path, entry in before.items():
        declaration = decisions.get(path)
        if declaration and declaration[0] != path:
            if path in after:
                issues.append(f"original path still present after rename: {path}")
        elif path not in allowed_targets and after.get(path) != entry:
            issues.append(f"undeclared change or missing path: {path}")

    for path, entry in after.items():
        if path in allowed_targets:
            _, expected_size = allowed_targets[path]
            if entry.get("type") != "F" or entry.get("size") != expected_size:
                issues.append(f"declared transform has wrong type or size: {path}")
        elif path not in before:
            issues.append(f"undeclared extra path: {path}")
    for path in allowed_targets:
        if path not in after:
            issues.append(f"declared transform missing: {path}")
    return issues
