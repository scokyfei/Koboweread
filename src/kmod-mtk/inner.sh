#!/bin/sh
# Runs inside the container started by build.sh (/src: this directory,
# /repo: the repository, /work: build volume, /out: kernels/4.9.77).
set -eu
export ARCH=arm CROSS_COMPILE=arm-linux-gnueabi-
commit=f5d86fdab03d7206773933fe985a6b1d63616b52
url=https://raw.githubusercontent.com/kobolabs/Kobo-Reader/$commit/hw/mt8113-libraC_vision7
sum_aa=e17e8787e61d082f49eb098036cb39f1766815c5674c9df5da350666e07c99c4
sum_ab=c00ea64689b57dfa5175f2162b9dc2a1d8084b99a870c65f8fff5dc49596b01d
module_layout_crc=a81081b3
K=/work/src/linux/v4.9
# GCC 9 reports issues as errors that Kobo's GCC 4.9.1 did not know about.
W="-Wno-error -Wno-attribute-alias -Wno-stringop-overflow -Wno-stringop-truncation -Wno-array-bounds -Wno-packed-not-aligned -Wno-misleading-indentation -Wno-address-of-packed-member -Wno-format-overflow -Wno-maybe-uninitialized -Wno-missing-attributes"

# 1. Source
for p in aa ab; do
 f=/work/kernel.tar.zst.part-$p; eval want=\$sum_$p
 if [ ! -f "$f" ] || [ "$(sha256sum "$f" | cut -c1-64)" != "$want" ]; then
  echo "KMOD_MTK download part-$p"; curl -fsSL --retry 3 -o "$f.part" "$url/kernel.tar.zst.part-$p"
  [ "$(sha256sum "$f.part" | cut -c1-64)" = "$want" ] || { echo "KMOD_MTK_CHECKSUM_MISMATCH part-$p" >&2; exit 3; }
  mv "$f.part" "$f"
 fi
done
if [ ! -f "$K/Makefile" ]; then
 echo "KMOD_MTK extract"; rm -rf /work/src; mkdir -p /work/src
 cat /work/kernel.tar.zst.part-aa /work/kernel.tar.zst.part-ab | zstd -dc | tar xf - -C /work/src
fi
cd "$K"
if ! cmp -s /src/kernel.config .config.kobo 2>/dev/null; then
 cp /src/kernel.config .config; cp /src/kernel.config .config.kobo
 make -s olddefconfig
 rm -f /work/objects.done
fi
[ "$(make -s kernelrelease)" = 4.9.77 ] || { echo KMOD_MTK_RELEASE_MISMATCH >&2; exit 4; }

# 2. Objects and CRCs
if [ ! -f /work/objects.done ]; then
 echo "KMOD_MTK compile kernel objects (several minutes)"
 make -k -j"$(nproc)" vmlinux KCFLAGS="$W" > /work/objects.log 2>&1 || :
 touch /work/objects.done
fi
find . -name '*.o' ! -name built-in.o ! -name '*.mod.o' -print0 | xargs -0 arm-linux-gnueabi-nm 2>/dev/null |
 awk '$3 ~ /^__crc_/ {sub(/^__crc_/, "", $3); print $1, $3}' | sort -u -k2,2 > /work/crcs.txt
got=$(awk '$2 == "module_layout" {print $1}' /work/crcs.txt)
[ "$got" = "$module_layout_crc" ] || { echo "KMOD_MTK_MODULE_LAYOUT_MISMATCH got=$got want=$module_layout_crc" >&2; exit 5; }
awk '{printf "0x%s\t%s\tvmlinux\tEXPORT_SYMBOL\n", $1, $2}' /work/crcs.txt > /work/vmlinux.symvers
echo "KMOD_MTK crcs=$(wc -l < /work/crcs.txt) module_layout=$got"

# 3. Modules
build_module(){ # name source-dir
 rm -rf "/work/m/$1"; mkdir -p "/work/m/$1"; cp -R "$2/." "/work/m/$1/"
 make -s -C "$K" M="/work/m/$1" KBUILD_EXTRA_SYMBOLS=/work/vmlinux.symvers KCFLAGS="$W" modules > "/work/m/$1.log" 2>&1 || { cat "/work/m/$1.log"; exit 6; }
 ko=/work/m/$1/$1.ko
 modinfo -F vermagic "$ko" | grep -qx '4.9.77 SMP preempt mod_unload modversions ARMv7 p2v8 ' || { echo "KMOD_MTK_VERMAGIC $1" >&2; exit 7; }
 arm-linux-gnueabi-nm -u "$ko" | awk '{print $2}' | sort > "/work/m/$1.undef"
 missing=$(awk '{print $2}' /work/crcs.txt | sort | comm -13 - "/work/m/$1.undef")
 [ -z "$missing" ] || { echo "KMOD_MTK_UNEXPORTED $1: $missing" >&2; exit 8; }
 arm-linux-gnueabi-strip --strip-debug -o "/out/$1.ko" "$ko"
 echo "KMOD_MTK built $1 imports=$(wc -l < "/work/m/$1.undef")"
}
build_module binder_linux /src/binder32
mkdir -p /work/m/madvise.src /work/m/pagecache.src
printf 'obj-m := kobo_madvise.o\n' > /work/m/madvise.src/Makefile
cp /repo/upstream/codex-kobo-android/module-prototype/vm-helper/kobo_madvise.c /work/m/madvise.src/
build_module kobo_madvise /work/m/madvise.src
printf 'obj-m := kobo_pagecache.o\n' > /work/m/pagecache.src/Makefile
cp /repo/src/kmod/pagecache/kobo_pagecache.c /work/m/pagecache.src/
build_module kobo_pagecache /work/m/pagecache.src

cd /out
sha256sum binder_linux.ko kobo_madvise.ko kobo_pagecache.ko > SHA256SUMS
printf '4.42.23303\n' > firmware
[ -f status ] || printf 'untested\n' > status
echo "KMOD_MTK modules written"
