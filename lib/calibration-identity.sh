#!/usr/bin/env bash

# Metadata identity for calibration hints; this is not content verification.
# Nested entries use the containing archive's identity and a relative path,
# so random extraction/staging directories do not defeat reuse. The selected
# FFmpeg/VMAF runtime is part of the identity so quality boundaries never cross
# toolchain changes silently.
hardcore_calibration_identity() {
    python3 - "$1" <<'PY'
import hashlib
import json
import os
import stat
import sys

try:
    path = os.path.realpath(sys.argv[1])
    info = os.stat(path)
    if not stat.S_ISREG(info.st_mode):
        raise ValueError("not a regular file")
    namespace = os.environ.get("HARDCORE_ARCHIVE_CALIBRATION_NAMESPACE", "")
    root = os.environ.get("HARDCORE_ARCHIVE_CALIBRATION_SOURCE_ROOT", "")
    runtime_id = os.environ.get("HARDCORE_ARCHIVE_VIDEO_RUNTIME_ID", "system-unidentified")
    if namespace and root and os.path.commonpath([path, os.path.realpath(root)]) == os.path.realpath(root):
        identity = ["nested", namespace, os.path.relpath(path, os.path.realpath(root)),
                    info.st_size, info.st_mtime_ns, runtime_id]
    else:
        identity = ["source", path, info.st_dev, info.st_ino, info.st_size,
                    info.st_mtime_ns, info.st_ctime_ns, runtime_id]
    print(hashlib.sha256(json.dumps(identity, ensure_ascii=True).encode()).hexdigest())
except (OSError, ValueError):
    sys.exit(1)
PY
}
export -f hardcore_calibration_identity