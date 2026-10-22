# llvm-bundle

Static [lld](https://lld.llvm.org), `opt` and `llc` builds for [Manuscript](https://github.com/manuscript-lang/manuscript), one per platform (Linux, macOS and Windows on amd64 and arm64). Manuscript's `ms` embeds the `lld` it links programs with, so no C toolchain or SDK is needed; `opt` and `llc` are for LLVM-optimized release builds.

Nothing here is patched: `build.sh` downloads the pinned upstream LLVM source (`llvm-version`), builds it statically (no shared libLLVM, no zlib or zstd) and packs the stripped binaries.

## Releases

A tag `llvm-<version>-r<revision>` publishes, per platform `<os>-<arch>` (`linux`, `darwin`, `windows` × `amd64`, `arm64`):

| Asset | Contents |
| --- | --- |
| `lld-<version>-<os>-<arch>.tar.gz` | `bin/lld` (use `-flavor gnu`, `darwin` or `link`) |
| `llvm-tools-<version>-<os>-<arch>.tar.gz` | `bin/opt`, `bin/llc` |
| `SHA256SUMS` | the checksum of every asset |

Consumers download a release asset and verify it against a checksum **pinned in their own repository**, never one fetched from the same release. The release notes list the binary and archive sizes.

The revision is bumped when the recipe changes without a version change. Linux binaries are fully static (`build.sh` fails if one is dynamically linked), so they run on glibc and musl hosts alike.

## Changing the recipe

Edit `build.sh` or `llvm-version` in a pull request: CI builds all six platforms (30 to 60 minutes) without publishing. After merging, push the tag to publish and update the pins in the consumer.

```sh
sh build.sh linux amd64   # needs cmake, ninja, curl, and a C++ toolchain; writes dist/
```
