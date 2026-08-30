#!/usr/bin/env python3
"""Enable per-file automatic AV1/HEVC hardware codec competition in runtime policy."""
from __future__ import annotations
import os
import pathlib
import sys

MARKER = "# HARDCORE_VIDEO_CODEC_AUTO_POLICY_V1"

def fail(label: str, count: int) -> None:
    print(f"Error: video-auto policy patch failed: {label}: expected one anchor, found {count}", file=sys.stderr)
    raise SystemExit(1)

def repl(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        fail(label, count)
    return text.replace(old, new, 1)

def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} INPUT_POLICY OUTPUT_POLICY", file=sys.stderr)
        return 2
    src, dst = map(pathlib.Path, sys.argv[1:])
    text = src.read_text(encoding="utf-8")
    if MARKER in text:
        dst.write_text(text, encoding="utf-8"); os.chmod(dst, 0o700); return 0

    text = repl(text,
        "# HARDCORE_DEFAULT_ON_CONTAINER_POLICY_V1\n",
        "# HARDCORE_DEFAULT_ON_CONTAINER_POLICY_V1\n" + MARKER + "\n",
        "auto policy marker")
    text = repl(text,
        "  --video-codec CODEC       av1 or hevc. Default: av1.\n",
        "  --video-codec CODEC       auto, av1, or hevc. Default: auto.\n"
        "                            auto compares working hardware codecs per file.\n",
        "video codec help")
    text = repl(text,
        "AV1 is preferred. The only automatic codec fallback is AV1 -> HEVC when a real\n"
        "hardware probe proves the GPU itself cannot encode AV1 and HEVC hardware encode\n"
        "passes. Missing/broken FFmpeg, drivers, permissions, or filters never trigger a fallback.\n",
        "auto compares every working hardware AV1/HEVC encoder exposed for this machine.\n"
        "Each file keeps the smallest candidate that satisfies the same VMAF and minimum-\n"
        "savings policy. Explicit --video-codec or --video-encoder requests remain authoritative.\n"
        "Broken advertised hardware capabilities still fail closed instead of being ignored.\n",
        "auto policy explanation")
    text = repl(text,
        'EFFECTIVE_VIDEO_CODEC=${CLI_VIDEO_CODEC:-${CONFIG_VIDEO_CODEC:-av1}}\n',
        'EFFECTIVE_VIDEO_CODEC=${CLI_VIDEO_CODEC:-${CONFIG_VIDEO_CODEC:-auto}}\n',
        "auto codec default")
    text = repl(text,
        "case $EFFECTIVE_VIDEO_CODEC in av1|hevc) ;; *) printf 'Error: video codec must be av1 or hevc.\\n' >&2; exit 1;; esac\n",
        "case $EFFECTIVE_VIDEO_CODEC in auto|av1|hevc) ;; *) printf 'Error: video codec must be auto, av1, or hevc.\\n' >&2; exit 1;; esac\n",
        "auto codec validation")

    old = '''if [[ $VIDEO_ENABLED == true && $VIDEO_RELEVANT == true ]]; then
    [[ -n $HARDWARE_VIDEO_ENCODER ]] || { printf 'Error: internal doctor error: video encoder was not resolved.\\n' >&2; exit 3; }
    # Append final codec/encoder so they win over earlier CLI/config values. This
    # also applies the permitted AV1->HEVC hardware compatibility fallback.
    FORWARDED+=(--video-codec "$EFFECTIVE_VIDEO_CODEC" --video-encoder "$HARDWARE_VIDEO_ENCODER" --video-parallel)
    printf 'Hardware video policy: %s via %s; CPU fallback disabled; video runs in parallel.\\n' "${EFFECTIVE_VIDEO_CODEC^^}" "$HARDWARE_VIDEO_ENCODER" >&2
fi'''
    new = '''if [[ $VIDEO_ENABLED == true && $VIDEO_RELEVANT == true ]]; then
    [[ -n $HARDWARE_VIDEO_ENCODER ]] || { printf 'Error: internal doctor error: video encoder was not resolved.\\n' >&2; exit 3; }
    if [[ $EFFECTIVE_VIDEO_CODEC == auto ]]; then
        [[ -n ${HARDWARE_VIDEO_PRIMARY_CODEC:-} ]] || { printf 'Error: internal doctor error: automatic video primary codec was not resolved.\\n' >&2; exit 3; }
        FORWARDED+=(--video-codec "$HARDWARE_VIDEO_PRIMARY_CODEC" --video-encoder "$HARDWARE_VIDEO_ENCODER" --video-parallel)
        export HARDCORE_ARCHIVE_VIDEO_CODEC_AUTO=1
        export HARDCORE_ARCHIVE_AUTO_AV1_ENCODER="${HARDWARE_AV1_ENCODER:-}"
        export HARDCORE_ARCHIVE_AUTO_HEVC_ENCODER="${HARDWARE_HEVC_ENCODER:-}"
        export HARDCORE_ARCHIVE_HARDWARE_ENCODER_LOCKED="$HARDWARE_VIDEO_ENCODER"
        printf 'Hardware video policy: AUTO; AV1=%s; HEVC=%s; primary=%s via %s; CPU fallback disabled.\\n' \\
            "${HARDWARE_AV1_ENCODER:-unavailable}" "${HARDWARE_HEVC_ENCODER:-unavailable}" \\
            "${HARDWARE_VIDEO_PRIMARY_CODEC^^}" "$HARDWARE_VIDEO_ENCODER" >&2
    else
        FORWARDED+=(--video-codec "$EFFECTIVE_VIDEO_CODEC" --video-encoder "$HARDWARE_VIDEO_ENCODER" --video-parallel)
        export HARDCORE_ARCHIVE_VIDEO_CODEC_AUTO=0
        export HARDCORE_ARCHIVE_AUTO_AV1_ENCODER=''
        export HARDCORE_ARCHIVE_AUTO_HEVC_ENCODER=''
        printf 'Hardware video policy: %s via %s; CPU fallback disabled; video runs in parallel.\\n' "${EFFECTIVE_VIDEO_CODEC^^}" "$HARDWARE_VIDEO_ENCODER" >&2
    fi
fi'''
    text = repl(text, old, new, "auto hardware forwarding")

    dst.write_text(text, encoding="utf-8")
    os.chmod(dst, 0o700)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
