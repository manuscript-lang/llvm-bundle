#!/bin/sh
# Builds the pinned static lld, opt, llc and llvm-split for the host: `sh build.sh <os> <arch>`.
# Writes to dist/, each with a .sha256 beside it:
#   lld-<version>-<os>-<arch>.tar.gz         bin/lld            the linker `ms` embeds (all of ELF, Mach-O, COFF)
#   llvm-tools-<version>-<os>-<arch>.tar.gz  bin/opt, bin/llc, bin/llvm-link, bin/llvm-dis, bin/llvm-split, bin/llvm-extract, bin/llvm-reduce   the optimizer, code generator, bitcode linker, disassembler, module splitter, function extractor and IR reducer
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
    # Releases from 22 on publish only the monolithic source archive; its top-level directories are the same trees.
    curl --fail --location --retry 3 -sS -o src.tar.xz \
        "https://github.com/llvm/llvm-project/releases/download/llvmorg-$version/llvm-project-$version.src.tar.xz"
    tar -xf src.tar.xz --strip-components=1 --exclude=mlgo-utils llvm-project-"$version".src/llvm llvm-project-"$version".src/lld \
        llvm-project-"$version".src/cmake llvm-project-"$version".src/third-party llvm-project-"$version".src/libunwind llvm-project-"$version".src/libc
    rm src.tar.xz
fi

# Each platform's tools generate code only for the machine they run on (`ms` has no cross-target builds), so only that
# backend is built; the other roughly halves the code generator.
case "$arch" in
    arm64) target=AArch64 ;;
    *) target=X86 ;;
esac
set -- -G Ninja -S llvm -B build -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_PROJECTS=lld -DLLVM_EXTERNAL_LLD_SOURCE_DIR="$work/lld" \
    "-DLLVM_TARGETS_TO_BUILD=$target" \
    -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_ENABLE_PLUGINS=OFF -DLLVM_BUILD_LLVM_DYLIB=OFF \
    -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_LIBPFM=OFF \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_DOCS=OFF -DLLVM_BUILD_TOOLS=OFF -DLLVM_INCLUDE_UTILS=OFF -DLLVM_ENABLE_BINDINGS=OFF
# Speed: ThinLTO across the whole tree, and no -fPIC since these are plain executables (never a shared library).
# ThinLTO needs clang everywhere: the system clang on Linux (linked with lld), Apple clang on macOS, clang-cl on Windows.
set -- "$@" -DLLVM_ENABLE_LTO=Thin -DLLVM_ENABLE_PIC=OFF
# Linking is most of the build, because ThinLTO generates all the code there and ccache cannot cache it. The linker's
# own ThinLTO cache keeps the generated code per module, so an unchanged tree relinks from the cache (CI saves the
# directory next to ccache's). lld caps it at 1 GB; Apple's linker prunes entries it has not used for a week.
lto_cache=$repository/.lto-cache
mkdir -p "$lto_cache"
case "$os" in
    darwin)
        osx_arch=x86_64
        [ "$arch" = arm64 ] && osx_arch=arm64
        set -- "$@" -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 "-DCMAKE_OSX_ARCHITECTURES=$osx_arch" \
            "-DCMAKE_EXE_LINKER_FLAGS=-Wl,-cache_path_lto,$lto_cache" ;;
    windows)
        lto_cache=$(cygpath -m "$lto_cache")
        set -- "$@" "-DCMAKE_EXE_LINKER_FLAGS=/lldltocache:$lto_cache /lldltocachepolicy:cache_size_bytes=1g" \
            -DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl -DLLVM_USE_LINKER=lld-link \
            -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded ;;
    *)
        # Linux tools run on glibc 2.28 and later, so CI builds in the manylinux_2_28 container (AlmaLinux 8) and links
        # libstdc++ and libgcc statically. The container's own gcc 8 is too old for LLVM's C++, so clang is pointed at the
        # newest gcc-toolset for its headers and libstdc++.
        linux_flags=
        gcc_dir=$(ls -d /opt/rh/gcc-toolset-*/root/usr/lib/gcc/*-redhat-linux/* 2>/dev/null | sort -V | tail -n 1)
        [ -n "$gcc_dir" ] && linux_flags="--gcc-install-dir=$gcc_dir"
        # -fuse-ld=lld is also needed here: CMake's first compiler test links before LLVM_USE_LINKER applies, and GNU ld
        # rejects the lld-only cache option.
        set -- "$@" -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DLLVM_USE_LINKER=lld \
            "-DCMAKE_C_FLAGS=$linux_flags" "-DCMAKE_CXX_FLAGS=$linux_flags" \
            "-DCMAKE_EXE_LINKER_FLAGS=$linux_flags -fuse-ld=lld -static-libstdc++ -static-libgcc -Wl,--thinlto-cache-dir=$lto_cache,--thinlto-cache-policy=cache_size_bytes=1g" ;;
esac
# A compiler cache (set up by CI) makes a rebuild with an unchanged tree or recipe mostly cache hits.
if command -v ccache >/dev/null 2>&1; then
    set -- "$@" -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
    ccache --zero-stats >/dev/null
fi
cmake "$@"
# LLVM_BUILD_TOOLS=OFF keeps the default target small; the ones we ship are built by name.
cmake --build build --target lld opt llc llvm-link llvm-dis llvm-split llvm-extract llvm-reduce
if command -v ccache >/dev/null 2>&1; then ccache --show-stats; fi

exe=
[ "$os" = windows ] && exe=.exe
stage=$work/stage
rm -rf "$stage"
mkdir -p "$stage/lld/bin" "$stage/tools/bin"
cp "build/bin/lld$exe" "$stage/lld/bin/"
cp "build/bin/opt$exe" "build/bin/llc$exe" "build/bin/llvm-link$exe" "build/bin/llvm-dis$exe" "build/bin/llvm-split$exe" \
   "build/bin/llvm-extract$exe" "build/bin/llvm-reduce$exe" "$stage/tools/bin/"
case "$os" in
    windows) ;;
    darwin) strip -x "$stage"/lld/bin/* "$stage"/tools/bin/* ;;
    *) strip --strip-unneeded "$stage"/lld/bin/* "$stage"/tools/bin/*
        # Fail the build if a binary needs a glibc newer than 2.28 or a library glibc does not provide.
        sh "$repository/check-glibc-floor.sh" "$stage"/lld/bin/* "$stage"/tools/bin/* ;;
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
