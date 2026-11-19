#!/bin/sh
# Offline maintenance (no Android running): rebuild the boot image of
# graphics-v197.img without the "debuggable" compile it shipped with (ART 7.0
# never inlines in a debuggable graph, so framework code runs without any
# inlining). Inputs, prepared on the computer by src/diag/oat-extract.py from
# the image's own boot*.oat files: the 13 boot jars (the same dex bytes the
# oat files embed), compiled-classes (classes that had compiled code) and
# preloaded-classes, in fast-v197/bootsrc/ with SHA256SUMS. The dex2oat
# command line is the one recorded in boot.oat, minus host paths, with
# cortex-a9 as the variant and a swap file. Output goes to lab/boot/out/ in
# the image; the shipped boot image is never touched (the session binds the
# new one only when fast-v197/bootnodebug-enabled exists).
# ART 7.0's dex2oat forces debuggable code for every boot image (ProcessOptions:
# "We need the boot image to always be debuggable", removed in Android 8),
# whatever the flags. bootsrc/dex2oat-nodebug is the image's dex2oat with one
# byte changed at 0xda8e (movne r7,#1 -> #0 before strbne r7,[r3,#48], the
# store to CompilerOptions::debuggable_); it is used for this compile only.
#   sh compile-boot.sh
set -eu
umask 022
ulimit -c 0
r=/tmp/kobo-android-runtime
base=/mnt/onboard/.adds/kobo-android-lab
# Modules from the per-kernel set (run-resident-session.sh); none: refuse.
kmods=$base/kernels/$(uname -r)
# Built-in ashmem (Libra Colour, MTK 4.9): the module set has no ashmem_linux.ko.
ashmem_mod=ashmem_linux;[ -f "$kmods/ashmem_linux.ko" ] || { [ -e /sys/class/misc/ashmem ] && ashmem_mod=; }
for m in $ashmem_mod kobo_madvise;do
 [ -f "$kmods/$m.ko" ] && [ ! -L "$kmods/$m.ko" ] && [ "$(sha256sum "$kmods/$m.ko" | awk '{print $1}')" = "$(awk -v n="$m.ko" '$2==n {print $1}' "$kmods/SHA256SUMS" 2>/dev/null)" ] || { echo "KERNEL_MODULES_MISSING release=$(uname -r) module=$m";exit 2; }
done
image=$base/graphics-v197.img;src=$base/fast-v197/bootsrc
jars="core-oj core-libart conscrypt okhttp core-junit bouncycastle ext framework telephony-common voip-common ims-common apache-xml org.apache.http.legacy.boot"
[ "$(id -u)" = 0 ]
[ ! -e "$base/weread-launch.lock" ] || { echo BOOT_COMPILE_REFUSED_SESSION_LOCK;exit 3; }
! awk -v root="$r" '$2==root {found=1} END {exit !found}' /proc/mounts || { echo BOOT_COMPILE_REFUSED_IMAGE_MOUNTED;exit 4; }
! grep -qE '^(binder_linux|ashmem_linux|kobo_madvise) ' /proc/modules || { echo BOOT_COMPILE_REFUSED_MODULES_LOADED;exit 4; }
(cd "$src" && sha256sum -c SHA256SUMS >/dev/null) || { echo BOOT_COMPILE_INPUT_HASH_MISMATCH;exit 5; }
mounted=0;loopdev=;vm=0;ash=0;proc=0;pid=;watcher=
cleanup(){
 code=$?;trap - EXIT
 if [ -n "$watcher" ];then kill "$watcher" 2>/dev/null || :;wait "$watcher" 2>/dev/null || :;fi
 if [ -n "$pid" ] && [ "$(readlink /proc/$pid/exe 2>/dev/null)" = "$r/lab/boot/dex2oat-nodebug" ];then kill -KILL "$pid" 2>/dev/null || :;wait "$pid" 2>/dev/null || :;fi
 [ "$mounted" != 1 ] || rm -rf "$r/lab/boot/src" "$r/lab/boot/dex2oat.swap"
 [ "$code" = 0 ] || [ "$mounted" != 1 ] || rm -rf "$r/lab/boot/out.new"
 [ "$proc" != 1 ] || umount "$r/proc"
 [ "$vm" != 1 ] || rmmod kobo_madvise
 [ "$ash" != 1 ] || rmmod ashmem_linux
 if [ "$mounted" = 1 ];then
  sync
  umount "$r" || { sleep 1;umount "$r"; } || code=5
  [ -z "$loopdev" ] || losetup -d "$loopdev" 2>/dev/null || :
 fi
 echo BOOT_COMPILE_EXIT=$code
 exit "$code"
}
trap cleanup EXIT
trap 'exit 143' TERM INT HUP
mkdir -p "$r"
# Image file system (2026-11-10): images are built as ext4 with a journal;
# older images without one (has_journal, bit 2 of the compat word at byte
# 1116) are still mounted as ext2.
img_fstype(){ j_=$(dd if="$1" bs=1 skip=1116 count=1 2>/dev/null | od -An -tu1 | tr -d ' ');[ $(( ${j_:-0} & 4 )) = 0 ] && echo ext2 || echo ext4; }
fstype=$(img_fstype "$image")
mount -t $fstype -o loop,noatime,user_xattr "$image" "$r";mounted=1
loopdev=$(awk -v root="$r" '$2==root {print $1}' /proc/mounts)
[ "$(df -Pk "$r" | awk 'NR==2 {print $4}')" -ge 300000 ] || { echo BOOT_COMPILE_LOW_IMAGE_SPACE;exit 8; }
rm -rf "$r/lab/boot/src" "$r/lab/boot/out.new";mkdir -p "$r/lab/boot/src" "$r/lab/boot/out.new"
cp "$src"/*.jar "$src/compiled-classes" "$src/preloaded-classes" "$r/lab/boot/src/"
cp "$src/dex2oat-nodebug" "$r/lab/boot/dex2oat-nodebug";chmod 0755 "$r/lab/boot/dex2oat-nodebug"
[ -z "$ashmem_mod" ] || { insmod "$kmods/ashmem_linux.ko";ash=1; }
insmod "$kmods/kobo_madvise.ko";vm=1
for n in ashmem kobo_madvise;do
 dev=$(cat /sys/class/misc/$n/dev);rm -f "$r/dev/$n";mknod "$r/dev/$n" c "${dev%:*}" "${dev#*:}";chmod 0600 "$r/dev/$n"
done
mount -t proc -o ro proc "$r/proc";proc=1
export ANDROID_ROOT=/system ANDROID_DATA=/data
dexargs=;locargs=
for j in $jars;do dexargs="$dexargs --dex-file=/lab/boot/src/$j.jar";locargs="$locargs --dex-location=/system/framework/$j.jar";done
start=$(cut -d' ' -f1 /proc/uptime)
KOBO_VM_SHIM=1 nice -n 10 /bin/sh -c 'echo 800 > /proc/$$/oom_score_adj; exec "$@"' sh "$r/lab/legacy-exec" "$r" /lab/boot/dex2oat-nodebug \
 --runtime-arg -Xms64m --runtime-arg -Xmx64m --image-classes=/lab/boot/src/preloaded-classes --compiled-classes=/lab/boot/src/compiled-classes \
 $dexargs $locargs --oat-file=/lab/boot/out.new/boot.oat --oat-location=/system/framework/arm/boot.oat --image=/lab/boot/out.new/boot.art \
 --base=0x70000000 --instruction-set=arm --instruction-set-variant=cortex-a9 --android-root=/system --include-patch-information \
 --runtime-arg -Xnorelocate --no-generate-debug-info --multi-image --no-inline-from=core-oj.jar --compile-pic \
 --swap-file=/lab/boot/dex2oat.swap -j1 > "$r/lab/boot/compile.log" 2>&1 &
pid=$!
(
 ticks=0
 while kill -0 "$pid" 2>/dev/null;do
  sleep 2;ticks=$((ticks+1))
  rss=$(awk '$1=="VmRSS:" {print $2}' /proc/$pid/status 2>/dev/null || :)
  avail=$(awk '$1=="MemAvailable:" {print $2}' /proc/meminfo)
  free=$(df -Pk "$r" | awk 'NR==2 {print $4}')
  [ $((ticks % 30)) != 0 ] || echo "BOOT_COMPILE_RESOURCE tick=$ticks rss_kib=${rss:-0} free_kib=$free available_kib=$avail"
  if [ "$avail" -lt 61440 ] || [ "$ticks" -ge 5400 ] || [ "$free" -lt 65536 ];then
   if [ "$(readlink /proc/$pid/exe 2>/dev/null)" = "$r/lab/boot/dex2oat-nodebug" ];then echo "BOOT_COMPILE_RESOURCE_LIMIT rss_kib=${rss:-0} available_kib=$avail ticks=$ticks";kill -KILL "$pid";fi
   break
  fi
 done
) &
watcher=$!
result=0;wait "$pid" || result=$?;pid=
kill "$watcher" 2>/dev/null || :;wait "$watcher" 2>/dev/null || :;watcher=
echo "BOOT_COMPILE_RESULT code=$result seconds=$(awk -v s="$start" '{print $1-s}' /proc/uptime)"
tail -15 "$r/lab/boot/compile.log"
[ "$result" = 0 ]
rm -rf "$r/lab/boot/out";mv "$r/lab/boot/out.new" "$r/lab/boot/out"
(cd "$r/lab/boot/out" && sha256sum boot*.art boot*.oat > SHA256SUMS && chmod 0644 * && ls -la)
head -c 8192 "$r/lab/boot/out/boot.oat" | tr '\0' '\n' | grep -a -A1 'debuggable\|compiler-filter'
