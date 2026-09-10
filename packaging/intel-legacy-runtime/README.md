# Optional Intel Media SDK compatibility runtime

This directory contains a **capability-gated**, isolated path for Intel Gen9
systems (notably Skylake/P530) whose HEVC encoder was exposed by the discontinued
Intel Media SDK but is not exposed by current oneVPL/VAAPI.

It is not the normal Hardcore Archive media runtime. Modern working hardware is
always preferred. The compatibility candidate becomes eligible for AUTO only
after its own bounded HEVC encode, codec check, and full-decode check succeed.

## Why this is separate

Intel archived Media SDK in 2023 and explicitly describes it as unmaintained,
including known security issues that will not receive fixes. It is therefore an
isolated compatibility component, never a replacement for the current FFmpeg,
oneVPL, libva configuration, or system packages.

The builder:

- pins Intel Media SDK 23.2.2 and FFmpeg 8.1.2 to exact Git commits;
- builds FFmpeg with --enable-libmfx and --disable-libvpl;
- applies one auditable compatibility patch that omits extended QSV coding
  options rejected by the Skylake HEVC implementation;
- copies the legacy dispatcher and hardware implementation beside that FFmpeg;
- gives the runtime a distinct manifest identity;
- makes no package-manager or system-wide changes.

The production wrapper sets `INTEL_MEDIA_RUNTIME=MSDK`, the private library
path, and the isolated full-feature iHD driver only for each compatibility
FFmpeg child process. It does not alter the parent environment or global libva
configuration.

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
      lib/dri/iHD_drv_video.so  # externally supplied; see below
      licenses/
      runtime-manifest.txt

Large binaries are not committed. A pinned, checksum-protected compatibility
runtime is published on the separate `intel-legacy-runtime-latest` prerelease
channel. On a relevant Intel/i915 host, a source checkout downloads it once into
the user's cache only after all modern hardware candidates fail. It remains
static until that cache is removed.

The full-feature `iHD_drv_video.so` is also required on Skylake. The free-kernel
Ubuntu/Debian driver can expose HEVC decode without HEVC encode. Hardcore
Archive does not install or redistribute the non-free driver. On Debian-family
systems its first-use setup asks the configured package manager to download
`intel-media-va-driver-non-free`, extracts the package into the same private
cache, and records its version and driver hash. No `sudo`, package installation,
or global libva setting is used. Manual placement at
`runtime/lib/dri/iHD_drv_video.so` and
`HARDCORE_ARCHIVE_INTEL_LEGACY_VA_DRIVER_DIR` remain supported.

The GitHub workflow builds the same pins in an ephemeral Ubuntu 22.04 runner,
inspects isolation, and publishes an immutable commit-addressed archive plus a
small rolling pointer. It does not include the Full Feature driver and cannot
prove GPU capability because hosted runners do not provide the target P530.

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
      --va-driver-dir /path/to/extracted/usr/lib/x86_64-linux-gnu/dri \
      --report intel-legacy-p530-report.txt

Omit `--va-driver-dir` when the full-feature driver has already been placed at
`runtime/lib/dri/iHD_drv_video.so`.

Success requires a non-empty, five-second HEVC encode. The runtime inspector
proves that FFmpeg resolves the private legacy libmfx dispatcher and excludes
oneVPL; the encode log must additionally report an Intel Media SDK session using
a hardware-accelerated implementation. The test also checks the codec, duration,
and complete decode; reports VMAF when available; and records comparison timings
for libx265 and libsvtav1 when installed.

The acceptance encode intentionally avoids the dynamic loader's LD_DEBUG mode.
That diagnostic mode can deadlock the discontinued Media SDK dispatcher on the
target P530 system and is therefore not a valid capability-test environment.

The tested legacy HEVC arguments explicitly disable QSV low-power mode. That
mode is not exposed by the Skylake/P530 Media SDK implementation and must not be
inherited from modern QSV defaults.

If the script fails, the runtime is unusable. Library presence, GPU name, and
the output of ffmpeg -encoders never count as success.

Runtime format 2 is required for the P530 test. Format 1 proved isolation but
still allowed FFmpeg's API-version heuristic to send extended HEVC options that
the Skylake implementation rejects. Rebuild or download a new artifact when
upgrading from format 1.

## Proven P530 result

On the target Intel HD Graphics P530, the isolated FFmpeg 8.1.2 / Media SDK
23.2.2 runtime completed 150 HEVC frames and modern FFmpeg verified a five-second
duration and full decode. The successful run required the Ubuntu 24.1.0
full-feature iHD driver supplied from `intel-media-va-driver-non-free`; the
same-version free-kernel driver advertised HEVC decoding only. The synthetic
encode ran at approximately 9x real time. VMAF and CPU comparisons were not
available in that host FFmpeg build, so this number is a capability/performance
diagnostic rather than a quality comparison.

## Production use

Normal `VIDEO_CODEC=auto` operation needs no legacy-specific command. The flow
is modern hardware probe, relevant Intel/i915 detection, private first-use setup,
real legacy HEVC probe, then selection. If download, extraction, isolation, or
encoding fails, the candidate is excluded and AUTO does not fall back to CPU.

Automatic setup can be disabled without disabling the normal media runtime:

    export HARDCORE_ARCHIVE_INTEL_LEGACY_AUTO_SETUP=0

The following manual paths remain useful for offline or controlled deployments.

Place the compatibility runtime in either of these locations:

    runtime/intel-legacy/
    runtime/linux-x86_64/intel-legacy/

Alternatively, point to it explicitly:

    export HARDCORE_ARCHIVE_INTEL_LEGACY_RUNTIME=/absolute/path/to/runtime
    export HARDCORE_ARCHIVE_INTEL_LEGACY_VA_DRIVER_DIR=/absolute/path/to/extracted/driver/dri
    bash hardcore-archive.sh --doctor "/data/My folder"

If the driver is copied into the runtime's `lib/dri` directory, only the first
environment variable is needed for a nonstandard runtime location. These
variables identify resources; the loader variables derived from them are set
only on legacy FFmpeg child processes.

AUTO order is modern proven hardware, then proven legacy Intel HEVC hardware,
then no automatic encoder. CPU encoders remain manual-only. Every application
start probes the candidate with a real HEVC encode. A missing, changed, broken,
wrongly linked, empty-output, wrong-codec, or undecodable runtime fails closed.
Calibration, production encoding, worker and nested-archive subprocesses retain
the runtime identity; VMAF and final decode checks continue using the modern
media toolchain.
