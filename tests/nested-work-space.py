#!/usr/bin/env python3
"""Exercise nested staging selection and the real recursive failure path."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = (ROOT / "lib/hardcore-archive-core.sh").read_text()
FUNCTIONS = "choose_nested_work_root() {" + CORE.split(
    "choose_nested_work_root() {", 1
)[1].split("\nbuild_sparse_manifest() {", 1)[0]

FIXTURE = r'''
MIB=1048576
SOURCE="$TEST_ROOT/source"
SOURCE_PARENT="$TEST_ROOT"
WORK_ROOT="$TEST_ROOT/cache"
WORK_DIR_OVERRIDE=${OVERRIDE:-}
ARCHIVE_PARENT="$TEST_ROOT/destination"
mkdir -p "$SOURCE" "$WORK_ROOT" "$ARCHIVE_PARENT"
filesystem_type() {
    if [[ $1 == "$ARCHIVE_PARENT/"* ]]; then
        printf '%s\n' "${DEST_FS:-ext4}"
    else
        printf 'ext4\n'
    fi
}
df() {
    local free=${CACHE_FREE:-20000000000}
    [[ ${!#} == "$ARCHIVE_PARENT/"* ]] && free=${DEST_FREE:-200000000000}
    printf 'Filesystem blocks used available capacity mounted\n'
    printf 'device 999999999999 0 %s 0%% /\n' "$free"
}
human_bytes() { printf '%s bytes' "$1"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
warn() { printf '%s\n' "$*" >&2; }
'''

PIPELINE = r'''
NESTED_COUNT=1
NESTED_MAX_DEPTH=2
NESTED_REPACKED_COUNT=0
NESTED_FALLBACK_COUNT=0
NESTED_SAVED_BYTES=0
VIDEO_TRANSCODE=true
VIDEO_CODEC=auto
VIDEO_MODE=balanced
QUALITY_CHECK=required
VIDEO_MIN_VMAF=92
VIDEO_ENCODER=hevc_vaapi
IMAGE_OPTIMIZE=true
IMAGE_MODE=maximum
VERIFY_MODE_EFFECTIVE=integrity
EFFORT=extreme
MC_AUTO=false
HARDCORE_ARCHIVE_DIAGNOSTIC_DIR="$TEST_ROOT/diagnostics"
mkdir -p "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR"
printf 'parent calibration\n' > "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/video.log"
ARCHIVE_MANIFEST_STAGE="$TEST_ROOT/manifests"
mkdir -p "$ARCHIVE_MANIFEST_STAGE"
NESTED_MANIFEST_FILE="$ARCHIVE_MANIFEST_STAGE/.hardcore-archive-nested-manifest.txt"
NESTED_RESULT_MANIFEST="$TEST_ROOT/result"
NESTED_REPACKED_LIST="$TEST_ROOT/repacked"
NESTED_FALLBACK_LIST="$TEST_ROOT/fallback"
NESTED_LIST="$TEST_ROOT/list"
SEVEN_ZIP_LOG="$TEST_ROOT/7zip.log"
SEVEN_ZIP=fake_7z
TEMP_ARCHIVE="$TEST_ROOT/final.7z"
printf 'source/photos.zip\n' > "$NESTED_LIST"
printf 'original payload' > "$SOURCE/photos.zip"
archive_replacement_path() { printf '%s.7z' "${1%.zip}"; }
hardcore_visual_open_log() { :; }
resolve_current_script() { printf '%s/child.sh' "$TEST_ROOT"; }
run_logged_stage() { :; }
fake_7z() {
    case $1 in
        l) printf 'Path = photos.zip\nPath = photo.jpg\nSize = 16\nEncrypted = -\n' ;;
        x) return 0 ;;
        a) printf 'smaller' > "$2" ;;
        t) return 0 ;;
        *) return 1 ;;
    esac
}
prepare_and_add_nested_archives
printf 'RESULT_ROOT=%s\n' "$NESTED_STAGE_PARENT"
cat "$NESTED_RESULT_MANIFEST"
'''


class NestedWorkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nested space ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def run_shell(self, script, **env):
        result = subprocess.run(
            ["bash", "-c", "set -Eeuo pipefail\n" + FUNCTIONS + FIXTURE + script],
            env=dict(os.environ, TEST_ROOT=str(self.root), **env),
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def select(self, setup="", **env):
        output = self.run_shell(setup + '\nchoose_nested_work_root\nprintf "SELECTED=%s\\n" "$NESTED_WORK_ROOT"', **env)
        return output.split("SELECTED=", 1)[1].strip()

    def test_roomier_destination_is_selected(self):
        self.assertEqual(self.select(), str(self.root / "destination/.hardcore-archive-work"))

    def test_roomier_cache_and_equal_space_keep_existing_root(self):
        for free in ("10000000000", "20000000000"):
            with self.subTest(free=free):
                self.assertEqual(self.select(DEST_FREE=free), str(self.root / "cache"))

    def test_explicit_work_directory_is_respected(self):
        self.assertEqual(self.select(OVERRIDE="configured"), str(self.root / "cache"))

    def test_unsupported_or_unknown_destination_is_not_selected(self):
        for env in ({"DEST_FS": "vfat"}, {"DEST_FREE": "unknown"}):
            with self.subTest(env=env):
                self.assertEqual(self.select(**env), str(self.root / "cache"))

    def test_source_overlap_including_symlink_is_rejected(self):
        dest_work = self.root / "destination/.hardcore-archive-work"
        for target in ('"$SOURCE"', '"$SOURCE/subdir"'):
            with self.subTest(target=target):
                self.assertEqual(self.select('mkdir -p "$SOURCE/subdir"\nln -s ' + target +
                                            ' "$ARCHIVE_PARENT/.hardcore-archive-work"'),
                                 str(self.root / "cache"))
                dest_work.unlink()

    def test_unwritable_candidate_falls_back(self):
        # A file blocking mkdir is deterministic even when tests run as root.
        self.assertEqual(self.select('touch "$ARCHIVE_PARENT/.hardcore-archive-work"'),
                         str(self.root / "cache"))

    def pipeline(self, error, rc):
        child = self.root / "child.sh"
        child.write_text('''#!/usr/bin/env bash
set -eu
printf '%s\\n' "$@" > "$TEST_ROOT/child-args"
[[ $HARDCORE_ARCHIVE_LIVE_LOG == "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/run.log" ]]
printf 'child calibration\\n' > "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/video.log"
printf '%s\\n' "$CHILD_ERROR"
exit "$CHILD_RC"
''')
        output = self.run_shell(PIPELINE, CHILD_ERROR=error, CHILD_RC=str(rc))
        args = (self.root / "child-args").read_text().splitlines()
        work = Path(args[args.index("--work-dir") + 1])
        self.assertEqual(work.parent.parent, self.root / "destination/.hardcore-archive-work")
        self.assertEqual(work.name, "child-work")
        self.assertEqual(args[args.index("--verify") + 1], "integrity")
        self.assertEqual((self.root / "source/photos.zip").read_text(), "original payload")
        diagnostic = self.root / "diagnostics"
        child_diagnostic = diagnostic / "nested/depth-1/source/photos.zip"
        self.assertEqual((diagnostic / "video.log").read_text(), "parent calibration\n")
        self.assertEqual((child_diagnostic / "video.log").read_text(), "child calibration\n")
        self.assertIn(f"Exit status: {rc}\n", (child_diagnostic / "run.log").read_text())
        return output

    def test_space_failure_is_reported_and_original_preserved(self):
        output = self.pipeline("Error: The shared output/work filesystem needs approximately 23GiB free in the conservative worst case.", 1)
        self.assertIn("insufficient-child-work-space", output)
        self.assertIn("original\tsource/photos.zip", output)
        self.assertEqual((self.root / "fallback").read_text(), "source/photos.zip\n")

    def test_other_errors_are_not_mislabeled_as_space_failures(self):
        output = self.pipeline("Error: An encoder failed.", 1)
        self.assertIn("recursive-archive-failed-rc-1", output)
        self.assertNotIn("insufficient-child-work-space", output)

    def test_smaller_successful_candidate_is_still_accepted(self):
        output = self.pipeline("Completed successfully.", 0)
        self.assertIn("candidate-smaller", output)
        self.assertEqual((self.root / "repacked").read_text(), "source/photos.7z\n")
        self.assertEqual((self.root / "fallback").read_text(), "")


if __name__ == "__main__":
    unittest.main()
