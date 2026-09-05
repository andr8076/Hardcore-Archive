# Hardcore Archive benchmark corpus

The benchmark suite has two complementary layers:

1. a small deterministic byte-preserving corpus for direct Hardcore-vs-7-Zip
   compression comparisons; and
2. real-world workload profiles that exercise Hardcore Archive's complete
   routing, image, video, nested-container, verification, and resource-scheduler
   pipeline.

## Byte-preserving baseline

The baseline corpus measures the five numbers needed to judge an archive
implementation directly:

- archive size;
- creation time;
- strong verification time;
- extraction time;
- peak resident memory.

Generate the corpus and run the benchmark:

```bash
python3 benchmarks/generate-corpus.py benchmarks/corpus --size-mib 64
bash benchmarks/run.sh benchmarks/corpus
```

If the corpus does not exist, `run.sh` generates it automatically. The generator
also writes `benchmarks/corpus.sha256`; the runner validates that manifest before
starting so changed/corrupt corpus data cannot silently invalidate a comparison.

The default suite runs two cases:

1. `hardcore` — Hardcore Archive with byte-preserving transforms disabled, so
   compression is measured against identical input bytes. Its normal integrity
   check remains part of the end-to-end creation command.
2. `sevenzip` — a maximum-compression solid LZMA2 7-Zip baseline with an archive
   integrity test after creation, matching the validated-creation shape as closely
   as possible.

Strong verification is timed separately from creation. It extracts the archive
once and checks every regular source payload against the corpus SHA-256 manifest.
The Hardcore case enables the same adaptive checksum verifier used by the
application: SSD/NVMe storage may hash concurrently while rotational storage
remains serial. The baseline uses ordinary serial `sha256sum -c`.

Pure extraction is measured separately with 7-Zip and does not include the
strong SHA-256 pass. This isolates decompression/extraction throughput from
cryptographic verification cost.

## Real-world workload profiles

`generate-workloads.py` creates lane-focused corpora instead of one blended test:

- `documents` — compressible text, structured logs, patterned binary and an
  already-compressed payload;
- `small-files` — thousands of small directory entries;
- `images` — multiple deliberately non-optimal PNGs for OxiPNG calibration and
  worker scheduling;
- `media` — deterministic FFmpeg-generated source video (requires
  `--with-media`);
- `archives` — nested ZIP and TAR/GZIP payloads;
- `containers` — DOCX, XLSX and JAR-style ZIP application containers;
- `mixed` — LZMA2, Copy, image, nested archive, container and optional video
  lanes active together; this is the primary shared-scheduler benchmark;
- `everything` — the mixed workload plus the many-small-files stress case.

Generate the default non-video workloads:

```bash
python3 benchmarks/generate-workloads.py benchmarks/workloads --size-mib 64
```

Include video work when FFmpeg is installed:

```bash
python3 benchmarks/generate-workloads.py benchmarks/workloads \
  --size-mib 64 --with-media \
  --profiles documents,small-files,images,media,archives,containers,mixed,everything
```

Run the complete production pipeline against every generated workload:

```bash
bash benchmarks/run-workloads.sh benchmarks/workloads
```

The runner keeps the machine awake for the **entire benchmark session**, not
only the Hardcore case: macOS uses `caffeinate`, while Linux uses a usable
`systemd-inhibit`. A benchmark refuses to start without that protection. If an
external inhibitor is already active, `HARDCORE_BENCHMARK_ALLOW_SLEEP=1` can be
used as an explicit override.

The real-world runner executes two intentionally different reference cases:

- `hardcore-full` — normal Hardcore Archive behavior, including transforms,
  strong verification of the final archived payload, calibrated OxiPNG, nested
  repacking, application-container policy and the shared CPU/RAM resource pool;
- `sevenzip-byte-preserving` — maximum-compression 7-Zip without media/container
  transforms.

Those two rows are **not** a quality-equivalent media comparison. The 7-Zip row
is useful as a byte-preserving size/time reference; Hardcore may legitimately
produce smaller transformed media while meeting its own VMAF/validation gates.
For direct compressor-ratio comparisons, use the byte-preserving baseline suite
above.

Select workloads or cases with environment variables:

```bash
HARDCORE_BENCHMARK_PROFILES=images,mixed \
HARDCORE_BENCHMARK_CASES=hardcore-full \
  bash benchmarks/run-workloads.sh benchmarks/workloads
```

Set `HARDCORE_BENCHMARK_WITH_MEDIA=1` when asking the runner to generate a
missing workload root with media enabled.

### Real-world metrics

`run-workloads.sh` records:

- source file count and logical bytes;
- archive bytes and compression ratio;
- creation, verification/recheck, and extraction wall time;
- creation user and system CPU time;
- average CPU utilization across the complete creation process;
- sampled **aggregate resident memory for the complete live process tree**
  (Hardcore/7-Zip plus concurrent helpers and descendants), rather than the
  largest RSS of one child process;
- machine CPU, logical-thread count, RAM, kernel, 7-Zip version, git commit and
  NVIDIA GPU/driver information when `nvidia-smi` is available.

Hardcore's `create` measurement includes its normal strong hash verification of
the final archived payload. The separate `verify` phase is an archive inspection
/recheck so creation cost and later integrity-check cost remain visible.

### Regression comparison

Compare a known-good real-world result with a new run:

```bash
python3 benchmarks/compare-results.py \
  benchmarks/results/good/summary.tsv \
  benchmarks/results/new/summary.tsv
```

Default regression thresholds are:

- archive size: +0.5%;
- creation/verification/extraction time: +10%;
- peak memory: +15%.

Make regressions fail a scripted benchmark job:

```bash
python3 benchmarks/compare-results.py old/summary.tsv new/summary.tsv \
  --fail-on-regression
```

Thresholds can be changed with `--size-regression`, `--time-regression`, and
`--memory-regression`.

## Results

Each baseline run creates a timestamped results directory containing:

```text
summary.tsv       one row per archive implementation
results.tsv       detailed create/verify/extract phase rows
environment.tsv   machine, version, corpus, and hash-worker context
*.time            raw wall-time + peak-RSS metrics for each phase
*.7z              the produced archives
```

The real-world runner uses the same filenames, but `summary.tsv` is keyed by
`profile` plus `case` and adds CPU-time/utilization and phase-status fields. Each
measured phase also gets a `*.log`. If a phase fails, its wall/CPU/RAM metrics,
exit code and log are written before the runner decides what can safely continue.
For example, a failed post-create inspection does not discard the completed
creation measurement, and extraction can still run when the archive exists.
Blocked phases are recorded explicitly as `not-run:<reason>`. The runner exits
nonzero after all safe work is recorded if any case failed.

Every real-world case also snapshots source metadata immediately before and after
the case. If the source changes, `*.source-changes.txt` names each added, removed
or modified path and the metadata fields that changed. This makes long-run
source-change failures diagnosable instead of reporting only a generic mismatch.

The baseline `summary.tsv` puts the requested metrics in direct columns:

```text
case
archive_bytes
creation_seconds
verification_seconds
extraction_seconds
peak_memory_kib
```

It also records source size, compression ratio, and each phase's individual peak
RSS. `peak_memory_kib` is the maximum observed peak RSS across creation,
verification, and extraction.

`results.tsv` retains one row per phase so regressions can be attributed to the
specific stage rather than only the overall maximum.

The byte-preserving baseline still uses `benchmarks/measure.py`. The real-world
runner uses `measure-extended.py`: wall time uses a monotonic clock; user/system
CPU time is retained; and a periodic process-table sample follows the benchmark
root PID through its live descendants and sums their RSS to produce
`peak_memory_kib`. The default sample interval is 0.5 seconds and can be changed
with `HARDCORE_BENCHMARK_SAMPLE_INTERVAL` (0.05–5 seconds). This is intentionally
an aggregate process-tree memory metric, which is the relevant quantity for the
shared CPU/RAM scheduler.

## Baseline corpus contents

The deterministic baseline corpus includes:

- highly repetitive text;
- structured JSON records;
- patterned binary data;
- deterministic incompressible binary data;
- 1,000 small files;
- duplicate content;
- a sparse file;
- already-compressed data;
- a nested ZIP;
- a repackable DOCX container.

Add `--with-media` when FFmpeg is available to include deterministic generated
video and PNG inputs. The default compression benchmark disables media/container
transformations so both archivers see identical source bytes.

## Benchmark cautions

Run performance measurements on an otherwise idle machine. Filesystem cache
state can affect verification and extraction times; the runners call `sync`
between phases when available but do not require privileged cache dropping. For
publishable numbers, run the suite several times after a warm-up and report the
median along with `environment.tsv`.

Media results are machine-specific because encoder availability, driver versions,
GPU architecture, FFmpeg build options, and libvmaf support can materially change
both speed and accepted output. Keep `environment.tsv` beside every result.

Set `HARDCORE_HASH_JOBS=N` to force a specific strong-verification worker count
for baseline scaling tests. Leaving it unset uses the application's adaptive
policy.
