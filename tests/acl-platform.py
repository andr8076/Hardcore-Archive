#!/usr/bin/env python3
"""Platform ACL policy tests, plus real Apple ACL round trips on macOS."""
import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "lib/hardcore-archive-metadata.py"
spec = importlib.util.spec_from_file_location("metadata", HELPER)
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)
UUID = "ABCDEFAB-CDEF-ABCD-EFAB-CDEF00000001"
ACL = f"!#acl 1\nuser:{UUID}:::deny:delete\nuser:{UUID}:::allow:read,readsecurity\n"


class ACLTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hardcore acl ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.tree = self.root / "tree"
        self.tree.mkdir()
        self.file = self.tree / "photo å & notes.txt"
        self.file.write_text("payload")
        self.meta = self.root / ".hardcore-archive-metadata"
        self.meta.mkdir()
        self.native = Mock()
        self.native.read.return_value = ACL

    def record(self, path=None, **fields):
        return dict(path=path or "tree/" + self.file.name, kind="file", target="", acl=ACL, **fields)

    def manifest(self, records):
        (self.meta / "acl.txt").write_text(metadata.DARWIN_ACL_HEADER + "\n"
                                          + "".join(json.dumps(r) + "\n" for r in records))

    def restore(self):
        with patch.object(metadata, "DarwinACL", return_value=self.native):
            return metadata.restore_acl(self.root, self.meta)

    def test_preserves_order_uuid_and_all_flags(self):
        text = (f"!#acl 1 no_inherit,defer_inherit\n"
                f"group:{UUID.lower()}:staff:20:deny,inherited:delete\n"
                f"user:{UUID}:someone:501:allow,directory_inherit,file_inherit,only_inherit,limit_inherit:read\n")
        result = metadata.normalize_darwin_acl(text)
        self.assertIn("!#acl 1 defer_inherit,no_inherit", result)
        self.assertLess(result.index("deny"), result.index("allow"))
        self.assertIn(UUID, result)
        self.assertNotIn("someone", result)
        self.assertIn("directory_inherit,file_inherit,limit_inherit,only_inherit", result)

    def test_rejects_malformed_acl_text(self):
        for text in ("", "!#acl 2\n", ACL + "\n", ACL + "# command: bad\n",
                     ACL.replace(UUID, "not-a-uuid"), ACL.replace("deny", "deny,"),
                     ACL.replace("delete", "unknown"), ACL.replace("delete", "delete,,read"),
                     ACL.replace("delete", "delete:extra"), ACL + "\x00",
                     "!#acl 1 no_inherit,\n", ACL.replace("deny", "execute")):
            with self.subTest(text=text), self.assertRaises(metadata.MetadataError):
                metadata.normalize_darwin_acl(text)

    def test_rejects_non_string_acl(self):
        for value in (None, {}, 1):
            with self.subTest(value=value), self.assertRaises(metadata.MetadataError):
                metadata.normalize_darwin_acl(value)

    def test_validates_all_paths_before_writes(self):
        for path in ("../outside", "/outside", "C:/outside", "tree/../other", "tree\\photo å & notes.txt"):
            self.manifest([self.record(), self.record(path)])
            with self.subTest(path=path), self.assertRaises(metadata.MetadataError):
                self.restore()
        self.native.write.assert_not_called()

    def test_duplicate_and_unknown_records_fail(self):
        for rows in ([self.record(), self.record()], [dict(self.record(), command="bad")],
                     [None], [dict(self.record(), kind="directory")], [dict(self.record(), acl=3)],
                     [dict(self.record(), target="unexpected")]):
            self.manifest(rows)
            with self.subTest(rows=rows), self.assertRaises(metadata.MetadataError):
                self.restore()
        self.native.write.assert_not_called()

    def test_parent_symlink_and_mistyped_leaf_rejected(self):
        (self.tree / "alias").symlink_to(self.tree, target_is_directory=True)
        (self.tree / "link").symlink_to(self.file)
        for path in ("tree/alias/" + self.file.name, "tree/link"):
            self.manifest([self.record(path)])
            with self.subTest(path=path), self.assertRaises(metadata.MetadataError):
                self.restore()
        self.native.write.assert_not_called()

    def test_typed_symlink_restored_without_following(self):
        link = self.tree / "link"
        link.symlink_to("../../outside")
        self.manifest([dict(self.record("tree/link"), kind="symlink", target="../../outside")])
        self.assertEqual(self.restore(), 1)
        self.assertEqual(self.native.write.call_args.args[0], link)

    def test_directories_restored_last_and_empty_acls_not_skipped(self):
        self.manifest([dict(self.record("tree"), kind="directory"),
                       dict(self.record(), acl=metadata.DARWIN_ACL_EMPTY)])
        self.assertEqual(self.restore(), 2)
        self.assertEqual(self.native.write.call_args_list[0].args, (self.file, metadata.DARWIN_ACL_EMPTY))
        self.assertEqual(self.native.write.call_args_list[-1].args[0], self.tree)

    def test_native_parser_failure_prevents_all_acl_writes(self):
        self.manifest([self.record(), dict(self.record("tree"), kind="directory")])
        self.native.parse.side_effect = [123, metadata.MetadataError("bad native ACL")]
        with self.assertRaises(metadata.MetadataError):
            self.restore()
        self.native.write.assert_not_called()

    def test_capture_uses_inventory_and_is_atomic_on_error(self):
        metadata.capture_files(self.root, self.meta / "files.tsv",
                               io.BytesIO(os.fsencode("tree\0tree/" + self.file.name + "\0")))
        manifest = self.meta / "acl.txt"
        manifest.write_text("previous manifest")
        self.native.read.side_effect = [ACL, metadata.MetadataError("permission denied")]
        with patch.object(metadata, "DarwinACL", return_value=self.native):
            with self.assertRaises(metadata.MetadataError):
                metadata.capture_darwin_acl(self.root, self.meta)
        self.assertEqual(manifest.read_text(), "previous manifest")
        self.assertEqual(list(self.meta.glob("acl.capture.*")), [])
        self.native.read.side_effect = None
        with patch.object(metadata, "DarwinACL", return_value=self.native):
            self.assertEqual(metadata.capture_darwin_acl(self.root, self.meta), 2)
        self.assertEqual(len(manifest.read_text().splitlines()), 3)

    def test_wrong_platform_and_future_manifest_fail(self):
        self.manifest([self.record()])
        with patch.object(sys, "platform", "linux"), self.assertRaisesRegex(metadata.MetadataError, "native macOS"):
            metadata.restore_acl(self.root, self.meta)

    def test_duplicate_json_field_and_oversized_record_fail(self):
        path = "tree/" + self.file.name
        (self.meta / "acl.txt").write_text(
            metadata.DARWIN_ACL_HEADER + "\n"
            + '{"path":' + json.dumps(path) + ',"path":' + json.dumps(path)
            + ',"kind":"file","target":"","acl":' + json.dumps(ACL) + '}\n'
        )
        with self.assertRaisesRegex(metadata.MetadataError, "duplicate macOS ACL field"):
            self.restore()
        (self.meta / "acl.txt").write_text(metadata.DARWIN_ACL_HEADER + "\n" + "x" * (2 * 1024 * 1024 + 1))
        with self.assertRaisesRegex(metadata.MetadataError, "oversized"):
            self.restore()
        (self.meta / "acl.txt").write_text("# hardcore-archive acl darwin-text-jsonl v2\n")
        with self.assertRaisesRegex(metadata.MetadataError, "format/version"):
            metadata.restore_acl(self.root, self.meta)

    def test_posix_acl_on_mac_fails_without_attempting_setfacl(self):
        (self.meta / "acl.txt").write_text(
            f"# file: tree/{self.file.name}\nuser::rw-\nuser:12345:r--\ngroup::r--\nmask::r--\nother::---\n")
        with patch.object(sys, "platform", "darwin"), patch.object(metadata.subprocess, "run") as run:
            with self.assertRaisesRegex(metadata.MetadataError, "Linux ACL semantics"):
                metadata.restore_acl(self.root, self.meta)
            run.assert_not_called()

    def test_doctor_routes_by_platform_without_brew_acl_advice(self):
        script = r'''
set -Eeuo pipefail
source "$TEST_REPO/lib/hardcore-archive-doctor-base.sh"
source "$TEST_REPO/lib/hardcore-archive-doctor-checks.sh"
source "$TEST_REPO/lib/hardcore-archive-doctor-report.sh"
SCRIPT_DIR="$TEST_REPO"
SOURCE="$TEST_SOURCE"
PLATFORM=Darwin
python3() { [[ $1 == "$SCRIPT_DIR/lib/hardcore-archive-metadata.py" && $2 == --check-acl && $3 == "$SOURCE" ]]; }
check_version_command() { printf 'unexpected getfacl check\n' >&2; return 9; }
check_acl_capability
[[ ${READY_LINES[*]} == *'native macOS'* ]]
python3() { printf 'read denied'; return 1; }
! check_acl_capability
[[ ${FAIL_DETAILS[*]} == *'read denied'* && ${#REPAIR_KEY_SEEN[@]} == 0 ]]
PACKAGE_MANAGER=brew
[[ -z $(packages_for_key acl) ]]
PLATFORM=Linux
check_version_command() { [[ $1 == ACL && $2 == getfacl && $3 == acl && $5 == --version ]]; }
check_acl_capability
[[ ${READY_LINES[*]} == *POSIX* ]]
'''
        result = subprocess.run(["bash", "-c", script], text=True, capture_output=True,
                                env=dict(os.environ, TEST_REPO=str(ROOT), TEST_SOURCE=str(self.tree)))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


@unittest.skipUnless(sys.platform == "darwin", "requires native macOS ACL APIs")
class NativeMacTests(unittest.TestCase):
    def test_real_capture_restore_permissions_inheritance_and_symlinks(self):
        with contextlib.ExitStack() as cleanup:
            temporary = cleanup.enter_context(tempfile.TemporaryDirectory(prefix="hardcore native acl "))
            # ACLs denying deletion are part of the round trip. Remove them
            # before TemporaryDirectory attempts to delete its own fixture.
            cleanup.callback(subprocess.run, ["/bin/chmod", "-RN", temporary],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            tree = source / "tree"
            tree.mkdir()
            # Set inheritance before creating children so inherited ACEs are real.
            subprocess.run(["/bin/chmod", "+a", "everyone allow read,readattr,readsecurity,file_inherit,directory_inherit", str(tree)], check=True)
            file = tree / "photo å & notes.txt"
            file.write_text("payload")
            subprocess.run(["/bin/chmod", "+a#", "0", "everyone deny delete", str(file)], check=True)
            empty = tree / "empty-acl.txt"
            empty.touch()
            subprocess.run(["/bin/chmod", "-N", str(empty)], check=True)
            outside = root / "outside.txt"
            outside.write_text("untouched")
            link = tree / "link"
            link.symlink_to(outside)
            native = metadata.DarwinACL()
            before_outside = native.read(outside)
            meta = source / ".hardcore-archive-metadata"
            meta.mkdir()
            paths = ["tree", "tree/" + file.name, "tree/empty-acl.txt", "tree/link"]
            inventory = b"".join(os.fsencode(p) + b"\0" for p in paths)
            subprocess.run([sys.executable, str(HELPER), "--check-acl", str(tree)], check=True)
            subprocess.run([sys.executable, str(HELPER), "--capture-files", "--root", str(source),
                            "--metadata-dir", str(meta)], input=inventory, check=True)
            subprocess.run([sys.executable, str(HELPER), "--capture-acl", "--root", str(source),
                            "--metadata-dir", str(meta)], check=True)
            expected = {p: native.read(source / p) for p in paths}
            self.assertIn("inherited", expected["tree/" + file.name])
            self.assertIn("deny:delete", expected["tree/" + file.name])
            self.assertEqual(expected["tree/empty-acl.txt"], metadata.DARWIN_ACL_EMPTY)
            restored = root / "restored"
            # An extraction does not copy the source ACLs; create fresh objects.
            (restored / "tree").mkdir(parents=True)
            (restored / "tree" / file.name).write_text("payload")
            (restored / "tree/empty-acl.txt").touch()
            (restored / "tree/link").symlink_to(outside)
            shutil.copytree(meta, restored / meta.name)
            # Restore must clear unwanted inherited/destination entries too.
            subprocess.run(["/bin/chmod", "+a", "everyone allow read", str(restored / "tree/empty-acl.txt")], check=True)
            subprocess.run([sys.executable, str(HELPER), "--root", str(restored),
                            "--metadata-dir", str(restored / meta.name)], check=True)
            self.assertEqual({p: native.read(restored / p) for p in paths}, expected)
            self.assertEqual(native.read(outside), before_outside)
            self.assertEqual(outside.read_text(), "untouched")
            # Reapplying ACLs must be idempotent.
            metadata.restore_acl(restored, restored / meta.name)
            self.assertEqual({p: native.read(restored / p) for p in paths}, expected)


if __name__ == "__main__":
    unittest.main()
