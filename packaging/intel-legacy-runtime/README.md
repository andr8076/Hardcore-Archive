# Optional Intel Media SDK compatibility runtime

This directory contains a **feasibility-gated**, isolated path for Intel Gen9
systems (notably Skylake/P530) whose HEVC encoder was exposed by the discontinued
Intel Media SDK but is not exposed by current oneVPL/VAAPI.

It is not the normal Hardcore Archive media runtime and it is not selected by
AUTO yet. Production integration is intentionally blocked until the acceptance
test proves a real HEVC encode on the target hardware.

## Why this is separate

Intel archived Media SDK in 2023 and explicitly describes it as unmaintained,
including known security issues that will not receive fixes. It is therefore an
opt-in compatibility component, never a replacement for the current FFmpeg,
oneVPL, libva configuration, or system packages.

The builder:

- pins Intel Media SDK 23.2.2 and FFmpeg 8.1.2 to exact Git commits;
- builds FFmpeg with --enable-libmfx and --disable-libvpl;
- copies the legacy dispatcher and hardware implementation beside that FFmpeg;
- gives the runtime a distinct manifest identity;
- makes no package-manager or system-wide changes.

The wrapper sets INTEL_MEDIA_RUNTIME=MSDK and replaces the library search path
with the private lib directory only for its child process. It never sets
LIBVA_DRIVER_NAME.

## Build

The initial supported build target is Linux x86_64. In a disposable build
environment, provide a C/C++ toolchain, CMake, Git, Make, NASM, pkg-config, and
development headers for libdrm and libva. The script reports missing
dependencies but does not install them.

    bash packaging/intel-legacy-runtime/build.sh

The output is:

    dist/intel-legacy-runtime/runtime/
      bin/ffmpeg
      bin/ffprobe
      lib/libmfx.so.1
      lib/libmfxhw64.so.1
      licenses/
      runtime-manifest.txt

Large binaries are intentionally not committed or downloaded automatically.
Redistribution should not be enabled until licensing, security, supported Linux
versions, and the target-machine evidence have been reviewed.

The manually triggered GitHub workflow builds the same pins in an ephemeral
Ubuntu 22.04 runner and retains the result as a short-lived workflow artifact.
It does not publish a release asset, and it cannot prove GPU capability because
hosted runners do not provide the target P530.

## Inspect isolation

    bash packaging/intel-legacy-runtime/inspect.sh \
      dist/intel-legacy-runtime/runtime

Inspection requires all of the following:

- the manifest identifies the legacy runtime;
- FFmpeg reports --enable-libmfx and not --enable-libvpl;
- its dynamic dependency is libmfx, not libvpl;
- libmfx resolves inside the supplied runtime;
- the legacy libmfxhw64.so.1 implementation exists;
- hevc_qsv is listed.

This only proves runtime integrity. Listing an encoder is not hardware proof.

## Prove capability on the P530

Run this as the normal desktop/service user with access to the Intel render
node. Do not use a container unless the render device and host media driver are
deliberately passed through.

    bash packaging/intel-legacy-runtime/prove-p530.sh \
      --runtime dist/intel-legacy-runtime/runtime \
      --report intel-legacy-p530-report.txt

Success requires a non-empty, five-second HEVC encode and proves through the
dynamic-loader trace that both the private legacy dispatcher and
libmfxhw64.so.1 were loaded, while oneVPL was not. It also checks the codec,
duration, and complete decode; reports VMAF when available; and records
comparison timings for libx265 and libsvtav1 when installed.

If the script fails, the runtime is unusable. Library presence, GPU name, and
the output of ffmpeg -encoders never count as success.

## Production gate

Only after a successful P530 report should a follow-up change add the candidate
to the existing capability-proof architecture. That change must carry a
structured identity (legacy FFmpeg path, runtime ID, encoder, hardware class,
and scoped environment) through calibration, worker subprocesses, nested
archives, quality validation, and final verification.

The intended AUTO order is modern proven hardware, then proven legacy Intel
hardware, then no automatic encoder. Software encoders remain manual-only.
