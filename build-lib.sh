#!/bin/sh
# Builds the pinned LLVM as one shared library for in-process use: `sh build-lib.sh <os> <arch>`.
# Writes dist/llvm-lib-<version>-<os>-<arch>.tar.gz (and its .sha256), holding
#   lib/libLLVM.so | lib/libLLVM.dylib | bin/LLVM-C.dll   one regular file, no symlinks, loaded by absolute path
#   include/llvm-c/*.h, include/llvm/Config/*             the C API headers (Target.h needs Config/Targets.def)
# Linux and macOS ship the full libLLVM (it exports the whole C API). Windows cannot build the full DLL (export limit), so it
# ships LLVM-C.dll, which holds the C API only. Only the machine's own backend is built, as in build.sh.
# This is a separate build from build.sh: a shared library needs position-independent code, the tools do not.
set -eu
os=$1
arch=$2
repository=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
version=$(tr -d '[:space:]' < "$repository/llvm-version")
work=${LLVM_WORK:-$repository/work}
out=$repository/dist
mkdir -p "$work" "$out"
cd "$work"

if [ ! -d llvm ]; then
    curl --fail --location --retry 3 -sS -o src.tar.xz \
        "https://github.com/llvm/llvm-project/releases/download/llvmorg-$version/llvm-project-$version.src.tar.xz"
    tar -xf src.tar.xz --strip-components=1 --exclude=mlgo-utils llvm-project-"$version".src/llvm llvm-project-"$version".src/cmake \
        llvm-project-"$version".src/third-party llvm-project-"$version".src/libc
    rm src.tar.xz
fi

case "$arch" in
    arm64) target=AArch64 ;;
    *) target=X86 ;;
esac
set -- -G Ninja -S llvm -B build-lib -DCMAKE_BUILD_TYPE=Release "-DLLVM_TARGETS_TO_BUILD=$target" \
    -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_ENABLE_PLUGINS=OFF -DLLVM_ENABLE_PIC=ON \
    -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_LIBPFM=OFF \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_DOCS=OFF -DLLVM_BUILD_TOOLS=OFF -DLLVM_INCLUDE_UTILS=OFF -DLLVM_ENABLE_BINDINGS=OFF
case "$os" in
    darwin)
        osx_arch=x86_64
        [ "$arch" = arm64 ] && osx_arch=arm64
        set -- "$@" -DLLVM_BUILD_LLVM_DYLIB=ON -DLLVM_LINK_LLVM_DYLIB=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
            "-DCMAKE_OSX_ARCHITECTURES=$osx_arch"
        shared=LLVM ;;
    windows)
        # clang-cl targets its own build's architecture; pin it to the platform's (the arm64 runner may carry an x64 clang).
        win_target=--target=x86_64-pc-windows-msvc
        [ "$arch" = arm64 ] && win_target=--target=aarch64-pc-windows-msvc
        set -- "$@" -DLLVM_BUILD_LLVM_C_DYLIB=ON -DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl \
            -DLLVM_USE_LINKER=lld-link -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded -DLLVM_ENABLE_PCH=OFF \
            "-DCMAKE_C_FLAGS=$win_target" "-DCMAKE_CXX_FLAGS=$win_target"
        shared=LLVM-C ;;
    *)
        # As build.sh: build in the manylinux_2_28 container so the glibc floor is 2.28, libstdc++ and libgcc linked statically.
        linux_flags=
        gcc_dir=$(ls -d /opt/rh/gcc-toolset-*/root/usr/lib/gcc/*-redhat-linux/* 2>/dev/null | sort -V | tail -n 1)
        [ -n "$gcc_dir" ] && linux_flags="--gcc-install-dir=$gcc_dir"
        set -- "$@" -DLLVM_BUILD_LLVM_DYLIB=ON -DLLVM_LINK_LLVM_DYLIB=OFF -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
            -DLLVM_USE_LINKER=lld "-DCMAKE_C_FLAGS=$linux_flags" "-DCMAKE_CXX_FLAGS=$linux_flags" \
            "-DCMAKE_SHARED_LINKER_FLAGS=$linux_flags -fuse-ld=lld -static-libstdc++ -static-libgcc" \
            "-DCMAKE_EXE_LINKER_FLAGS=$linux_flags -fuse-ld=lld -static-libstdc++ -static-libgcc"
        shared=LLVM ;;
esac
if command -v ccache >/dev/null 2>&1; then
    set -- "$@" -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
fi
cmake "$@"
cmake --build build-lib --target "$shared"

stage=$work/stage-lib
rm -rf "$stage"
mkdir -p "$stage/lib" "$stage/bin" "$stage/include"
cp -R llvm/include/llvm-c "$stage/include/llvm-c"
mkdir -p "$stage/include/llvm/Config"
cp build-lib/include/llvm/Config/*.h build-lib/include/llvm/Config/*.def "$stage/include/llvm/Config/" 2>/dev/null || true
cp llvm/include/llvm/Config/*.def "$stage/include/llvm/Config/" 2>/dev/null || true
case "$os" in
    windows) cp build-lib/bin/LLVM-C.dll "$stage/bin/" ; cp build-lib/lib/LLVM-C.lib "$stage/lib/" 2>/dev/null || true
             # LoadLibrary needs a Windows path (D:/a/...), not the MSYS one (/d/a/...).
             library=$(cygpath -m "$stage/bin/LLVM-C.dll") ;;
    darwin) cp "$(ls build-lib/lib/libLLVM*.dylib | head -n 1)" "$stage/lib/libLLVM.dylib"
            strip -x "$stage/lib/libLLVM.dylib"
            # The macOS floor is 12.0 (the deployment target above): fail if the library asks for anything newer.
            minos=$(otool -l "$stage/lib/libLLVM.dylib" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }')
            echo "macOS minos: $minos"
            case "$minos" in 12.0 | 11.* | 10.*) ;; *) echo "libLLVM.dylib needs macOS $minos, above the 12.0 floor" >&2; exit 1 ;; esac
            library=$stage/lib/libLLVM.dylib ;;
    *) real=$(ls build-lib/lib/libLLVM.so.* build-lib/lib/libLLVM-*.so 2>/dev/null | head -n 1)
       cp -L "$real" "$stage/lib/libLLVM.so"
       strip --strip-unneeded "$stage/lib/libLLVM.so"
       sh "$repository/check-glibc-floor.sh" "$stage/lib/libLLVM.so"
       library=$stage/lib/libLLVM.so ;;
esac

asset=llvm-lib-$version-$os-$arch.tar.gz
tar -czf "$out/$asset" -C "$stage" .
( cd "$out"; if command -v sha256sum >/dev/null 2>&1; then sha256sum "$asset" > "$asset.sha256"; else shasum -a 256 "$asset" > "$asset.sha256"; fi )

echo "sizes (bytes, library then archive):"
wc -c "$library" "$out/$asset"
if [ "$os" = windows ]; then
    echo "LLVM-C.dll exports of interest:"
    dumpbin -nologo -exports "$library" | grep -E "LLVMInitialize(X86|AArch64)|LLVMRunPasses|LLVMGetVersion|LLVMInstallFatalErrorHandler|LLVMParseIRInContext" || true
    dumpbin -nologo -exports "$library" | grep -c "LLVM" || true
fi
