#!/usr/bin/env python3
"""Apply current default-on transform and container-repack policy to the stable frontend."""
from __future__ import annotations
import os
import pathlib
import sys

MARKER = "# HARDCORE_DEFAULT_ON_CONTAINER_POLICY_V1"


def fail(label: str, count: int) -> None:
    print(f"Error: policy update patch failed: {label}: expected one anchor, found {count}", file=sys.stderr)
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
        dst.write_text(text, encoding="utf-8")
        os.chmod(dst, 0o700)
        return 0

    text = repl(text,
"""# Preservation-first frontend for Hardcore Archive. It resolves policy, scans
# the requested source before feature-specific dependency checks, performs a
# strict capability doctor, and then delegates to the full archive engine.""",
"""# HARDCORE_DEFAULT_ON_CONTAINER_POLICY_V1
# Safety-first frontend for Hardcore Archive. Validated transformations are on
# by default, but every transformed candidate is accepted only after the
# feature-specific safety/size checks succeed. Source deletion remains opt-in.""",
"policy marker")

    text = repl(text,
"""Default policy
  Source data is preserved. Video transcoding, image optimization, nested-
  archive repacking, and source deletion are opt-in. Before a create job starts,
  Hardcore Archive scans the source and checks only capabilities required by
  the selected workflow and file types. There are no dependency fallbacks.""",
"""Default policy
  Safe archive transformations are enabled by default: hardware video transcode,
  lossless JPEG/PNG optimization, recursive nested-archive repacking, and
  format-preserving application-container repacking. A transformed candidate is
  used only when its own validation policy passes and it is smaller where that
  feature requires a size win. Source deletion remains explicit/opt-in. Before
  create work starts, Hardcore Archive scans the source and checks only required
  capabilities. There are no dependency fallbacks.""",
"help default policy")

    text = repl(text,
"""Transformation opt-ins:
  --video-transcode         Validated video transcoding. Hardware encoding is mandatory.
  --no-video-transcode      Store original video bitstreams. Default unless config opts in.
  --image-optimize          Validated lossless JPEG/PNG optimization.
  --no-image-optimize       Store original JPEG/PNG bitstreams. Default unless config opts in.
  --nested-repack           Validated nested-archive repacking.
  --no-nested-repack        Preserve nested archives bit-for-bit. Default unless config opts in.""",
"""Transformations (enabled by default):
  --video-transcode         Enable validated hardware video transcoding.
  --no-video-transcode      Store original video bitstreams.
  --image-optimize          Enable validated lossless JPEG/PNG optimization.
  --no-image-optimize       Store original JPEG/PNG bitstreams.
  --nested-repack           Recursively repack true archive files (ZIP/RAR/7z/etc.).
  --no-nested-repack        Preserve true nested archives bit-for-bit.
  --container-repack        Repack safe ZIP-based application containers while
                            preserving their original file type. Default.
  --no-container-repack     Preserve DOCX/XLSX/PPTX/ODF/EPUB/NPZ/WHL/JAR/WAR
                            containers bit-for-bit.""",
"help transform policy")

    text = repl(text,
"""VIDEO_STATE=auto
IMAGE_STATE=auto
NESTED_STATE=auto
MC_AUTO_STATE=auto""",
"""VIDEO_STATE=auto
IMAGE_STATE=auto
NESTED_STATE=auto
CONTAINER_STATE=auto
MC_AUTO_STATE=auto""",
"container state")

    text = repl(text,
"""        --no-nested-repack)
            NESTED_STATE=false; shift ;;
        --video-no-preflight)""",
"""        --no-nested-repack)
            NESTED_STATE=false; shift ;;
        --container-repack)
            CONTAINER_STATE=true; shift ;;
        --no-container-repack)
            CONTAINER_STATE=false; shift ;;
        --video-no-preflight)""",
"container CLI")

    text = repl(text,
"""VIDEO_CONFIG=''
IMAGE_CONFIG=''
NESTED_CONFIG=''
CONFIG_VIDEO_CODEC=''""",
"""VIDEO_CONFIG=''
IMAGE_CONFIG=''
NESTED_CONFIG=''
CONTAINER_CONFIG=''
CONFIG_VIDEO_CODEC=''""",
"container config variable")

    text = repl(text,
"""    VIDEO_CONFIG=$(config_bool_value VIDEO_TRANSCODE "$CONFIG_FILE" || true)
    IMAGE_CONFIG=$(config_bool_value IMAGE_OPTIMIZE "$CONFIG_FILE" || true)
    NESTED_CONFIG=$(config_bool_value NESTED_REPACK "$CONFIG_FILE" || true)
    CONFIG_VIDEO_CODEC=$(config_value VIDEO_CODEC "$CONFIG_FILE" || true); CONFIG_VIDEO_CODEC=${CONFIG_VIDEO_CODEC,,}""",
"""    VIDEO_CONFIG=$(config_bool_value VIDEO_TRANSCODE "$CONFIG_FILE" || true)
    IMAGE_CONFIG=$(config_bool_value IMAGE_OPTIMIZE "$CONFIG_FILE" || true)
    NESTED_CONFIG=$(config_bool_value NESTED_REPACK "$CONFIG_FILE" || true)
    CONTAINER_CONFIG=$(config_bool_value CONTAINER_REPACK "$CONFIG_FILE" || true)
    CONFIG_VIDEO_CODEC=$(config_value VIDEO_CODEC "$CONFIG_FILE" || true); CONFIG_VIDEO_CODEC=${CONFIG_VIDEO_CODEC,,}""",
"load container config")

    text = repl(text,
"""VIDEO_ENABLED=$(resolve_bool_state "$VIDEO_STATE" "$VIDEO_CONFIG" false)
IMAGE_ENABLED=$(resolve_bool_state "$IMAGE_STATE" "$IMAGE_CONFIG" false)
NESTED_ENABLED=$(resolve_bool_state "$NESTED_STATE" "$NESTED_CONFIG" false)
MC_AUTO_ENABLED=$(resolve_bool_state "$MC_AUTO_STATE" "$CONFIG_MC_AUTO" true)""",
"""VIDEO_ENABLED=$(resolve_bool_state "$VIDEO_STATE" "$VIDEO_CONFIG" true)
IMAGE_ENABLED=$(resolve_bool_state "$IMAGE_STATE" "$IMAGE_CONFIG" true)
NESTED_ENABLED=$(resolve_bool_state "$NESTED_STATE" "$NESTED_CONFIG" true)
CONTAINER_ENABLED=$(resolve_bool_state "$CONTAINER_STATE" "$CONTAINER_CONFIG" true)
MC_AUTO_ENABLED=$(resolve_bool_state "$MC_AUTO_STATE" "$CONFIG_MC_AUTO" true)""",
"default-on transforms")

    text = repl(text,
"""NESTED_COUNT=0
NESTED_PATHS=()
SYMLINK_COUNT=0""",
"""NESTED_COUNT=0
NESTED_PATHS=()
CONTAINER_COUNT=0
SYMLINK_COUNT=0""",
"container counter")

    text = repl(text,
"""is_nested_path() {
    case ${1,,} in *.7z|*.zip|*.rar|*.tar|*.tar.gz|*.tgz|*.tar.bz2|*.tbz|*.tbz2|*.tar.xz|*.txz|*.tar.zst|*.tzst) return 0;; *) return 1;; esac
}

ROOT_DEVICE=''""",
"""is_nested_path() {
    case ${1,,} in *.7z|*.zip|*.rar|*.tar|*.tar.gz|*.tgz|*.tar.bz2|*.tbz|*.tbz2|*.tar.xz|*.txz|*.tar.zst|*.tzst) return 0;; *) return 1;; esac
}
is_container_repack_path() {
    case ${1,,} in *.docx|*.xlsx|*.pptx|*.odt|*.ods|*.odp|*.epub|*.npz|*.whl|*.jar|*.war) return 0;; *) return 1;; esac
}

ROOT_DEVICE=''""",
"container classifier")

    text = repl(text,
"""        elif is_png_path "$path"; then PNG_COUNT=$((PNG_COUNT + 1))
        elif is_nested_path "$path"; then NESTED_COUNT=$((NESTED_COUNT + 1)); NESTED_PATHS+=("$path")
        fi""",
"""        elif is_png_path "$path"; then PNG_COUNT=$((PNG_COUNT + 1))
        elif is_nested_path "$path"; then NESTED_COUNT=$((NESTED_COUNT + 1)); NESTED_PATHS+=("$path")
        elif is_container_repack_path "$path"; then CONTAINER_COUNT=$((CONTAINER_COUNT + 1))
        fi""",
"container scan")

    text = repl(text,
"""VIDEO_RELEVANT=false
IMAGE_RELEVANT=false
NESTED_RELEVANT=false
(( NESTED_COUNT > 0 )) && $NESTED_ENABLED && NESTED_RELEVANT=true
(( VIDEO_COUNT > 0 )) && VIDEO_RELEVANT=true
(( JPEG_COUNT > 0 || PNG_COUNT > 0 )) && IMAGE_RELEVANT=true
# Strict source-specific dependency/capability doctor.
source "$SCRIPT_DIR/lib/hardcore-archive-doctor.sh"

check_strict_runtime_capabilities""",
"""VIDEO_RELEVANT=false
IMAGE_RELEVANT=false
NESTED_RELEVANT=false
CONTAINER_RELEVANT=false
(( NESTED_COUNT > 0 )) && $NESTED_ENABLED && NESTED_RELEVANT=true
(( CONTAINER_COUNT > 0 )) && $CONTAINER_ENABLED && CONTAINER_RELEVANT=true
(( VIDEO_COUNT > 0 )) && VIDEO_RELEVANT=true
(( JPEG_COUNT > 0 || PNG_COUNT > 0 )) && IMAGE_RELEVANT=true
# Strict source-specific dependency/capability doctor.
source "$SCRIPT_DIR/lib/hardcore-archive-doctor.sh"
[[ $CONTAINER_ENABLED == true && $CONTAINER_RELEVANT == true ]] && \
    add_info "Format-preserving container repack: $CONTAINER_COUNT candidate file(s)."

check_strict_runtime_capabilities""",
"container relevance")

    text = repl(text,
"""if [[ $NESTED_ENABLED != true || $NESTED_RELEVANT != true ]]; then NESTED_ENABLED=false; FORWARDED+=(--no-nested-repack); fi

# Preserve CLI opt-in precedence""",
"""if [[ $NESTED_ENABLED != true || $NESTED_RELEVANT != true ]]; then NESTED_ENABLED=false; FORWARDED+=(--no-nested-repack); fi
if [[ $CONTAINER_ENABLED != true || $CONTAINER_RELEVANT != true ]]; then CONTAINER_ENABLED=false; fi

# Preserve CLI opt-in precedence""",
"disable irrelevant containers")

    text = repl(text,
"""export HARDCORE_ARCHIVE_DEPENDENCIES_APPROVED=1
export VIDEO_AUDIO_COPY=$VIDEO_AUDIO_COPY_COMPAT

set +e""",
"""export HARDCORE_ARCHIVE_DEPENDENCIES_APPROVED=1
export VIDEO_AUDIO_COPY=$VIDEO_AUDIO_COPY_COMPAT
export HARDCORE_ARCHIVE_CONTAINER_REPACK=$CONTAINER_ENABLED
export HARDCORE_ARCHIVE_CONTAINER_COUNT=$CONTAINER_COUNT
if [[ $CONTAINER_ENABLED == true && $CONTAINER_RELEVANT == true ]]; then
    printf 'Container policy: format-preserving repack enabled for %s candidate file(s).\\n' "$CONTAINER_COUNT" >&2
fi

set +e""",
"container environment")

    dst.write_text(text, encoding="utf-8")
    os.chmod(dst, 0o700)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
