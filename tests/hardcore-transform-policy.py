#!/usr/bin/env python3
"""A declared transform may change one file; unrelated corruption must fail."""
import importlib.util
from pathlib import Path
import subprocess
from unittest.mock import patch


path = Path(__file__).resolve().parents[1] / "benchmarks/hardcore_transform_policy.py"
spec = importlib.util.spec_from_file_location("hardcore_transform_policy", path)
assert spec and spec.loader
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)

before = {
    "keep.txt": {"type": "F", "size": 3, "sha256": "old-keep"},
    "photo.jpg": {"type": "F", "size": 9, "sha256": "old-photo"},
    "nested.zip": {"type": "F", "size": 100, "sha256": "old-zip"},
    "link": {"type": "L", "target": "keep.txt"},
}
after = {
    "keep.txt": before["keep.txt"],
    "photo.jpg": {"type": "F", "size": 7, "sha256": "new-photo"},
    "nested.7z": {"type": "F", "size": 40, "sha256": "new-archive"},
    "link": before["link"],
}
contents = {
    ".hardcore-archive-image-manifest.txt":
        b"optimized\tWork Tools/photo.jpg\tWork Tools/photo.jpg\t9\t7\tjpegtran\n",
    ".hardcore-archive-nested-manifest.txt":
        b"action\toriginal path\tarchived path\toriginal bytes\tcandidate bytes\tarchived bytes\treason\n"
        b"repacked\tWork Tools/nested.zip\tWork Tools/nested.7z\t100\t40\t40\tcandidate-smaller\n",
}


def fake_extract(command, **_kwargs):
    return subprocess.CompletedProcess(command, 0, contents.get(command[-1], b""), b"")


with patch.object(policy.subprocess, "run", side_effect=fake_extract):
    declarations = policy.declared_transforms(Path("archive.7z"), "7z", "Work Tools")
assert declarations == {"photo.jpg": ("photo.jpg", 9, 7), "nested.zip": ("nested.7z", 100, 40)}
assert policy.check_transform_roundtrip(before, after, declarations) == []

corrupt = dict(after)
corrupt["keep.txt"] = {"type": "F", "size": 3, "sha256": "corrupted-same-size"}
assert any("keep.txt" in error for error in policy.check_transform_roundtrip(before, corrupt, declarations))
corrupt = dict(after)
corrupt["nested.7z"] = {"type": "F", "size": 39, "sha256": "new-archive"}
assert any("nested.7z" in error for error in policy.check_transform_roundtrip(before, corrupt, declarations))
corrupt = dict(after)
corrupt["other.txt"] = {"type": "F", "size": 1, "sha256": "extra"}
assert any("other.txt" in error for error in policy.check_transform_roundtrip(before, corrupt, declarations))

contents[".hardcore-archive-image-manifest.txt"] += b"optimized\tWork Tools/keep.txt\tWork Tools/photo.jpg\t3\t7\tinvalid\n"
with patch.object(policy.subprocess, "run", side_effect=fake_extract):
    try:
        policy.declared_transforms(Path("archive.7z"), "7z", "Work Tools")
    except policy.TransformPolicyError:
        pass
    else:
        raise AssertionError("duplicate target accepted")

print("Hardcore transform policy tests passed.")
