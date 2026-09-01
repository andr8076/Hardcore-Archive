# Hardcore Archive benchmark corpus

Generate a deterministic mixed corpus and compare Hardcore Archive with a plain
maximum-compression 7-Zip run:

```bash
python3 benchmarks/generate-corpus.py benchmarks/corpus --size-mib 64
bash benchmarks/run.sh benchmarks/corpus
```

Add `--with-media` when FFmpeg is available to include a deterministic video and
PNG. The default benchmark disables transformations so the archive engines are
compared on identical source bytes. Media-policy benchmarks should be run
separately on a machine with the intended GPU.

`results.tsv` records, for creation, verification, and extraction:

- wall-clock seconds;
- peak resident memory when the platform `time` implementation exposes it;
- archive bytes;
- logical source bytes;
- archive/source percentage.

The corpus includes repeated text, structured JSON, patterned binary data,
deterministic incompressible data, many small files, duplicate content, a sparse
file, pre-compressed data, a nested ZIP, and a repackable DOCX container.
