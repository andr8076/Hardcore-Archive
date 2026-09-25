# Hardcore Archive

Hardcore Archive turns a folder into one verified `.7z` archive.

It is **content-aware**: videos, images, nested archives, documents, and ordinary files use different safe paths.

## The 30-second version

- Want a strong general-purpose archive? Use normal mode.
- Want exact bytes back? Disable transforms and use strong hash verification.
- Want to inspect or restore an archive? Use the read-only commands.
- Never delete the source until a restore or strong hash check has passed.

Hardcore Archive is not magic compression. It coordinates 7-Zip, FFmpeg, image tools, and metadata manifests.

## Fastest safe start

```bash
# Check the source and required tools
./hardcore-archive --doctor "/data/My folder"

# Create an archive
./hardcore-archive "/data/My folder" "/archives/my-folder.7z"

# Inspect it
./hardcore-archive --inspect "/archives/my-folder.7z"

# Restore it somewhere new
./hardcore-archive --restore "/archives/my-folder.7z" "/restore/my-folder"
```

Use a destination that does not already exist. Restore is the easiest confidence check.
## Before the first run

### Portable release

Portable releases include the application runtime and command-line tools.

```bash
./hardcore-archive --doctor "/data/My folder"
```

You still need the operating system GPU driver and permissions for hardware video encoding.

### Source checkout

Install dependencies with a plan shown before anything changes:

```bash
./install-dependencies.sh --dry-run
./install-dependencies.sh
```

The installer detects common Linux package managers and macOS Homebrew. It asks before installing. The doctor can offer an exact missing-capability plan.

- **Missing** means a required tool is not installed.
- **Unsupported** means the tool exists but lacks a required feature.
- **Broken** means a real capability probe failed.

Only Missing items go to the installer. Broken and Unsupported items stay diagnostics.
## What normal mode does

Normal mode creates one final `.7z` and chooses a lane per file:

```text
ordinary files       -> solid LZMA2
already-compressed   -> 7-Zip Copy lane
videos               -> validated video candidate or original
JPEG/PNG             -> lossless optimizer or original
nested archives      -> smaller validated nested replacement or original
DOCX/XLSX/etc.       -> same file type, repacked only when smaller
metadata             -> manifests stored inside the archive
```

A candidate is kept only when its safety checks pass. If it is unsafe, invalid, or not smaller where a size win is required, the original is preserved.

Safe transformations are enabled by default:

```text
VIDEO_TRANSCODE=true
IMAGE_OPTIMIZE=true
NESTED_REPACK=true
CONTAINER_REPACK=true
```

Turn off a lane for one run when you want conservative behavior:

```bash
./hardcore-archive --no-video-transcode --no-image-optimize \
  --no-nested-repack --no-container-repack \
  "/data/My folder" "/archives/my-folder.7z"
```
## Exact bytes versus smaller media

These are different goals:

- **Exact restore:** every file payload has the same SHA-256 after restore.
- **Declared transform:** a file is intentionally changed, such as a validated video transcode or nested repack.

Normal mode may report `TRANSFORMED`. That is not a failure; the report lists the intentional changes.

For an exact-byte archive, disable all transforms:

```bash
./hardcore-archive \
  --no-video-transcode \
  --no-image-optimize \
  --no-nested-repack \
  --no-container-repack \
  --verify hashes \
  "/data/My folder" "/archives/exact.7z"
```

`--verify hashes` extracts and compares payload SHA-256 values. `--verify integrity` is faster: it checks 7-Zip streams and archive-path completeness, but does not hash every restored payload.

Source deletion is always opt-in:

```bash
./hardcore-archive --verify hashes --remove-source \
  "/data/My folder" "/archives/my-folder.7z"
```

If strong verification fails, the source is not deleted.
## Inspect, restore, and logs

```bash
./hardcore-archive --inspect "/archives/my-folder.7z"
./hardcore-archive --restore "/archives/my-folder.7z" "/restore/my-folder"
```

Restore is fail-closed. It rejects unsafe archive paths, checks completeness, verifies embedded hashes when available, and rebuilds metadata such as:

- file modes and timestamps;
- symlinks and hard links;
- sparse files;
- Linux extended attributes and ACLs when supported;
- macOS ACLs on macOS.

Restore does not modify the archive or the original source.

Every run creates a visible log folder beside the destination, normally named `hardcore-archive-logs/<archive>-<timestamp>-<id>/`.

Useful files include:

```text
run.log              complete transcript
report.txt           success or failure summary
timings.tsv          measured phase timings
7zip.log             latest archive stage
video.log            video decisions and commands
state.txt            resumable run state
```
## Configuration

Defaults come from the repository `config` file.

Override them, in order:

```text
repository config
-> ~/.config/hardcore-archive/config
-> --config FILE
-> command-line options
```

Common settings:

```text
EFFORT=extreme
QUALITY_CHECK=92
VIDEO_CODEC=auto
VIDEO_SPECIAL_POLICY=ask
IMAGE_MODE=maximum
NESTED_MAX_DEPTH=3
RESUME=true
POWER_OFF_ON_SUCCESS=false
```

The program never edits your config automatically. Use `./hardcore-archive --help` for the complete option list.

## Batch mode

Archive each direct child folder:

```bash
./hardcore-archive --batch "/data/projects" "/archives/projects"
```

Batch and nested jobs inherit the parent policy. Use `--no-resume` when you deliberately want to rebuild completed work.
## Benchmarking

Generate a deterministic corpus:

```bash
python3 benchmarks/generate-corpus.py benchmarks/corpus --size-mib 64
bash benchmarks/run.sh benchmarks/corpus
```

Compare an existing folder with other compressors:

```bash
python3 benchmarks/compression-judge.py "/data/Work Tools" \
  --hardcore "$PWD" \
  --output-dir "/data/judge-results"
```

Check a long-running judge:

```bash
python3 benchmarks/check-compression-judge.py "/data/judge-results"
```

The judge records size, ratio, compression time, restore time, exact round-trip status, transformations, and errors. See [`benchmarks/README.md`](benchmarks/README.md) for the full benchmark guide.

Do not compare transformed Hardcore output with an exact 7-Zip result as if they were the same promise.
## Development map

The shell entrypoint is intentionally thin. Modules own separate boundaries:

```text
cli / launcher
  -> inventory -> planner -> scheduler -> executor
  -> transforms: video, image, nested, containers
  -> archive backend -> verification -> restore
  -> manifests, metadata, reporting
```

Project priorities:

1. correctness before compression ratio;
2. safe fallback to the original file;
3. parallel work only where it improves wall time;
4. explicit manifests for every transformation;
5. focused tests before long corpus runs.

Important tests:

```bash
bash tests/frontend-policy.sh
bash tests/metadata-roundtrip.sh
bash tests/nested-output-paths.sh
python3 tests/restore-roundtrip.py
```

For video behavior, read [`docs/video-quality-validation.md`](docs/video-quality-validation.md).

## If something goes wrong

1. Keep the source folder.
2. Keep the run log and failure report.
3. Run `--inspect` on the archive.
4. Restore into a new empty destination.
5. Run `--doctor` and read the first reported capability problem.
6. Do not delete diagnostics until the problem is understood.

The detailed historical README is preserved at [`docs/README-reference.md`](docs/README-reference.md).
