# Bundled FFmpeg + VMAF runtime

Hardcore Archive release packages should carry a tested media runtime in `runtime/` instead of asking each user to assemble a compatible FFmpeg/libvmaf installation.

The Git repository intentionally does **not** store the built binaries. `versions.env` pins the source inputs; `build.sh` creates the runtime; release packaging copies the resulting `runtime/` directory beside Hardcore Archive.

## Runtime layout

```text
runtime/
  bin/
    ffmpeg
    ffprobe
  lib/
    libvmaf.so*        # Linux
    libvmaf*.dylib     # macOS
  licenses/
    FFmpeg-LICENSE.md
    VMAF-LICENSE
  runtime-manifest.txt
```

At startup `lib/runtime.sh` looks for `runtime/bin` first. In source/development trees it also accepts `runtime/<os>-<arch>/bin`. The selected directory is prepended to `PATH`, so the existing core and doctor use the same FFmpeg and FFprobe without invasive command rewriting.

A source checkout without a bundled runtime may use the host FFmpeg as a development fallback. A packaged release is expected to include `runtime/bin`. `HARDCORE_ARCHIVE_USE_SYSTEM_FFMPEG=1` is an explicit developer/distro-package escape hatch.

## Build

Install the normal C/C++ build toolchain plus `git`, `curl`, `meson`, `ninja`, `pkg-config`, and `make`. Linux release builders should also provide the development packages for the hardware APIs they intend to expose (for example libva/libdrm, nv-codec-headers/ffnvcodec, and oneVPL). Those GPU/device libraries remain host responsibilities; Hardcore Archive does not bundle GPU drivers.

Then run:

```bash
bash packaging/media-runtime/build.sh
```

By default the output is:

```text
dist/media-runtime/runtime/
```

Before publishing it:

```bash
bash packaging/media-runtime/smoke-test.sh dist/media-runtime/runtime
```

The smoke test verifies FFmpeg/FFprobe execution, rejects `--enable-nonfree`, checks that the `libvmaf` filter is exposed, and executes a real one-frame VMAF comparison.

## Reproducibility and cache identity

The runtime manifest records the pinned FFmpeg version, VMAF commit, model policy, target platform/architecture, and runtime revision. At application startup Hardcore Archive hashes that manifest into `HARDCORE_ARCHIVE_VIDEO_RUNTIME_ID`.

This ID is intended to be included anywhere quality/calibration cache identity is formed. A runtime change must not silently inherit a quality boundary measured with a different FFmpeg/VMAF stack.

## Updating versions

Update `versions.env` deliberately. Build and smoke-test every supported release target together. Do not track VMAF `master` dynamically during release builds; the full commit SHA is the source of truth.

Do not add `--enable-nonfree` to the FFmpeg build. The build and smoke-test scripts fail if it appears in FFmpeg's configuration.

The model policy is currently `builtin-default` so bundling the runtime does not silently change Hardcore Archive's existing VMAF threshold semantics. A future model change should be treated as a quality-policy change, with calibration/cache invalidation and benchmark comparison.
