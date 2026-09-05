#!/usr/bin/env python3
"""Capture and compare source-tree metadata for benchmark diagnostics."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import stat


def entry_type(mode: int) -> str:
    if stat.S_ISREG(mode):
        return "file"
    if stat.S_ISDIR(mode):
        return "dir"
    if stat.S_ISLNK(mode):
        return "symlink"
    if stat.S_ISFIFO(mode):
        return "fifo"
    if stat.S_ISSOCK(mode):
        return "socket"
    if stat.S_ISCHR(mode):
        return "char-device"
    if stat.S_ISBLK(mode):
        return "block-device"
    return "other"


def snapshot_record(path: Path) -> dict[str, object]:
    st = path.lstat()
    kind = entry_type(st.st_mode)
    record: dict[str, object] = {
        "type": kind,
        "size": st.st_size,
        "mode": stat.S_IMODE(st.st_mode),
        "mtime_ns": st.st_mtime_ns,
        "ctime_ns": st.st_ctime_ns,
    }
    if kind == "symlink":
        try:
            record["target"] = os.readlink(path)
        except OSError as exc:
            record["target_error"] = str(exc)
    return record


def capture(root: Path) -> dict[str, dict[str, object]]:
    root = root.resolve()
    root_stat = root.stat()
    root_device = root_stat.st_dev
    result: dict[str, dict[str, object]] = {".": snapshot_record(root)}
    stack = [root]
    while stack:
        directory = stack.pop()
        with os.scandir(directory) as entries:
            items = sorted(entries, key=lambda e: os.fsencode(e.name))
        for item in items:
            path = Path(item.path)
            rel = os.path.relpath(path, root)
            record = snapshot_record(path)
            result[rel] = record
            # Match Hardcore's default one-filesystem source walk: record the
            # mount-point entry itself, but do not recurse into another device.
            if record["type"] == "dir" and item.stat(follow_symlinks=False).st_dev == root_device:
                stack.append(path)
    return result


def load(path: Path) -> dict[str, dict[str, object]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema") != 1 or not isinstance(data.get("entries"), dict):
        raise SystemExit(f"invalid source snapshot: {path}")
    return data["entries"]


def save(root: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    data = {"schema": 1, "root": str(root.resolve()), "entries": capture(root)}
    temporary = output.with_name(output.name + ".tmp")
    temporary.write_text(json.dumps(data, ensure_ascii=True, sort_keys=True), encoding="utf-8")
    os.replace(temporary, output)


def compare(before_path: Path, after_path: Path, report: Path) -> int:
    before = load(before_path)
    after = load(after_path)
    before_paths = set(before)
    after_paths = set(after)
    added = sorted(after_paths - before_paths, key=os.fsencode)
    removed = sorted(before_paths - after_paths, key=os.fsencode)
    modified: list[tuple[str, list[str]]] = []
    for path in sorted(before_paths & after_paths, key=os.fsencode):
        if before[path] == after[path]:
            continue
        fields = sorted(key for key in set(before[path]) | set(after[path]) if before[path].get(key) != after[path].get(key))
        modified.append((path, fields))

    report.parent.mkdir(parents=True, exist_ok=True)
    with report.open("w", encoding="utf-8") as handle:
        handle.write("Hardcore Archive benchmark source-change report\n")
        handle.write(f"Added: {len(added)}\nRemoved: {len(removed)}\nModified: {len(modified)}\n\n")
        for path in added:
            handle.write(f"ADDED\t{json.dumps(path, ensure_ascii=False)}\n")
        for path in removed:
            handle.write(f"REMOVED\t{json.dumps(path, ensure_ascii=False)}\n")
        for path, fields in modified:
            handle.write(f"MODIFIED\t{json.dumps(path, ensure_ascii=False)}\tfields={','.join(fields)}\n")
            for field in fields:
                handle.write(
                    f"  {field}: {json.dumps(before[path].get(field), ensure_ascii=False)} -> "
                    f"{json.dumps(after[path].get(field), ensure_ascii=False)}\n"
                )

    return 1 if added or removed or modified else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    cap = sub.add_parser("capture")
    cap.add_argument("root")
    cap.add_argument("output")
    cmp = sub.add_parser("compare")
    cmp.add_argument("before")
    cmp.add_argument("after")
    cmp.add_argument("report")
    args = parser.parse_args()
    if args.command == "capture":
        save(Path(args.root), Path(args.output))
        return 0
    return compare(Path(args.before), Path(args.after), Path(args.report))


if __name__ == "__main__":
    raise SystemExit(main())
