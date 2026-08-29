# Hardcore Archive

Hardcore Archive creates aggressively compressed, verified `.7z` archives on Linux and macOS.

The public entry point is `hardcore-archive.sh`. The full archive engine lives in `lib/hardcore-archive-core.sh`; the frontend exists so archive policy stays simple and safe without removing any of the advanced engine features.

## Default behavior

A normal run is source-preserving:

- original videos are archived bit-for-bit; video transcoding is off
- original JPEG/PNG files are archived bit-for-bit; image optimization is off
- nested archives are preserved as files; recursive repacking is off
- the source folder is kept
- generated staging/work files are cleaned after success
- archive integrity and completeness are still checked

```bash
bash hardcore-archive.sh "/data/My folder"
```

The source is deleted only when `--remove-source` is explicitly supplied. In that mode Hardcore Archive automatically requires strong hash or extraction verification before deletion.

Temporary files are different from source files: when an AV1/HEVC transcode, optimized image, or repacked nested archive is created for inclusion, that generated working copy is disposable and is cleaned after the job. `--keep-work` is the explicit opt-in for retaining working data. Failed jobs may keep validated resume data so the work can be resumed.

## Opt-in transformations

All previous transformation features remain available:

```bash
# Video transcoding (AV1 by default)
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

Transformations can also be opted into in the config file:

```text
VIDEO_TRANSCODE=true
IMAGE_OPTIMIZE=true
NESTED_REPACK=true
```

See `config.example` for common settings.

## Source deletion

```bash
bash hardcore-archive.sh --remove-source "/data/My folder"
```

`--remove-source` is the only normal option that authorizes deletion of user-owned source content. The engine verifies the archive before deleting anything and refuses integrity-only verification for this mode.

If video transcoding is also enabled, the archive can contain the validated transcoded video instead of the original bitstream. The source is still removed only because `--remove-source` was explicitly requested.

## Inspect and restore

```bash
bash hardcore-archive.sh --inspect "/archives/Important.7z"
bash hardcore-archive.sh --restore "/archives/Important.7z" "/restore/Important"
```

Restore validates archive paths, extracts into a temporary destination, verifies embedded hashes when available, reapplies supported metadata, and only then commits the restored tree.

## Requirements

Hardcore Archive requires Bash 4.2 or newer and a GNU-compatible command set. The script performs its own dependency preflight and prints installation guidance when required tools are missing.

For the full macOS feature set, the core currently expects Homebrew packages along these lines:

```bash
brew install bash coreutils findutils util-linux sevenzip ffmpeg python jpeg-turbo oxipng acl
```

Optional media tools are only needed when their corresponding transformation feature is enabled.

## Tests

The frontend policy can be checked without running a real archive job:

```bash
bash tests/frontend-policy.sh
```

This verifies that transformations are off by default, config opt-ins work, explicit CLI opt-ins override config, negative switches win when specified last, and the video resume-cache compatibility value follows `--video-copy-audio`.

## Help

```bash
bash hardcore-archive.sh --help
```

The frontend passes the existing archive, compression, batch, verification, restore, reporting, media-quality, and resource-tuning options through to the engine.
