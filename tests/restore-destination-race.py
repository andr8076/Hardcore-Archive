#!/usr/bin/env python3
"""Regression coverage for restore destination commit races and layouts.

The fake archiver creates a competing destination from inside extraction, which
is deterministically after restore_existing_archive's initial destination check
and before its final commit. The production lib/restore.sh module is sourced
unchanged by the harness.
"""
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RESTORE_MODULE = ROOT / "lib/restore.sh"

FAKE_ARCHIVER = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import sys

root = Path(os.environ["TEST_ROOT"])
command = sys.argv[1]
with (root / "calls").open("a") as log:
    log.write(command + "\n")

if command == "t":
    sys.exit(0)
if command == "l":
    for path in sorted((root / "payload").rglob("*")):
        if path.is_dir():
            continue
        rel = path.relative_to(root / "payload")
        print(f"Path = {rel}")
        print(f"Size = {path.stat().st_size}")
        print()
    sys.exit(0)
if command == "x":
    destination = Path(next(arg[2:] for arg in sys.argv[2:] if arg.startswith("-o")))
    shutil.copytree(root / "payload", destination, dirs_exist_ok=True)

    race = os.environ.get("TEST_RACE_DESTINATION")
    if race:
        target = Path(os.environ["TEST_DESTINATION"])
        if race == "directory":
            target.mkdir()
            (target / "sentinel.txt").write_text("independent directory\n")
        elif race == "file":
            target.write_text("independent file\n")
        elif race == "symlink":
            symlink_target = root / "independent-target.txt"
            symlink_target.write_text("independent symlink target\n")
            target.symlink_to(symlink_target)
        elif race == "dangling-symlink":
            target.symlink_to(root / "missing-independent-target")
        else:
            raise RuntimeError(f"unknown race kind: {race}")
    sys.exit(0)
sys.exit(2)
'''

NOOP_METADATA = "#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n"


class RestoreDestinationRaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hardcore restore race ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.payload = self.root / "payload"
        self.payload.mkdir()
        self.archive = self.root / "archive.7z"
        self.archive.touch()
        self.destination = self.root / "restored"
        self.fake = self.root / "fake-7z"
        self.fake.write_text(FAKE_ARCHIVER)
        self.fake.chmod(0o700)
        self.metadata = self.root / "metadata-helper.py"
        self.metadata.write_text(NOOP_METADATA)
        self.metadata.chmod(0o700)

    def calls(self):
        path = self.root / "calls"
        return path.read_text().splitlines() if path.exists() else []

    def run_restore(self, **extra_env):
        script = r'''set -Eeuo pipefail
MIB=1048576
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
human_bytes() { printf '%s bytes' "$1"; }
# Keep this test about restore's production commit path. These wrappers make
# unrelated GNU/BSD command-line differences deterministic in both CI runners.
df() {
    printf 'Filesystem blocks used available capacity mounted\n'
    printf 'device 999999999999 0 999999999999 0%% /\n'
}
date() { printf '2026-09-08T12:00:00+00:00\n'; }
sync() { :; }
flock() { return 0; }
realpath() {
    local mode=${1:-} path
    if [[ $mode == -e || $mode == -m ]]; then
        shift
    else
        mode=-m
    fi
    [[ ${1:-} == -- ]] && shift
    path=$1
    python3 - "$mode" "$path" <<'PYREALPATH'
import os, sys
mode, path = sys.argv[1:3]
resolved = os.path.realpath(path)
if mode == '-e' and not os.path.exists(resolved):
    raise SystemExit(1)
print(resolved)
PYREALPATH
}
rm() {
    local -a args=()
    local arg
    for arg in "$@"; do
        [[ $arg == --one-file-system ]] && continue
        args+=("$arg")
    done
    command rm "${args[@]}"
}
source "$RESTORE_MODULE"
POSITIONAL=("$TEST_ARCHIVE" "$TEST_DESTINATION")
restore_existing_archive
'''
        env = dict(
            os.environ,
            TEST_ROOT=str(self.root),
            TEST_ARCHIVE=str(self.archive),
            TEST_DESTINATION=str(self.destination),
            SEVEN_ZIP=str(self.fake),
            METADATA_HELPER=str(self.metadata),
            RESTORE_MODULE=str(RESTORE_MODULE),
            **extra_env,
        )
        result = subprocess.run(
            ["bash", "-c", script],
            text=True,
            capture_output=True,
            timeout=30,
            env=env,
        )
        self.assertFalse(list(self.root.glob(".*.restore.*")), result.stdout + result.stderr)
        self.assertFalse(Path(str(self.destination) + ".restore.lock").exists(), result.stdout + result.stderr)
        return result

    def make_single_directory(self):
        source = self.payload / "source"
        source.mkdir()
        (source / "inside.txt").write_text("single directory payload\n")

    def make_single_file(self):
        (self.payload / "lonely.txt").write_text("single file payload\n")

    def make_multiple_entries(self):
        (self.payload / "first.txt").write_text("first\n")
        folder = self.payload / "folder"
        folder.mkdir()
        (folder / "second.txt").write_text("second\n")

    def assert_race_refused(self, kind):
        self.make_single_directory()
        result = self.run_restore(TEST_RACE_DESTINATION=kind)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), ["t", "l", "x"])
        self.assertNotIn("Restore completed successfully", result.stdout)
        return result

    def test_late_directory_destination_is_preserved(self):
        self.assert_race_refused("directory")
        self.assertTrue(self.destination.is_dir())
        self.assertEqual((self.destination / "sentinel.txt").read_text(), "independent directory\n")
        self.assertFalse((self.destination / "source").exists())

    def test_late_file_destination_is_preserved(self):
        self.assert_race_refused("file")
        self.assertTrue(self.destination.is_file())
        self.assertEqual(self.destination.read_text(), "independent file\n")

    def test_late_symlink_destination_and_target_are_preserved(self):
        self.assert_race_refused("symlink")
        self.assertTrue(self.destination.is_symlink())
        target = self.root / "independent-target.txt"
        self.assertEqual(os.readlink(self.destination), str(target))
        self.assertEqual(target.read_text(), "independent symlink target\n")

    def test_late_dangling_symlink_destination_is_preserved(self):
        self.assert_race_refused("dangling-symlink")
        self.assertTrue(self.destination.is_symlink())
        self.assertEqual(os.readlink(self.destination), str(self.root / "missing-independent-target"))
        self.assertFalse(self.destination.exists())

    def test_preexisting_dangling_symlink_is_rejected_before_extraction(self):
        target = self.root / "never-created"
        self.destination.symlink_to(target)
        self.make_single_directory()
        result = self.run_restore()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertTrue(self.destination.is_symlink())
        self.assertEqual(os.readlink(self.destination), str(target))

    def test_single_directory_layout_is_preserved(self):
        self.make_single_directory()
        result = self.run_restore()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.destination / "inside.txt").read_text(), "single directory payload\n")
        self.assertFalse((self.destination / "source").exists())

    def test_single_file_layout_is_preserved(self):
        self.make_single_file()
        result = self.run_restore()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.destination.is_dir())
        self.assertEqual((self.destination / "lonely.txt").read_text(), "single file payload\n")

    def test_multiple_entry_layout_is_preserved(self):
        self.make_multiple_entries()
        result = self.run_restore()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.destination / "first.txt").read_text(), "first\n")
        self.assertEqual((self.destination / "folder" / "second.txt").read_text(), "second\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
