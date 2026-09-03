# Bundled FFmpeg + VMAF runtime

Hardcore Archive owns a pinned, tested FFmpeg/VMAF runtime so users do not need to assemble a compatible `libvmaf` installation themselves.

The Git repository intentionally does **not** store large generated binaries. GitHub Actions builds the current pinned runtime for each supported platform and publishes it under one rolling release tag: `media-runtime-latest`.

A source checkout downloads that runtime automatically the first time it needs it, verifies the SHA-256 checksum, stores it in the user's cache, and then keeps using that same local copy. It does **not** check GitHub for a newer runtime on every launch. Packaged application releases may place the same runtime directly in `runtime/`, which avoids the first-use download entirely.

## User behavior

Normal users do not need to run the build script.

Runtime selection is:

```text
1. runtime/bin shipped with an application package
2. runtime/<os>-<arch>/bin in a development/package workspace
3. cached Hardcore Archive media runtime
4. download media-runtime-latest once and cache it
5. system FFmpeg only as an offline/development fallback
```

Set:

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

The workflow replaces the contents of the rolling release:

```text
media-runtime-latest
```

Each `.tar.gz` has a companion SHA-256 file. Each platform uploads independently after its smoke test passes, so one unsupported/broken platform does not block working platforms.

The Linux runtime includes pinned `nv-codec-headers`, so FFmpeg exposes NVENC/CUVID support without requiring those development headers on the user's machine. Actual NVIDIA, VAAPI, QSV, and VideoToolbox drivers/device access remain host responsibilities and are verified at runtime.

## Updating a cached runtime

A runtime is intentionally static after first download. Updating the project source does not silently replace the quality toolchain already used for previous calibration.

To deliberately fetch the current rolling runtime again, remove the cached platform runtime and run Hardcore Archive normally. On Linux the cache is under:

```text
~/.cache/hardcore-archive/media-runtime/<platform>/runtime
```

On macOS it is under `~/Library/Caches/hardcore-archive/media-runtime/` unless `XDG_CACHE_HOME` is set.

The newly downloaded runtime has its own manifest-derived `HARDCORE_ARCHIVE_VIDEO_RUNTIME_ID`, so calibration measured with the previous FFmpeg/VMAF toolchain is not silently reused.

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

`versions.env` pins FFmpeg, VMAF, Linux NV codec headers, and the model policy. The runtime manifest records those inputs plus the build target. Hardcore Archive hashes that manifest into `HARDCORE_ARCHIVE_VIDEO_RUNTIME_ID`.

Update the source pins deliberately. The workflow rebuilds `media-runtime-latest`; there is no runtime revision number to maintain.

Do not track upstream branches dynamically during release builds, and do not add `--enable-nonfree` to the FFmpeg build. The build and smoke-test scripts reject such a configuration.

The model policy remains `builtin-default`; a future model change should be treated as a quality-policy change with cache invalidation and benchmark comparison.
