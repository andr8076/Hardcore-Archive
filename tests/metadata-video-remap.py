#!/usr/bin/env python3
"""Transcoded and omitted videos must have restorable metadata paths."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile


helper = Path(__file__).resolve().parents[1] / "lib/hardcore-archive-metadata.py"
spec = importlib.util.spec_from_file_location("hardcore_metadata", helper)
assert spec and spec.loader
metadata = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = metadata
spec.loader.exec_module(metadata)


with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    directory = root / "metadata"
    directory.mkdir()
    original = "source/clip.mp4"
    renamed = "source/clip.mkv"
    same = "source/same.mkv"
    omitted = "source/omit.mp4"
    fallback = "source/keep.mp4"
    paths = [original, same, omitted, fallback]
    header = "type\tmode\tuid\tgid\tmtime_epoch\tpath\tlink_target\n"
    uid, gid = os.getuid(), os.getgid()
    files = header + "".join(f"regular file\t640\t{uid}\t{gid}\t1\t{path}\t\n" for path in paths)
    (directory / "files.tsv").write_text(files)
    (directory / "acl.txt").write_text("".join(f"# file: {path}\nuser::rw-\n\n" for path in paths))
    xheader = "# hardcore-archive xattrs-and-flags jsonl v1\n"
    (directory / "xattrs.txt").write_text(xheader + "".join(
        json.dumps({"path": path, "xattrs": {"user.test": "YQ=="}}) + "\n" for path in paths
    ))
    (directory / "sparse.tsv").write_text(
        "path\tlogical_size\tstart\tlength\n" +
        "".join(f"{path}\t100\t10\t5\n" for path in paths)
    )
    decisions = root / "videos.tsv"
    decisions.write_text(
        f"transcoded\t{original}\t{renamed}\t100\t90\n"
        f"transcoded\t{same}\t{same}\t100\t90\n"
        f"omitted\t{omitted}\t\t100\t0\n"
        f"original\t{fallback}\t{fallback}\t100\t100\n"
    )
    assert metadata.remap_video_metadata(directory, decisions) == 2
    for name in ("files.tsv", "acl.txt", "xattrs.txt"):
        text = (directory / name).read_text()
        assert renamed in text and original not in text and omitted not in text and fallback in text
    assert (directory / "sparse.tsv").read_text() == (
        "path\tlogical_size\tstart\tlength\n"
        f"{fallback}\t100\t10\t5\n"
    )
    # Validate restored paths before touching any file's ownership or mode.
    restored = root / "restored"
    (restored / "source").mkdir(parents=True)
    for path in (renamed, same, fallback):
        (restored / path).write_bytes(b"data")
    assert metadata.restore_file_metadata(restored, directory) == 3

    (directory / "files.tsv").write_text(files + f"regular file\t640\t{uid}\t{gid}\t1\t{renamed}\t\n")
    try:
        metadata.remap_video_metadata(directory, decisions)
    except metadata.MetadataError as error:
        assert "collides" in str(error)
    else:
        raise AssertionError("video path collision accepted")

    (directory / "files.tsv").write_text(files)
    (directory / "acl.txt").write_text(metadata.DARWIN_ACL_HEADER + "\n" + "".join(
        json.dumps({"path": path, "acl": "!#acl 1"}) + "\n" for path in paths
    ))
    assert metadata.remap_video_metadata(directory, decisions) == 2
    mac_acl = (directory / "acl.txt").read_text()
    assert renamed in mac_acl and original not in mac_acl and omitted not in mac_acl

print("Video metadata remap tests passed.")
