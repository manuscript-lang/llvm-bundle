#!/bin/sh
# Builds the pinned static lld, opt and llc for the host: `sh build.sh <os> <arch>`.
# Writes to dist/, each with a .sha256 beside it:
#   lld-<version>-<os>-<arch>.tar.gz         bin/lld            the linker `ms` embeds (all of ELF, Mach-O, COFF)
#   llvm-tools-<version>-<os>-<arch>.tar.gz  bin/opt, bin/llc   the optimizer and code generator
# The version is the single pin in llvm-version. Everything is linked statically (no libLLVM shared library) and built
# once in CI, then consumed by checksum.
# Set LLVM_WORK to keep the source and build trees somewhere else (default: ./work).
set -eu
os=$1
arch=$2
repository=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
version=$(tr -d '[:space:]' < "$repository/llvm-version")
work=${LLVM_WORK:-$repository/work}
out=$repository/dist
mkdir -p "$work" "$out"
cd "$work"

# llvm's CMake expects the cmake and third-party trees next to the llvm source directory, and lld's Mach-O
# linker includes libunwind's headers from ../libunwind/include.
if [ ! -d llvm ]; then
    base=https://github.com/llvm/llvm-project/releases/download/llvmorg-$version
    for part in llvm lld cmake third-party libunwind; do
        curl --fail --location --retry 3 -sS -o "$part.tar.xz" "$base/$part-$version.src.tar.xz"
        mkdir -p "$part"
        tar -xf "$part.tar.xz" -C "$part" --strip-components=1
        rm "$part.tar.xz"
    done
fi

set -- -G Ninja -S llvm -B build -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_PROJECTS=lld -DLLVM_EXTERNAL_LLD_SOURCE_DIR="$work/lld" \
    "-DLLVM_TARGETS_TO_BUILD=X86;AArch64" \
    -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_ENABLE_PLUGINS=OFF -DLLVM_BUILD_LLVM_DYLIB=OFF \
    -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_LIBPFM=OFF \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_DOCS=OFF -DLLVM_BUILD_TOOLS=OFF -DLLVM_INCLUDE_UTILS=OFF -DLLVM_ENABLE_BINDINGS=OFF
case "$os" in
    darwin)
        osx_arch=x86_64
        [ "$arch" = arm64 ] && osx_arch=arm64
        set -- "$@" -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 "-DCMAKE_OSX_ARCHITECTURES=$osx_arch" ;;
    windows) set -- "$@" -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded ;;
    *) set -- "$@" "-DCMAKE_EXE_LINKER_FLAGS=-static-libstdc++ -static-libgcc" ;;
esac
cmake "$@"
# LLVM_BUILD_TOOLS=OFF keeps the default target small; the three we ship are built by name.
cmake --build build --target lld opt llc

exe=
[ "$os" = windows ] && exe=.exe
stage=$work/stage
rm -rf "$stage"
mkdir -p "$stage/lld/bin" "$stage/tools/bin"
cp "build/bin/lld$exe" "$stage/lld/bin/"
cp "build/bin/opt$exe" "build/bin/llc$exe" "$stage/tools/bin/"
case "$os" in
    windows) ;;
    darwin) strip -x "$stage"/lld/bin/* "$stage"/tools/bin/* ;;
    *) strip --strip-unneeded "$stage"/lld/bin/* "$stage"/tools/bin/* ;;
esac

lld_asset=lld-$version-$os-$arch.tar.gz
tools_asset=llvm-tools-$version-$os-$arch.tar.gz
tar -czf "$out/$lld_asset" -C "$stage/lld" "bin"
tar -czf "$out/$tools_asset" -C "$stage/tools" "bin"
(
    cd "$out"
    for f in "$lld_asset" "$tools_asset"; do
        if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f" > "$f.sha256"; else shasum -a 256 "$f" > "$f.sha256"; fi
    done
)
echo "sizes (bytes, stripped binaries then archives):"
wc -c "$stage"/lld/bin/* "$stage"/tools/bin/* "$out/$lld_asset" "$out/$tools_asset"
