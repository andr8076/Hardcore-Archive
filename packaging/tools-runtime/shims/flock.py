#!/usr/bin/env python3
"""Small util-linux flock-compatible subset used by Hardcore Archive."""

import fcntl
import os
import subprocess
import sys


def main(argv: list[str]) -> int:
    if argv and argv[0] in {"--version", "-V"}:
        print("flock (Hardcore Archive portable runtime) 1.0")
        return 0

    nonblocking = False
    unlock = False
    while argv and argv[0] in {"-n", "--nonblock", "-u", "--unlock"}:
        option = argv.pop(0)
        nonblocking |= option in {"-n", "--nonblock"}
        unlock |= option in {"-u", "--unlock"}
    if not argv:
        print("flock: missing file descriptor or lock file", file=sys.stderr)
        return 64

    target = argv.pop(0)
    opened = None
    try:
        if target.isdecimal():
            descriptor = int(target)
        else:
            opened = open(target, "a+b")
            descriptor = opened.fileno()
        operation = fcntl.LOCK_UN if unlock else fcntl.LOCK_EX
        if nonblocking and not unlock:
            operation |= fcntl.LOCK_NB
        try:
            fcntl.flock(descriptor, operation)
        except BlockingIOError:
            return 1
        if argv:
            return subprocess.call(argv, close_fds=False)
        return 0
    finally:
        if opened is not None:
            opened.close()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
