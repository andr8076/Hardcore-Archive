#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
JUDGE = ROOT / "benchmarks" / "compression-judge.py"
CHECK = ROOT / "benchmarks" / "check-compression-judge.py"


def load_judge():
    spec = importlib.util.spec_from_file_location("compression_judge", JUDGE)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main() -> int:
    judge = load_judge()
    with tempfile.TemporaryDirectory(prefix="hardcore-judge-test-") as temporary:
        root = Path(temporary)
        source = root / "source"
        source.mkdir()
        (source / "alpha.txt").write_text("alpha\n" * 100, encoding="utf-8")
        expected = judge.folder_manifest(source)

        changed = root / "changed"
        changed.mkdir()
        (changed / "alpha.txt").write_text("corrupt\n", encoding="utf-8")
        difference_report = root / "differences.txt"
        exact, differences, difference_count = judge.verify_restored(
            changed, expected, difference_report
        )
        assert not exact
        assert difference_count == 1
        assert differences == ["size changed: alpha.txt (600 -> 8)"]
        assert difference_report.read_text(encoding="utf-8") == "size changed: alpha.txt (600 -> 8)\n"

        fake_bin = root / "bin"
        fake_bin.mkdir()
        fake_gzip = fake_bin / "gzip"
        fake_gzip.write_text(
            """#!/usr/bin/env bash
set -Eeuo pipefail
case ${1:-} in
    --version) printf 'fake gzip 1.0\\n'; exit 0 ;;
esac
if [[ " $* " == *" -d "* ]]; then
    cat -- "${@: -1}"
else
    cat -- "${@: -1}"
fi
""",
            encoding="utf-8",
        )
        fake_gzip.chmod(0o755)

        output = root / "results"
        environment = {"PATH": f"{fake_bin}:/usr/bin:/bin"}
        completed = subprocess.run(
            [
                sys.executable,
                str(JUDGE),
                str(source),
                "--methods",
                "gzip",
                "--output-dir",
                str(output),
                "--heartbeat-seconds",
                "5",
            ],
            env=environment,
            check=False,
        )
        assert completed.returncode == 0
        status = json.loads((output / "run-status.json").read_text(encoding="utf-8"))
        assert status["state"] == "complete"
        assert status["exit_code"] == 0
        results = json.loads((output / "results.json").read_text(encoding="utf-8"))
        assert results["source_stable"] is True
        assert results["results"][0]["exact_payload_roundtrip"] is True
        subprocess.run([sys.executable, str(CHECK), str(output)], check=True)

    print("Compression Judge tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
