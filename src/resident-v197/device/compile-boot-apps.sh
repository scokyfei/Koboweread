#!/bin/sh
# Offline maintenance, after compile-boot.sh: compile system_server's
# services.odex, WebView's odex and WeRead's speed-profile odex against the
# non-debuggable boot image in lab/boot/out/ (an odex is only used with the
# boot image it was compiled against; with -Xnodex2oat a mismatch means
# interpreting). services.jar and webview.apk carry no dex in this image:
# bootsrc/services.jar and bootsrc/webview.apk hold the dex unquickened from
# their shipped odex files (src/diag/oat-extract.py). Flags are the ones
# recorded in those odex files (filter speed), with cortex-a9 and -Xmx128m
# (the recorded -Xmx512m makes dex2oat segfault on this 512 MB device); WeRead's use
# compile-speed-profile.sh's. The new boot image is bind-mounted over
# system/framework/arm only while dex2oat runs. Output: lab/boot/apps/.
#   sh compile-boot-apps.sh
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
image=$base/graphics-v197.img;src=$base/fast-v197/bootsrc;pkg=com.tencent.weread.eink
[ "$(id -u)" = 0 ]
[ ! -e "$base/weread-launch.lock" ] || { echo BOOTAPPS_REFUSED_SESSION_LOCK;exit 3; }
! awk -v root="$r" '$2==root {found=1} END {exit !found}' /proc/mounts || { echo BOOTAPPS_REFUSED_IMAGE_MOUNTED;exit 4; }
! grep -qE '^(binder_linux|ashmem_linux|kobo_madvise) ' /proc/modules || { echo BOOTAPPS_REFUSED_MODULES_LOADED;exit 4; }
(cd "$src" && sha256sum -c SHA256SUMS >/dev/null) || { echo BOOTAPPS_INPUT_HASH_MISMATCH;exit 5; }
mounted=0;loopdev=;vm=0;ash=0;proc=0;bound=;pid=
cleanup(){
 code=$?;trap - EXIT
 if [ -n "$pid" ];then kill -KILL "$pid" 2>/dev/null || :;wait "$pid" 2>/dev/null || :;fi
 for t in $bound;do umount "$t" || code=6;done
 [ "$mounted" != 1 ] || rm -rf "$r/lab/boot/appsrc" "$r/lab/boot/dex2oat.swap"
 [ "$code" = 0 ] || [ "$mounted" != 1 ] || rm -rf "$r/lab/boot/apps.new"
 [ "$proc" != 1 ] || umount "$r/proc"
 [ "$vm" != 1 ] || rmmod kobo_madvise
 [ "$ash" != 1 ] || rmmod ashmem_linux
 if [ "$mounted" = 1 ];then
  sync
  umount "$r" || { sleep 1;umount "$r"; } || code=5
  [ -z "$loopdev" ] || losetup -d "$loopdev" 2>/dev/null || :
 fi
 echo BOOTAPPS_EXIT=$code
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
[ -f "$r/lab/boot/out/SHA256SUMS" ] && (cd "$r/lab/boot/out" && sha256sum -c SHA256SUMS >/dev/null) || { echo BOOTAPPS_NO_VALID_BOOT_IMAGE;exit 6; }
appdir=$(cd "$r" && ls -d data/app/$pkg-* 2>/dev/null | head -n 1)
[ -n "$appdir" ] || { echo BOOTAPPS_APK_MISSING;exit 6; }
prof=$r/data/misc/profiles/cur/0/$pkg/primary.prof
[ -s "$prof" ] || { echo BOOTAPPS_NO_PROFILE;exit 7; }
rm -rf "$r/lab/boot/appsrc" "$r/lab/boot/apps.new";mkdir -p "$r/lab/boot/appsrc" "$r/lab/boot/apps.new"
cp "$src"/services.jar "$src"/*.apk "$r/lab/boot/appsrc/";cp "$prof" "$r/lab/boot/appsrc/weread.prof"
for f in "$r"/lab/boot/out/boot*.art "$r"/lab/boot/out/boot*.oat;do
 t=$r/system/framework/arm/${f##*/};[ -f "$t" ] || { echo "BOOTAPPS_TARGET_MISSING ${f##*/}";exit 6; }
 mount --bind "$f" "$t";bound="$t $bound"
done
[ -z "$ashmem_mod" ] || { insmod "$kmods/ashmem_linux.ko";ash=1; }
insmod "$kmods/kobo_madvise.ko";vm=1
for n in ashmem kobo_madvise;do
 dev=$(cat /sys/class/misc/$n/dev);rm -f "$r/dev/$n";mknod "$r/dev/$n" c "${dev%:*}" "${dev#*:}";chmod 0600 "$r/dev/$n"
done
mount -t proc -o ro proc "$r/proc";proc=1
export ANDROID_ROOT=/system ANDROID_DATA=/data
export BOOTCLASSPATH=/system/framework/core-oj.jar:/system/framework/core-libart.jar:/system/framework/conscrypt.jar:/system/framework/okhttp.jar:/system/framework/core-junit.jar:/system/framework/bouncycastle.jar:/system/framework/ext.jar:/system/framework/framework.jar:/system/framework/telephony-common.jar:/system/framework/voip-common.jar:/system/framework/ims-common.jar:/system/framework/apache-xml.jar:/system/framework/org.apache.http.legacy.boot.jar
run(){ # name, dex2oat arguments...
 n=$1;shift;start=$(cut -d' ' -f1 /proc/uptime)
 KOBO_VM_SHIM=1 nice -n 10 /bin/sh -c 'echo 800 > /proc/$$/oom_score_adj; exec "$@"' sh "$r/lab/legacy-exec" "$r" /system/bin/dex2oat "$@" \
  --boot-image=/system/framework/boot.art --instruction-set=arm --instruction-set-variant=cortex-a9 --include-patch-information \
  --runtime-arg -Xnorelocate --no-generate-debug-info --no-inline-from=core-oj.jar --compile-pic --swap-file=/lab/boot/dex2oat.swap -j1 \
  > "$r/lab/boot/apps.new/$n.log" 2>&1 &
 pid=$!;result=0;wait "$pid" || result=$?;pid=;rm -f "$r/lab/boot/dex2oat.swap"
 echo "BOOTAPPS_RESULT $n code=$result seconds=$(awk -v s="$start" '{print $1-s}' /proc/uptime)"
 [ "$result" = 0 ] || { tail -15 "$r/lab/boot/apps.new/$n.log";exit 8; }
}
# Every odex shipped under /system (their APKs/JARs carry no dex here):
# name, unquickened source in bootsrc/, path in the image.
SYSTEM_ODEX="services:services.jar:system/framework/services.jar:system/framework/oat/arm/services.odex
webview:webview.apk:system/app/webview/webview.apk:system/app/webview/oat/arm/webview.odex
ExtShared:ExtShared.apk:system/app/ExtShared/ExtShared.apk:system/app/ExtShared/oat/arm/ExtShared.odex
DefaultContainerService:DefaultContainerService.apk:system/priv-app/DefaultContainerService/DefaultContainerService.apk:system/priv-app/DefaultContainerService/oat/arm/DefaultContainerService.odex
ExtServices:ExtServices.apk:system/priv-app/ExtServices/ExtServices.apk:system/priv-app/ExtServices/oat/arm/ExtServices.odex
PackageInstaller:PackageInstaller.apk:system/priv-app/PackageInstaller/PackageInstaller.apk:system/priv-app/PackageInstaller/oat/arm/PackageInstaller.odex
SettingsProvider:SettingsProvider.apk:system/priv-app/SettingsProvider/SettingsProvider.apk:system/priv-app/SettingsProvider/oat/arm/SettingsProvider.odex
StatementService:StatementService.apk:system/priv-app/StatementService/StatementService.apk:system/priv-app/StatementService/oat/arm/StatementService.odex"
for entry in $SYSTEM_ODEX;do
 IFS=: read -r n file loc oat <<EOE
$entry
EOE
 [ -f "$r/$oat" ] || { echo "BOOTAPPS_TARGET_MISSING $oat";exit 6; }
 run "$n" --runtime-arg -Xms64m --runtime-arg -Xmx128m --runtime-arg -classpath --runtime-arg '&' --abort-on-hard-verifier-error --compiler-filter=speed \
  --dex-file=/lab/boot/appsrc/$file --dex-location=/$loc --oat-file=/lab/boot/apps.new/$n.odex --oat-location=/$oat
done
run weread --runtime-arg -Xms16m --runtime-arg -Xmx96m --compiler-filter=speed-profile --profile-file=/lab/boot/appsrc/weread.prof \
 --dex-file=/$appdir/base.apk --oat-file=/lab/boot/apps.new/weread-speed-profile.odex --oat-location=/$appdir/oat/arm/base.odex
rm -rf "$r/lab/boot/apps";mv "$r/lab/boot/apps.new" "$r/lab/boot/apps"
(cd "$r/lab/boot/apps" && sha256sum *.odex > SHA256SUMS && chmod 0644 * && ls -la)
