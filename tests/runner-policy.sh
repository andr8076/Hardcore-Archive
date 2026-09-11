#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

FRONTEND=${FRONTEND:-/tmp/hardcore-archive-root.sh}
DOCTOR_LOADER=${DOCTOR_LOADER:-/tmp/hardcore-archive-doctor-loader.sh}
DOCTOR_BASE=${DOCTOR_BASE:-/tmp/hardcore-archive-doctor-base.sh}
DOCTOR_CHECKS=${DOCTOR_CHECKS:-/tmp/hardcore-archive-doctor-checks.sh}
DOCTOR_REPORT=${DOCTOR_REPORT:-/tmp/hardcore-archive-doctor-report.sh}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-archive-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/app/lib" "$TMP/home/.config/hardcore-archive" "$TMP/bin" "$TMP/source" "$TMP/docs" "$TMP/png"
cp "$FRONTEND" "$TMP/app/hardcore-archive.sh"
cp "$DOCTOR_LOADER" "$TMP/app/lib/hardcore-archive-doctor.sh"
cp "$DOCTOR_BASE" "$TMP/app/lib/hardcore-archive-doctor-base.sh"
cp "$DOCTOR_CHECKS" "$TMP/app/lib/hardcore-archive-doctor-checks.sh"
cp "$DOCTOR_REPORT" "$TMP/app/lib/hardcore-archive-doctor-report.sh"
cp "$(dirname -- "$DOCTOR_LOADER")/runtime.sh" "$TMP/app/lib/runtime.sh"
for module in \
    video-encoder-capabilities.sh \
    hardcore-archive-doctor-video-fix.sh \
    hardcore-archive-doctor-video-auto.sh \
    hardcore-archive-doctor-encoder-menu.sh \
    hardcore-archive-doctor-encoder-runtime.sh \
    intel-legacy-video.sh \
    hardcore-archive-doctor-intel-legacy.sh
do
    sibling="$(dirname -- "$DOCTOR_LOADER")/$module"
    [[ -f $sibling ]] && cp "$sibling" "$TMP/app/lib/$module"
done

cat > "$TMP/app/lib/hardcore-archive-core.sh" <<'FAKE_CORE'
printf 'VIDEO_AUDIO_COPY=%s\n' "${VIDEO_AUDIO_COPY-unset}"
printf 'DEP_APPROVED=%s\n' "${HARDCORE_ARCHIVE_DEPENDENCIES_APPROVED-unset}"
printf 'ARG=%s\n' "$@"
FAKE_CORE

cat > "$TMP/bin/7zz" <<'EOF_TOOL'
#!/usr/bin/env bash
[[ ${1:-} == i ]] && exit 0
exit 0
EOF_TOOL
cat > "$TMP/bin/getfacl" <<'EOF_TOOL'
#!/usr/bin/env bash
[[ ${1:-} == --version ]] && exit 0
exit 0
EOF_TOOL
cat > "$TMP/bin/systemd-inhibit" <<'EOF_TOOL'
#!/usr/bin/env bash
[[ ${1:-} == --list ]] && exit 0
exit 0
EOF_TOOL
cat > "$TMP/bin/findmnt" <<'EOF_TOOL'
#!/usr/bin/env bash
[[ ${1:-} == --version ]] && exit 0
exit 0
EOF_TOOL
cat > "$TMP/bin/lsblk" <<'EOF_TOOL'
#!/usr/bin/env bash
[[ ${1:-} == --version ]] && exit 0
exit 0
EOF_TOOL
cat > "$TMP/bin/setsid" <<'EOF_TOOL'
#!/usr/bin/env bash
[[ ${1:-} == --version ]] && exit 0
exit 0
EOF_TOOL
cat > "$TMP/bin/jpegtran" <<'EOF_TOOL'
#!/usr/bin/env bash
[[ ${1:-} == -version ]] && exit 0
exit 0
EOF_TOOL
cat > "$TMP/bin/djpeg" <<'EOF_TOOL'
#!/usr/bin/env bash
[[ ${1:-} == -version ]] && exit 0
exit 0
EOF_TOOL
cat > "$TMP/bin/oxipng" <<'EOF_TOOL'
#!/usr/bin/env bash
[[ ${1:-} == --version ]] && exit 0
exit 0
EOF_TOOL
cat > "$TMP/bin/ffmpeg" <<'EOF_TOOL'
#!/usr/bin/env bash
if [[ " $* " == *" -version "* ]]; then echo 'ffmpeg fake'; exit 0; fi
if [[ " $* " == *" -buildconf "* ]]; then echo '--enable-libvmaf'; exit 0; fi
if [[ " $* " == *" -encoders "* ]]; then
    cat <<'OUT'
 V..... av1_vaapi AV1
 V..... hevc_vaapi HEVC
 V..... libx265 HEVC software
OUT
    if [[ (${FAKE_NO_LIBSVTAV1:-0} != 1 || ${0##*/} != ffmpeg) &&
          (${FAKE_NO_SYSTEM_LIBSVTAV1:-0} != 1 || ${0##*/} != system-ffmpeg) ]]; then
        printf ' V..... libsvtav1 AV1 software\n'
    fi
    exit 0
fi
if [[ " $* " == *" -filters "* ]]; then
    if [[ ${FAKE_NO_VMAF:-0} != 1 ]]; then echo ' ... libvmaf V->V'; fi
    echo ' ... ssim VV->V'
    exit 0
fi
if [[ ${FAKE_HW_BROKEN:-0} == 1 && " $* " == *"_vaapi "* ]]; then echo 'device initialization failed' >&2; exit 1; fi
if [[ ${FAKE_CPU_BROKEN:-0} == 1 && ( " $* " == *" libsvtav1 "* || " $* " == *" libx265 "* ) ]]; then echo 'software encoder failed' >&2; exit 1; fi
if [[ ${FAKE_AV1_INCOMPAT:-0} == 1 && " $* " == *" av1_vaapi "* ]]; then echo 'device does not support AV1' >&2; exit 1; fi
last=${!#}
if [[ $last != - ]]; then
    if [[ " $* " == *" av1_vaapi "* || " $* " == *" libsvtav1 "* ]]; then printf 'av1\n' > "$last"; else printf 'hevc\n' > "$last"; fi
fi
exit 0
EOF_TOOL
cat > "$TMP/bin/ffprobe" <<'EOF_TOOL'
#!/usr/bin/env bash
if [[ " $* " == *" -version "* ]]; then echo 'ffprobe fake'; exit 0; fi
last=${!#}
cat -- "$last"
EOF_TOOL
chmod +x "$TMP/bin"/*
cp "$TMP/bin/ffmpeg" "$TMP/bin/system-ffmpeg"

: > "$TMP/source/movie.mp4"
: > "$TMP/source/photo.jpg"
: > "$TMP/source/image.png"
: > "$TMP/source/stuff.zip"
: > "$TMP/docs/readme.txt"
: > "$TMP/png/image.png"

run_frontend() {
    HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" PATH="$TMP/bin:$PATH" \
    HARDCORE_ARCHIVE_USE_SYSTEM_FFMPEG=1 \
    HARDCORE_ARCHIVE_SYSTEM_FFMPEG="$TMP/bin/system-ffmpeg" \
    HARDCORE_ARCHIVE_PACKAGE_MANAGER=pacman \
        bash "$TMP/app/hardcore-archive.sh" "$@"
}

assert_has() { local out=$1 text=$2; grep -Fqx -- "$text" <<< "$out" || { printf 'Expected line not found: %s\n%s\n' "$text" "$out" >&2; exit 1; }; }
assert_contains() { local out=$1 text=$2; grep -Fq -- "$text" <<< "$out" || { printf 'Expected text not found: %s\n%s\n' "$text" "$out" >&2; exit 1; }; }
assert_lacks() { local out=$1 text=$2; ! grep -Fqx -- "$text" <<< "$out" || { printf 'Unexpected line: %s\n%s\n' "$text" "$out" >&2; exit 1; }; }

# Explicitly disabled transformations do not require their optional tools.
for tool in ffmpeg ffprobe jpegtran djpeg oxipng setsid; do mv "$TMP/bin/$tool" "$TMP/bin/$tool.off"; done
out=$(run_frontend --no-video-transcode --no-image-optimize --no-nested-repack --no-container-repack "$TMP/source" 2>&1)
assert_has "$out" 'ARG=--no-video-transcode'
assert_has "$out" 'ARG=--no-image-optimize'
assert_has "$out" 'ARG=--no-nested-repack'
assert_has "$out" 'DEP_APPROVED=1'
for tool in ffmpeg ffprobe jpegtran djpeg oxipng setsid; do mv "$TMP/bin/$tool.off" "$TMP/bin/$tool"; done

# The documented short yes flag is an option, not the source positional.
out=$(run_frontend -y --no-video-transcode --no-image-optimize --no-nested-repack --no-container-repack "$TMP/docs" 2>&1)
assert_has "$out" 'ARG=-y'
assert_has "$out" "ARG=$TMP/docs"

# Safe transformations are enabled by default and are forwarded to the static
# engine after dependency and hardware validation.
out=$(run_frontend "$TMP/source" 2>&1)
assert_has "$out" 'ARG=av1_vaapi'
assert_contains "$out" 'Automatic video competition: AV1 (av1_vaapi) vs HEVC (hevc_vaapi) per file.'
assert_contains "$out" 'Self-check: READY for this source'

# A configured feature with no matching content is disabled before dependency checks.
# The frontend-only auto codec must also be translated to a neutral concrete
# core value, otherwise the static core rejects VIDEO_CODEC=auto before it sees
# that video transcoding is disabled.
mv "$TMP/bin/ffmpeg" "$TMP/bin/ffmpeg.off"
printf 'VIDEO_TRANSCODE=true\n' > "$TMP/home/.config/hardcore-archive/config"
out=$(run_frontend "$TMP/docs" 2>&1)
assert_has "$out" 'ARG=--no-video-transcode'
assert_has "$out" 'ARG=--video-codec'
assert_has "$out" 'ARG=av1'
mv "$TMP/bin/ffmpeg.off" "$TMP/bin/ffmpeg"

# Hardware AV1 is forced when video work is actually needed.
: > "$TMP/home/.config/hardcore-archive/config"
out=$(run_frontend --video-transcode "$TMP/source" 2>&1)
assert_has "$out" 'ARG=--video-encoder'
assert_has "$out" 'ARG=av1_vaapi'
assert_has "$out" 'ARG=--video-parallel'
assert_contains "$out" 'Hardware video policy: AUTO; AV1=av1_vaapi; HEVC=hevc_vaapi; primary=AV1 via av1_vaapi'

# Automatic discovery excludes an unusable AV1 candidate and uses working HEVC
# without a user-supplied codec setting. The probe reason remains diagnostic.
out=$(FAKE_AV1_INCOMPAT=1 run_frontend --video-transcode "$TMP/source" 2>&1)
assert_contains "$out" 'Automatic video candidate excluded after runtime probe: AV1'
assert_contains "$out" 'Hardware video policy: AUTO; AV1=unavailable; HEVC=hevc_vaapi; primary=HEVC via hevc_vaapi'
assert_has "$out" 'ARG=hevc'
assert_has "$out" 'ARG=hevc_vaapi'
assert_has "$out" 'DEP_APPROVED=1'

# If neither hardware candidate works, automatic mode still blocks creation.
set +e
out=$(FAKE_HW_BROKEN=1 run_frontend --video-transcode "$TMP/source" 2>&1); rc=$?
set -e
(( rc == 3 )) || { printf 'All failed auto-codec candidates must fail doctor.\n%s\n' "$out" >&2; exit 1; }
assert_contains "$out" 'No automatic hardware candidate passed its runtime probe'
assert_contains "$out" 'Manual software encoders are available but are never automatic'

# Explicit AV1 codec mode retains its existing HEVC compatibility fallback.
out=$(FAKE_AV1_INCOMPAT=1 run_frontend --video-transcode --video-codec av1 "$TMP/source" 2>&1)
assert_has "$out" 'ARG=hevc'
assert_has "$out" 'ARG=hevc_vaapi'
assert_contains "$out" 'GPU cannot encode AV1; using the only permitted fallback: HEVC via hevc_vaapi.'

# Missing required image capability is a hard failure with informational package
# guidance, never an executable repair command.
mv "$TMP/bin/oxipng" "$TMP/bin/oxipng.off"
set +e
out=$(run_frontend --image-optimize "$TMP/png" 2>&1); rc=$?
set -e
(( rc == 3 )) || { printf 'Expected doctor failure rc=3, got %s\n%s\n' "$rc" "$out" >&2; exit 1; }
assert_contains "$out" 'MISSING'
assert_contains "$out" 'PNG optimizer'
assert_contains "$out" 'Suggested package names (informational only; verify for your system):'
assert_contains "$out" 'Package family detected: pacman'
assert_contains "$out" 'oxipng'
assert_lacks "$out" 'sudo '
mv "$TMP/bin/oxipng.off" "$TMP/bin/oxipng"

# Installed FFmpeg without required libvmaf is UNSUPPORTED, not silently downgraded to SSIM.
set +e
out=$(FAKE_NO_VMAF=1 run_frontend --video-transcode "$TMP/source" 2>&1); rc=$?
set -e
(( rc == 3 )) || { printf 'Expected unsupported failure.\n%s\n' "$out" >&2; exit 1; }
assert_contains "$out" 'UNSUPPORTED'
assert_contains "$out" 'FFmpeg libvmaf filter'
assert_contains "$out" 'comparing codecs without a common quality measurement is forbidden.'

# Advertised hardware encoder that cannot actually run is BROKEN.
set +e
out=$(FAKE_HW_BROKEN=1 run_frontend --video-transcode --video-codec av1 --quality-check off "$TMP/source" 2>&1); rc=$?
set -e
(( rc == 3 )) || { printf 'Expected broken hardware failure.\n%s\n' "$out" >&2; exit 1; }
assert_contains "$out" 'BROKEN'
assert_contains "$out" 'Hardware AV1 encode'

# Explicit doctor scans the target, prints only relevant active work, and never invokes the core.
out=$(run_frontend --doctor --image-optimize "$TMP/png" 2>&1)
assert_contains "$out" 'Hardcore Archive doctor'
assert_contains "$out" '1 PNG'
assert_contains "$out" 'Active work: archive + image'
assert_contains "$out" 'Result: READY.'
if grep -Fq 'ARG=' <<< "$out"; then printf 'Doctor unexpectedly invoked core.\n%s\n' "$out" >&2; exit 1; fi

# Existing precedence and compatibility behavior remains intact.
printf 'VIDEO_TRANSCODE=false\nIMAGE_OPTIMIZE=false\nNESTED_REPACK=false\n' > "$TMP/home/.config/hardcore-archive/config"
out=$(run_frontend --video-transcode --image-optimize --nested-repack "$TMP/source" 2>&1)
assert_has "$out" 'ARG=--config'
assert_has "$out" 'ARG=av1_vaapi'
out=$(run_frontend --video-transcode --no-video-transcode "$TMP/source" 2>&1)
assert_has "$out" 'ARG=--no-video-transcode'
out=$(run_frontend --video-transcode --video-copy-audio "$TMP/source" 2>&1)
assert_has "$out" 'VIDEO_AUDIO_COPY=true'
out=$(run_frontend --video-special-policy preserve "$TMP/source" 2>&1)
assert_has "$out" 'ARG=--video-special-policy'
assert_has "$out" 'ARG=preserve'

# Proven CPU encoders are valid only after explicit selection and are routed
# sequentially. AUTO above still failed instead of selecting either one.
out=$(run_frontend --video-transcode --video-encoder libsvtav1 "$TMP/source" 2>&1)
assert_has "$out" 'ARG=libsvtav1'
assert_has "$out" 'ARG=--video-sequential'
assert_contains "$out" 'Manual software video policy: AV1 via libsvtav1'
assert_contains "$out" 'AUTO remains hardware-only'

out=$(run_frontend --video-transcode --video-encoder libx265 "$TMP/source" 2>&1)
assert_has "$out" 'ARG=libx265'
assert_has "$out" 'ARG=hevc'

# The managed/default FFmpeg may omit an optional CPU encoder while the saved
# pre-activation host FFmpeg provides it. Selection retains that distinct path.
out=$(FAKE_NO_LIBSVTAV1=1 run_frontend --video-transcode --video-encoder libsvtav1 "$TMP/source" 2>&1)
assert_has "$out" 'ARG=libsvtav1'
assert_contains "$out" 'Manual software video policy: AV1 via libsvtav1'

set +e
out=$(FAKE_CPU_BROKEN=1 run_frontend --video-transcode --video-encoder libsvtav1 "$TMP/source" 2>&1); rc=$?
set -e
(( rc == 3 )) || { printf 'Broken explicit software encoder must fail doctor.\n%s\n' "$out" >&2; exit 1; }
assert_contains "$out" 'did not pass its runtime capability probe'

set +e
out=$(FAKE_NO_LIBSVTAV1=1 FAKE_NO_SYSTEM_LIBSVTAV1=1 run_frontend --video-transcode --video-encoder libsvtav1 "$TMP/source" 2>&1); rc=$?
set -e
(( rc == 3 )) || { printf 'Unavailable explicit software encoder must fail doctor.\n%s\n' "$out" >&2; exit 1; }
assert_contains "$out" 'No available FFmpeg runtime advertises the supported encoder'
assert_lacks "$out" 'ARG=libx265'

printf 'Frontend + doctor policy tests passed.\n'
