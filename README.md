# Hardcore Archive

Hardcore Archive creates aggressively compressed, verified `.7z` archives on Linux and macOS.

The public entry point is `hardcore-archive.sh`. A small launcher resolves the configuration layers and delegates to the tested archive frontend in `hardcore-archive-runner.sh`; the full engine remains in `lib/hardcore-archive-core.sh`.

## Configuration

The repository now ships a real `config` file. **That file is the installation's actual default configuration.** If you edit it, you change the defaults used by `hardcore-archive.sh`.

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

## Nested archives

With `NESTED_REPACK=false`, ZIP/RAR/7z/tar-family files are preserved as original nested files inside the final archive.

With `NESTED_REPACK=true`, supported nested archives are inspected and may be recursively repacked. A generated replacement is used only when it passes the engine's validation and content-selection rules; the user-owned source archive is not modified in place.

## Source deletion

```bash
bash hardcore-archive.sh --remove-source "/data/My folder"
```

`--remove-source` is the only normal option that authorizes deletion of user-owned source content. Strong archive verification is required before deletion.

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

This runs both the archive/doctor policy suite and the config-layer suite. The config tests verify shipped defaults, personal overrides, explicit `--config` overrides, CLI precedence, `--no-config`, and missing-config handling.

## Help

```bash
bash hardcore-archive.sh --help
```
