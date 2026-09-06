#!/usr/bin/env python3
from __future__ import annotations

import csv
import importlib.util
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RUNNER = (ROOT / "../lib/hardcore-archive-zopfli-adaptive.py").resolve()

spec = importlib.util.spec_from_file_location("hardcore_zopfli_adaptive", RUNNER)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

assert module._probe_budget(20) == 7
assert module._probe_budget(45) == 15
assert module._probe_budget(75) == 20
assert module._probe_budget(90) == 20

tier, deep_budget, zi, ziwi, bps, ppm, threshold = module.choose_effort(1_000_000, 980_000, 1000, 20)
assert tier == "strong" and zi == 5 and ziwi == 2
assert 0 < deep_budget <= 19
assert bps > threshold and ppm > 0

tier, deep_budget, *_ = module.choose_effort(1_000_000, 999_500, 1000, 20)
assert tier == "stop" and deep_budget == 0

with tempfile.TemporaryDirectory(prefix="hardcore-zopfli-test-") as td:
    tmp = Path(td)
    oxipng = tmp / "oxipng"
    calls = tmp / "calls.log"
    oxipng.write_text(
        """#!/usr/bin/env python3
import os, pathlib, sys
args=sys.argv[1:]
if args and args[0]=='--help':
    print('--threads --zopfli --zi --ziwi')
    raise SystemExit(0)
with open(os.environ['FAKE_OXI_CALLS'],'a',encoding='utf-8') as h:
    h.write(' '.join(args)+'\\n')
target=pathlib.Path(args[-1])
size=target.stat().st_size
zi=0
if '--zi' in args:
    zi=int(args[args.index('--zi')+1])
if os.environ.get('FAKE_OXI_MODE') == 'low':
    shrink=500
elif zi <= 1:
    shrink=20_000
else:
    shrink=10_000
with target.open('r+b') as h:
    h.truncate(max(1,size-shrink))
""",
        encoding="utf-8",
    )
    oxipng.chmod(0o755)

    baseline = tmp / "baseline.png"
    baseline.write_bytes(b"x" * 1_000_000)
    work = tmp / "work"
    work.mkdir()
    log = tmp / "image.log"
    telemetry = tmp / "image.zopfli.tsv"
    env = os.environ.copy()
    env["FAKE_OXI_CALLS"] = str(calls)

    completed = subprocess.run(
        [
            sys.executable, str(RUNNER), "run",
            "--oxipng", str(oxipng), "--baseline", str(baseline),
            "--work-dir", str(work), "--threads", "4", "--budget", "20",
            "--relative", "graphics/logo.png", "--log-file", str(log),
            "--telemetry-file", str(telemetry),
        ],
        text=True, capture_output=True, env=env, check=True,
    )
    fields = completed.stdout.strip().split("\t")
    assert fields[0] == "optimized"
    assert fields[3] == "adaptive-zopfli-strong"
    assert int(fields[2]) == 970_000
    call_lines = calls.read_text(encoding="utf-8").splitlines()
    assert len(call_lines) == 2
    assert "--zi 1" in call_lines[0] and "--ziwi 1" in call_lines[0]
    assert "--zi 5" in call_lines[1] and "--ziwi 2" in call_lines[1]

    rows = list(csv.DictReader(telemetry.open(encoding="utf-8"), delimiter="\t"))
    assert len(rows) == 1
    row = rows[0]
    assert row["decision"] == "strong"
    assert int(row["extra_bytes"]) == 30_000
    assert float(row["extra_bytes_per_second"]) > 0
    assert float(row["probe_bytes_per_second"]) > float(row["minimum_probe_bytes_per_second"])
    assert row["deep_status"] == "ok"

    summary = subprocess.run(
        [sys.executable, str(RUNNER), "summary", "--telemetry-file", str(telemetry)],
        text=True, capture_output=True, check=True,
    ).stdout
    assert "attempts=1" in summary
    assert "deep=1" in summary
    assert "extra_bytes=30000" in summary
    assert "extra_bytes_per_second=" in summary

    calls.write_text("", encoding="utf-8")
    telemetry.unlink()
    work2 = tmp / "work-low"
    work2.mkdir()
    env["FAKE_OXI_MODE"] = "low"
    completed = subprocess.run(
        [
            sys.executable, str(RUNNER), "run",
            "--oxipng", str(oxipng), "--baseline", str(baseline),
            "--work-dir", str(work2), "--threads", "4", "--budget", "20",
            "--relative", "graphics/tiny-gain.png", "--log-file", str(log),
            "--telemetry-file", str(telemetry),
        ],
        text=True, capture_output=True, env=env, check=True,
    )
    fields = completed.stdout.strip().split("\t")
    assert fields[0] == "optimized"
    assert fields[3] == "adaptive-zopfli-stop"
    assert len(calls.read_text(encoding="utf-8").splitlines()) == 1
    row = next(csv.DictReader(telemetry.open(encoding="utf-8"), delimiter="\t"))
    assert row["decision"] == "stop"
    assert row["deep_status"] == "not-run"

print("Adaptive Zopfli policy tests passed.")
