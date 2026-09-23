#!/usr/bin/env python3
"""Exercise production restore with controlled listings and optional real 7-Zip."""
import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RESTORE_MODULE = ROOT / "lib/restore.sh"
SEVEN_ZIP = next((p for name in ("7zz", "7z", "7za") if (p := shutil.which(name))), None)

FAKE_ARCHIVER = r'''#!/usr/bin/env python3
import os, pathlib, shutil, signal, sys
root = pathlib.Path(os.environ['TEST_ROOT'])
command = sys.argv[1]
with (root / 'calls').open('a') as log:
    log.write(command + '\n')
if command == 'i':
    sys.exit(0)
if command == 't':
    sys.exit(int(os.environ.get('TEST_INTEGRITY_RC', '0')))
if command == 'l':
    if '-ba' not in sys.argv or os.environ.get('TEST_LEAK_HEADER'):
        print('Path = ' + str(root / 'archive with spaces.7z'))
        print('Type = 7z\n\n----------')
    print((root / 'listing').read_text(), end='')
    sys.exit(int(os.environ.get('TEST_LIST_RC', '0')))
if command == 'x':
    destination = pathlib.Path(next(arg[2:] for arg in sys.argv[2:] if arg.startswith('-o')))
    shutil.copytree(root / 'payload', destination, dirs_exist_ok=True, symlinks=True)
    ignored_link = os.environ.get('TEST_IGNORED_SYMLINK')
    if ignored_link:
        (destination / ignored_link).unlink()
        print(f'ERROR: Dangerous symbolic link path was ignored : {ignored_link} : ../../01-text/repeated-logs.log')
        print('Sub items Errors: 1')
        print('Archives with Errors: 1')
        print('Error: Archive extraction failed.')
        sys.exit(1)
    if os.environ.get('TEST_SIGNAL'):
        os.kill(os.getppid(), signal.SIGTERM)
    sys.exit(int(os.environ.get('TEST_EXTRACT_RC', '0')))
sys.exit(2)
'''


class RestoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hardcore restore ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.payload = self.root / "payload"
        self.tree = self.payload / "source"
        self.tree.mkdir(parents=True)
        self.name = "photo å & notes.txt"
        self.content = b"restore round-trip payload\n"
        self.file = self.tree / self.name
        self.file.write_bytes(self.content)
        self.file.chmod(0o777)
        self.meta = self.payload / ".hardcore-archive-metadata"
        self.meta.mkdir()
        (self.meta / "files.tsv").write_text(
            "type\tmode\tuid\tgid\tmtime_epoch\tpath\tlink_target\n"
            f"regular file\t640\t{os.getuid()}\t{os.getgid()}\t1700000000\tsource/{self.name}\t\n"
        )
        self.archive = self.root / "archive with spaces.7z"
        self.archive.touch()
        self.destination = self.root / "restored files"
        self.fake = self.root / "fake-7z"
        self.fake.write_text(FAKE_ARCHIVER)
        self.fake.chmod(0o700)
        self.listing = self.root / "listing"
        self.listing.write_text(f"Path = source/{self.name}\nSize = {len(self.content)}\n\n")
        self.outside = self.root / "outside.txt"
        self.outside.write_text("do not touch\n")

    def run_restore(self, real=False, frontend=False, **env):
        script = r'''set -Eeuo pipefail
MIB=1048576
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
human_bytes() { printf '%s bytes' "$1"; }
df() {
    printf 'Filesystem blocks used available capacity mounted\n'
    printf 'device 999999999999 0 %s 0%% /\n' "${TEST_FREE:-999999999999}"
}
source "$RESTORE_MODULE"
POSITIONAL=("$TEST_ARCHIVE" "$TEST_DESTINATION")
restore_existing_archive
'''
        command = ["bash", "-c", script]
        if frontend:
            (self.root / "7zz").symlink_to(self.fake)
            env["PATH"] = str(self.root) + os.pathsep + os.environ["PATH"]
            command = ["bash", str(ROOT / "hardcore-archive"), "--no-config", "--no-poweroff",
                       "--allow-sleep", "--yes", "--restore", str(self.archive), str(self.destination)]
        result = subprocess.run(
            command, text=True, capture_output=True, timeout=30,
            env=dict(os.environ, TEST_ROOT=str(self.root), TEST_ARCHIVE=str(self.archive),
                     TEST_DESTINATION=str(self.destination), SEVEN_ZIP=SEVEN_ZIP if real else str(self.fake),
                     METADATA_HELPER=str(ROOT / "lib/hardcore-archive-metadata.py"),
                     RESTORE_MODULE=str(RESTORE_MODULE), **env),
        )
        self.assertEqual(self.outside.read_text(), "do not touch\n")
        self.assertEqual(self.file.read_bytes(), self.content)
        self.assertFalse(list(self.root.glob(".*.restore.*")), result.stdout + result.stderr)
        return result

    def calls(self):
        path = self.root / "calls"
        return path.read_text().splitlines() if path.exists() else []

    def assert_failed(self, result, before_extraction=True):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.destination.exists())
        self.assertFalse(Path(str(self.destination) + ".restore.lock").exists())
        if before_extraction:
            self.assertNotIn("x", self.calls())
        else:
            self.assertIn("x", self.calls())

    def assert_restored(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        restored = self.destination / self.name
        self.assertEqual(restored.read_bytes(), self.content)
        self.assertEqual(stat.S_IMODE(restored.stat().st_mode), 0o640)
        self.assertEqual(int(restored.stat().st_mtime), 1700000000)
        self.assertFalse(list(self.destination.glob(".hardcore-archive-*")))
        self.assertFalse(Path(str(self.destination) + ".restore.lock").exists())
        self.assertIn("Restore completed successfully", result.stdout)

    def add_hashes(self):
        (self.payload / ".hardcore-archive-sha256.txt").write_text(
            hashlib.sha256(self.content).hexdigest() + f"  source/{self.name}\n"
        )

    def add_dangerous_relative_symlink(self):
        target_directory = self.tree / "01-text"
        target_directory.mkdir()
        target = target_directory / "repeated-logs.log"
        target.write_text("symlink target payload\n")
        link_directory = self.tree / "06-paths-and-metadata" / "links"
        link_directory.mkdir(parents=True)
        link = link_directory / "relative-link-to-text"
        link_target = "../../01-text/repeated-logs.log"
        link.symlink_to(link_target)
        relative_link = "source/06-paths-and-metadata/links/relative-link-to-text"
        relative_target = "source/01-text/repeated-logs.log"
        owner = f"{os.getuid()}\t{os.getgid()}\t1700000000"
        with (self.meta / "files.tsv").open("a") as manifest:
            manifest.write(f"directory\t755\t{owner}\tsource/01-text\t\n")
            manifest.write(f"regular file\t644\t{owner}\t{relative_target}\t\n")
            manifest.write(f"directory\t755\t{owner}\tsource/06-paths-and-metadata\t\n")
            manifest.write(f"directory\t755\t{owner}\t{link_directory.relative_to(self.payload)}\t\n")
            manifest.write(f"symbolic link\t777\t{owner}\t{relative_link}\t{link_target}\n")
        with self.listing.open("a") as listing:
            listing.write(f"Path = {relative_target}\nSize = {target.stat().st_size}\n\n")
            listing.write(f"Path = {relative_link}\nSize = {len(link_target)}\n\n")
        return relative_link, link_target

    def rename_source_root(self, name):
        old_tree = self.tree
        self.tree = self.payload / name
        old_tree.rename(self.tree)
        self.file = self.tree / self.name
        manifest = self.meta / "files.tsv"
        manifest.write_text(manifest.read_text().replace("source/", f"{name}/"))
        self.listing.write_text(
            f"Path = {name}/{self.name}\nSize = {len(self.content)}\n\n"
        )

    def test_absolute_archive_path_and_metadata_roundtrip(self):
        self.assert_restored(self.run_restore())
        self.assertEqual(self.calls(), ["t", "l", "x"])

    def test_public_launcher_restore_roundtrip(self):
        self.add_hashes()
        self.assert_restored(self.run_restore(frontend=True))

    def test_public_launcher_failed_extraction_cleans_up(self):
        self.assert_failed(self.run_restore(frontend=True, TEST_EXTRACT_RC="2"), before_extraction=False)

    def test_ignored_dangerous_symlink_is_recreated_from_metadata(self):
        relative_link, link_target = self.add_dangerous_relative_symlink()
        result = self.run_restore(TEST_IGNORED_SYMLINK=relative_link)
        self.assert_restored(result)
        restored_link = self.destination / relative_link.removeprefix("source/")
        self.assertTrue(restored_link.is_symlink())
        self.assertEqual(os.readlink(restored_link), link_target)
        self.assertEqual(restored_link.read_text(), "symlink target payload\n")
        self.assertIn("symlinks_recreated=1", result.stdout)
        self.assertIn("skipped only 1 symbolic link", result.stdout)

    def test_ignored_symlink_escaping_restore_root_is_rejected(self):
        relative_link, _ = self.add_dangerous_relative_symlink()
        manifest = self.meta / "files.tsv"
        metadata = manifest.read_text()
        self.assertIn("../../01-text/repeated-logs.log", metadata)
        manifest.write_text(metadata.replace(
            "../../01-text/repeated-logs.log", "../../../../outside.txt"
        ))
        result = self.run_restore(TEST_IGNORED_SYMLINK=relative_link)
        self.assert_failed(result, before_extraction=False)
        self.assertIn("symbolic link target escapes restore root", result.stderr)

    def test_embedded_hashes_verified_before_and_after_metadata(self):
        self.add_hashes()
        result = self.run_restore()
        self.assert_restored(result)
        self.assertIn("Verifying extracted file hashes", result.stdout)
        self.assertIn("Verifying hashes after sparse and metadata restoration", result.stdout)

    def test_no_hash_manifest_does_not_require_hash_comparison(self):
        result = self.run_restore()
        self.assert_restored(result)
        self.assertNotIn("Verifying extracted file hashes", result.stdout)

    def test_legitimate_internal_prefix_source_name_is_restored(self):
        self.rename_source_root(".hardcore-archive-photos")
        self.assert_restored(self.run_restore())

    def test_invalid_file_metadata_fails_before_commit(self):
        manifest = self.meta / "files.tsv"
        manifest.write_text(manifest.read_text().replace("\t640\t", "\t999\t"))
        result = self.run_restore()
        self.assert_failed(result, before_extraction=False)
        self.assertIn("invalid mode", result.stderr)

    def test_corrupt_extracted_content_is_not_committed(self):
        self.add_hashes()
        (self.payload / ".hardcore-archive-sha256.txt").write_text(f"{'0' * 64}  source/{self.name}\n")
        result = self.run_restore()
        self.assert_failed(result, before_extraction=False)
        self.assertIn("hash verification failed", result.stderr)

    def test_unsafe_first_or_later_member_is_never_skipped(self):
        valid = self.listing.read_text()
        for path in ("/tmp/escape", "../outside.txt", "source/../../outside.txt",
                     r"C:\escape", "C:escape", r"\\server\share\escape",
                     r"source\..\escape", ""):
            for first in (True, False):
                with self.subTest(path=path, first=first):
                    unsafe = f"Path = {path}\nSize = 1\n\n"
                    self.listing.write_text(unsafe + valid if first else valid + unsafe)
                    result = self.run_restore()
                    self.assert_failed(result)
                    self.assertIn("Unsafe archive paths", result.stderr)

    def test_unexpected_archive_header_still_fails_closed(self):
        self.assert_failed(self.run_restore(TEST_LEAK_HEADER="1"))

    def test_listing_failure_including_partial_safe_output_fails_closed(self):
        for text in ("", self.listing.read_text()):
            with self.subTest(text=text):
                self.listing.write_text(text)
                self.assert_failed(self.run_restore(TEST_LIST_RC="2"))

    def test_invalid_member_size_fails_closed(self):
        for size in ("-1", "unknown", "1.5"):
            with self.subTest(size=size):
                self.listing.write_text(f"Path = source/file\nSize = {size}\n")
                self.assert_failed(self.run_restore())

    def test_integrity_failure_prevents_listing_and_extraction(self):
        self.assert_failed(self.run_restore(TEST_INTEGRITY_RC="2"))
        self.assertEqual(self.calls(), ["t"])

    def test_space_estimate_uses_member_size_and_safety_margin(self):
        required = len(self.content) + len(self.content) // 20 + 256 * 1048576
        self.assert_failed(self.run_restore(TEST_FREE=str(required - 1)))
        self.assert_restored(self.run_restore(TEST_FREE=str(required)))

    def test_failed_extraction_removes_partial_temporary_tree(self):
        self.assert_failed(self.run_restore(TEST_EXTRACT_RC="2"), before_extraction=False)

    def test_termination_removes_partial_temporary_tree(self):
        result = self.run_restore(TEST_SIGNAL="1")
        self.assertEqual(result.returncode, 143, result.stdout + result.stderr)
        self.assert_failed(result, before_extraction=False)

    def test_hostile_metadata_fails_without_committing(self):
        manifest = self.meta / "files.tsv"
        manifest.write_text(manifest.read_text().replace(f"source/{self.name}", "../outside.txt"))
        self.assert_failed(self.run_restore(), before_extraction=False)

    def test_existing_destination_is_unchanged(self):
        self.destination.mkdir()
        sentinel = self.destination / "keep.txt"
        sentinel.write_text("existing\n")
        result = self.run_restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sentinel.read_text(), "existing\n")
        self.assertEqual(self.calls(), [])

    def test_active_lock_is_not_truncated_or_removed(self):
        lock = Path(str(self.destination) + ".restore.lock")
        with lock.open("w+") as handle:
            handle.write("owned by another process\n")
            handle.flush()
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_restore()
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(lock.read_text(), "owned by another process\n")
            self.assertEqual(self.calls(), [])

    def test_sparse_reconstruction_preserves_bytes(self):
        sparse = self.tree / "sparse.bin"
        content = b"head" + b"\0" * 65536 + b"tail"
        sparse.write_bytes(content)
        (self.meta / "sparse.tsv").write_text(
            f"path\tlogical_size\tstart\tlength\nsource/sparse.bin\t{len(content)}\t4\t65536\n"
        )
        self.assert_restored(self.run_restore())
        self.assertEqual((self.destination / "sparse.bin").read_bytes(), content)

    def test_malformed_sparse_metadata_fails_before_commit(self):
        (self.meta / "sparse.tsv").write_text(
            "path\tlogical_size\tstart\tlength\nsource/file.bin\tnot-a-size\t0\t1\n"
        )
        result = self.run_restore()
        self.assert_failed(result, before_extraction=False)
        self.assertIn("invalid sparse metadata", result.stderr)

    @unittest.skipUnless(SEVEN_ZIP, "7-Zip is not installed; controlled-backend restore tests still run")
    def test_real_7zip_dangerous_relative_symlink_roundtrip(self):
        relative_link, link_target = self.add_dangerous_relative_symlink()
        self.archive.unlink()
        created = subprocess.run(
            [SEVEN_ZIP, "a", "-t7z", "-mx=0", "-snl", str(self.archive), "."],
            cwd=self.payload, text=True, capture_output=True, timeout=30,
        )
        self.assertEqual(created.returncode, 0, created.stdout + created.stderr)
        result = self.run_restore(real=True)
        self.assert_restored(result)
        restored_link = self.destination / relative_link.removeprefix("source/")
        self.assertTrue(restored_link.is_symlink(), result.stdout + result.stderr)
        self.assertEqual(os.readlink(restored_link), link_target)
        self.assertEqual(restored_link.read_text(), "symlink target payload\n")

    @unittest.skipUnless(SEVEN_ZIP, "7-Zip is not installed; controlled-backend restore tests still run")
    def test_real_7zip_metadata_and_hash_roundtrip(self):
        self.add_hashes()
        # The placeholder is not an archive; remove only that exact fixture file.
        self.archive.unlink()
        created = subprocess.run(
            [SEVEN_ZIP, "a", "-t7z", "-mx=0", str(self.archive), "."],
            cwd=self.payload, text=True, capture_output=True, timeout=30,
        )
        self.assertEqual(created.returncode, 0, created.stdout + created.stderr)
        self.assert_restored(self.run_restore(real=True))


if __name__ == "__main__":
    unittest.main(verbosity=2)
