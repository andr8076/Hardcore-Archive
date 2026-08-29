# Hardcore Archive

Hardcore Archive creates aggressively compressed, verified `.7z` archives on Linux and macOS.

The public entry point is `hardcore-archive.sh`. The full archive engine lives in `lib/hardcore-archive-core.sh`; the frontend resolves preservation policy, source-specific capabilities, GPU policy, and diagnostics before delegating to the engine.

## Default behavior

A normal run is source-preserving:

- original videos are archived bit-for-bit; video transcoding is off
- original JPEG/PNG files are archived bit-for-bit; image optimization is off
- nested archives are preserved as files; recursive repacking is off
- the source folder is kept
- generated staging/work files are cleaned after success
- archive integrity and completeness are checked

```bash
bash hardcore-archive.sh "/data/My folder"
```

The source is deleted only when `--remove-source` is explicitly supplied. In that mode Hardcore Archive requires strong verification before deletion.

Temporary files are different from source files: generated AV1/HEVC files, optimized images, nested-archive staging, and other working copies are disposable and are cleaned after a successful job unless `--keep-work` is selected. Failed jobs may retain validated resume data.

## Strict source-specific dependency policy

Hardcore Archive does not have optional dependency fallbacks.

Before a create job starts, the frontend first inventories the requested source. It then determines which capabilities can actually be used by that source and the selected options, and checks only those capabilities.

Examples:

- FFmpeg is not required when video transcoding is disabled.
- FFmpeg is also not required when video transcoding is configured on but the selected source contains no videos that can be transformed.
- JPEG tools are required only when JPEG optimization will run.
- A PNG optimizer is required only when PNG optimization will run.
- Nested archives are listed before recursive media requirements are chosen, so a text-only ZIP does not automatically require media libraries.
- `setsid`, batch storage mapping, GPU support, quality filters, and similar capabilities are required only when the workflow will use them.

The strict doctor distinguishes three failure types:

- **MISSING** — a required program/package is not installed.
- **UNSUPPORTED** — the program exists, but lacks the exact capability Hardcore Archive needs, such as a required FFmpeg encoder or filter.
- **BROKEN** — the capability is present or advertised, but a real startup/runtime probe fails.

If any required capability fails, the archive does not start. There is no prompt to continue with reduced functionality and `--yes` does not bypass the doctor.

## Doctor

Run the same source-specific check manually with:

```bash
bash hardcore-archive.sh --doctor "/data/My folder"
```

You can combine `--doctor` with transformation options:

```bash
bash hardcore-archive.sh --doctor --video-transcode --image-optimize "/data/My folder"
```

A normal create job runs this doctor automatically. When everything is ready it prints a short READY message and continues. If anything is wrong, the full doctor report is shown automatically and the job stops.

The report contains only capabilities relevant to that source/workflow and prints repair commands for the detected package manager. Repair commands are **never executed** by Hardcore Archive.

Example failure shape:

```text
MISSING
  PNG optimizer                PNG optimization is enabled for this source...

Repair command (not executed):
  sudo pacman -S --needed oxipng

Result: NOT READY. No dependency fallback will be used.
```

Package-manager guidance is generated for common `pacman`, `apt`, `dnf`, `zypper`, and Homebrew systems.

## Opt-in transformations

All transformation features remain available:

```bash
# Hardware video transcoding (AV1 preferred)
bash hardcore-archive.sh --video-transcode "/data/My folder"

# Lossless JPEG/PNG optimization
bash hardcore-archive.sh --image-optimize "/data/My folder"

# Recursive nested-archive repacking
bash hardcore-archive.sh --nested-repack "/data/My folder"

# Combine them
bash hardcore-archive.sh --video-transcode --image-optimize --nested-repack "/data/My folder"
```

The corresponding negative switches remain available:

```text
--no-video-transcode
--no-image-optimize
--no-nested-repack
```

Transformations can also be enabled in the config file:

```text
VIDEO_TRANSCODE=true
IMAGE_OPTIMIZE=true
NESTED_REPACK=true
```

See `config.example` for common settings.

## Hardware video policy

Video transcoding is hardware-only. CPU encoders such as `libsvtav1` and `libx265` are not accepted as fallbacks.

The doctor checks that:

1. FFmpeg and FFprobe are installed and working.
2. the required hardware encoder is exposed by FFmpeg.
3. required quality validation is present (`libvmaf` when video preflight quality checking is active).
4. a real short hardware encode succeeds.
5. FFprobe confirms that the probe produced the requested codec.

AV1 is preferred. The **only automatic codec fallback** is AV1 → HEVC when the AV1 hardware probe specifically indicates that the GPU itself cannot encode AV1 and a real HEVC hardware encode succeeds.

Missing FFmpeg support, missing drivers, device permissions, broken VA-API/NVENC/QSV/VideoToolbox, or missing quality filters do not trigger codec fallback; they are doctor failures.

Hardware video work is forced into parallel mode so the GPU encoder can operate while CPU-side 7-Zip/image work proceeds.

## No degraded dependency behavior

If a selected capability is required, it must work. Examples:

- missing `oxipng`/`optipng` while PNG optimization is needed → fail
- missing `jpegtran` or `djpeg` while JPEG optimization is needed → fail
- missing ACL support used by archive metadata capture → fail
- missing `setsid` when worker process groups are needed → fail
- missing `libvmaf` when video preflight quality validation is enabled → fail
- hardware encoder advertised but unable to encode → fail

Preserving an original because a **successful transformation** is not smaller or does not satisfy validation remains part of archive-content policy; that is not a missing-dependency fallback.

## Source deletion

```bash
bash hardcore-archive.sh --remove-source "/data/My folder"
```

`--remove-source` is the only normal option that authorizes deletion of user-owned source content. The engine verifies the archive before deleting anything and refuses weak integrity-only verification for this mode.

## Inspect and restore

```bash
bash hardcore-archive.sh --inspect "/archives/Important.7z"
bash hardcore-archive.sh --restore "/archives/Important.7z" "/restore/Important"
```

Restore validates archive paths, extracts into a temporary destination, verifies embedded hashes when available, reapplies supported metadata, and only then commits the restored tree.

## Tests

The frontend/doctor policy can be tested without creating a real archive:

```bash
bash tests/frontend-policy.sh
```

The tests cover preservation defaults, source-specific dependency suppression, hard failures for missing/unsupported/broken capabilities, exact repair-command output, hardware AV1 enforcement, the permitted AV1→HEVC hardware fallback, doctor-only mode, config precedence, and the video resume-cache compatibility value.

## Help

```bash
bash hardcore-archive.sh --help
```

The frontend passes the existing archive, compression, batch, verification, restore, reporting, media-quality, and resource-tuning options through to the engine.
