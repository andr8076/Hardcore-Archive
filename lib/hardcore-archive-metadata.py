#!/usr/bin/env python3
"""Safely restore metadata data from a Hardcore Archive extraction."""
from __future__ import annotations

import argparse
import base64
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile


class MetadataError(RuntimeError):
    pass


ACL_ENTRY = re.compile(
    r"^(?:default:)?(?:(?:user|group):[^:]*:[rwx-]{3}|(?:mask|other)::[rwx-]{3})$"
)
ACL_COMMENT = re.compile(
    r"^(?:# (?:owner|group): [A-Za-z0-9_.@+\\ -]+|# flags: [st-]{3})$"
)


def _metadata_parts(relative: str) -> tuple[str, ...]:
    if not relative or "\x00" in relative or os.path.isabs(relative):
        raise MetadataError(f"unsafe metadata path: {relative!r}")
    normalized = relative.replace("\\", "/")
    if len(normalized) >= 2 and normalized[1] == ":":
        raise MetadataError(f"unsafe metadata path: {relative!r}")
    parts = pathlib.PurePosixPath(normalized).parts
    if not parts or ".." in parts or any(part in ("", ".") for part in parts):
        raise MetadataError(f"unsafe metadata path: {relative!r}")
    return tuple(parts)


def safe_existing_path(
    root: pathlib.Path,
    relative: str,
    *,
    allow_leaf_symlink: bool = True,
    reject_parent_symlinks: bool = False,
) -> pathlib.Path:
    parts = _metadata_parts(relative)
    candidate = root.joinpath(*parts)

    if reject_parent_symlinks:
        current = root
        for part in parts[:-1]:
            current = current / part
            if current.is_symlink():
                raise MetadataError(
                    f"ACL path contains a symlink component: {relative!r}"
                )

    resolved_parent = pathlib.Path(os.path.realpath(candidate.parent))
    try:
        resolved_parent.relative_to(root)
    except ValueError as exc:
        raise MetadataError(f"metadata path leaves restore root: {relative!r}") from exc
    if not os.path.lexists(candidate):
        raise MetadataError(f"metadata path does not exist in restored tree: {relative!r}")
    if not allow_leaf_symlink and candidate.is_symlink():
        raise MetadataError(f"ACL path is a symlink leaf: {relative!r}")
    return candidate


def restore_file_metadata(root: pathlib.Path, metadata_dir: pathlib.Path) -> int:
    manifest = metadata_dir / "files.tsv"
    if not manifest.is_file():
        return 0
    rows: list[tuple[pathlib.Path, str, str, str, str]] = []
    with manifest.open("r", encoding="utf-8", errors="surrogateescape") as handle:
        next(handle, None)
        for line_number, line in enumerate(handle, 2):
            parts = line.rstrip("\n").split("\t", 6)
            if len(parts) != 7:
                raise MetadataError(f"invalid files.tsv row {line_number}")
            _kind, mode, uid, gid, mtime, relative, _target = parts
            path = safe_existing_path(root, relative)
            rows.append((path, mode, uid, gid, mtime))

    rows.sort(key=lambda row: (row[0].is_dir(), -len(row[0].parts)))
    for path, mode, uid, gid, mtime in rows:
        try:
            os.chmod(path, int(mode, 8), follow_symlinks=False)
        except (OSError, NotImplementedError, ValueError):
            pass
        try:
            timestamp = int(mtime)
            os.utime(path, (timestamp, timestamp), follow_symlinks=False)
        except (OSError, NotImplementedError, ValueError):
            pass
        if os.geteuid() == 0:
            try:
                os.chown(path, int(uid), int(gid), follow_symlinks=False)
            except (OSError, NotImplementedError, ValueError):
                pass
    return len(rows)


def load_xattrs(
    root: pathlib.Path, metadata_dir: pathlib.Path
) -> tuple[int, list[tuple[pathlib.Path, int]]]:
    manifest = metadata_dir / "xattrs.txt"
    if not manifest.is_file():
        return 0, []
    restored = 0
    flags: list[tuple[pathlib.Path, int]] = []
    with manifest.open("r", encoding="utf-8", errors="replace") as handle:
        for line_number, line in enumerate(handle, 1):
            if not line.strip() or line.startswith("#"):
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as exc:
                raise MetadataError(f"invalid xattrs.txt row {line_number}") from exc
            path = safe_existing_path(root, str(record.get("path", "")))
            attributes = record.get("xattrs", {})
            if not isinstance(attributes, dict):
                raise MetadataError(f"invalid xattr map on row {line_number}")
            if hasattr(os, "setxattr"):
                for name, encoded in attributes.items():
                    try:
                        value = base64.b64decode(encoded, validate=True)
                        os.setxattr(path, str(name), value, follow_symlinks=False)
                        restored += 1
                    except (OSError, ValueError, TypeError):
                        pass
            if record.get("flags"):
                try:
                    flags.append((path, int(record["flags"])))
                except (TypeError, ValueError) as exc:
                    raise MetadataError(
                        f"invalid file flags on xattrs.txt row {line_number}"
                    ) from exc
    return restored, flags


def sanitize_acl(
    root: pathlib.Path, source: pathlib.Path, destination: pathlib.Path
) -> tuple[int, bool]:
    """Write a confined ACL-only setfacl restore file.

    Archive-supplied owner/group/flags comments are validated but deliberately
    omitted. Ownership is restored from files.tsv and flags from xattrs.txt, so
    ACL restoration cannot gain those additional side effects through setfacl.
    """
    if not source.is_file():
        destination.write_text("", encoding="utf-8")
        return 0, False

    output: list[str] = []
    current: list[str] = []
    count = 0
    extended = False

    def flush() -> None:
        nonlocal count, extended, current
        if not current:
            return
        file_lines = [line for line in current if line.startswith("# file: ")]
        if len(file_lines) != 1:
            raise MetadataError("ACL block must contain exactly one # file entry")
        relative = file_lines[0][8:]
        # setfacl --restore resolves names itself. Reject every symlink component
        # so the path sanitized here is the same path setfacl later modifies.
        safe_existing_path(
            root,
            relative,
            allow_leaf_symlink=False,
            reject_parent_symlinks=True,
        )
        output.append(f"# file: {relative}")
        for line in current:
            if line.startswith("# file: ") or not line:
                continue
            if line.startswith(("# owner: ", "# group: ", "# flags: ")):
                if not ACL_COMMENT.fullmatch(line):
                    raise MetadataError(
                        f"unsafe or unsupported ACL comment for {relative!r}: {line!r}"
                    )
                # Do not pass ownership or flags to setfacl. They have separate,
                # explicitly bounded restoration paths in this helper.
                continue
            entry = line.split("\t#effective:", 1)[0].rstrip()
            if not ACL_ENTRY.fullmatch(entry):
                raise MetadataError(
                    f"unsafe or unsupported ACL entry for {relative!r}: {line!r}"
                )
            if entry.startswith("default:") or re.match(
                r"^(?:user|group):[^:]+:", entry
            ):
                extended = True
            output.append(entry)
        output.append("")
        count += 1
        current = []

    with source.open("r", encoding="utf-8", errors="surrogateescape") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if line.startswith("# file: ") and current:
                flush()
            if line or current:
                current.append(line)
    flush()
    destination.write_text(
        "\n".join(output), encoding="utf-8", errors="surrogateescape"
    )
    return count, extended


def restore_acl(root: pathlib.Path, metadata_dir: pathlib.Path) -> int:
    source = metadata_dir / "acl.txt"
    fd, name = tempfile.mkstemp(prefix="acl.safe.", suffix=".txt", dir=metadata_dir)
    os.close(fd)
    safe_manifest = pathlib.Path(name)
    try:
        count, extended = sanitize_acl(root, source, safe_manifest)
        if count == 0 or not extended:
            return 0
        setfacl = shutil.which("setfacl")
        if not setfacl:
            raise MetadataError(
                "the archive contains extended ACLs, but setfacl is unavailable"
            )
        completed = subprocess.run(
            [setfacl, f"--restore={safe_manifest}"], cwd=root, check=False
        )
        if completed.returncode != 0:
            raise MetadataError(f"setfacl failed with exit code {completed.returncode}")
        return count
    finally:
        try:
            safe_manifest.unlink()
        except FileNotFoundError:
            pass


def restore_flags(flags: list[tuple[pathlib.Path, int]]) -> int:
    if not hasattr(os, "chflags"):
        return 0
    restored = 0
    for path, value in flags:
        try:
            os.chflags(path, value, follow_symlinks=False)
            restored += 1
        except OSError:
            pass
    return restored


def restore(root: pathlib.Path, metadata_dir: pathlib.Path) -> None:
    root = pathlib.Path(os.path.realpath(root))
    metadata_dir = pathlib.Path(os.path.realpath(metadata_dir))
    try:
        metadata_dir.relative_to(root)
    except ValueError as exc:
        raise MetadataError("metadata directory is outside the restore root") from exc
    files = restore_file_metadata(root, metadata_dir)
    xattrs, flags = load_xattrs(root, metadata_dir)
    acls = restore_acl(root, metadata_dir)
    flag_count = restore_flags(flags)
    print(
        f"Metadata restored: files={files} xattrs={xattrs} "
        f"acl_paths={acls} flags={flag_count}"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--metadata-dir", required=True)
    args = parser.parse_args()
    try:
        restore(pathlib.Path(args.root), pathlib.Path(args.metadata_dir))
    except MetadataError as exc:
        print(f"Error: safe metadata restoration failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
