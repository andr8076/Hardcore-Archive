#!/bin/sh

# Portable launcher and compatibility name for existing commands/scripts.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
case "$(uname -s 2>/dev/null)-$(uname -m 2>/dev/null)" in
    Linux-x86_64|Linux-amd64) TARGET=linux-x86_64 ;;
    Linux-arm64|Linux-aarch64) TARGET=linux-arm64 ;;
    Darwin-x86_64|Darwin-amd64) TARGET=macos-x86_64 ;;
    Darwin-arm64|Darwin-aarch64) TARGET=macos-arm64 ;;
    *) TARGET=unknown ;;
esac
for BASH_BIN in "$SCRIPT_DIR/runtime/bin/bash" "$SCRIPT_DIR/runtime/$TARGET/bin/bash"; do
    [ ! -x "$BASH_BIN" ] || exec "$BASH_BIN" "$SCRIPT_DIR/hardcore-archive" "$@"
done
exec bash "$SCRIPT_DIR/hardcore-archive" "$@"
