#!/usr/bin/env python3
from __future__ import annotations

import csv
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "benchmarks" / "generate-workloads.py"
COMPARATOR = ROOT / "benchmarks" / "compare-results.py"
MEASURE = ROOT / "benchmarks" / "measure-extended.py"
SNAPSHOT = ROOT / "benchmarks" / "source-snapshot.py"
RUNNER = ROOT / "benchmarks" / "run-workloads.sh"
INSPECT = ROOT / "lib" / "inspect.sh"
ENTRYPOINT = ROOT / "hardcore-archive"


def run(command: list[str], *, check: bool = True, env: dict[str, str] | None = None, **kwargs):
    return subprocess.run(command, check=check, env=env, **kwargs)


def digest_tree(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        digest.update(str(path.relative_to(root)).encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def write_summary(
    path: Path,
    creation: float | str,
    archive_bytes: int | str,
    peak: int | str,
    *,
    overall_status: str = "success",
    verification: float | str = 2,
    extraction: float | str = 3,
) -> None:
    fields = [
        "profile", "case", "source_files", "source_bytes", "archive_bytes", "ratio_percent",
        "creation_seconds", "verification_seconds", "extraction_seconds",
        "create_average_cpu_percent", "create_user_seconds", "create_system_seconds",
        "peak_memory_kib", "verification_kind", "overall_status",
    ]
    row = {
        "profile": "documents", "case": "hardcore-full", "source_files": "4", "source_bytes": "1000000",
        "archive_bytes": str(archive_bytes), "ratio_percent": "50", "creation_seconds": str(creation),
        "verification_seconds": str(verification), "extraction_seconds": str(extraction),
        "create_average_cpu_percent": "150", "create_user_seconds": "5", "create_system_seconds": "1",
        "peak_memory_kib": str(peak), "verification_kind": "test", "overall_status": overall_status,
    }
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t")
        writer.writeheader()
        writer.writerow(row)


def test_measurement(temp: Path) -> None:
    metric = temp / "metric.tsv"
    run([sys.executable, str(MEASURE), "--output", str(metric), "--", sys.executable, "-c", "sum(range(10000))"])
    values = metric.read_text(encoding="utf-8").strip().split("\t")
    assert len(values) == 5
    assert float(values[0]) >= 0
    assert int(values[1]) >= 0
    assert float(values[2]) >= 0
    assert float(values[3]) >= 0
    assert float(values[4]) >= 0

    failure_metric = temp / "failure.time"
    failure_log = temp / "failure.log"
    failed = run(
        [sys.executable, str(MEASURE), "--output", str(failure_metric), "--log", str(failure_log), "--",
         "bash", "-c", "echo phase-out; echo phase-error >&2; exit 7"],
        check=False,
    )
    assert failed.returncode == 7
    assert len(failure_metric.read_text(encoding="utf-8").strip().split("\t")) == 5
    log = failure_log.read_text(encoding="utf-8")
    assert "phase-out" in log and "phase-error" in log

    single_metric = temp / "single.time"
    tree_metric = temp / "tree.time"
    run([
        sys.executable, str(MEASURE), "--output", str(single_metric), "--sample-interval", "0.2", "--",
        sys.executable, "-c", "import time; x=bytearray(24*1024*1024); time.sleep(1.5)",
    ])
    run([
        sys.executable, str(MEASURE), "--output", str(tree_metric), "--sample-interval", "0.2", "--",
        sys.executable, "-c",
        "import subprocess,time; x=bytearray(24*1024*1024); "
        "subprocess.run(['" + sys.executable.replace("'", "\\'") + "','-c','import time; x=bytearray(32*1024*1024); time.sleep(1.2)']); "
        "time.sleep(.4)",
    ])
    single_peak = int(single_metric.read_text(encoding="utf-8").split("\t")[1])
    tree_peak = int(tree_metric.read_text(encoding="utf-8").split("\t")[1])
    assert tree_peak > single_peak + 16 * 1024, (single_peak, tree_peak)


def test_source_snapshot(temp: Path) -> None:
    source = temp / "source"
    source.mkdir()
    (source / "changed.txt").write_text("before\n", encoding="utf-8")
    (source / "removed.txt").write_text("remove\n", encoding="utf-8")
    before = temp / "before.json"
    after = temp / "after.json"
    report = temp / "changes.txt"
    run([sys.executable, str(SNAPSHOT), "capture", str(source), str(before)])
    (source / "changed.txt").write_text("after and larger\n", encoding="utf-8")
    (source / "removed.txt").unlink()
    (source / "added.txt").write_text("new\n", encoding="utf-8")
    run([sys.executable, str(SNAPSHOT), "capture", str(source), str(after)])
    compared = run([sys.executable, str(SNAPSHOT), "compare", str(before), str(after), str(report)], check=False)
    assert compared.returncode == 1
    text = report.read_text(encoding="utf-8")
    assert 'ADDED\t"added.txt"' in text
    assert 'REMOVED\t"removed.txt"' in text
    assert 'MODIFIED\t"changed.txt"' in text
    assert "size:" in text


def make_fake_7zip(path: Path) -> None:
    path.write_text(
        r'''#!/usr/bin/env bash
set -Eeuo pipefail
if (($# == 0)); then
    printf '7-Zip fake\nVersion 1\n'
    exit 0
fi
cmd=$1; shift
case "$cmd" in
    t) printf 'Everything is Ok\n' ;;
    l)
        mode=${1:-}; shift || true
        if [[ $mode == -slt ]]; then
            printf 'Method = LZMA2:24\nFolder = -\nFolder = +\n'
            for i in $(seq 1 5000); do printf 'Path = payload/file-%05d\nFolder = -\n' "$i"; done
        else
            printf '.hardcore-archive-metadata/archive-info.txt\n'
            printf '.hardcore-archive-image-manifest.txt\n'
            printf '.hardcore-archive-sha256.txt\n'
            printf 'payload/file.txt\n'
        fi
        ;;
    x)
        if [[ " $* " == *" -so "* ]]; then
            printf 'Hardcore Archive information\nScript version: test\n'
            exit 0
        fi
        out=''; archive=''
        for arg in "$@"; do
            case "$arg" in -o*) out=${arg#-o} ;; *.7z) archive=$arg ;; esac
        done
        [[ -n $out ]] || exit 2
        name=${archive##*/}; name=${name%%.*}
        mkdir -p -- "$out/$name"
        printf extracted > "$out/$name/file.txt"
        ;;
    a) : > "$1" ;;
    *) printf 'unsupported fake 7z command: %s\n' "$cmd" >&2; exit 2 ;;
esac
''',
        encoding="utf-8",
    )
    path.chmod(0o755)


def test_inspect(temp: Path) -> None:
    fake = temp / "7zz"
    make_fake_7zip(fake)
    archive = temp / "sample.7z"
    archive.write_bytes(b"archive")
    env = os.environ.copy()
    env["SEVEN_ZIP_BIN"] = str(fake)
    # Exercise the inspect implementation directly; the public entrypoint route
    # is asserted below and is exercised in the full repository CI environment.
    completed = run(
        ["bash", "-c", 'set -Eeuo pipefail; source "$1"; hardcore_inspect_main --inspect "$2"', "_", str(INSPECT), str(archive)],
        env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    assert "Integrity:" in completed.stdout and "passed" in completed.stdout
    assert "First method reported: LZMA2:24" in completed.stdout
    assert "Embedded SHA-256 manifest: present" in completed.stdout
    entrypoint = ENTRYPOINT.read_text(encoding="utf-8")
    assert 'source "$HARDCORE_ARCHIVE_ROOT/lib/inspect.sh"' in entrypoint
    assert "hardcore_inspect_main" in entrypoint


def make_fake_hardcore(path: Path) -> None:
    path.write_text(
        r'''#!/usr/bin/env bash
set -Eeuo pipefail
printf '%q ' "$@" >> "${FAKE_ARGV_LOG:?}"
printf '\n' >> "$FAKE_ARGV_LOG"
for arg in "$@"; do
    [[ $arg != --allow-sleep ]] || { printf 'benchmark incorrectly allowed sleep\n' >&2; exit 88; }
done
if [[ ${1:-} == --inspect ]]; then
    if [[ ${FAKE_INSPECT_FAIL:-0} == 1 ]]; then
        printf 'synthetic inspect failure\n' >&2
        exit 9
    fi
    printf 'synthetic inspect success\n'
    exit 0
fi
source=${@: -2:1}
archive=${@: -1}
printf fake > "$archive"
if [[ ${FAKE_SOURCE_CHANGE:-0} == 1 ]]; then
    printf '\nchanged during benchmark\n' >> "$source/documents/notes.txt"
    printf 'synthetic source-change failure\n' >&2
    exit 12
fi
printf 'synthetic create success\n'
''',
        encoding="utf-8",
    )
    path.chmod(0o755)


def test_runner_resilience(temp: Path) -> None:
    workloads = temp / "workloads"
    run([sys.executable, str(GENERATOR), str(workloads), "--size-mib", "4", "--profiles", "documents"])
    fake_hardcore = temp / "hardcore"
    fake_7z = temp / "7zz"
    argv_log = temp / "argv.log"
    make_fake_hardcore(fake_hardcore)
    make_fake_7zip(fake_7z)

    env = os.environ.copy()
    env.update({
        "HARDCORE_ARCHIVE_BIN": str(fake_hardcore),
        "SEVEN_ZIP_BIN": str(fake_7z),
        "HARDCORE_BENCHMARK_PROFILES": "documents",
        "HARDCORE_BENCHMARK_CASES": "hardcore-full",
        "HARDCORE_BENCHMARK_INHIBITED": "1",
        "HARDCORE_BENCHMARK_SAMPLE_INTERVAL": "0.2",
        "FAKE_ARGV_LOG": str(argv_log),
        "FAKE_INSPECT_FAIL": "1",
    })
    failed_results = temp / "failed-results"
    completed = run(["bash", str(RUNNER), str(workloads), str(failed_results)], env=env, check=False)
    assert completed.returncode == 1
    rows = list(csv.DictReader((failed_results / "results.tsv").open(encoding="utf-8"), delimiter="\t"))
    by_phase = {row["phase"]: row for row in rows}
    assert by_phase["create"]["status"] == "success"
    assert by_phase["verify"]["status"] == "failed" and by_phase["verify"]["exit_code"] == "9"
    assert by_phase["extract"]["status"] == "success"
    assert (failed_results / "documents.hardcore-full.verify.time").is_file()
    assert "synthetic inspect failure" in (failed_results / "documents.hardcore-full.verify.log").read_text(encoding="utf-8")
    summary = next(csv.DictReader((failed_results / "summary.tsv").open(encoding="utf-8"), delimiter="\t"))
    assert summary["overall_status"] == "failed"
    assert summary["create_status"] == "success" and summary["verify_status"] == "failed" and summary["extract_status"] == "success"
    assert "--allow-sleep" not in argv_log.read_text(encoding="utf-8")

    # Re-generate a clean source, then simulate the exact failure seen in the
    # uploaded benchmark: source changed while create was running. The harness
    # must retain create timing and name the changed path.
    run([sys.executable, str(GENERATOR), str(workloads), "--size-mib", "4", "--profiles", "documents", "--force"])
    env["FAKE_INSPECT_FAIL"] = "0"
    env["FAKE_SOURCE_CHANGE"] = "1"
    changed_results = temp / "source-changed-results"
    changed = run(["bash", str(RUNNER), str(workloads), str(changed_results)], env=env, check=False)
    assert changed.returncode == 1
    rows = list(csv.DictReader((changed_results / "results.tsv").open(encoding="utf-8"), delimiter="\t"))
    by_phase = {row["phase"]: row for row in rows}
    assert by_phase["create"]["status"] == "failed" and by_phase["create"]["exit_code"] == "12"
    assert by_phase["verify"]["status"].startswith("not-run")
    assert by_phase["extract"]["status"].startswith("not-run")
    reports = list(changed_results.glob("*.source-changes.txt"))
    assert len(reports) == 1
    report = reports[0].read_text(encoding="utf-8")
    assert 'MODIFIED\t"documents/notes.txt"' in report


def test_comparator(temp: Path) -> None:
    baseline = temp / "baseline.tsv"
    good = temp / "good.tsv"
    bad = temp / "bad.tsv"
    incomplete = temp / "incomplete.tsv"
    write_summary(baseline, 10.0, 500000, 100000)
    write_summary(good, 10.5, 501000, 105000)
    write_summary(bad, 13.0, 510000, 130000)
    write_summary(incomplete, 10.0, 500000, 100000, overall_status="failed", verification="", extraction="")
    run([sys.executable, str(COMPARATOR), str(baseline), str(good), "--fail-on-regression"])
    failed = run([sys.executable, str(COMPARATOR), str(baseline), str(bad), "--fail-on-regression"], check=False)
    assert failed.returncode == 1
    incomplete_result = run([sys.executable, str(COMPARATOR), str(baseline), str(incomplete), "--fail-on-regression"], check=False)
    assert incomplete_result.returncode == 1


def main() -> int:
    run([sys.executable, "-m", "py_compile", str(GENERATOR), str(COMPARATOR), str(MEASURE), str(SNAPSHOT)])
    run(["bash", "-n", str(RUNNER)])
    run(["bash", "-n", str(INSPECT)])
    run(["bash", "-n", str(ENTRYPOINT)])

    with tempfile.TemporaryDirectory(prefix="hardcore-bench-test-") as temp:
        temp_path = Path(temp)
        first = temp_path / "first"
        second = temp_path / "second"
        profiles = "documents,images,archives,containers"
        for output in (first, second):
            run([sys.executable, str(GENERATOR), str(output), "--size-mib", "4", "--profiles", profiles])
            for name in profiles.split(","):
                assert (output / name).is_dir(), name
                assert (output / f"{name}.sha256").is_file(), name
        for name in profiles.split(","):
            assert digest_tree(first / name) == digest_tree(second / name), name

        test_measurement(temp_path)
        test_source_snapshot(temp_path)
        test_inspect(temp_path)
        test_comparator(temp_path)
        test_runner_resilience(temp_path)

    print("Real-world benchmark workload tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
