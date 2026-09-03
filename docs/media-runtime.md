# Versioned FFmpeg/VMAF runtime

Hardcore Archive release packages are designed to carry their own tested media-quality toolchain instead of requiring every user to assemble a compatible FFmpeg + libvmaf installation.

## Why this exists

Video acceptance is a data-loss decision: a source may be replaced by a smaller lossy representation only when the candidate passes the configured quality floor and savings policy. That makes the FFmpeg/VMAF implementation part of the archive policy, not merely an incidental dependency.

A release runtime therefore pins:

- FFmpeg;
- libvmaf;
- the VMAF model files shipped with that libvmaf release;
- the build revision used by Hardcore Archive.

The build adds the VMAF/runtime revision to FFmpeg's `--extra-version`. Existing calibration keys already include `ffmpeg -version`, so changing the bundled quality stack invalidates stale calibration records automatically.

## Runtime selection

Default selection is:

```text
explicit HARDCORE_FFMPEG_DIR
        ↓
matching runtime/<platform>-<arch>
        ↓
system ffmpeg/ffprobe
```

The source checkout remains convenient for development because it can use the host tools. Published release packages should contain the matching runtime and therefore take the deterministic bundled path automatically.

Environment controls:

```text
HARDCORE_MEDIA_RUNTIME=auto       default
HARDCORE_MEDIA_RUNTIME=bundled    require a bundled runtime
HARDCORE_MEDIA_RUNTIME=system     deliberately use the host FFmpeg
HARDCORE_FFMPEG_DIR=/path         explicit custom runtime override
```

A partially present bundled runtime is treated as broken instead of silently falling back to the host. This prevents a damaged release package from changing quality behavior unnoticed.

## Host/runtime boundary

Bundled by Hardcore Archive:

- `ffmpeg`;
- `ffprobe`;
- `libvmaf`;
- VMAF model files;
- license texts and a runtime manifest.

Provided by the host:

- Linux/macOS kernel facilities;
- GPU drivers and device nodes;
- VAAPI/NVIDIA/VideoToolbox runtime interfaces needed by the machine's hardware.

This keeps GPU-driver ownership with the operating system while making VMAF availability and the FFmpeg/VMAF pairing deterministic.

## Runtime identity

Every generated runtime contains a one-line `runtime-id`, for example:

```text
hca-media-ffmpeg-9.0.1-vmaf-3.2.0-opus-1.5.2-r1
```

The same revision is embedded into FFmpeg's version string. Run logs print the selected runtime source and ID so a quality result can be traced back to its toolchain.

## Building

`packaging/build-media-runtime.sh` builds a runtime into the repository's `runtime/<platform>-<arch>/` directory by default. It uses pinned upstream versions, builds libvmaf locally, builds libopus for the FFmpeg audio path, builds FFmpeg against that local stack, rejects `--enable-nonfree`, runs a real libvmaf smoke test, copies VMAF models/licenses, and writes checksums to `manifest.txt`.

Large generated binaries are intentionally not committed. CI/release jobs build them into release artifacts.

## Release policy

When updating FFmpeg or VMAF:

1. change the pinned version in the runtime build script;
2. increment the runtime revision;
3. build each supported release target;
4. require the VMAF smoke test and normal Hardcore Archive tests to pass;
5. publish new release artifacts rather than replacing binaries in an existing release.

Never enable FFmpeg's `--enable-nonfree` in a distributed Hardcore Archive runtime.
