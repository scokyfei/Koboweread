#!/bin/sh
# Offline maintenance: compile WeRead with speed-profile using the hot-method
# profile ART recorded during real use (KOBO_COMPILE_FILTER=speed compiles
# every method ahead of time instead; larger output, longer compile). Output goes to lab/fast/ in the image;
# the original odex is never touched. run-fast-session.sh bind-mounts the
# candidate only while its recorded SHA-256 matches.
# Based on Codex's verified-speed81/compile-candidate.sh guards.
set -eu
umask 077
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
# WeRead 1.9.7 only (graphics-v197.img), kept apart from fast/ (1.9.8) and fast-v188/ (1.8.8).
# KOBO_COMPILE_IMAGE may say v197 or be empty.
tag=${KOBO_COMPILE_IMAGE-}
case "$tag" in
 ''|v197) image=$base/graphics-v197.img;apk_sha=351105bda1ac58bc037c2d604982635a24018eb0f9b9964abeb5b84647565f1c;;
 *) echo "COMPILE_IMAGE_UNKNOWN tag=$tag";exit 2;;
esac
echo "FAST_COMPILE_IMAGE ${image##*/}"
pkg=com.tencent.weread.eink
out=/lab/fast/weread-speed-profile.odex
filter=${KOBO_COMPILE_FILTER:-speed-profile}
# speed: dex2oat outgrows this device's memory without a swap file, as Android
# itself gives it for large apps on low-memory devices (--swap-fd).
swap=
# Its RSS then includes the mapped swap file (reclaimable, disk-backed), so the
# RSS cap is higher; the MemAvailable floor (80 MiB) still guards the device.
case "$filter" in speed-profile) max_bytes=157286400;max_ticks=900;max_rss=337920;; speed) max_bytes=314572800;max_ticks=1800;max_rss=471040;swap=--swap-file=/lab/fast/dex2oat.swap;; *) echo COMPILE_FILTER_UNSUPPORTED;exit 2;;esac
[ "$(id -u)" = 0 ]
# A lock whose owner is gone (another boot, or the process ended: a session cut
# off by a reboot leaves it) is not a session; launch-resident.sh treats it the
# same way and replaces it at the next start.
lock=$base/weread-launch.lock
if [ -e "$lock" ];then
 old_pid=;old_start=;old_boot=;[ ! -f "$lock/owner" ] || read old_pid old_start old_boot extra < "$lock/owner" || :
 case "$old_pid" in ''|*[!0-9]*) old_pid=0;;esac
 if [ "$old_boot" = "$(cat /proc/sys/kernel/random/boot_id)" ] && [ -n "$old_start" ] && [ "$(awk '{print $22}' /proc/$old_pid/stat 2>/dev/null || :)" = "$old_start" ];then echo COMPILE_REFUSED_SESSION_LOCK;exit 3;fi
 echo COMPILE_STALE_LOCK_IGNORED
fi
! awk -v root="$r" '$2==root {found=1} END {exit !found}' /proc/mounts || { echo COMPILE_REFUSED_IMAGE_MOUNTED;exit 4; }
# The image was not unmounted cleanly last time (a session cut off by a
# reboot): its block bitmaps may be stale, and writing 45 MB into it then
# puts new data on blocks that are in use (2026-11-10: wr.log and the new odex
# shared a block). Only the session start checks and repairs it (e2fsck -fp),
# so refuse here. The same marker covers this script's own mount.
dirty=$base/resident-v197/session-dirty
[ ! -e "$dirty" ] || { echo COMPILE_REFUSED_IMAGE_UNCLEAN;exit 9; }
! grep -qE '^(binder_linux|ashmem_linux|kobo_madvise) ' /proc/modules || { echo COMPILE_REFUSED_MODULES_LOADED;exit 4; }
mounted=0;loopdev=;vm=0;ash=0;proc=0;pid=;watcher=
cleanup(){
 code=$?;trap - EXIT
 if [ -n "$watcher" ];then kill "$watcher" 2>/dev/null || :;wait "$watcher" 2>/dev/null || :;fi
 if [ -n "$pid" ] && [ "$(readlink /proc/$pid/exe 2>/dev/null)" = "$r/system/bin/dex2oat" ];then kill -KILL "$pid" 2>/dev/null || :;wait "$pid" 2>/dev/null || :;fi
 # A failed compile must not leave the session without a candidate (it would
 # fall back to the interpret-only odex): put the previous one back.
 if [ "$mounted" = 1 ] && [ ! -f "$r$out" ] && [ -f "$r/lab/fast/weread-speed-profile-prev.odex" ];then
  mv "$r/lab/fast/weread-speed-profile-prev.odex" "$r$out";mv "$r/lab/fast/weread-speed-profile-prev.odex.sha256" "$r$out.sha256";echo FAST_COMPILE_PREVIOUS_RESTORED
 fi
 [ "$mounted" != 1 ] || rm -f "$r$out.new" "$r/lab/fast/dex2oat.swap"
 [ "$proc" != 1 ] || umount "$r/proc"
 [ "$vm" != 1 ] || rmmod kobo_madvise
 [ "$ash" != 1 ] || rmmod ashmem_linux
 if [ "$mounted" = 1 ];then
  sync
  if umount "$r" || { sleep 1;umount "$r"; };then rm -f "$dirty";else code=5;fi
  [ -z "$loopdev" ] || losetup -d "$loopdev" 2>/dev/null || :
 fi
 echo FAST_COMPILE_EXIT=$code
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
: > "$dirty"
loopdev=$(awk -v root="$r" '$2==root {print $1}' /proc/mounts)
# Install directory: -1 for 2.1.2, -2 after the 1.9.8 downgrade install.
appdir=$(cd "$r" && ls -d data/app/$pkg-* 2>/dev/null | head -n 1)
[ -n "$appdir" ] || { echo FAST_COMPILE_APK_MISSING;exit 6; }
apk=/$appdir/base.apk
apk_have=$(sha256sum "$r$apk" | cut -d' ' -f1)
# Koboweread-Colour: the official channel-900 1.9.7 build is accepted as well.
[ "$apk_have" = "$apk_sha" ] || { [ "$apk_sha" = 351105bda1ac58bc037c2d604982635a24018eb0f9b9964abeb5b84647565f1c ] && [ "$apk_have" = fae543b19c935024d5f51ac0d42df00bc6ebb5de2fc197b51bb3131e3b16707d ]; } || { echo FAST_COMPILE_APK_HASH_MISMATCH;exit 6; }
mkdir -p "$r/lab/fast"
prof=$r/data/misc/profiles/cur/0/$pkg/primary.prof
[ -s "$prof" ] || { echo FAST_COMPILE_NO_PROFILE;exit 7; }
cp "$prof" "$r/lab/fast/weread.prof"
sha256sum "$r/lab/fast/weread.prof"
# Keep the previous candidate for rollback; only the newest is bind-mounted.
if [ -f "$r$out" ] && [ -f "$r$out.sha256" ];then
 mv "$r$out" "$r/lab/fast/weread-speed-profile-prev.odex"
 mv "$r$out.sha256" "$r/lab/fast/weread-speed-profile-prev.odex.sha256"
 echo FAST_COMPILE_PREVIOUS_KEPT
fi
rm -f "$r$out" "$r$out.sha256" "$r$out.new"
[ "$(df -Pk "$r" | awk 'NR==2 {print $4}')" -ge 250000 ] || { echo FAST_COMPILE_LOW_IMAGE_SPACE;exit 8; }
[ -z "$ashmem_mod" ] || { insmod "$kmods/ashmem_linux.ko";ash=1; }
insmod "$kmods/kobo_madvise.ko";vm=1
for n in ashmem kobo_madvise;do
 dev=$(cat /sys/class/misc/$n/dev);rm -f "$r/dev/$n";mknod "$r/dev/$n" c "${dev%:*}" "${dev#*:}";chmod 0600 "$r/dev/$n"
done
mount -t proc -o ro proc "$r/proc";proc=1
export ANDROID_ROOT=/system ANDROID_DATA=/data ANDROID_STORAGE=/storage EXTERNAL_STORAGE=/storage/emulated/legacy
export BOOTCLASSPATH=/system/framework/core-oj.jar:/system/framework/core-libart.jar:/system/framework/conscrypt.jar:/system/framework/okhttp.jar:/system/framework/core-junit.jar:/system/framework/bouncycastle.jar:/system/framework/ext.jar:/system/framework/framework.jar:/system/framework/telephony-common.jar:/system/framework/voip-common.jar:/system/framework/ims-common.jar:/system/framework/apache-xml.jar:/system/framework/org.apache.http.legacy.boot.jar
start=$(cut -d' ' -f1 /proc/uptime)
KOBO_VM_SHIM=1 nice -n 10 /bin/sh -c 'echo 800 > /proc/$$/oom_score_adj; exec "$@"' sh "$r/lab/legacy-exec" "$r" /system/bin/dex2oat --dex-file=$apk --oat-file=$out.new --oat-location=/$appdir/oat/arm/base.odex --instruction-set=arm --instruction-set-variant=cortex-a9 --compiler-filter=$filter $swap --profile-file=/lab/fast/weread.prof --compile-pic --runtime-arg -Xms16m --runtime-arg -Xmx96m --runtime-arg -Xnorelocate -j1 > "$r/lab/fast/compile.log" 2>&1 &
pid=$!
(
 ticks=0
 while kill -0 "$pid" 2>/dev/null;do
  sleep 2;ticks=$((ticks+1))
  rss=$(awk '$1=="VmRSS:" {print $2}' /proc/$pid/status 2>/dev/null || :)
  bytes=$(stat -c %s "$r$out.new" 2>/dev/null || echo 0)
  avail=$(awk '$1=="MemAvailable:" {print $2}' /proc/meminfo)
  free=$(df -Pk "$r" | awk 'NR==2 {print $4}')
  [ $((ticks % 15)) != 0 ] || echo "FAST_COMPILE_RESOURCE tick=$ticks rss_kib=${rss:-0} output_bytes=$bytes free_kib=$free available_kib=$avail"
  if [ "$avail" -lt 81920 ] || [ "$ticks" -ge "$max_ticks" ] || [ "${rss:-0}" -gt "$max_rss" ] || [ "$bytes" -gt "$max_bytes" ] || [ "$free" -lt 65536 ];then
   if [ "$(readlink /proc/$pid/exe 2>/dev/null)" = "$r/system/bin/dex2oat" ];then echo "FAST_COMPILE_RESOURCE_LIMIT rss_kib=${rss:-0} available_kib=$avail ticks=$ticks";kill -KILL "$pid";fi
   break
  fi
 done
) &
watcher=$!
result=0;wait "$pid" || result=$?;pid=
kill "$watcher" 2>/dev/null || :;wait "$watcher" 2>/dev/null || :;watcher=
echo "FAST_COMPILE_RESULT code=$result seconds=$(awk -v s="$start" '{print $1-s}' /proc/uptime)"
tail -20 "$r/lab/fast/compile.log"
[ "$result" = 0 ]
head -c 16384 "$r$out.new" | tr '\0' '\n' | grep -a -A1 compiler-filter
mv "$r$out.new" "$r$out"
sha256sum "$r$out" | cut -d' ' -f1 > "$r$out.sha256"
chmod 0644 "$r$out" "$r$out.sha256"
stat -c 'FAST_COMPILE_OUTPUT_BYTES=%s' "$r$out"
echo "FAST_COMPILE_OUTPUT_SHA256=$(cat "$r$out.sha256")"
