# Hardcore Archive

Hardcore Archive creates aggressively compressed, verified `.7z` archives on Linux and macOS.

The public entry point is `hardcore-archive.sh`. A small launcher resolves the configuration layers, the runtime runner prepares the archive engine, and the strict policy/doctor frontend validates the selected workflow before archive work begins. The large legacy engine remains in `lib/hardcore-archive-core.sh` and receives deterministic runtime engine patches rather than being duplicated.

## Configuration

The repository ships a real `config` file. **That file is the installation's actual default configuration.** If you edit it, you change the defaults used by `hardcore-archive.sh`.

Configuration precedence is deliberately simple:

```text
1. ./config                                  shipped installation defaults
2. ~/.config/hardcore-archive/config         personal overrides
   macOS: ~/Library/Application Support/hardcore-archive/config
3. --config FILE                             explicit per-run overrides
4. command-line options                      highest priority
```

The files are layered rather than replacing one another. A personal config therefore only needs to contain settings you want to override.

For example, changing the repository `config` to:

```text
VIDEO_TRANSCODE=true
IMAGE_OPTIMIZE=true
```

makes those the defaults for that installation. A personal config can then contain only:

```text
VIDEO_MODE=maximum
```

and a command such as:

```bash
bash hardcore-archive.sh --no-video-transcode "/data/My folder"
```

still wins over every config file.

`--no-config` ignores the personal and explicit `--config` layers. It does **not** ignore `./config`, because `./config` is the program's shipped base configuration rather than an optional user override.

Hardcore Archive never modifies any config file automatically.

## Default behavior

The shipped `config` is preservation-first:

- video transcoding is off
- JPEG/PNG optimization is off
- nested archive repacking is off
- source deletion is off unless `--remove-source` is supplied
- generated staging/work files are cleaned after success
- archive integrity and completeness are checked

```bash
bash hardcore-archive.sh "/data/My folder"
```

Temporary generated files are different from source data: AV1/HEVC outputs, optimized images, nested-archive staging, and other working copies are disposable and are cleaned after a successful job unless `--keep-work` is selected. Failed jobs may retain validated resume data.

## Compression lanes

Hardcore Archive still creates **one final `.7z` archive**, but it no longer wastes solid-LZMA2 work on file formats that are already entropy-compressed.

The source inventory is divided by compression strategy:

```text
ordinary compressible files ──> one solid LZMA2 lane
already-compressed files     ──> one 7-Zip Copy lane
videos                       ──> video transform/preserve lane
JPEG/PNG                     ──> image transform/preserve lane
nested archives              ──> nested-repack lane when enabled
                                      │
                                      └── all added to the same final .7z
```

The LZMA2 lane keeps ordinary data together so cross-file similarity can benefit from one solid dictionary instead of compressing extensions independently.

The Copy lane is used for preserved formats where another LZMA2 pass is normally wasted work, including compressed archives, compressed package/document containers, compressed audio, and additional compressed image formats. Examples include ZIP/7z/RAR, gzip/xz/zstd, DOCX/XLSX/PPTX, EPUB/JAR/APK, DEB/RPM, MP3/FLAC/Opus, WebP/AVIF/HEIC, and similar formats.

Transform lanes always take precedence. For example:

- an MP4 selected for video transcoding goes through the video lane, not the generic Copy lane
- JPEG/PNG goes through the image lane even when optimization is disabled; preserved originals are then stored with Copy
- a ZIP goes through nested repacking when `NESTED_REPACK=true`; with repacking disabled, the original ZIP goes directly to the Copy lane

Plain TAR and PDF are deliberately **not** assumed to be incompressible and remain eligible for the solid LZMA2 lane.

The match-cycle tuning sample is also built only from LZMA2-lane files, so already-compressed content no longer distorts the LZMA tuning decision.

The archive plan and success report show both lane counts and byte totals.

## Strict source-specific dependency policy

Hardcore Archive does not have degraded dependency fallbacks.

Before a create job starts, the frontend inventories the requested source. It then determines which capabilities can actually be used by that source and the selected configuration, and checks only those capabilities.

Examples:

- FFmpeg is not required when video transcoding is disabled.
- FFmpeg is not required when transcoding is enabled but the selected source has no relevant videos.
- JPEG/PNG tools are required only for image types that will actually be optimized.
- Nested archives are inspected before recursive media requirements are chosen, so a text-only ZIP does not automatically require media libraries.
- GPU support, quality filters, worker process groups, batch storage mapping, and similar capabilities are required only when the workflow uses them.

The doctor distinguishes:

- **MISSING** — a required program/package is not installed.
- **UNSUPPORTED** — the tool exists but lacks the exact encoder/filter/API required.
- **BROKEN** — the capability is advertised but a real runtime probe fails.

If any required capability fails, the archive does not start. `--yes` does not bypass the doctor.

## Doctor

Run the source-specific check manually with:

```bash
bash hardcore-archive.sh --doctor "/data/My folder"
```

or include transformations:

```bash
bash hardcore-archive.sh --doctor --video-transcode --image-optimize "/data/My folder"
```

Normal create jobs run the same check automatically. On failure the full doctor report is printed automatically together with an exact repair command for common `pacman`, `apt`, `dnf`, `zypper`, or Homebrew systems.

Repair commands are **printed only**. Hardcore Archive never installs software.

## Transformations

Transformations can be enabled in `config`, in a user/custom config, or on the command line:

```bash
bash hardcore-archive.sh --video-transcode "/data/My folder"
bash hardcore-archive.sh --image-optimize "/data/My folder"
bash hardcore-archive.sh --nested-repack "/data/My folder"
bash hardcore-archive.sh --video-transcode --image-optimize --nested-repack "/data/My folder"
```

Negative CLI switches remain available and override config:

```text
--no-video-transcode
--no-image-optimize
--no-nested-repack
```

## Hardware video policy

Video transcoding is hardware-only. CPU encoders such as `libsvtav1` and `libx265` are not accepted as dependency fallbacks.

The doctor verifies FFmpeg/FFprobe, the requested hardware encoder, required quality filters, a real short hardware encode, and the codec of the produced probe.

AV1 is preferred. The **only automatic codec fallback** is AV1 → HEVC when the AV1 hardware probe specifically proves that the GPU itself cannot encode AV1 and a real HEVC hardware encode succeeds.

Missing FFmpeg support, drivers, permissions, broken VA-API/NVENC/QSV/VideoToolbox, or missing required quality filters are hard failures rather than fallback triggers.

Hardware video work runs in parallel with CPU-side archive/image work when applicable.

FFmpeg filter and encoder discovery consumes the complete `ffmpeg -filters` / `ffmpeg -encoders` tables before deciding whether a capability exists. This avoids `pipefail`/SIGPIPE false negatives from early-exiting `grep -q` pipelines on large/newer FFmpeg builds.

## Nested archives

With `NESTED_REPACK=false`, supported compressed nested archives are preserved bit-for-bit and stored through the Copy lane inside the final archive.

With `NESTED_REPACK=true`, supported nested archives are inspected and may be recursively repacked. A generated replacement is used only when it passes the engine's validation and content-selection rules; the user-owned source archive is not modified in place.

## Source deletion

```bash
bash hardcore-archive.sh --remove-source "/data/My folder"
```

`--remove-source` is the only normal option that authorizes deletion of user-owned source content. Strong archive verification is required before deletion.

## Power off after completion

Use `--poweroff` when a long unattended archive job should shut the computer down after it finishes successfully:

```bash
bash hardcore-archive.sh --poweroff "/data/My folder" "/archives/My folder.7z"
```

The same behavior can be made the installation default in `config`:

```text
POWER_OFF_ON_SUCCESS=true
```

`--no-poweroff` overrides that config setting for one run. Poweroff is armed only for real create/batch jobs. It is never attempted after an archive failure, `--doctor`, `--inspect`, `--restore`, `--version`, `--help`, or `--analyze-only`.

On Linux the feature deliberately requires `systemctl poweroff`; Hardcore Archive does not silently substitute a different shutdown mechanism. On macOS it uses the system `osascript` shutdown request. The archive is already fully completed and validated before the shutdown request is issued. If shutdown itself fails, the archive remains successful but the launcher exits with a distinct post-run error.

## Inspect and restore

```bash
bash hardcore-archive.sh --inspect "/archives/Important.7z"
bash hardcore-archive.sh --restore "/archives/Important.7z" "/restore/Important"
```

Restore validates archive paths, extracts into a temporary destination, verifies embedded hashes when available, reapplies supported metadata, and only then commits the restored tree.

## Tests

Run:

```bash
bash tests/frontend-policy.sh
```

This runs the archive/doctor policy suite, config-layer suite, Copy/LZMA lane suite, FFmpeg capability-detection regression suite, and poweroff-on-success policy suite. The lane test applies the deterministic engine patch to the real legacy core, syntax-checks the resulting runtime engine, verifies patch idempotence, verifies transform precedence, and checks that Copy entries still target the same final archive. The FFmpeg test uses very large fake filter/encoder tables to catch `pipefail`/SIGPIPE false negatives, while the poweroff test verifies success-only shutdown, config/CLI precedence, diagnostic-mode safety, and shutdown-failure reporting.

## Help

```bash
bash hardcore-archive.sh --help
```
