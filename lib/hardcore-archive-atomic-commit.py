#!/usr/bin/env python3
"""Atomically rename a prepared restore tree into place without replacement.

Linux uses renameat2(..., RENAME_NOREPLACE). macOS uses
renamex_np(..., RENAME_EXCL). There is deliberately no check-then-rename or
ordinary-rename fallback: if the platform or filesystem cannot provide an
atomic no-replace rename, restore must fail closed.
"""

import ctypes
import errno
import os
import sys

EXIT_DESTINATION_EXISTS = 17
EXIT_UNAVAILABLE = 18
EXIT_COMMIT_FAILED = 19


def _stderr(message):
    print(message, file=sys.stderr)


def _unsupported_errors():
    values = {errno.EINVAL, errno.ENOSYS}
    for name in ("ENOTSUP", "EOPNOTSUPP"):
        value = getattr(errno, name, None)
        if value is not None:
            values.add(value)
    return values


def _finish(rc, destination, operation):
    if rc == 0:
        return 0

    error = ctypes.get_errno()
    if error in (errno.EEXIST, getattr(errno, "ENOTEMPTY", errno.EEXIST)):
        _stderr(f"Restore destination already exists at commit time: {destination}")
        return EXIT_DESTINATION_EXISTS
    if error in _unsupported_errors():
        _stderr(
            f"Required atomic no-replace restore commit is unavailable for "
            f"{destination} ({operation}: {os.strerror(error)})."
        )
        return EXIT_UNAVAILABLE
    if error == errno.EXDEV:
        _stderr(
            "Restore staging and destination are not on the same filesystem; "
            "an atomic restore commit is impossible."
        )
        return EXIT_COMMIT_FAILED

    _stderr(
        f"Atomic restore commit failed for {destination} "
        f"({operation}: {os.strerror(error)})."
    )
    return EXIT_COMMIT_FAILED


def _linux_commit(source, destination):
    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = getattr(libc, "renameat2", None)
    if renameat2 is None:
        _stderr(
            "Required atomic no-replace restore commit is unavailable: "
            "libc does not expose renameat2()."
        )
        return EXIT_UNAVAILABLE

    renameat2.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    renameat2.restype = ctypes.c_int
    at_fdcwd = -100
    rename_noreplace = 1
    ctypes.set_errno(0)
    rc = renameat2(
        at_fdcwd,
        os.fsencode(source),
        at_fdcwd,
        os.fsencode(destination),
        rename_noreplace,
    )
    return _finish(rc, destination, "renameat2(RENAME_NOREPLACE)")


def _macos_commit(source, destination):
    libc = ctypes.CDLL(None, use_errno=True)
    renamex_np = getattr(libc, "renamex_np", None)
    if renamex_np is None:
        _stderr(
            "Required atomic no-replace restore commit is unavailable: "
            "libc does not expose renamex_np()."
        )
        return EXIT_UNAVAILABLE

    renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    renamex_np.restype = ctypes.c_int
    rename_excl = 0x00000004
    ctypes.set_errno(0)
    rc = renamex_np(
        os.fsencode(source),
        os.fsencode(destination),
        rename_excl,
    )
    return _finish(rc, destination, "renamex_np(RENAME_EXCL)")


def atomic_commit(source, destination):
    if sys.platform.startswith("linux"):
        return _linux_commit(source, destination)
    if sys.platform == "darwin":
        return _macos_commit(source, destination)

    _stderr(
        f"Required atomic no-replace restore commit is unsupported on "
        f"platform {sys.platform!r}; restore was not committed."
    )
    return EXIT_UNAVAILABLE


def main(argv):
    if len(argv) != 3:
        _stderr(f"Usage: {argv[0]} PREPARED_SOURCE DESTINATION")
        return 2
    source, destination = argv[1:]
    return atomic_commit(source, destination)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
