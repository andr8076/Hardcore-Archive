#!/usr/bin/env python3
"""Capture filesystem metadata and safely restore it from an extraction."""
from __future__ import annotations

import argparse
import base64
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile


class MetadataError(RuntimeError):
    pass


def capture_files(root: pathlib.Path, destination: pathlib.Path, stream) -> int:
    """Capture find's NUL-delimited inventory with one lstat per entry.

    Keep traversal policy with the caller (mount boundaries and symlinks), and
    keep the existing seven-column files.tsv representation for restoration.
    """
    count = 0
    pending = b""
    with destination.open("w", encoding="utf-8", errors="surrogateescape") as output:
        output.write("type\tmode\tuid\tgid\tmtime_epoch\tpath\tlink_target\n")
        while True:
            chunk = stream.read(65536)
            if not chunk:
                if pending:
                    raise MetadataError("unterminated metadata path inventory")
                break
            names = (pending + chunk).split(b"\0")
            pending = names.pop()
            for raw in names:
                relative = os.fsdecode(raw)
                parts = pathlib.PurePath(relative).parts
                if not relative or os.path.isabs(relative) or ".." in parts or any(c in relative for c in "\t\n\r"):
                    raise MetadataError(f"unrepresentable metadata path: {relative!r}")
                path = root / relative
                info = path.lstat()
                if stat.S_ISREG(info.st_mode):
                    kind = "regular file" if info.st_size else "regular empty file"
                elif stat.S_ISDIR(info.st_mode):
                    kind = "directory"
                elif stat.S_ISLNK(info.st_mode):
                    kind = "symbolic link"
                elif stat.S_ISFIFO(info.st_mode):
                    kind = "fifo"
                elif stat.S_ISSOCK(info.st_mode):
                    kind = "socket"
                elif stat.S_ISBLK(info.st_mode):
                    kind = "block special file"
                elif stat.S_ISCHR(info.st_mode):
                    kind = "character special file"
                else:
                    kind = "unknown"
                target = os.readlink(path) if stat.S_ISLNK(info.st_mode) else ""
                if any(c in target for c in "\t\n\r"):
                    raise MetadataError(f"unrepresentable symlink target: {relative!r}")
                # Integer division also matches stat %Y for pre-epoch times.
                output.write(f"{kind}\t{stat.S_IMODE(info.st_mode):o}\t{info.st_uid}\t{info.st_gid}\t"
                             f"{info.st_mtime_ns // 1_000_000_000}\t{relative}\t{target}\n")
                count += 1
    return count


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
                    f"metadata path contains a symlink component: {relative!r}"
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
    rows: list[tuple[pathlib.Path, str, int, int, int, int]] = []
    seen: set[pathlib.Path] = set()
    with manifest.open("r", encoding="utf-8", errors="surrogateescape") as handle:
        header = next(handle, "").rstrip("\n")
        if header != "type\tmode\tuid\tgid\tmtime_epoch\tpath\tlink_target":
            raise MetadataError("invalid files.tsv header")
        for line_number, line in enumerate(handle, 2):
            parts = line.rstrip("\n").split("\t", 6)
            if len(parts) != 7:
                raise MetadataError(f"invalid files.tsv row {line_number}")
            kind, mode_text, uid_text, gid_text, mtime_text, relative, target = parts
            path = safe_existing_path(root, relative, reject_parent_symlinks=True)
            if path in seen:
                raise MetadataError(f"duplicate files.tsv path on row {line_number}: {relative!r}")
            seen.add(path)
            if not re.fullmatch(r"[0-7]{3,4}", mode_text):
                raise MetadataError(f"invalid mode on files.tsv row {line_number}")
            if not uid_text.isascii() or not uid_text.isdecimal():
                raise MetadataError(f"invalid uid on files.tsv row {line_number}")
            if not gid_text.isascii() or not gid_text.isdecimal():
                raise MetadataError(f"invalid gid on files.tsv row {line_number}")
            if not re.fullmatch(r"-?[0-9]+", mtime_text, flags=re.ASCII):
                raise MetadataError(f"invalid mtime on files.tsv row {line_number}")

            info = path.lstat()
            expected_kinds = {
                "regular file": stat.S_ISREG,
                "regular empty file": stat.S_ISREG,
                "file": stat.S_ISREG,  # Compatibility with early manifests.
                "directory": stat.S_ISDIR,
                "symbolic link": stat.S_ISLNK,
                "fifo": stat.S_ISFIFO,
                "socket": stat.S_ISSOCK,
                "block special file": stat.S_ISBLK,
                "character special file": stat.S_ISCHR,
            }
            matcher = expected_kinds.get(kind)
            if matcher is None or not matcher(info.st_mode):
                raise MetadataError(
                    f"restored object type does not match files.tsv row {line_number}"
                )
            if kind == "regular empty file" and info.st_size != 0:
                raise MetadataError(f"restored file is not empty on files.tsv row {line_number}")
            if kind == "symbolic link":
                if os.readlink(path) != target:
                    raise MetadataError(f"symlink target does not match files.tsv row {line_number}")
            elif target:
                raise MetadataError(f"unexpected link target on files.tsv row {line_number}")
            rows.append(
                (
                    path,
                    kind,
                    int(mode_text, 8),
                    int(uid_text),
                    int(gid_text),
                    int(mtime_text),
                )
            )

    # Restore children before directories so each directory timestamp is the
    # final operation affecting it. Validate every row before mutating anything.
    rows.sort(key=lambda row: (row[1] == "directory", -len(row[0].parts)))
    for path, kind, mode, uid, gid, mtime in rows:
        if os.geteuid() == 0:
            try:
                os.chown(path, uid, gid, follow_symlinks=False)
            except (OSError, NotImplementedError, OverflowError, ValueError) as exc:
                raise MetadataError(f"could not restore ownership for {path}: {exc}") from exc

        # Unix symlink permissions are not mutable on the supported platforms;
        # chmod would either follow the link or report an unsupported operation.
        if kind != "symbolic link":
            try:
                os.chmod(path, mode, follow_symlinks=False)
            except (OSError, NotImplementedError, OverflowError, ValueError) as exc:
                raise MetadataError(f"could not restore mode for {path}: {exc}") from exc
        try:
            os.utime(path, (mtime, mtime), follow_symlinks=False)
        except (OSError, NotImplementedError, OverflowError, ValueError) as exc:
            raise MetadataError(f"could not restore timestamp for {path}: {exc}") from exc
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
            path = safe_existing_path(
                root, str(record.get("path", "")), reject_parent_symlinks=True
            )
            attributes = record.get("xattrs", {})
            if not isinstance(attributes, dict):
                raise MetadataError(f"invalid xattr map on row {line_number}")
            if attributes and not hasattr(os, "setxattr"):
                raise MetadataError(
                    f"archive contains xattrs on row {line_number}, but this platform cannot restore them"
                )
            for name, encoded in attributes.items():
                if not isinstance(name, str) or not name or "\x00" in name:
                    raise MetadataError(f"invalid xattr name on row {line_number}")
                if not isinstance(encoded, str):
                    raise MetadataError(f"invalid xattr value on row {line_number}")
                try:
                    value = base64.b64decode(encoded, validate=True)
                except (ValueError, TypeError) as exc:
                    raise MetadataError(f"invalid xattr value on row {line_number}") from exc
                try:
                    os.setxattr(path, name, value, follow_symlinks=False)
                except (OSError, NotImplementedError, OverflowError, ValueError) as exc:
                    raise MetadataError(
                        f"could not restore xattr {name!r} for {path}: {exc}"
                    ) from exc
                restored += 1
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
    if flags and not hasattr(os, "chflags"):
        raise MetadataError(
            "the archive contains file flags, but this platform cannot restore them"
        )
    if not flags:
        return 0
    restored = 0
    for path, value in flags:
        try:
            os.chflags(path, value, follow_symlinks=False)
            restored += 1
        except (OSError, NotImplementedError, OverflowError, ValueError) as exc:
            raise MetadataError(f"could not restore file flags for {path}: {exc}") from exc
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
    parser.add_argument("--capture-files", action="store_true",
                        help="Capture NUL-delimited relative paths from stdin into files.tsv")
    args = parser.parse_args()
    try:
        if args.capture_files:
            capture_files(pathlib.Path(args.root), pathlib.Path(args.metadata_dir) / "files.tsv", sys.stdin.buffer)
        else:
            restore(pathlib.Path(args.root), pathlib.Path(args.metadata_dir))
    except (MetadataError, OSError) as exc:
        print(f"Error: metadata {'capture' if args.capture_files else 'restoration'} failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
