#!/usr/bin/env python3
"""Verify that a renamed nested archive has restorable metadata."""
import importlib.util
import json
from pathlib import Path
import tempfile


HELPER = Path(__file__).resolve().parents[1] / "lib/hardcore-archive-metadata.py"
spec = importlib.util.spec_from_file_location("metadata_helper", HELPER)
assert spec and spec.loader
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    directory = root / "metadata"
    directory.mkdir()
    original = "source/nested.zip"
    archived = "source/nested.7z"
    (directory / "files.tsv").write_text(
        "type\tmode\tuid\tgid\tmtime_epoch\tpath\tlink_target\n"
        f"regular file\t644\t1000\t1000\t1\t{original}\t\n"
        "directory\t755\t1000\t1000\t1\tsource\t\n"
    )
    (directory / "acl.txt").write_text(f"# file: {original}\nuser::rw-\n")
    (directory / "xattrs.txt").write_text(
        "# hardcore-archive xattrs-and-flags jsonl v1\n"
        + json.dumps({"path": original, "xattrs": {"user.test": "YQ=="}}) + "\n"
    )
    (directory / "sparse.tsv").write_text(
        "path\tlogical_size\tstart\tlength\n"
        f"{original}\t100\t10\t5\n"
    )
    decisions = root / "nested.tsv"
    decisions.write_text(f"repacked\t{original}\t{archived}\t100\t90\t90\tcandidate-smaller\n")
    assert metadata.remap_nested_metadata(directory, decisions) == 1
    assert archived in (directory / "files.tsv").read_text()
    assert original not in (directory / "files.tsv").read_text()
    assert f"# file: {archived}" in (directory / "acl.txt").read_text()
    assert json.loads((directory / "xattrs.txt").read_text().splitlines()[1])["path"] == archived
    assert (directory / "sparse.tsv").read_text() == "path\tlogical_size\tstart\tlength\n"
    (directory / "files.tsv").write_text(
        (directory / "files.tsv").read_text()
        + f"regular file\t644\t1000\t1000\t1\t{original}\t\n"
    )
    try:
        metadata.remap_nested_metadata(directory, decisions)
    except metadata.MetadataError:
        pass
    else:
        raise AssertionError("renamed member collision was accepted")

print("Nested metadata remap tests passed.")
