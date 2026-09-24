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

        fake_hardcore = root / "fake-hardcore"
        fake_hardcore.write_text(
            """#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${1:-} == --version ]]; then printf 'fake hardcore 1.0\\n'; exit 0; fi
if [[ " $* " == *" --restore "* ]]; then
    archive=${@: -2:1}; destination=${@: -1}
    [[ ! -e $destination ]] || { printf 'destination already exists\\n' >&2; exit 41; }
    mkdir -p -- "$destination"
    tar -xf "$archive" -C "$destination"
else
    source=${@: -2:1}; archive=${@: -1}
    tar -cf "$archive" -C "$(dirname -- "$source")" "$(basename -- "$source")"
fi
""",
            encoding="utf-8",
        )
        fake_hardcore.chmod(0o755)
        hardcore_result = judge.benchmark_hardcore(
            str(fake_hardcore),
            source,
            expected,
            judge.payload_size(expected),
            0,
            root / "hardcore-results",
            lossless=True,
        )
        assert hardcore_result.status == "PASS", hardcore_result
        assert hardcore_result.exact_payload_roundtrip is True

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
        fake_bzip2 = fake_bin / "bzip2"
        fake_bzip2.write_text(
            f"""#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${{1:-}} == --version ]]; then printf 'fake bzip2 1.0\\n'; exit 0; fi
if [[ -e '{output}/gzip/restored' || -e '{output}/gzip/restored.tar' ]]; then
    printf 'previous method restore was not cleaned up\\n' >&2
    exit 42
fi
cat -- "${{@: -1}}"
""",
            encoding="utf-8",
        )
        fake_bzip2.chmod(0o755)
        environment = {"PATH": f"{fake_bin}:/usr/bin:/bin"}
        completed = subprocess.run(
            [
                sys.executable,
                str(JUDGE),
                str(source),
                "--methods",
                "gzip,bzip2",
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
        assert results["results"][1]["status"] == "PASS"
        assert not (output / "gzip" / "restored").exists()
        assert not (output / "bzip2" / "restored").exists()
        subprocess.run([sys.executable, str(CHECK), str(output)], check=True)

    print("Compression Judge tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
