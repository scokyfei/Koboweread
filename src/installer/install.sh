#!/bin/sh
# WeRead 1.8.8 for Kobo Libra 2 / Libra Colour: installer, started by the KOReader plugin
# (wereadkobo.koplugin) in the background:
#   sh install.sh PLUGIN_DIR
# Reads PLUGIN_DIR/payload/ (host.tar.gz, rootfs.tar.xz,
# SHA256SUMS, apk-meta, dirtimes) and builds BASE=/mnt/onboard/.adds/kobo-weread-home:
# launcher files, then a 2 GB ext4 image graphics-v188.img holding Android 7
# and WeRead 1.8.8 (registered, empty data: first start shows the agreement
# and the login page). Everything is built in BASE.part and renamed to BASE at
# the end; on failure BASE.part (only what this run made) is removed.
# Progress for the plugin: PLUGIN_DIR/install.progress, one line
#   STEP STEPS PERCENT TEXT      (TEXT fixed for a step: the plugin's dialog
#   shows it once per step and moves only the bar)
# Result: PLUGIN_DIR/install.state ("running", "done" or "failed CODE TEXT").
# Log: PLUGIN_DIR/install.log. Nothing is written to /tmp (RAM).
set -u
set -o pipefail 2>/dev/null || :
umask 022
pd=$(cd "${1:?}" && pwd) || exit 2
echo $$ > "$pd/install.pid"
pl=$pd/payload
base=/mnt/onboard/.adds/kobo-weread-home
part=$base.part
mnt=$part/.image-mnt
img=$part/graphics-v188.img
image_mb=2048
steps=7
progress(){ printf '%s %s %s %s\n' "$1" "$steps" "$2" "$3" > "$pd/install.progress.new" && mv "$pd/install.progress.new" "$pd/install.progress"; echo "PROGRESS $*"; }
mounted=0
fail(){
 code=$1;shift
 echo "INSTALL_FAILED code=$code $*"
 cd /
 if [ "$mounted" = 1 ];then sync;umount "$mnt" 2>/dev/null || echo INSTALL_UMOUNT_FAILED;fi
 # Only this run's own partial output; an existing installation is never touched.
 [ "${made_part:-0}" = 1 ] && rm -rf "$part"
 printf 'failed %s %s\n' "$code" "$*" > "$pd/install.state"
 exit "$code"
}
trap 'fail 130 被中断' INT TERM
trap '' HUP
echo "INSTALL_BEGIN $(date) plugin=$pd"
printf 'running\n' > "$pd/install.state"

progress 1 0 "检查设备"
[ "$(id -u)" = 0 ] || fail 10 "需要以 root 运行（KOReader 在 Kobo 上本就是 root）"
# N418 Libra 2 (i.MX6SLL, kernel 4.1.15); N428 Libra Colour (MT8113, kernel 4.9.77: built-in ashmem, binder32 module).
case "$(cut -d, -f1 /mnt/onboard/.kobo/version 2>/dev/null)" in N418*|N428*) :;; *) fail 11 "这台设备不是 Kobo Libra 2 或 Libra Colour";;esac
kver=$(uname -r)
# kernels.list: "RELEASE FIRMWARE" per kernel this package has modules for.
grep -q "^$kver " "$pl/kernels.list" 2>/dev/null || fail 12 "这个固件的内核还不受支持（当前内核 $kver；支持的固件：$(awk '{printf "%s ", $2}' "$pl/kernels.list" 2>/dev/null)）"
[ -x /mnt/onboard/.adds/koreader/luajit ] || fail 13 "KOReader 不在 /mnt/onboard/.adds/koreader"

# The Libra Colour kernel has its own (unused) /dev/binder: our modules mark a running Android.
if grep -q ' /tmp/kobo-android-runtime ' /proc/mounts || grep -qE '^(binder_linux|ashmem_linux|kobo_madvise) ' /proc/modules;then fail 15 "另一个 Android 正在运行，请先关闭";fi
for f in host.tar.gz rootfs.tar.xz SHA256SUMS apk-meta dirtimes kernels.list;do [ -f "$pl/$f" ] || fail 16 "安装包缺少 $f";done
# Host-only upgrade. The transaction directory doubles as the launch guard.
upgrade=$base/.host-upgrade
rollback_upgrade(){
 [ -f "$upgrade/journal" ] || return 0
 while IFS= read -r f;do
  if [ -f "$upgrade/old/$f" ];then
   cp -p "$upgrade/old/$f" "$base/$f.upgrade-new" &&
    mv "$base/$f.upgrade-new" "$base/$f" || return 1
  else
   rm -f "$base/$f" "$base/$f.upgrade-new" || return 1
  fi
 done < "$upgrade/journal"
 sync
}
if [ -e "$base" ];then
 [ -d "$base" ] && [ ! -L "$base" ] && [ -f "$base/installed" ] &&
  grep -qx 'version=1.8.8' "$base/installed" && [ -s "$base/graphics-v188.img" ] ||
  fail 14 "仅支持同版本原地升级"
 lock=$base/weread-launch.lock
 if [ -e "$lock" ];then
  read -r lock_pid lock_start lock_boot lock_kind < "$lock/owner" || fail 15 "请先关闭后台 Android"
  [ "$lock_kind" = upgrade ] &&
   { [ "$lock_boot" != "$(cat /proc/sys/kernel/random/boot_id)" ] ||
     [ "$lock_start" != "$(awk '{print $22}' "/proc/$lock_pid/stat" 2>/dev/null)" ]; } ||
   fail 15 "请先关闭后台 Android"
  rm "$lock/owner" && rmdir "$lock" || fail 26 "无法清理上次升级锁"
 fi
 progress 2 5 "校验升级包"
 (cd "$pl" && sha256sum -c SHA256SUMS) || fail 20 "安装包校验失败"
 [ -s "$pl/launcher-cert" ] && grep -q '  launcher-cert$' "$pl/SHA256SUMS" ||
  fail 24 "升级包缺少启动器签名信息"
 release_upgrade_lock(){
  if [ "${owns_upgrade_lock:-0}" = 1 ];then rm -f "$lock/owner";rmdir "$lock";fi
 }
 upgrade_fail(){
  if rollback_upgrade;then rm -rf "$upgrade";else release_upgrade_lock;fail 26 "升级恢复失败，请保留备份并重试";fi
  release_upgrade_lock
  fail 28 "$1，已恢复原组件"
 }
 trap 'upgrade_fail 被中断' INT TERM
 if ! mkdir "$lock" 2>/dev/null;then fail 15 "Android 正在启动";fi
 owns_upgrade_lock=1
 printf '%s %s %s upgrade\n' "$$" "$(awk '{print $22}' /proc/$$/stat)" "$(cat /proc/sys/kernel/random/boot_id)" > "$lock/owner" ||
  upgrade_fail "无法记录升级锁"
 if [ -d "$upgrade" ];then
  rollback_upgrade || { release_upgrade_lock;fail 26 "上次升级恢复失败"; }
  rm -rf "$upgrade" || { release_upgrade_lock;fail 26 "无法清理上次升级"; }
 fi
 cert=$(cat "$pl/launcher-cert")
 signature=$(unzip -p "$base/resident-v188/KoboProbe-resident.apk" META-INF/LAB.RSA | od -An -v -tx1 | tr -d ' \n')
 case "$signature" in *"$cert"*) :;; *) release_upgrade_lock;fail 27 "启动器签名不同，无法保留现有 Android 镜像";;esac
 mkdir "$upgrade" || { release_upgrade_lock;fail 25 "无法锁定升级目录"; }
 printf '%s\n' "$$" > "$upgrade/pid" || upgrade_fail "无法记录升级进程"
 progress 3 20 "备份并准备组件"
 mkdir "$upgrade/new" "$upgrade/old" &&
  tar -xzf "$pl/host.tar.gz" -C "$upgrade/new" || upgrade_fail "解包失败"
 cd "$upgrade/new" || upgrade_fail "无法打开暂存目录"
 # Update package-owned files only. Preserve flags, settings and data.
 find . -type f | sed 's@^./@@' | while IFS= read -r f;do
  case "$f" in
   device-profile|display-cadence|display-profile|resident-*/io-tune|fast-*/*-disabled|fast-*/*-enabled)
    [ ! -e "$base/$f" ] || continue
    # A missing switch can be an explicit user choice.
    case "$f" in fast-*/*-disabled|fast-*/*-enabled) continue;;esac;;
  esac
  printf '%s\n' "$f"
 done > "$upgrade/files"
 sed '/^package=/d' "$base/installed" > installed &&
  printf 'package=%s\n' "$(cat "$pl/package-version")" >> installed || upgrade_fail "无法更新安装记录"
 echo installed >> "$upgrade/files"
 while IFS= read -r f;do
  if [ -e "$base/$f" ];then
   mkdir -p "$upgrade/old/$(dirname "$f")" &&
    cp -p "$base/$f" "$upgrade/old/$f" || upgrade_fail "备份失败"
  fi
 done < "$upgrade/files"
 cp "$upgrade/files" "$upgrade/journal.new" && mv "$upgrade/journal.new" "$upgrade/journal" || upgrade_fail "无法记录回滚清单"
 sync
 progress 4 55 "替换并核对组件"
 while IFS= read -r f;do
  mkdir -p "$base/$(dirname "$f")" && cp -p "$f" "$base/$f.upgrade-new" &&
   mv "$base/$f.upgrade-new" "$base/$f" && cmp -s "$f" "$base/$f" ||
   upgrade_fail "组件写入或校验失败"
 done < "$upgrade/files"
 sync
 cd /
 rm "$upgrade/journal" || upgrade_fail "无法提交升级"
 release_upgrade_lock
 rm -rf "$upgrade"
 progress 7 100 "升级完成"
 printf 'done\n' > "$pd/install.state"
 exit 0
fi
apk_name=weread-1.8.8.apk
apk=$pd/$apk_name
# Older lab packages supply the APK within payload.
[ -f "$apk" ] || apk=$pl/$apk_name
[ -f "$apk" ] || fail 21 "请自行下载 $apk_name，并放到 wereadkobo.koplugin 目录（与 main.lua 同级）"
if grep -q ' lib/' "$pl/apk-meta";then
 command -v unzip >/dev/null 2>&1 || fail 23 "设备缺少 unzip，无法提取 APK 原生库"
fi
# A run that was cut off (power, reset) leaves BASE.part: only its own output.
if grep -q " $mnt " /proc/mounts;then umount "$mnt" || fail 18 "上次未完成的安装仍挂载着镜像";fi
rm -rf "$part" || fail 19 "无法清理上次未完成的安装"
free_kb=$(df -k /mnt/onboard | awk 'NR==2 {print $4}')
[ "$free_kb" -ge $(( (image_mb + 300) * 1024 )) ] || fail 17 "存储空间不足：需要约 $((image_mb + 300)) MB，只剩 $((free_kb / 1024)) MB"

progress 2 2 "校验安装包"
# Legacy lab manifests may list the bundled APK. Verify the other payload files.
( cd "$pl" && awk -v apk="$apk_name" '$2 != apk' SHA256SUMS | sha256sum -c - ) ||
 fail 20 "安装包校验失败，请重新复制"

progress 3 6 "复制启动文件"
made_part=1
mkdir -p "$part" && tar -xzf "$pl/host.tar.gz" -C "$part" || fail 31 "复制启动文件失败"

# The image: written in 64 MB pieces (FAT has no sparse files; the card takes
# 2 GB of zeroes at roughly 10-20 MB/s), then formatted as ext4 with a
# journal (2026-11-10): the Kobo's busybox mke2fs makes ext2, the packaged
# tune2fs adds the journal, so an Android cut off by a reboot or a flat
# battery leaves a journal to replay instead of stale block bitmaps.
n=0;pieces=$((image_mb / 64))
while [ "$n" -lt "$pieces" ];do
 progress 4 $((8 + n * 32 / pieces)) "创建 2 GB 的 Android 镜像"
 echo "IMAGE_MB $((n * 64))"
 dd if=/dev/zero of="$img" bs=1048576 count=64 seek=$((n * 64)) conv=notrunc 2>/dev/null || fail 40 "写入镜像失败（存储卡空间或错误）"
 n=$((n + 1))
done
sync
[ "$(stat -c %s "$img")" = $((image_mb * 1048576)) ] || fail 41 "镜像大小不对"
progress 5 40 "格式化镜像"
mke2fs -F -b 4096 -m 0 "$img" >/dev/null || fail 50 "格式化镜像失败"
"$part/resident-v188/tune2fs" -O has_journal -J size=32 "$img" >/dev/null || fail 52 "镜像加日志失败"
mkdir -p "$mnt" && mount -t ext4 -o loop,noatime,user_xattr "$img" "$mnt" || fail 51 "挂载镜像失败"
mounted=1

# The system, fed to xz/tar in 4 MB pieces of the compressed file so that the
# progress follows the bytes read.
total=$(stat -c %s "$pl/rootfs.tar.xz");chunk=4194304;count=$(( (total + chunk - 1) / chunk ))
{
 i=0
 while [ "$i" -lt "$count" ];do
  dd if="$pl/rootfs.tar.xz" bs=$chunk skip=$i count=1 2>/dev/null
  i=$((i + 1))
  [ $((i % 4)) = 0 ] || [ "$i" = "$count" ] && progress 6 $((42 + i * 48 / count)) "解压 Android 系统" >&2
 done
} | xz -dc | tar -x -f - -C "$mnt" || fail 60 "解压系统失败"
[ -x "$mnt/system/bin/app_process32" ] && [ -f "$mnt/data/system/packages.xml" ] || fail 61 "系统文件不完整"

progress 7 92 "放入微信读书 1.8.8"
# apk-meta: one line per file, "PATH UID GID MODE MTIME [APK_ENTRY]" (the values the
# package manager recorded; a different time would make it digest the APK again).
while read -r path uid gid mode mtime entry;do
 t=$mnt/${path#./}
 if [ -n "$entry" ];then
  unzip -p "$apk" "$entry" > "$t.new" || fail 70 "提取 APK 内的 $entry 失败"
 else
  cp "$apk" "$t.new" || fail 70 "放入 APK 失败"
 fi
 chown "$uid:$gid" "$t.new" && chmod "$mode" "$t.new" && touch -d "@$mtime" "$t.new" && mv "$t.new" "$t" || fail 70 "放入 APK 失败"
done < "$pl/apk-meta"
# Directory times as in the source image ("PATH MTIME" per directory): the
# package manager compares a package directory's time with the one it
# recorded and otherwise verifies the APK again, which fails here and drops
# WeRead. Last, after every file is in place.
while read -r path mtime;do touch -d "@$mtime" "$mnt/${path#./}" || fail 73 "无法设置目录时间";done < "$pl/dirtimes"
sync
df -Pk "$mnt" | awk 'NR==2 {print $4}' > "$part/resident-v188/image-free-kb"
cd /
umount "$mnt" || fail 71 "卸载镜像失败"
mounted=0
rmdir "$mnt"
printf 'version=1.8.8\ninstalled=%s\npackage=%s\n' "$(date '+%Y-%m-%d %H:%M')" "$(cat "$pl/package-version" 2>/dev/null)" > "$part/installed"
mv "$part" "$base" || fail 72 "无法完成安装目录"
made_part=0
sync
progress 7 100 "安装完成"
printf 'done\n' > "$pd/install.state"
echo "INSTALL_DONE $(date)"
