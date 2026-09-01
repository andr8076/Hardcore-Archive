# Hardcore Archive benchmark corpus

The benchmark suite generates a deterministic mixed corpus and measures the five
numbers needed to judge an archive implementation directly:

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

## Results

Each run creates a timestamped results directory containing:

```text
summary.tsv       one row per archive implementation
results.tsv       detailed create/verify/extract phase rows
environment.tsv   machine, version, corpus, and hash-worker context
*.time            raw wall-time + peak-RSS metrics for each phase
*.7z              the produced archives
```

`summary.tsv` puts the requested metrics in direct columns:

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

Wall time and peak memory are measured by `benchmarks/measure.py` using a fresh
process for every phase. Wall time uses a monotonic high-resolution clock. Peak
RSS is normalized to KiB across Linux and macOS using `resource.getrusage`, which
avoids GNU/BSD `/usr/bin/time` output differences.

## Corpus contents

The deterministic corpus includes:

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
transformations so both archivers see identical source bytes. Media-policy
benchmarks should be run separately on the target GPU.

## Benchmark cautions

Run on an otherwise idle machine. Filesystem cache state can affect verification
and extraction times; the runner calls `sync` between phases when available but
does not require privileged cache dropping. For publishable numbers, run the
suite several times after a warm-up and report the median along with
`environment.tsv`.

Set `HARDCORE_HASH_JOBS=N` to force a specific strong-verification worker count
for scaling tests. Leaving it unset uses the application's adaptive policy.
