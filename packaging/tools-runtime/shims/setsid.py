#!/usr/bin/env python3
"""Small util-linux setsid-compatible subset used by Hardcore Archive."""

import os
import sys


def main(argv: list[str]) -> int:
    if argv and argv[0] in {"--version", "-V"}:
        print("setsid (Hardcore Archive portable runtime) 1.0")
        return 0
    if argv and argv[0] == "--":
        argv.pop(0)
    if not argv:
        print("setsid: missing command", file=sys.stderr)
        return 64
    try:
        os.setsid()
    except PermissionError:
        child = os.fork()
        if child:
            _, status = os.waitpid(child, 0)
            return os.waitstatus_to_exitcode(status)
        os.setsid()
    os.execvp(argv[0], argv)
    return 127


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
