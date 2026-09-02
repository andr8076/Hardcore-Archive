# Hardcore Archive

Hardcore Archive creates aggressively compressed, verified `.7z` archives on Linux and macOS.

The public entry point is `hardcore-archive`. The historical `hardcore-archive.sh` name remains as a tiny compatibility shim, so existing commands continue to work. Runtime orchestration is split across focused `lib/*.sh` modules, and the complete executable policy and archive engine are checked-in static sources. Startup does not generate or source-patch Python or shell code.

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
    archive.sh                static archive-engine boundary
    video.sh                  hardware-only video policy
    images.sh                 image-policy boundary
    containers.sh             format-preserving application containers
    nested.sh                 recursive nested-archive policy
    verify.sh                 inspect/verification command boundary
    restore.sh                restore command boundary
    reporting.sh              persistent run logs and diagnostics
    hardcore-archive-core.sh  checked-in archive engine
    hardcore-archive-metadata.py trusted metadata restore helper
```

The old transformation scripts are retained only as development/migration history. No production path invokes them. Changes to the engine are reviewed, syntax-checked, and tested as normal static source changes.

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

- video candidates must pass hardware/decode checks, the configured VMAF floor, and the configured minimum size saving;
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

`VIDEO_CODEC=auto` is the default. When both working AV1 and HEVC hardware encoders are available, Hardcore Archive checks them against the same VMAF floor and minimum-savings target for each video, then uses the candidate predicted to be smaller. `--video-codec av1` and `--video-codec hevc` remain explicit overrides.

Hardware calibration (VAAPI, NVENC and QSV) now reuses successful settings for similar videos:

- **First file in a group:** search the encoder's quality range using three 3-second segments (one for clips shorter than 9 seconds).
- **Cache hit:** encode and measure one 3-second center segment from the current video at the cached setting. Both your configured `QUALITY_CHECK` VMAF target and predicted minimum savings must pass. A failed check, unavailable measurement, or insufficient saving triggers full calibration.
- **Early stopping:** if three failed trials span at least four quality steps, vary by no more than 0.25 VMAF, and remain at least 5 points below your target, stop that codec's search. Another available codec can still qualify; otherwise the original is preserved. This is a conservative rejection heuristic, not proof that higher quality could never pass.

The cache groups sources by codec/profile, resolution, pixel format/bit depth, frame rate, interlacing, aspect ratio and color metadata. Keys also include the output codec, hardware encoder, selected VAAPI device, FFmpeg build, actual scaling/denoising filters and VMAF target. Only a successful full calibration writes a quality setting; failures are never cached. Every cache hit measures the new file, and its savings estimate includes that file's audio. The selected candidate reuses those measurements instead of repeating the separate three-segment preflight. Final codec, duration, stream-count, full-decode and actual-size checks remain in place.

For cache grouping only, average and declared frame rates each use the nearest whole-number rate when within 1% of it. For example, 59.9386 and 60.0053 fps share the 60 fps group; 30, 50 and 60 fps remain separate. Rates outside that tolerance retain their exact rational value, and invalid rates disable cache reuse. This avoids a fresh calibration for every camera clip whose measured average frame rate differs slightly. Video timestamps, encoding and VMAF sampling are unchanged; the cached setting still has to pass a fresh quality and savings check on the current file.

These are **sampled quality checks**: one center segment can miss difficult scenes elsewhere, and a cached setting may compress less than a fresh search. Use `VIDEO_CALIBRATION_CACHE=false` for a full search on every file, or `VIDEO_CALIBRATION_EARLY_ABORT=false` to disable plateau stopping. Unsupported encoder families retain their existing preflight behavior; `QUALITY_CHECK=off` bypasses calibration as before.

VMAF scoring runs on the **CPU**, separately from hardware encoding. `VIDEO_QUALITY_THREADS=auto` explicitly enables up to 8 VMAF workers, bounded by the logical CPUs available to the process. Set it to `1`–`64` to override that cap; the available-CPU limit still applies. FFmpeg's [libvmaf default does not create worker threads](https://ffmpeg.org/ffmpeg-filters.html#libvmaf), so leaving this unset in the FFmpeg command can make scoring slow while total CPU and GPU utilization look low. This setting changes execution parallelism, not your VMAF target, scoring resolution, or sampled frames. The log now identifies sample encoding versus VMAF scoring and reports their elapsed times. Batch CPU budgeting includes these workers.

VMAF compares frames using a common time base and nearest-timestamp matching. Matroska sample timestamps are rounded to milliseconds; FFmpeg's default matching can otherwise pair a sample frame with the preceding reference frame and report falsely low quality even for a lossless sample. This keeps the original frame cadence and quality target. Calibration keys include this matching policy, so older cached settings are not reused after the correction. The real-FFmpeg regression uses SSIM's shared frame-matching machinery to check lossless and deliberately shifted samples even where libvmaf is unavailable.

Settings persist across runs and are shared with batch/nested children. They expire after 30 days and are separated by quality target and processing settings. The default directory is `~/.cache/hardcore-archive/video-calibration-v1` on Linux or `~/Library/Caches/hardcore-archive/video-calibration-v1` on macOS (`XDG_CACHE_HOME` is respected). Override it with `VIDEO_CALIBRATION_CACHE_DIR`; deleting its contents forces fresh calibration. Cache writes are atomic, and unavailable or malformed cache entries simply fall back to full calibration.

Before an interactive create run starts, Hardcore Archive prints the available AV1/HEVC FFmpeg encoders in two groups:

```text
GPU / hardware encoders (selectable)
CPU / software encoders (informational only; GPU encoding is mandatory)
```

Working hardware entries are real encode probes, not just names returned by `ffmpeg -encoders`. On Linux/VAAPI, entries are expanded per `/dev/dri/renderD*` device and include the GPU/device label when available. Choosing a VAAPI entry exports that exact render node through calibration, preflight, nested child work, and the final FFmpeg command, so selecting a GPU does not merely select the generic `av1_vaapi`/`hevc_vaapi` backend.

`[0] AUTO` keeps automatic AV1/HEVC competition. Selecting a numbered GPU entry locks that exact encoder (and, for VAAPI, render node). An explicit `--video-encoder NAME` also bypasses the prompt. `--yes`, non-interactive runs, and nested child runs do not block waiting for input.

On FFmpeg 9 VA-API, Hardcore Archive explicitly uses CQP/global-quality rate control and treats warnings that the requested encoder option was ignored as a broken configuration. VMAF extraction reads `pooled_metrics.vmaf.mean` specifically.

Video encoder selection belongs exclusively to the video/doctor policy modules and the checked-in engine. CPU fallback is forbidden at the engine level.

Video transcoding is intentionally perceptually lossy, not bit-exact. The loss budget is now one direct quality-check value rather than a separate hardcoded VMAF constant:

```text
QUALITY_CHECK=92
```

Set it to any value from 0 through 100. A higher value preserves more visual fidelity but usually reduces the compression opportunity. Override it per run with `--quality-check V`, or use `QUALITY_CHECK=off` / `--quality-check off` to disable sample quality checks. Batch and nested jobs inherit the same value. The launcher translates this user-facing setting into the engine's internal VMAF threshold, so the acceptance score is no longer fixed in normal configuration.

## Persistent diagnostics

Every create run starts a persistent transcript before dependency checks. On Linux it is stored under:

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

## Verification

`VERIFY_MODE=integrity` is the shipped default. It runs the 7-Zip stream/CRC integrity test and checks that the archive contains exactly the expected paths. It does **not** extract every payload again and does **not** compare payload SHA-256 hashes, so normal archive creation avoids the expensive content-hash verification pass.

The modes are:

- `integrity` — default; 7-Zip stream/CRC integrity plus exact path-completeness checking, without payload hash comparison;
- `hashes` — one extraction pass plus SHA-256 comparison of every archived regular file;
- `extract` — the same strong extraction-and-hash path, retained as an explicit name;
- `auto` — legacy strong-verification alias that currently resolves to `hashes` when explicitly selected.

Strong verification needs temporary space roughly equal to the extracted archive. Because the default is now integrity-only, `--remove-source` requires an explicit `--verify hashes` or `--verify extract`; the program refuses to delete a source after integrity-only verification.

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

Restore validates archive paths, extracts into a temporary destination, verifies embedded hashes when available, reconstructs sparse allocation, and reapplies modes, times, ownership where privileged, extended attributes, flags, and ACLs before committing the restored tree. ACL manifests are treated strictly as data: absolute/traversing paths, symlink leaves, malformed blocks, and unsupported entries are rejected before `setfacl` is invoked. If an archive contains extended ACLs and `setfacl` is unavailable, restore fails safely instead of silently dropping them.

## Benchmarks

### Resource-use audit

High overall CPU usage is not guaranteed, and is not a reliable throughput measure by itself. Current stage policies are:

| Stage | Current execution policy | Limit or tradeoff |
| --- | --- | --- |
| LZMA2 compression | Two threads by default; explicit `THREADS` / `--threads` override | More threads can split independent blocks, increase RAM use and change compression ratio. |
| Match-cycle tuning | Four bounded trials, sequential, two threads each | Startup work; small inputs skip it. |
| Video encoding | Hardware encoder; sequential files; can overlap LZMA2/images | A busy video engine may not show as GPU 3D utilization. Decode/filter work remains on the CPU. |
| VMAF scoring | Up to eight CPU workers by default | Configurable with `VIDEO_QUALITY_THREADS`; keeps the same samples and scoring resolution. |
| Images | Up to four file workers in auto mode; two Oxipng threads each | Bounded by CPU/file count and the parallel-memory plan; `IMAGE_JOBS` overrides file workers. |
| Container and nested-archive repacking | Sequential files | Still a utilization limit; independent-file concurrency needs a memory/storage budget. |
| Metadata capture | One Python process, one `lstat` per inventory entry | Replaces five external `stat` processes per entry; still subject to filesystem latency. |
| Strong checksum comparison | Up to four GNU workers on detected SSD/NVMe; one on rotational/unknown storage | Worker groups are balanced by payload bytes. A single large file still occupies one worker. |
| Strong source-hash creation | Sequential payloads | Remains a potential bottleneck when strong verification is explicitly enabled. |
| Copy storage, integrity checks, extraction | Delegated to 7-Zip | Throughput depends on storage and the archive's independent compression blocks. |

The metadata manifest format and GNU checksum checks are unchanged. Byte balancing preserves each checksum line verbatim; unsupported manifest formats fall back to the previous splitting behavior. Archive writes remain serialized. Default integrity verification still avoids payload SHA-256 comparisons. The benchmark suite below is needed to measure end-to-end throughput on the actual source, disk and GPU; these policies alone do not prove maximum hardware utilization.

### Running benchmarks

The deterministic mixed corpus covers repeated text, structured data, incompressible and patterned binary data, many small files, duplicates, sparse files, pre-compressed data, a nested ZIP, and a repackable DOCX. Optional generated media can be included for machine-specific video tests.

```bash
python3 benchmarks/generate-corpus.py benchmarks/corpus --size-mib 64
bash benchmarks/run.sh benchmarks/corpus
```

The harness compares Hardcore Archive with maximum-compression 7-Zip and records archive size/ratio, create time, strong verify time, extraction time, and peak resident memory in `results.tsv`. The verify phase includes both extraction and SHA-256 manifest checking. See `benchmarks/README.md` for details.

## Tests

Run:

```bash
bash tests/frontend-policy.sh
```

The suite includes default integrity/no-content-hash policy checks, explicit single-pass hash verification checks, metadata round trips and hostile ACL paths, deterministic corpus generation, static-module wiring, and the existing compression/video/container policies.
