#!/usr/bin/env python3
"""Bind every generated VAAPI FFmpeg command to the user-selected render node."""
from __future__ import annotations
import os
import pathlib
import sys

MARKER = "# HARDCORE_EXPLICIT_VAAPI_DEVICE_V1"


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} INPUT_CORE OUTPUT_CORE", file=sys.stderr)
        return 2
    src, dst = map(pathlib.Path, sys.argv[1:])
    text = src.read_text(encoding="utf-8")
    if MARKER in text:
        dst.write_text(text, encoding="utf-8")
        os.chmod(dst, 0o700)
        return 0

    double_count = text.count('"vaapi=va:"')
    single_count = text.count("'vaapi=va:'")
    if double_count < 4:
        print(
            f"Error: VAAPI-device engine patch failed: expected at least 4 double-quoted VAAPI device anchors, found {double_count}",
            file=sys.stderr,
        )
        return 1

    text = text.replace('"vaapi=va:"', '"vaapi=va:${HARDCORE_ARCHIVE_VAAPI_DEVICE:-}"')
    text = text.replace("'vaapi=va:'", '"vaapi=va:${HARDCORE_ARCHIVE_VAAPI_DEVICE:-}"')

    anchor = "# HARDCORE_HARDWARE_ONLY_VIDEO_V1\n"
    if anchor not in text:
        print("Error: VAAPI-device engine patch failed: hardware-policy marker missing", file=sys.stderr)
        return 1
    text = text.replace(anchor, anchor + MARKER + "\n", 1)

    state_anchor = '''            printf 'video_encoder=%s\\n' "${VIDEO_ENCODER:-unset}"'''
    if state_anchor in text:
        text = text.replace(
            state_anchor,
            state_anchor + '''\n            printf 'video_vaapi_device=%s\\n' "${HARDCORE_ARCHIVE_VAAPI_DEVICE:-auto}"''',
            1,
        )

    dst.write_text(text, encoding="utf-8")
    os.chmod(dst, 0o700)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
