# Hardcore Archive

Hardcore Archive creates aggressively compressed, verified `.7z` archives on Linux and macOS.

The public entry point is `hardcore-archive.sh`. The launcher resolves layered configuration, the runtime runner applies deterministic fail-closed policy/engine patches, and the source-specific doctor verifies the capabilities actually required before archive work begins. The stable legacy engine remains in `lib/hardcore-archive-core.sh`.

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

Validated transforms are now **on by default**:

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

For each candidate, the helper:

1. validates that the source is a structurally plausible container for its extension;
2. refuses encrypted entries, unsafe paths, duplicate entry names, and known signed containers;
3. streams the original payload into a new container using maximum broadly compatible ZIP Deflate, while storing already-compressed inner media instead of wasting Deflate work;
4. preserves ZIP entry metadata where compatible;
5. preserves special format requirements such as EPUB/ODF `mimetype` being first and uncompressed;
6. verifies the rebuilt archive, format structure, and SHA-256 of every internal payload entry;
7. accepts the candidate only when it is smaller than the original.

Signed OOXML/ODF/JAR/WAR containers are preserved unchanged because repacking could invalidate their signatures. APK is deliberately **not** in this lane because modern APK signatures can be invalidated by changing ZIP layout even when every payload byte is unchanged. Unsupported package/container formats continue through the safe Copy lane.

Every decision is reported in `.hardcore-archive-container-manifest.txt` and the normal success report:

```text
action    original path    archived path    original bytes    candidate bytes    archived bytes    reason
repacked  report.docx      report.docx      18432000          16724011           16724011          candidate-smaller
original  signed.docx      signed.docx      9211000           0                  9211000           signed-container-preserved
original  book.epub        book.epub        8421991           8510042            8421991           candidate-not-smaller
```

## Nested archives

`NESTED_REPACK` still has a separate purpose and remains enabled by default.

It handles **true archives** such as ZIP/RAR/7z/TAR-compressed files. These may be unpacked recursively, have their contents processed by Hardcore Archive, and be replaced by a validated smaller `.7z` archive.

That is different from application-container repack:

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

Video transcoding is hardware-only. CPU encoders are not accepted as dependency fallbacks.

AV1 is preferred. The only automatic codec fallback is AV1 → HEVC when a real hardware probe proves that the GPU itself cannot encode AV1 and a real HEVC hardware encode succeeds.

On FFmpeg 9 VA-API, Hardcore Archive explicitly uses CQP/global-quality rate control and treats warnings that the requested encoder option was ignored as a broken configuration. VMAF extraction reads `pooled_metrics.vmaf.mean` specifically, avoiding the old 0..1 feature-metric/0..100 VMAF mix-up.

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

The suite covers source-specific doctor/frontend behavior, configuration layering, LZMA/Copy routing, FFmpeg capability detection, FFmpeg 9/VMAF regressions, format-preserving container repack, nested-decision reporting, and poweroff-on-success behavior. Runtime patch tests apply the deterministic patches to the real legacy core and syntax-check the generated engine.

## Help

```bash
bash hardcore-archive.sh --help
```
