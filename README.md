# llvm-bundle

Static [lld](https://lld.llvm.org), `opt`, `llc` and `llvm-split` builds for [Manuscript](https://github.com/manuscript-lang/manuscript), one per platform (Linux, macOS and Windows on amd64 and arm64). Manuscript's `ms` embeds the `lld` it links programs with, so no C toolchain or SDK is needed; `opt` and `llc` are for LLVM-optimized release builds.

Upstream is patched in one place only: `lld-macho-adrp-add-adr-slot.patch` makes lld's Mach-O `AdrpAdd`/`AdrpLdrGot` linker optimization hint write its `adr` in the `add`'s slot instead of the `adrp`'s, which otherwise clobbers a register the code in between still uses (drop it once llvm/llvm-project fixes this). `build.sh` downloads the pinned upstream LLVM source archive (`llvm-version`), builds it statically (no shared libLLVM, no zlib or zstd) with only the backend for the platform's own architecture (X86 on amd64, AArch64 on arm64) and packs the stripped binaries.

## Releases

A tag `llvm-<version>-r<revision>` publishes, per platform `<os>-<arch>` (`linux`, `darwin`, `windows` × `amd64`, `arm64`):

| Asset | Contents |
| --- | --- |
| `lld-<version>-<os>-<arch>.tar.gz` | `bin/lld` (use `-flavor gnu`, `darwin` or `link`) |
| `llvm-tools-<version>-<os>-<arch>.tar.gz` | `bin/opt`, `bin/llc`, `bin/llvm-link`, `bin/llvm-dis`, `bin/llvm-split` |
| `SHA256SUMS` | the checksum of every asset |

Consumers download a release asset and verify it against a checksum **pinned in their own repository**, never one fetched from the same release. The release notes list the binary and archive sizes.

The revision is bumped when the recipe changes without a version change. Linux binaries are built on Ubuntu 24.04, so they need its glibc or newer.

## Changing the recipe

Edit `build.sh` or `llvm-version` in a pull request: CI builds all six platforms (30 to 60 minutes) without publishing. After merging, push the tag to publish and update the pins in the consumer.

```sh
sh build.sh linux amd64   # needs cmake, ninja, curl, and a C++ toolchain; writes dist/
```
