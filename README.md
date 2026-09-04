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

Video, image, container, and nested transformation manifests are added together with the safety metadata in one final archive update. This avoids repeatedly copying the existing archive just to add small manifest files. Integrity and completeness verification run after that update.

Nested staging automatically compares the normal working directory with a working directory beside the output archive and uses the suitable location with more free space. An explicit `--work-dir` keeps nested work in that location. Child media staging uses the same selected filesystem. Expansion limits and child capacity checks still apply; a child rejected by a space check is reported as `insufficient-child-work-space`, with details in its child log.

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

Automatic discovery uses real encode probes, not GPU-model rules or FFmpeg's encoder list alone. If AV1 is exposed by FFmpeg but fails on the installed hardware while HEVC works, only HEVC participates; the reverse also works. Excluded candidates and probe errors remain visible in diagnostics. No usable hardware candidate, missing VMAF, or a failed explicitly requested encoder still stops preflight rather than silently bypassing the quality or hardware-encoding requirements.

### GPU decoding and filtering

`VIDEO_ACCELERATION=auto` enables preprocessing acceleration alongside the existing hardware encoder:

| Encoder backend | Preferred preprocessing | Compatible fallback |
| --- | --- | --- |
| AMD/Linux VAAPI | VAAPI decoding and `scale_vaapi` high-quality scaling/format conversion | VAAPI decoding with CPU filters, then CPU decoding and filters |
| NVIDIA NVENC | CUDA decoding and `scale_cuda` Lanczos scaling/format conversion | CUDA decoding with CPU filters, then CPU decoding and filters |
| Other hardware backends / unsupported source pixel formats | Existing CPU decoding and filtering | Existing hardware encoding policy |

The accelerated paths support probed 8-bit and 10-bit 4:2:0 source formats. Actual calibration encodes exercise the decoder, filters and encoder together; merely having a filter or encoder listed by FFmpeg does not count as a successful probe. Missing GPU filters select CPU filtering directly. Denoising retains the existing CPU `hqdn3d` filter, using hardware decoding where possible. With quality checks disabled, GPU scaling is not selected because there is no quality comparison available.

**Compression takes priority over GPU utilization.** When resizing with GPU filters, the program also searches the quality-valid boundary using CPU Lanczos. Software-filter candidates compare hardware decoding against software decoding, rather than always paying for a GPU-to-CPU-to-GPU transfer. All paths use the same unmodified software VMAF reference and audio/savings policy. The candidate with the lowest accepted three-segment video bitrate wins. Only when those bitrate estimates are equal does a bounded speed probe break the tie: one identical center segment, at most 12 seconds of video per finalist, encoded with each candidate's validated settings. The probe times encoding without repeating VMAF; it never makes an unvalidated candidate eligible. A faster but larger candidate cannot win. AV1 and HEVC then compete as before. A direct GPU path without resizing or denoising retains the existing fast path. These sampled comparisons do not guarantee the smallest possible file or fastest full encode.

**Remember the preprocessing decision, not just the quality setting.** A separate per-video/per-codec selection record routes repeat runs straight to the winning path. Its existing boundary record must still pass one fresh quality/size check; the selection record alone cannot authorize transcoding. A codec rejected at the highest-quality endpoint on every available path is remembered too: a repeat run rechecks the CPU path's known failing scene once. Recovery, failed measurement, missing quality records, or changed source/profile/build/device/filter/audio/savings policy reopens comparison. Probe errors are not cached as rejection evidence. Selection records expire after 30 days without sliding their expiration on reuse, so alternatives are periodically reconsidered. CPU preprocessing forced by a full-encode failure cannot reload an accelerated winner.

On a first comparison, a confirmed endpoint failure on one path seeds a single endpoint test on the next path before another binary search. A passing endpoint continues into the normal boundary search; an unmeasurable endpoint is not treated as a quality rejection. Existing per-path calibration records remain usable, so upgrading does not discard the measurements from a previous GPU test. A first comparison still does more work than a repeat run, especially when another path needs calibration.

Sample encoding/probe failures, failed quality checks, and insufficient savings retry progressively more conservative preprocessing, ending with the existing CPU path. If an accelerated full encode or its decode audit fails, its partial output is removed and that encoder is recalibrated with CPU preprocessing before retrying. Full encoding is capped at three attempts per video across AUTO's two encoders. Hardware video encoding remains mandatory throughout; failure of the encoder itself never starts a software encoder.

VMAF scoring and the final full decode audit remain on the CPU. The audit treats decoder errors as fatal (`-xerror`). Stream-count, codec, duration, final size and archive verification checks remain in place. Acceleration does not change the VMAF target, sampling timestamps or audio/subtitle/attachment/chapter mappings.

Configuration (also inherited by batch/nested jobs):

```ini
VIDEO_ACCELERATION=auto
VIDEO_GPU_FILTERS=auto
VIDEO_CUDA_DEVICE=0
```

Use `VIDEO_GPU_FILTERS=off` to retain CPU filters while comparing hardware and software decoding. Use `VIDEO_ACCELERATION=cpu` to restore CPU decoding and filtering while retaining the hardware encoder. `VIDEO_CUDA_DEVICE` selects the NVIDIA GPU index for capability probes, sample/full encoding and CUDA decoding; VAAPI uses the existing selected render device. No additional GPU filtering package is required for the CPU fallback paths.

The video log prints the selected preprocessing path, decision reuse, path comparisons, speed probes, fallbacks and complete full-encode commands. Selection and speed-probe work is included in calibration timings. Calibration keys include the actual decode/filter path and CUDA device. Completed-output resume keys include the preprocessing/selection policy; toggling it cannot silently reuse an output from the previous policy. Records predating preprocessing-aware quality keys are ignored, but the GPU update's per-path measurements are retained. Real speed and size gains depend on the source, FFmpeg build and driver and should be checked with the small video corpus before a full archive run. Disable `VIDEO_CALIBRATION_CACHE` to ignore both quality and selection records.

### Calibration reuse

Hardware calibration (VAAPI, NVENC and QSV) prioritizes compression at your configured `QUALITY_CHECK` target. A cached setting is a search hint until a compression boundary has been found for that exact video:

- **First file in a group:** binary-search the encoder's quality range using three 3-second segments (one for clips shorter than 9 seconds), seeking the highest compression setting that passes every tested segment.
- **Similar unfamiliar video or old cache entry:** test the hint on all three segments. If it passes, check the next compression step and search upward when that also passes; if it fails, search toward higher quality. A conservative group setting cannot simply become the final setting for an easier video. The search is bounded by the encoder's finite quality range; it does not sweep every setting.
- **Previously optimized, unchanged video:** reuse its own boundary after one fresh check at its previously worst sample position. Both the fresh sample's size estimate and the stored three-segment estimate must meet minimum savings with the current audio policy. Codec competition uses the three-segment estimate, so the choice does not change merely because a repeat run sampled a harder scene.
- **Plateau detection:** three failed trials spanning at least four quality steps, varying by no more than 0.25 VMAF and remaining at least 5 points below target trigger a check at the encoder's highest-quality endpoint, at the failing sample position. If that check passes, continue searching; a plateau alone no longer rejects the codec.
- **Confirmed codec rejection:** only a measured failure at the highest-quality endpoint is remembered, for that exact video and codec. A repeat run rechecks the same failing position at that setting once. If it still fails, skip the repeated search; if it recovers or measurement fails, search afresh. Another codec can still qualify. Probe/encoder errors are never stored as quality rejections, and a rejection is never shared with other videos.

The cache groups sources by codec/profile, resolution, pixel format/bit depth, frame rate, interlacing, aspect ratio and color metadata. Keys also include the output codec, hardware encoder, selected device, preprocessing path, FFmpeg build, actual scaling/denoising filters and VMAF target. Successful boundary searches update the group hint and per-video record; successful repeat validation refreshes only that video's record. The selected candidate reuses those measurements instead of repeating the separate three-segment preflight. Final codec, duration, stream-count, full-decode and actual-size checks remain in place.

Per-video identity uses the original resolved path, device/inode, size, and nanosecond modification/change times, plus the exact source profile and encoding policy. Staging symlinks resolve to that original. Nested videos use the containing archive's identity plus their relative path, size and stored modification time, so fresh extraction directories do not defeat reuse. This is a fast metadata identity for hints, not a content-hash guarantee; fresh quality/size validation is still required. Changed source metadata or encoding policy invalidates the per-video entry. Within the same preprocessing policy, legacy per-video records remain search hints and must undergo a boundary search before one-shot reuse. Previous reports are not imported.

For cache grouping only, average and declared frame rates each use the nearest whole-number rate when within 1% of it. For example, 59.9386 and 60.0053 fps share the 60 fps group; 30, 50 and 60 fps remain separate. Rates outside that tolerance retain their exact rational value, and invalid rates disable cache reuse. Video timestamps, encoding and VMAF sampling are unchanged.

These are **sampled quality checks**, not a whole-video quality guarantee or an exhaustive search for the smallest possible output. Boundary search assumes the encoder's usual quality-versus-compression ordering; VMAF and file size can have local irregularities. Use `VIDEO_CALIBRATION_CACHE=false` for a fresh search on every file, or `VIDEO_CALIBRATION_EARLY_ABORT=false` to disable plateau-triggered endpoint checks. Confirmed per-video endpoint rejections still get one fresh check when caching is enabled. Unsupported encoder families retain their existing preflight behavior; `QUALITY_CHECK=off` bypasses calibration as before.

VMAF scoring runs on the **CPU**, separately from hardware encoding. `VIDEO_QUALITY_THREADS=auto` explicitly enables up to 8 VMAF workers, bounded by the logical CPUs available to the process. Set it to `1`–`64` to override that cap; the available-CPU limit still applies. FFmpeg's [libvmaf default does not create worker threads](https://ffmpeg.org/ffmpeg-filters.html#libvmaf), so leaving this unset in the FFmpeg command can make scoring slow while total CPU and GPU utilization look low. This setting changes execution parallelism, not your VMAF target, scoring resolution, or sampled frames. The log now identifies sample encoding versus VMAF scoring and reports their elapsed times. Batch CPU budgeting includes these workers.

VMAF compares frames using a common time base and nearest-timestamp matching. Matroska sample timestamps are rounded to milliseconds; FFmpeg's default matching can otherwise pair a sample frame with the preceding reference frame and report falsely low quality even for a lossless sample. This keeps the original frame cadence and quality target. Calibration keys include this matching policy, so older cached settings are not reused after the correction. The real-FFmpeg regression uses SSIM's shared frame-matching machinery to check lossless and deliberately shifted samples even where libvmaf is unavailable.

Settings persist across runs and are shared with batch/nested children. Entries expire after 30 days; successful per-video validation refreshes that video's entry. The default directory is `~/.cache/hardcore-archive/video-calibration-v1` on Linux or `~/Library/Caches/hardcore-archive/video-calibration-v1` on macOS (`XDG_CACHE_HOME` is respected). Override it with `VIDEO_CALIBRATION_CACHE_DIR`; deleting its contents forces fresh calibration. Cache writes are atomic. Missing or malformed per-video entries fall back to a search seeded by the shared group; without a usable group entry, full calibration runs. `--no-resume` disables reuse of completed video outputs but keeps calibration hints enabled.

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

Every create run puts its logs in a visible `hardcore-archive-logs` folder in the destination directory. For example, creating `/mnt/SSD/test-compress.7z` creates:

```text
/mnt/SSD/hardcore-archive-logs/test-compress.7z-<timestamp>-<unique-id>/
    run.log
    report.txt
    video.log
    image.log
    7zip.log
    match-cycle.log
    hash-verification.log
    state.txt
    timings.tsv
    timings.txt
    nested/depth-1/<nested-archive-path>/run.log
```

The transcript starts before dependency checks and includes stdout, stderr, and the exit status. Component logs are written there while the job runs and retained on success as well as failure; unused components may have empty logs. `7zip.log` contains the latest archive stage; the full transcript retains earlier stages. `report.txt` is the optional success report (`--no-report` disables it). Failure reports also stay in this folder; a preserved failed archive stays beside the requested archive.

Nested jobs have their own component logs beside their `run.log`, including detailed video calibration even when the nested job uses `--no-report`. Batch runs use the same visible folder inside the batch destination, with each item's logs and planning output under `batch/<item>/`. Each top-level run has a unique directory, so reruns keep previous logs. Without an explicit destination, logs go beside the automatically chosen archive (or inside the automatic batch output directory).

The start of the run prints the exact log directory. Upload that run's folder to include the parent and child diagnostics together. The video log records the exact FFmpeg command used for full transcodes, including the selected VAAPI render node when one is locked. Existing logs and already-running jobs keep their original locations.

The success report includes phase timings recorded directly with a monotonic clock: calibration/sample validation, full video encoding, full video decode validation, archive writing, archive verification (including strong extraction/hashing when selected), and nested processing. `timings.tsv` retains individual durations and exit statuses; `timings.txt` summarizes them even for children using `--no-report` and runs that fail after cleanup is installed. These measurements do not depend on parsing `run.log`. Each archive has its own journal. Worker phases can overlap, and the parent's nested-processing duration includes child work and parent archive updates, so the phase totals must not be added to infer wall time. Inventory, staging, and other preparation/finalization work are outside these measured phases.

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

On macOS, ACL capture and restoration use Apple's built-in, no-follow ACL APIs through Python; **do not install Homebrew `acl`** (that package is for Linux). The doctor probes native ACL reads on the source. Native ACL manifests preserve principal UUIDs, allow/deny order, inheritance flags, and empty ACLs; restoration reads each applied ACL back to verify it. Symlinks are handled only as explicitly typed records with matching link targets, without touching their targets, and symlinked parents are rejected. ACL capture errors stop archive creation rather than silently omitting permissions. Use the current version to restore these manifests. Extended Linux/POSIX ACLs and macOS ACLs are not silently translated: restore on the matching OS when these permissions must be preserved. UUID-based principals are retained exactly; accounts on another Mac are not automatically remapped by name.

Choose a destination that does not already exist. Archive-member validation uses a headerless 7-Zip listing, so an absolute path to the archive itself is allowed while absolute or traversing member paths remain forbidden. A failed listing, integrity check, extraction, or metadata/hash check prevents committing the restored tree; temporary extraction data is cleaned up on failure or a handled interruption. Restore does not repeat video calibration or compression, and does not modify the archive or original source files.

## Benchmarks

### Resource-use audit

High overall CPU usage is not guaranteed, and is not a reliable throughput measure by itself. Current stage policies are:

| Stage | Current execution policy | Limit or tradeoff |
| --- | --- | --- |
| LZMA2 compression | Two threads by default; explicit `THREADS` / `--threads` override | More threads can split independent blocks, increase RAM use and change compression ratio. |
| Match-cycle tuning | Four bounded trials, sequential, two threads each | Startup work; small inputs skip it. |
| Video encoding | Hardware encoder; VAAPI/CUDA preprocessing where accepted; sequential files; can overlap LZMA2/images | GPU/CPU scaling compete on quality and predicted compression. Unsupported acceleration falls back to CPU preprocessing. VMAF and the final decode audit remain on CPU. |
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
