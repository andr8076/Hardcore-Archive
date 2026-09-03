#!/usr/bin/env python3
"""Check batched manifest inputs against the engine's completeness contract."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = (ROOT / "lib/hardcore-archive-core.sh").read_text()
FUNCTIONS = "build_expected_paths_and_hashes() {" + CORE.split(
    "build_expected_paths_and_hashes() {", 1
)[1].split("\nverify_archive_hashes_single_pass() {", 1)[0]
for name, following in [("add_image_results_to_archive", "classify_video_stage_results"),
                        ("add_video_results_to_archive", "choose_nested_work_root")]:
    FUNCTIONS += "\n" + name + "() {" + CORE.split(name + "() {", 1)[1].split(
        "\n" + following + "() {", 1)[0]
METADATA = ["files.tsv", "acl.txt", "xattrs.txt", "RESTORE-NOTES.txt",
            "sparse.tsv", "archive-info.txt"]
LANES = ["video", "image", "container", "nested"]

# Capture exactly the paths/content sent to the archiver; emulate its listing
# for the production completeness checker. Real compression is not required to
# verify the number of updates or that no manifest/payload has been omitted.
BACKEND = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['TEST_ROOT'])
archive = root / 'archive.json'
items = json.loads(archive.read_text())
if sys.argv[1] == 'l':
    print('----------')
    for name in sorted(items):
        print('Path = ' + name)
    sys.exit(0)
assert sys.argv[1] == 'a'
inputs = [s for s in sys.argv[3:] if not s.startswith('-')]
with (root / 'calls').open('a') as f:
    f.write(json.dumps(inputs) + '\n')
for name in inputs:
    p = Path(name)
    if not p.exists():
        sys.exit(2)
    paths = [p, *p.rglob('*')] if p.is_dir() else [p]
    for path in paths:
        if str(path) != os.environ.get('OMIT', ''):
            items[str(path)] = None if path.is_dir() else path.read_bytes().hex()
archive.write_text(json.dumps(items))
'''

FIXTURE = r'''
SOURCE_PARENT=$TEST_ROOT
SOURCE_NAME=source
ARCHIVE_MANIFEST_STAGE="$TEST_ROOT/manifests"
EXPECTED_PATHS="$TEST_ROOT/expected"
ARCHIVE_PATHS="$TEST_ROOT/actual"
HASH_MANIFEST="$TEST_ROOT/hashes"
INVENTORY_RAW="$TEST_ROOT/inventory"
TEMP_ARCHIVE="$TEST_ROOT/archive.json"
SEVEN_ZIP="$TEST_ROOT/archiver"
SEVEN_ZIP_LOG="$TEST_ROOT/7zip.log"
VIDEO_RESULT_MANIFEST="$TEST_ROOT/video.rows"
IMAGE_RESULT_MANIFEST="$TEST_ROOT/image.rows"
CONTAINER_RESULT_MANIFEST="$TEST_ROOT/container.rows"
NESTED_RESULT_MANIFEST="$TEST_ROOT/nested.rows"
NESTED_REPACK=true
CONTAINER_REPACK=true
is_video_path() { return 1; }
is_image_path() { return 1; }
is_nested_archive_path() { return 1; }
is_format_preserving_container_path() { return 1; }
source_find() { find "$@"; }
# Metadata capture has its own round-trip tests. Here use a fixed complete
# bundle to exercise the unmodified expected-path and archive-update functions.
build_metadata_bundle() { test -d "$ARCHIVE_MANIFEST_STAGE/.hardcore-archive-metadata"; }
run_logged_stage() { shift 2; "$@"; }
# The fixture has already written each manifest. Exercise the real lane
# finalizers too, so an accidental early archive update is counted.
write_video_manifest() { :; }
write_image_manifest() { :; }
human_bytes() { printf '%s' "$1"; }
VIDEO_COMPRESSED_COUNT=0
VIDEO_COMPRESSED_BYTES=0
VIDEO_FALLBACK_COUNT=0
VIDEO_FALLBACK_BYTES=0
IMAGE_OPTIMIZED_COUNT=0
IMAGE_OPTIMIZED_BYTES=0
IMAGE_FALLBACK_COUNT=0
IMAGE_FALLBACK_BYTES=0
VIDEO_COMPRESSED_LIST="$TEST_ROOT/empty"
VIDEO_FALLBACK_LIST="$TEST_ROOT/empty"
IMAGE_OPTIMIZED_LIST="$TEST_ROOT/empty"
IMAGE_FALLBACK_LIST="$TEST_ROOT/empty"
ARCHIVE_MANIFEST_FILE="$ARCHIVE_MANIFEST_STAGE/.hardcore-archive-video-manifest.txt"
IMAGE_MANIFEST_FILE="$ARCHIVE_MANIFEST_STAGE/.hardcore-archive-image-manifest.txt"
: > "$TEST_ROOT/empty"
if (( VIDEO_COUNT > 0 )); then add_video_results_to_archive; fi
if (( IMAGE_COUNT > 0 )); then add_image_results_to_archive; fi
add_safety_manifests_to_archive
verify_archive_completeness
'''


class ManifestBatchTests(unittest.TestCase):
    def run_case(self, lanes=(), mode="integrity", video_manifest=True,
                 missing=None, omit="", expected_rc=0):
        with tempfile.TemporaryDirectory(prefix="manifest batch ") as temp:
            root = Path(temp)
            source = root / "source"
            source.mkdir()
            (source / "ordinary.txt").write_bytes(b"unchanged payload")
            (root / "inventory").write_bytes(b"17\0source/ordinary.txt\0")
            stage = root / "manifests"
            meta = stage / ".hardcore-archive-metadata"
            meta.mkdir(parents=True)
            for name in METADATA:
                (meta / name).write_text("fixture " + name)
            env = dict(os.environ, TEST_ROOT=temp, VERIFY_MODE_EFFECTIVE=mode,
                       VIDEO_WRITE_MANIFEST=str(video_manifest).lower(), OMIT=omit)
            for lane in LANES:
                env[lane.upper() + "_COUNT"] = str(int(lane in lanes))
                rows = ""
                if lane in lanes:
                    relative = "source/" + lane + " payload"
                    (root / relative).write_text("original " + lane)
                    rows = f"original\t{relative}\t{relative}\t10\t10"
                    rows += "\t10\tfallback\n" if lane in ("nested", "container") else "\n"
                    name = ".hardcore-archive-" + lane + "-manifest.txt"
                    if lane != missing:
                        # Deliberately leave a video file present even when
                        # disabled; selection must follow the user's setting.
                        (stage / name).write_text(rows)
                (root / (lane + ".rows")).write_text(rows)
            initial = {"source": None}
            initial.update({str(p.relative_to(root)): p.read_bytes().hex()
                            for p in source.iterdir()})
            (root / "archive.json").write_text(json.dumps(initial))
            backend = root / "archiver"
            backend.write_text(BACKEND)
            backend.chmod(0o700)
            result = subprocess.run(["bash", "-c", "set -Eeuo pipefail\n" + FUNCTIONS + FIXTURE],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, expected_rc, result.stdout + result.stderr)
            calls = [json.loads(line) for line in (root / "calls").read_text().splitlines()]
            self.assertEqual(len(calls), 1)
            if expected_rc:
                return result
            archived = json.loads((root / "archive.json").read_text())
            for name, content in initial.items():
                self.assertEqual(archived[name], content)
            for lane in LANES:
                name = ".hardcore-archive-" + lane + "-manifest.txt"
                included = lane in lanes and (lane != "video" or video_manifest)
                self.assertEqual(name in archived, included)
                if included:
                    self.assertEqual(bytes.fromhex(archived[name]), (stage / name).read_bytes())
            hashes = root / "hashes"
            if mode == "integrity":
                self.assertEqual(hashes.read_bytes(), b"")
                self.assertNotIn(".hardcore-archive-sha256.txt", archived)
            else:
                self.assertEqual(bytes.fromhex(archived[".hardcore-archive-sha256.txt"]), hashes.read_bytes())
                for line in hashes.read_text().splitlines():
                    digest, name = line.split("  ", 1)
                    self.assertEqual(digest, hashlib.sha256((root / name).read_bytes()).hexdigest())
            self.assertIn("Archive completeness check passed", result.stdout)
            return result

    def test_integrity_with_no_media(self):
        self.run_case()

    def test_each_manifest_and_all_manifests(self):
        for lanes in [[lane] for lane in LANES] + [LANES]:
            with self.subTest(lanes=lanes):
                self.run_case(lanes)

    def test_strong_modes_keep_payload_hashes(self):
        for mode in ("hashes", "extract"):
            with self.subTest(mode=mode):
                self.run_case(LANES, mode=mode)

    def test_video_manifest_can_still_be_disabled(self):
        self.run_case(LANES, video_manifest=False)

    def test_missing_required_manifest_fails_update(self):
        self.run_case(LANES, missing="nested", expected_rc=2)

    def test_silently_omitted_manifest_fails_completeness(self):
        result = self.run_case(LANES, omit=".hardcore-archive-image-manifest.txt", expected_rc=1)
        self.assertIn("Expected archive paths are missing", result.stderr)


if __name__ == "__main__":
    unittest.main()
