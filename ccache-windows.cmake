# ccache refuses clang-cl's depfile flags (-clang:-MD -clang:-MT -clang:-MF) as unsupported and then caches nothing.
# Track headers through /showIncludes (the MSVC way) instead. Measured on both Windows runners: 100% uncacheable
# without this, cache hits with it.
set(CMAKE_DEPFILE_FLAGS_C "")
set(CMAKE_DEPFILE_FLAGS_CXX "")
set(CMAKE_NINJA_DEPTYPE_C msvc)
set(CMAKE_NINJA_DEPTYPE_CXX msvc)
