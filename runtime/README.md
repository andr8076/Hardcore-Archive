# Bundled media runtime

Release packages may place a tested FFmpeg/VMAF toolchain here without committing large binaries to Git.

Expected layout:

```text
runtime/
  linux-x86_64/
    bin/ffmpeg
    bin/ffprobe
    lib/libvmaf.so...
    share/vmaf/model/...
    runtime-id
    manifest.txt
  macos-arm64/
    ...
```

At startup Hardcore Archive prefers the matching bundled runtime. Source checkouts fall back to the system FFmpeg when no matching runtime is present.

Selection can be controlled with environment variables:

```text
HARDCORE_MEDIA_RUNTIME=auto      bundled when present, otherwise system (default)
HARDCORE_MEDIA_RUNTIME=bundled   require the bundled runtime
HARDCORE_MEDIA_RUNTIME=system    force the system FFmpeg
HARDCORE_FFMPEG_DIR=/path        use a custom runtime containing ffmpeg/ffprobe
```

`HARDCORE_FFMPEG_DIR` may point either to a runtime root containing `bin/ffmpeg` and `bin/ffprobe`, or directly to a directory containing those two executables.

Runtime binaries belong in generated release artifacts, not repository history.
