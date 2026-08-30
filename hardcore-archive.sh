#!/usr/bin/env bash

# Compatibility name retained for existing commands/scripts.
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
exec "$SCRIPT_DIR/hardcore-archive" "$@"
