#!/bin/sh
# Fails when an ELF executable needs glibc newer than 2.28, or a shared library other than glibc's own:
# `sh toolchain/check-glibc-floor.sh <file>...`. It reads the binary's version requirements, the ones the
# loader enforces at start, so weak references count. MS_GLIBC_FLOOR overrides the floor, as `major.minor`.
set -eu
floor=${MS_GLIBC_FLOOR:-2.28}
[ $# -gt 0 ] || { echo "usage: $0 <elf file>..." >&2; exit 2; }
status=0
for file in "$@"; do
    info=$(objdump -p "$file")
    needed=$(printf '%s\n' "$info" | awk '$1 == "NEEDED" { print $2 }')
    for lib in $needed; do
        case "$lib" in
            libc.so.6 | libm.so.6 | libpthread.so.0 | libdl.so.2 | librt.so.1 | ld-linux-*.so.* | linux-vdso.so.1) ;;
            *) echo "$file: needs $lib, which is not part of glibc" >&2; status=1 ;;
        esac
    done
    # Lines of the "Version References" section name one version each, e.g. `0x09691a75 0x00 05 GLIBC_2.2.5`.
    bad=$(printf '%s\n' "$info" | awk -v floor="$floor" '
        BEGIN { split(floor, f, "."); }
        $NF ~ /^(GLIBC|GLIBCXX|CXXABI|GCC)_[0-9.]+$/ && NF == 4 {
            name = $NF
            if (name !~ /^GLIBC_/) { print name; next }
            sub(/^GLIBC_/, "", name)
            n = split(name, v, ".")
            if (v[1] + 0 > f[1] + 0 || (v[1] + 0 == f[1] + 0 && v[2] + 0 > f[2] + 0)) print $NF
        }' | sort -u)
    if [ -n "$bad" ]; then
        echo "$file: needs versions above glibc $floor:" >&2
        printf '  %s\n' $bad >&2
        status=1
    fi
done
[ "$status" -eq 0 ] && echo "glibc floor $floor holds for $*"
exit "$status"
