# Portable tools runtime

This package supplies the ordinary command-line dependencies used by Hardcore
Archive: modern Bash and Python, GNU core/find/text tools, 7-Zip, libjpeg-turbo,
OxiPNG, libmagic, and the Linux filesystem utilities. The media runtime remains
a separately built pinned FFmpeg/VMAF input and is merged into the final
portable release.

The CI workflow creates a version-constrained conda-forge environment, records its exact explicit
package specification, copies it into `runtime/`, moves it to an unrelated path,
and runs `smoke-test.sh`. That relocation test prevents a build-prefix-dependent
environment from being published.

For a manual build, prepare the same dependencies in a prefix and run:

```bash
HCA_TOOLS_PREFIX=/path/to/prefix \
HCA_TOOLS_TARGET=linux-x86_64 \
bash packaging/tools-runtime/build.sh
```
