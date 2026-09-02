#!/usr/bin/env python3
"""Resource-use regressions with real filesystem metadata and GNU checksums."""
import importlib.util
import io
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "lib/hardcore-archive-metadata.py"
VERIFY = ROOT / "lib/verify.sh"
spec = importlib.util.spec_from_file_location("metadata", HELPER)
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


class ResourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_capture_matches_stat_and_roundtrips_modes_times_and_symlinks(self):
        tree = self.root / "tree"
        tree.mkdir()
        (tree / "file æ.txt").write_bytes(b"payload")
        (tree / "empty").touch()
        (tree / "link").symlink_to("file æ.txt")
        (tree / "dangling").symlink_to("absent")
        os.mkfifo(tree / "pipe")
        paths = ["tree"] + [f"tree/{p.name}" for p in tree.iterdir()]
        for name in paths:
            path = self.root / name
            if not path.is_symlink():
                path.chmod(0o750 if path.is_dir() else 0o640)
            os.utime(path, (1700000000, 1700000000), follow_symlinks=False)
        meta = self.root / "meta"
        meta.mkdir()
        expected = ["type\tmode\tuid\tgid\tmtime_epoch\tpath\tlink_target\n"]
        for name in paths:
            path = self.root / name
            fields = subprocess.check_output(["stat", "--printf=%F\t%a\t%u\t%g\t%Y", "--", str(path)],
                                             env=dict(os.environ, LC_ALL="C")).decode()
            target = os.readlink(path) if path.is_symlink() else ""
            expected.append(f"{fields}\t{name}\t{target}\n")
        count = metadata.capture_files(self.root, meta / "files.tsv",
                                       io.BytesIO(b"\0".join(os.fsencode(p) for p in paths) + b"\0"))
        self.assertEqual(count, len(paths))
        self.assertEqual((meta / "files.tsv").read_text(), "".join(expected))
        (tree / "file æ.txt").chmod(0o777)
        os.utime(tree / "file æ.txt", (1800000000, 1800000000))
        metadata.restore_file_metadata(self.root, meta)
        self.assertEqual(stat.S_IMODE((tree / "file æ.txt").stat().st_mode), 0o640)
        self.assertEqual(int((tree / "file æ.txt").stat().st_mtime), 1700000000)
        self.assertEqual(os.readlink(tree / "link"), "file æ.txt")
        self.assertEqual(os.readlink(tree / "dangling"), "absent")

    def test_capture_cli_handles_large_inventory_and_rejects_missing_paths(self):
        tree = self.root / "tree"
        tree.mkdir()
        names = []
        for i in range(800):
            name = "tree/" + f"{i:04d}-" + "x" * 90
            (self.root / name).touch()
            names.append(name)
        listing = b"\0".join(os.fsencode(p) for p in names) + b"\0"
        self.assertGreater(len(listing), 65536)
        result = subprocess.run(["python3", str(HELPER), "--capture-files", "--root", str(self.root),
                                 "--metadata-dir", str(self.root)], input=listing, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len((self.root / "files.tsv").read_text().splitlines()), 801)
        for listing in (b"tree/missing\0", b"../outside\0", b"tree/unterminated"):
            result = subprocess.run(["python3", str(HELPER), "--capture-files", "--root", str(self.root),
                                     "--metadata-dir", str(self.root)], input=listing, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"capture failed", result.stderr)

    def test_checksum_workers_balance_bytes_and_preserve_escaped_names(self):
        names = ["large 0", "large\\1", "large\n2", "large3", "small0", "small1", "small2", "small3"]
        for i, name in enumerate(names):
            (self.root / name).write_bytes(b"x" * (100000 if i < 4 else 10))
        real_sha = shutil.which("sha256sum")
        manifest = self.root / "manifest"
        manifest.write_bytes(subprocess.check_output([real_sha, "--", *names], cwd=self.root))
        fake = self.root / "sha-wrapper"
        fake.write_text('#!/usr/bin/env bash\ncp -- "${!#}" "$CAPTURE/$(basename -- "${!#}")"\n'
                        'exec "$REAL_SHA" "$@"\n')
        fake.chmod(0o700)
        capture = self.root / "capture"
        capture.mkdir()
        script = r'''
set -Eeuo pipefail
source "$VERIFY"
export HARDCORE_REAL_SHA256SUM="$FAKE_SHA" HARDCORE_HASH_JOBS=4
hardcore_enable_adaptive_hash_verifier
bash -c 'sha256sum -c --quiet "$MANIFEST"'
'''
        env = dict(os.environ, VERIFY=str(VERIFY), FAKE_SHA=str(fake), REAL_SHA=real_sha,
                   CAPTURE=str(capture), MANIFEST=str(manifest))
        result = subprocess.run(["bash", "-c", script], cwd=self.root, env=env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")  # Exported functions must import cleanly.
        parts = list(capture.iterdir())
        self.assertEqual(len(parts), 4)
        lines = manifest.read_bytes().splitlines(keepends=True)
        assigned = []
        for part in parts:
            content = part.read_bytes().splitlines(keepends=True)
            self.assertEqual(len(content), 2)
            self.assertEqual(sum(line in lines[:4] for line in content), 1)
            assigned.extend(content)
        self.assertCountEqual(assigned, lines)
        (self.root / names[2]).write_bytes(b"corrupt")
        result = subprocess.run(["bash", "-c", script], cwd=self.root, env=env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"FAILED", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
