# Bundled FFmpeg + VMAF runtime

Hardcore Archive owns a pinned, tested FFmpeg/VMAF runtime so users do not need to assemble a compatible `libvmaf` installation themselves.

The Git repository intentionally does **not** store large generated binaries. Instead, GitHub Actions builds the pinned runtime for each supported platform and publishes it under the rolling release tag for the current runtime revision. Source checkouts fetch that prebuilt runtime automatically on first use and cache it locally. Packaged application releases may place the same runtime directly in `runtime/`, which avoids the first-use download.

## User behavior

Normal users do not need to run the build script.

Runtime selection is:

```text
1. runtime/bin shipped with an application package
2. runtime/<os>-<arch>/bin in a development/package workspace
3. cached pinned Hardcore Archive media runtime
4. automatically download the pinned runtime from this repository
5. system FFmpeg only as an offline/development fallback
```

The automatic download is cached by runtime revision and target platform. Set:

```bash
HARDCORE_ARCHIVE_AUTO_RUNTIME=0
```

to disable automatic fetching, or:

```bash
HARDCORE_ARCHIVE_USE_SYSTEM_FFMPEG=1
```

to explicitly force the host FFmpeg/FFprobe.

The strict doctor still performs a real VMAF execution and hardware encoder probe. A downloaded FFmpeg that cannot actually use the required host GPU/driver capability therefore fails closed rather than silently changing policy.

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

The selected directory is prepended to `PATH`, and its `lib/` directory is added to the platform library search path. The existing core and doctor therefore use the same FFmpeg and FFprobe without command rewriting.

## Automatic builds

`.github/workflows/media-runtime.yml` builds and smoke-tests the runtime for:

```text
linux-x86_64
linux-arm64
macos-x86_64
macos-arm64
```

It publishes assets under:

```text
media-runtime-r<revision>
```

Each `.tar.gz` has a companion SHA-256 file. The source-checkout bootstrap verifies that checksum before activating the downloaded executables.

The Linux runtime includes pinned `nv-codec-headers`, so FFmpeg exposes NVENC/CUVID support without requiring those development headers on the user's machine. Actual NVIDIA, VAAPI, QSV, and VideoToolbox drivers/device access remain host responsibilities and are verified at runtime.

## Building manually

Manual building is primarily for release development or debugging. Install the normal C/C++ build toolchain plus `git`, `curl`, `meson`, `ninja`, `pkg-config`, and `make`. Linux release builders should also provide development packages for libva/libdrm and oneVPL when those APIs should be exposed.

Then run:

```bash
bash packaging/media-runtime/build.sh
bash packaging/media-runtime/smoke-test.sh dist/media-runtime/runtime
```

The output is:

```text
dist/media-runtime/runtime/
```

## Reproducibility and cache identity

`versions.env` pins FFmpeg, VMAF, Linux NV codec headers, the model policy, and the media-runtime revision. The runtime manifest records those inputs plus the build target. Hardcore Archive hashes that manifest into `HARDCORE_ARCHIVE_VIDEO_RUNTIME_ID`.

The runtime ID is included in calibration identity, so changing FFmpeg/VMAF cannot silently reuse a quality boundary measured with another toolchain.

Update `versions.env` deliberately and increment `HCA_MEDIA_RUNTIME_REVISION` whenever the published runtime changes. Do not track upstream branches dynamically during release builds.

Do not add `--enable-nonfree` to the FFmpeg build. The build and smoke-test scripts reject such a configuration.

The model policy remains `builtin-default`; a future model change should be treated as a quality-policy change with cache invalidation and benchmark comparison.
