#!/usr/bin/env python3
"""Direct staging keeps source bytes intact and rejects unsafe lane decisions."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


helper = Path(__file__).resolve().parents[1] / "lib/hardcore-direct-stage.py"
spec = importlib.util.spec_from_file_location("hardcore_direct_stage", helper)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def rejects(source, output, lanes, contains):
    try:
        module.assemble(source, output, lanes)
    except ValueError as error:
        assert contains in str(error), str(error)
    else:
        raise AssertionError(f"accepted invalid decision: {contains}")
    assert not output.exists()


with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    source = root / "Work Tools"
    (source / "docs").mkdir(parents=True)
    (source / "docs" / "keep.txt").write_bytes(b"unchanged")
    (source / "docs" / "nested.zip").write_bytes(b"zip contents")
    (source / "docs" / "photo.png").write_bytes(b"original image")
    (source / "docs" / "clip.mp4").write_bytes(b"original video")
    (source / "docs" / "omit.mp4").write_bytes(b"omitted video")
    image = root / "image-lane"
    video = root / "video-lane"
    nested = root / "nested-lane"
    for directory in (image, video, nested):
        (directory / source.name / "docs").mkdir(parents=True)
    (image / source.name / "docs" / "photo.png").write_bytes(b"optimized image")
    (video / source.name / "docs" / "clip.mkv").write_bytes(b"converted video")
    (nested / source.name / "docs" / "nested.7z").write_bytes(b"converted zip")
    image_manifest = root / "images.tsv"
    video_manifest = root / "videos.tsv"
    nested_manifest = root / "nested.tsv"
    image_manifest.write_text(f"optimized\t{source.name}/docs/photo.png\t{source.name}/docs/photo.png\t14\t15\tpngquant\n")
    video_manifest.write_text(
        f"transcoded\t{source.name}/docs/clip.mp4\t{source.name}/docs/clip.mkv\t14\t15\n"
        f"omitted\t{source.name}/docs/omit.mp4\t\t13\t0\n"
    )
    nested_manifest.write_text(f"repacked\t{source.name}/docs/nested.zip\t{source.name}/docs/nested.7z\t12\t13\t13\tsmaller\n")
    lanes = [module.Lane("image", image_manifest, image),
             module.Lane("video", video_manifest, video),
             module.Lane("nested", nested_manifest, nested)]
    # The archive target must be distinct from every source entry.
    rejects(source, source / "stage", lanes, "stage must be separate")
    (source / "docs" / "nested.7z").write_bytes(b"collision")
    rejects(source, root / "collision", lanes, "collides with source")
    (source / "docs" / "nested.7z").unlink()
    stage = root / "stage"
    assert module.assemble(source, stage, lanes) == 4
    staged = stage / source.name / "docs"
    assert (staged / "keep.txt").read_bytes() == b"unchanged"
    assert (staged / "photo.png").read_bytes() == b"optimized image"
    assert (staged / "clip.mkv").read_bytes() == b"converted video"
    assert (staged / "nested.7z").read_bytes() == b"converted zip"
    assert not (staged / "clip.mp4").exists()
    assert not (staged / "nested.zip").exists()
    assert not (staged / "omit.mp4").exists()
    assert (source / "docs" / "clip.mp4").read_bytes() == b"original video"
    assert (source / "docs" / "omit.mp4").read_bytes() == b"omitted video"
    manifest_stage = root / "manifests"
    metadata = manifest_stage / ".hardcore-archive-metadata"
    metadata.mkdir(parents=True)
    (metadata / "files.tsv").write_text(
        "type\tmode\tuid\tgid\tmtime_epoch\tpath\tlink_target\n" +
        "".join(f"{'directory' if name in (source.name, source.name + '/docs') else 'regular file'}"
                f"\t755\t{os.getuid()}\t{os.getgid()}\t1\t{name}\t\n"
                for name in (source.name, source.name + "/docs", *(
                    source.name + "/docs/" + file for file in ("keep.txt", "photo.png", "clip.mkv", "nested.7z")
                )))
    )
    for name, content in {
        "acl.txt": "", "xattrs.txt": "# hardcore-archive xattrs-and-flags jsonl v1\n",
        "sparse.tsv": "path\tlogical_size\tstart\tlength\n",
        "archive-info.txt": "Fixture: direct stage\n", "RESTORE-NOTES.txt": "Restore with Hardcore Archive\n",
    }.items():
        (metadata / name).write_text(content)
    (manifest_stage / ".hardcore-archive-video-manifest.txt").write_text("Fixture video decisions\n")
    expected = root / "expected-paths.txt"
    wanted = [source.name, source.name + "/docs"] + [
        source.name + "/docs/" + file for file in ("keep.txt", "photo.png", "clip.mkv", "nested.7z")
    ] + [".hardcore-archive-metadata"] + [
        ".hardcore-archive-metadata/" + file for file in module.METADATA_FILES
    ] + [".hardcore-archive-video-manifest.txt"]
    expected.write_text("\n".join(sorted(wanted)) + "\n")
    complete_stage = root / "complete-stage"
    assert module.assemble(source, complete_stage, lanes, manifest_stage, expected) == 4
    assert (complete_stage / ".hardcore-archive-metadata" / "files.tsv").read_text() == (
        metadata / "files.tsv").read_text()
    assert (complete_stage / ".hardcore-archive-video-manifest.txt").is_file()
    expected.write_text("\n".join(sorted(wanted[:-1])) + "\n")
    rejects_with_manifests = root / "unexpected-manifest"
    try:
        module.assemble(source, rejects_with_manifests, lanes, manifest_stage, expected)
    except ValueError as error:
        assert "staged paths differ" in str(error)
    else:
        raise AssertionError("accepted archive with an unaccounted manifest")
    assert not rejects_with_manifests.exists()
    expected.write_text("\n".join(sorted(wanted)) + "\n")
    (metadata / "acl.txt").unlink()
    (metadata / "acl.txt").symlink_to(source / "docs" / "keep.txt")
    try:
        module.assemble(source, root / "linked-manifest", lanes, manifest_stage, expected)
    except ValueError as error:
        assert "linked files" in str(error)
    else:
        raise AssertionError("accepted a linked metadata file")
    assert not (root / "linked-manifest").exists()
    (metadata / "acl.txt").unlink()
    (metadata / "acl.txt").write_text("")
    if shutil.which("7z"):
        archive = root / "single-pass.7z"
        subprocess.run(["7z", "a", str(archive), source.name, ".hardcore-archive-metadata",
                        ".hardcore-archive-video-manifest.txt", "-t7z", "-mx=3", "-snl", "-snh", "-spd", "-y"],
                       cwd=complete_stage, check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["7z", "t", str(archive)], check=True, stdout=subprocess.DEVNULL)
        restored = root / "restored"
        subprocess.run(["7z", "x", str(archive), f"-o{restored}", "-y"],
                       check=True, stdout=subprocess.DEVNULL)
        for name in ("keep.txt", "photo.png", "clip.mkv", "nested.7z"):
            assert (restored / source.name / "docs" / name).read_bytes() == (staged / name).read_bytes()
        for name in ("clip.mp4", "nested.zip", "omit.mp4"):
            assert not (restored / source.name / "docs" / name).exists()
        assert (restored / ".hardcore-archive-metadata" / "files.tsv").read_bytes() == (
            metadata / "files.tsv").read_bytes()
        metadata_helper = helper.parent / "hardcore-archive-metadata.py"
        subprocess.run([sys.executable, str(metadata_helper), "--root", str(restored),
                        "--metadata-dir", str(restored / ".hardcore-archive-metadata")],
                       check=True, stdout=subprocess.DEVNULL)
        assert int((restored / source.name / "docs" / "clip.mkv").stat().st_mtime) == 1

    nested_manifest.write_text(f"repacked\t{source.name}/docs/nested.zip\t../outside\t12\t13\t13\tsmaller\n")
    rejects(source, root / "traversal", lanes, "unsafe")
    nested_manifest.write_text(f"repacked\t{source.name}/docs/nested.zip\t{source.name}/docs/nested.7z\t12\t13\t13\tsmaller\n")
    (nested / source.name / "docs" / "nested.7z").unlink()
    (nested / source.name / "docs" / "nested.7z").symlink_to(source / "docs" / "nested.zip")
    rejects(source, root / "linked", lanes, "linked")
    (nested / source.name / "docs" / "nested.7z").unlink()
    (nested / source.name / "docs" / "nested.7z").write_bytes(b"converted zip")
    (source / "docs" / "escape").symlink_to(root, target_is_directory=True)
    (video / source.name / "docs" / "escape").mkdir()
    (video / source.name / "docs" / "escape" / "clip.mkv").write_bytes(b"converted video")
    video_manifest.write_text(
        f"transcoded\t{source.name}/docs/clip.mp4\t{source.name}/docs/escape/clip.mkv\t14\t15\n"
    )
    rejects(source, root / "parent-link", lanes, "linked parent")

print("Direct staging policy tests passed.")
