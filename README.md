# Hardcore Archive

Hardcore Archive creates aggressively compressed, verified `.7z` archives on Linux and macOS.

The public entry point is now `hardcore-archive`. The historical `hardcore-archive.sh` name remains as a tiny compatibility shim, so existing commands continue to work. Runtime orchestration is split across focused `lib/*.sh` modules. The stable legacy compression engine remains temporarily in `lib/hardcore-archive-core.sh` and is being migrated section-by-section without changing archive behavior.

## Architecture

The shell application is now organized by responsibility:

```text
hardcore-archive              thin public entrypoint
hardcore-archive.sh           compatibility shim
hardcore-archive-runner.sh    thin runtime shim

lib/
    common.sh                 shared shell helpers
    platform.sh               Linux/macOS paths and platform actions
    config.sh                 config layering and launcher policy
    doctor.sh                 strict doctor wiring
    inventory.sh              inventory/command-routing boundary
    planner.sh                runtime component planning
    scheduler.sh              top-level runtime orchestration
    archive.sh                archive engine assembly / Copy-LZMA boundary
    video.sh                  hardware-only video policy
    images.sh                 image-policy boundary
    containers.sh             format-preserving application containers
    nested.sh                 recursive nested-archive policy
    verify.sh                 inspect/verification command boundary
    restore.sh                restore command boundary
    reporting.sh              persistent run logs and diagnostics
```

This is an incremental migration. New policy should go into the matching module rather than into the giant legacy core or the thin runner. The legacy core is deliberately left behaviorally unchanged while functions are moved out mechanically and covered by tests. The transitional Python engine patchers still exist for the sections not yet migrated; they can be retired as those sections move into native modules.

## Configuration

The repository ships a real `config` file. **That file is the installation's actual base configuration.**

```text
1. ./config                                  shipped installation defaults
2. ~/.config/hardcore-archive/config         personal overrides
   macOS: ~/Library/Application Support/hardcore-archive/config
3. --config FILE                             explicit per-run overrides
4. command-line options                      highest priority
```

`--no-config` ignores personal and explicit config layers, but it does not ignore `./config`. Hardcore Archive never edits config files automatically.

## Default behavior

Validated transforms are **on by default**:

```text
VIDEO_TRANSCODE=true
IMAGE_OPTIMIZE=true
NESTED_REPACK=true
CONTAINER_REPACK=true
```

This does **not** mean “replace everything regardless of result.” Each lane retains its own safety gate:

- video candidates must pass hardware/quality/decode checks and the configured minimum size saving;
- JPEG/PNG replacements are lossless, validated, and must be smaller;
- nested archive replacements must validate and beat the original archive;
- application-container replacements preserve their original file type and internal payload, validate successfully, and must be smaller;
- source deletion remains off unless `--remove-source` is explicitly supplied.

Any transform can be disabled for one run:

```text
--no-video-transcode
--no-image-optimize
--no-nested-repack
--no-container-repack
```

## Compression lanes

Hardcore Archive produces **one final `.7z`** while routing files according to what can actually improve them:

```text
ordinary compressible files ──> solid LZMA2 lane
true nested archives         ──> recursive nested-repack lane
application ZIP containers   ──> format-preserving repack lane
videos                       ──> hardware video transform/preserve lane
JPEG/PNG                     ──> lossless image transform/preserve lane
other compressed files       ──> 7-Zip Copy lane
                                      │
                                      └── same final .7z
```

The Copy lane avoids wasting LZMA2 on entropy-compressed data such as compressed audio, WebP/AVIF/HEIC, package files that are unsafe to rewrite, and compressed streams. Plain TAR and PDF are deliberately not assumed to be incompressible and remain eligible for LZMA2.

Transform lanes have priority over the generic Copy lane.

## Format-preserving application-container repack

`CONTAINER_REPACK=true` is enabled by default.

Supported safe ZIP-based application containers currently include:

```text
.docx  .xlsx  .pptx
.odt   .ods   .odp
.epub  .npz   .whl
.jar   .war
```

The important invariant is that the restored file stays the same kind of file:

```text
report.docx
    ↓ temporary inspection/repack
report.docx
```

Extracting the final Hardcore Archive does **not** turn a DOCX into a `word/`, `_rels/`, and `docProps/` directory tree.

For each candidate, the helper validates the source container, refuses unsafe/encrypted/signed layouts, rebuilds it with compatible ZIP compression, preserves format requirements such as EPUB/ODF `mimetype`, verifies SHA-256 of every internal payload entry, and accepts the candidate only when it is smaller.

Signed OOXML/ODF/JAR/WAR containers are preserved unchanged because repacking could invalidate their signatures. APK is deliberately **not** in this lane because modern APK signatures can be invalidated by changing ZIP layout even when every payload byte is unchanged. Unsupported package/container formats continue through the safe Copy lane.

Every decision is recorded in the container manifest and normal report.

## Nested archives

`NESTED_REPACK` remains enabled by default and has a separate purpose from application-container repacking.

It handles **true archives** such as ZIP/RAR/7z/TAR-compressed files. These may be unpacked recursively, have their contents processed by Hardcore Archive, and be replaced by a validated smaller `.7z` archive.

```text
photos.zip   → may become photos.7z
report.docx  → always remains report.docx
```

If nested repacking cannot beat the original archive, the original is preserved. The report records original size, candidate size, archived size, and the exact rejection/acceptance reason for every nested archive.

## Strict source-specific dependency policy

Hardcore Archive does not silently degrade because a required capability is missing.

Before a create job starts, the frontend inventories the requested source, determines which enabled transforms are actually relevant, and checks only the capabilities those files require. The doctor distinguishes:

- **MISSING** — executable/package absent;
- **UNSUPPORTED** — tool exists but lacks the exact required capability;
- **BROKEN** — capability is advertised but a real runtime probe fails.

Run it manually with:

```bash
bash hardcore-archive.sh --doctor "/data/My folder"
```

Normal create jobs perform the same check automatically. Repair commands are printed, never executed automatically.

## Hardware video policy

Video transcoding is hardware-only. CPU encoders are never accepted as dependency fallbacks.

`VIDEO_CODEC=auto` is the default. When both working AV1 and HEVC hardware encoders are available, Hardcore Archive calibrates them against the same VMAF floor and minimum-savings target for each video, then uses the smaller quality-valid candidate. `--video-codec av1` and `--video-codec hevc` remain explicit overrides.

Before an interactive create run starts, Hardcore Archive prints the available AV1/HEVC FFmpeg encoders in two groups:

```text
GPU / hardware encoders (selectable)
CPU / software encoders (informational only; GPU encoding is mandatory)
```

Working hardware entries are real encode probes, not just names returned by `ffmpeg -encoders`. On Linux/VAAPI, entries are expanded per `/dev/dri/renderD*` device and include the GPU/device label when available. Choosing a VAAPI entry exports that exact render node through calibration, preflight, nested child work, and the final FFmpeg command, so selecting a GPU does not merely select the generic `av1_vaapi`/`hevc_vaapi` backend.

`[0] AUTO` keeps automatic AV1/HEVC competition. Selecting a numbered GPU entry locks that exact encoder (and, for VAAPI, render node). An explicit `--video-encoder NAME` also bypasses the prompt. `--yes`, non-interactive runs, and nested child runs do not block waiting for input.

On FFmpeg 9 VA-API, Hardcore Archive explicitly uses CQP/global-quality rate control and treats warnings that the requested encoder option was ignored as a broken configuration. VMAF extraction reads `pooled_metrics.vmaf.mean` specifically.

Video encoder selection belongs exclusively to the video/doctor policy modules and the transitional hardware-video engine patches. CPU fallback is forbidden at the engine level.

## Persistent diagnostics

Every create run starts a persistent transcript before runtime patching or dependency checks. On Linux it is stored under:

```text
~/.local/state/hardcore-archive/runs/<timestamp>-<pid>/run.log
```

On interruption or failure, component logs and state are preserved beside it when available (`video.log`, `image.log`, `7zip.log`, `match-cycle.log`, `state.txt`). The video log records the exact FFmpeg command used for full transcodes, including the selected VAAPI render node when one is locked.

## Image optimization

JPEG/PNG optimization is enabled by default. Originals remain untouched on disk; only validated smaller lossless candidates are written into the final archive. If no safe size win exists, the original image is stored.

## Source deletion

Source deletion remains explicit:

```bash
bash hardcore-archive.sh --remove-source "/data/My folder"
```

Deletion is authorized only after the strong verification path completes successfully.

## Power off after completion

For unattended runs:

```bash
bash hardcore-archive.sh --poweroff "/data/My folder" "/archives/My folder.7z"
```

or set:

```text
POWER_OFF_ON_SUCCESS=true
```

`--no-poweroff` overrides it for one run. Poweroff is never attempted after failure or for help/doctor/inspect/restore/version/analyze-only modes.

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
