#!/bin/sh
# Static ARM host tools for the launcher payload (docs/公开版设计.md):
#   KOBO_BUILD_OUT=DIR sh src/tools/build-host-tools.sh
# - e2fsck from e2fsprogs 1.47.1 (GPL v2; tarball tools/dl/e2fsprogs-1.47.1.tar.xz,
#   sha256 checked), configured as on 2026-11-07 (resident-v188/e2fsck):
#   lseek64 forced on, -D_LARGEFILE64_SOURCE, no pkg-config, static musl.
# - tune2fs from the same build (journal on/off for the Android image).
# - kobo-mkswap, kobo-squeeze (src/kmod/zram), static musl.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
top=$(CDPATH= cd -- "$here/../.." && pwd)
tools=${KOBO_TOOLS:-$top/tools}
out=${KOBO_BUILD_OUT:?Set an output directory}
mkdir -p "$out";out=$(CDPATH= cd -- "$out" && pwd)
zig=$tools/ziglang/zig
export ZIG_GLOBAL_CACHE_DIR=${ZIG_GLOBAL_CACHE_DIR:-$top/build/zig-cache} ZIG_LOCAL_CACHE_DIR=${ZIG_LOCAL_CACHE_DIR:-$top/build/zig-cache}
for p in kobo-mkswap kobo-squeeze;do
 "$zig" cc -target arm-linux-musleabi -mcpu=cortex_a9 -static -O2 -Wall -Wextra "$top/src/kmod/zram/$p.c" -o "$out/$p"
done
tarball=$tools/dl/e2fsprogs-1.47.1.tar.xz
want=5a33dc047fd47284bca4bb10c13cfe7896377ae3d01cb81a05d406025d99e0d1
[ -f "$tarball" ] || { echo "MISSING $tarball (run bootstrap.sh)" >&2;exit 2; }
if command -v sha256sum >/dev/null 2>&1;then got=$(sha256sum "$tarball" | cut -c1-64);else got=$(shasum -a 256 "$tarball" | cut -c1-64);fi
[ "$got" = "$want" ] || { echo "E2FSPROGS_SHA256_MISMATCH $got" >&2;exit 3; }
# Layout src/ beside obj/ as in the original build: __FILE__ strings then match.
w=$out/e2fsprogs;rm -rf "$w";mkdir -p "$w/obj" "$w/src";(cd "$w/src" && tar xf "$tarball")
for t in cc ar ranlib;do
 case $t in cc) c="cc -target arm-linux-musleabi -mcpu=cortex_a9";; *) c=$t;;esac
 printf '#!/bin/sh\nexec "%s" %s "$@"\n' "$zig" "$c" > "$w/obj/z$t";chmod 755 "$w/obj/z$t"
done
(cd "$w/obj" && ac_cv_func_lseek64=yes CC="$w/obj/zcc" AR="$w/obj/zar" RANLIB="$w/obj/zranlib" CFLAGS='-O2 -D_LARGEFILE64_SOURCE' \
 LDFLAGS='-static' PKG_CONFIG='' ../src/e2fsprogs-1.47.1/configure --host=arm-linux-musleabi --disable-nls --disable-fuse2fs \
 --disable-uuidd --disable-tdb --disable-imager --disable-defrag --disable-e2initrd-helper --disable-fsck --without-libarchive \
 --disable-elf-shlibs > "$w/configure.log" 2>&1 && make -j4 libs > "$w/make.log" 2>&1 && make -j4 -C e2fsck e2fsck.static >> "$w/make.log" 2>&1) \
 || { echo "E2FSCK_BUILD_FAILED (see $w)" >&2;exit 4; }
# tune2fs (2026-11-10): adds or removes the journal of the Android image
# (ext2 <-> ext4 with a journal, docs/1.9.7版本.md).
(cd "$w/obj" && make -j4 -C misc tune2fs.static >> "$w/make.log" 2>&1) || { echo "TUNE2FS_BUILD_FAILED (see $w)" >&2;exit 4; }
# zig 0.13 builds its objcopy as a host program, which fails to link on newer
# macOS releases (undefined _sigaction/_bzero); fall back to llvm-objcopy
# (KOBO_OBJCOPY, PATH, or Homebrew's llvm).
strip_all(){
 if [ -n "${KOBO_OBJCOPY:-}" ];then "$KOBO_OBJCOPY" --strip-all "$1" "$2";return;fi
 "$zig" objcopy --strip-all "$1" "$2" 2>/dev/null && return
 for c in llvm-objcopy /opt/homebrew/opt/llvm/bin/llvm-objcopy /usr/local/opt/llvm/bin/llvm-objcopy;do
  if command -v "$c" >/dev/null 2>&1;then "$c" --strip-all "$1" "$2";return;fi
 done
 echo "HOST_TOOLS_NO_OBJCOPY (set KOBO_OBJCOPY to an ELF objcopy)" >&2;return 1
}
strip_all "$w/obj/misc/tune2fs.static" "$out/tune2fs"
# The deployed copy (sha 5302506c...) is e2fsck.static with strip-all.
strip_all "$w/obj/e2fsck/e2fsck.static" "$out/e2fsck"
echo "HOST_TOOLS_DONE $out"
