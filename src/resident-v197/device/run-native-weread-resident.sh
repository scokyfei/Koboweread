#!/bin/sh
set -eu
# Android shared runtime paths must not inherit the private launcher log umask.
# Application children set their own restrictive umask after UID drop.
umask 022
ulimit -c 0
root=/tmp/kobo-android-runtime
cd "$root/lab"
touch_mode=${KOBO_WEREAD_TOUCH_MODE:-targets}
heap_headroom=${KOBO_WEREAD_HEAP_HEADROOM:-0}
case "$heap_headroom" in 0|1) :;; *) echo UNSUPPORTED_HEAP_HEADROOM;exit 135;;esac
[ ! -e "$root/lab/weread-heap-headroom-enabled" ] && [ ! -L "$root/lab/weread-heap-headroom-enabled" ] || { echo EXISTING_HEAP_HEADROOM_MARKER;exit 135; }
if [ "$heap_headroom" = 1 ];then
 [ "${KOBO_WEREAD_INTERACTIVE:-0}" = 1 ] && [ "${KOBO_WEREAD_REUSE:-0}" = 1 ] && [ "${KOBO_WEREAD_STARTUP_PROFILE:-diagnostic}" = reading ] && [ "${KOBO_WEREAD_JIT:-0}" = 1 ] || { echo HEAP_HEADROOM_REQUIRES_READING_SESSION;exit 135; }
fi
display_cadence=${KOBO_WEREAD_DISPLAY_CADENCE:-30}
case "$display_cadence" in 30|15) :;; *) echo UNSUPPORTED_DISPLAY_CADENCE;exit 134;;esac
[ ! -e "$root/lab/display-cadence15-enabled" ] && [ ! -L "$root/lab/display-cadence15-enabled" ] || { echo EXISTING_DISPLAY_CADENCE_MARKER;exit 134; }
if [ "$display_cadence" = 15 ];then
 [ "${KOBO_WEREAD_INTERACTIVE:-0}" = 1 ] && [ "${KOBO_WEREAD_REUSE:-0}" = 1 ] && [ "${KOBO_WEREAD_STARTUP_PROFILE:-diagnostic}" = reading ] || { echo DISPLAY_CADENCE_REQUIRES_READING_SESSION;exit 134; }
fi
display_profile=${KOBO_WEREAD_DISPLAY_PROFILE:-reagl-text}
case "$display_profile" in classic|reagl|reagl-text) :;; *) echo UNSUPPORTED_DISPLAY_PROFILE;exit 131;;esac
startup_profile=${KOBO_WEREAD_STARTUP_PROFILE:-diagnostic}
[ "$startup_profile" = reading ] || exit 138
[ ! -e "$root/lab/weread-startup-service-grace" ] && [ ! -L "$root/lab/weread-startup-service-grace" ] || { echo EXISTING_STARTUP_SERVICE_GRACE;exit 130; }
case "$startup_profile" in
 diagnostic) startup_diagnostics=1;;
 reading)
  [ "${KOBO_WEREAD_INTERACTIVE:-0}" = 1 ] && [ "${KOBO_WEREAD_REUSE:-0}" = 1 ] || { echo READING_PROFILE_REQUIRES_EXISTING_INTERACTIVE_INSTALL;exit 125; }
  startup_diagnostics=0;;
 *) echo UNSUPPORTED_STARTUP_PROFILE;exit 125;;
esac
startup_stage(){ echo "WEREAD_STARTUP_STAGE stage=$1 uptime=$(awk '{print $1}' /proc/uptime) profile=$startup_profile"; }
startup_stage runtime_begin
. "$root/lab/startup-readiness.sh"
. "$root/lab/module-cleanup.sh"
fast_animation(){
 # Window/transition/animator scales: 0 for this session (e-ink cannot show the
 # frames; each frame holds the window lock waiting for SurfaceFlinger), back to
 # 1 before shutdown so other entries keep Android's defaults.
 # fast/anim-window: only window and activity-transition scales go to 0 (the
 # reader's slide-in otherwise runs ~5 s at ~30 fps beside the book loading,
 # SurfaceFlinger alone ~30% CPU); WeRead's own animators keep scale 1.
 anim_mode=$1
 if [ -e /mnt/onboard/.adds/kobo-android-lab/fast-v197/anim-window ];then [ "$anim_mode" != off ] || anim_mode=window
 elif [ -e /mnt/onboard/.adds/kobo-android-lab/fast-v197/anim-disabled ];then return 0;fi
 [ -f "$root/lab/fast/animation-scales.dex" ] || return 0
 CLASSPATH=/lab/fast/animation-scales.dex KOBO_VM_SHIM=1 timeout 20 "$root/lab/legacy-exec" "$root" /system/bin/app_process32 -Xnorelocate -Xnoimage-dex2oat -Xnodex2oat /system/bin FastAnimationScales "$anim_mode" || echo "FAST_ANIMATION_SCALES_FAILED mode=$anim_mode"
}
# Readiness polling instead of fixed sleeps. Same failure checks follow each use.
poll_until(){ poll_limit=$1;shift;poll_n=0;while [ "$poll_n" -lt "$poll_limit" ];do if eval "$*";then return 0;fi;poll_n=$((poll_n+1));sleep 0.1;done;return 1; }
service_found(){ chroot "$root" /system/bin/service check "$1" 2>/dev/null | grep -q ": found"; }
existing_launch_timeout=60
[ "$startup_profile" != reading ] || existing_launch_timeout=120
session_seconds=${KOBO_WEREAD_SESSION_SECONDS:-180}
# Resident launcher: Android stays up between foreground periods (resident-loop.sh).
resident=${KOBO_WEREAD_RESIDENT:-0}
case "$resident" in 0|1) :;; *) echo UNSUPPORTED_RESIDENT_MODE;exit 142;;esac
[ "$resident" = 0 ] || { [ "$session_seconds" = 1800 ] && [ "${KOBO_WEREAD_INTERACTIVE:-0}" = 1 ]; } || { echo RESIDENT_REQUIRES_INTERACTIVE_LONG;exit 142; }
case "$session_seconds" in 180|1800) :;; *) echo UNSUPPORTED_SESSION_DURATION;exit 123;;esac
[ "$session_seconds" = 180 ] || [ "${KOBO_WEREAD_INTERACTIVE:-0}" = 1 ] || { echo LONG_SESSION_REQUIRES_INTERACTIVE;exit 124; }
interactive_bridge_seconds=$((session_seconds+60))
interactive_touch_option=--interactive
[ "$session_seconds" != 1800 ] || interactive_touch_option=--interactive-long
[ ! -e "$root/lab/weread-jit-enabled" ] && [ ! -L "$root/lab/weread-jit-enabled" ] || { echo EXISTING_JIT_CONFIGURATION_MARKER;exit 121; }
case "$touch_mode" in targets|weread|session) :;; *) echo UNKNOWN_TOUCH_MODE;exit 82;;esac
if [ "${KOBO_WEREAD_INTERACTIVE:-0}" = 1 ];then
 [ "$(df -Pk "$root" | awk 'NR==2 {print $4}')" -ge 131072 ] || { echo INTERACTIVE_IMAGE_FREE_SPACE_BELOW_128_MIB;exit 120; }
 [ "$touch_mode" = session ] && [ "${KOBO_WEREAD_TOUCH_TEST:-0}" = 1 ] && [ "${KOBO_WEREAD_LIVE_DISPLAY:-0}" = 1 ] && [ "${KOBO_WEREAD_INPUT_TEST:-0}" = 1 ] && [ "${KOBO_WEREAD_HOST_NETWORK_STATE:-0}" = 1 ] || { echo INTERACTIVE_REQUIRES_LIVE_TOUCH_AND_HOST_NETWORK_STATE;exit 111; }
 [ "${KOBO_WEREAD_AGREEMENT_DIAG:-0}" != 1 ] && [ "${KOBO_WEREAD_DIAGNOSTIC_TAP:-0}" != 1 ] && [ "${KOBO_WEREAD_WEB_DIAGNOSTICS:-0}" != 1 ] || { echo INTERACTIVE_EXCLUDES_AUTOMATED_TAPS_AND_WEB_DEBUGGING;exit 112; }
elif [ "$touch_mode" = session ];then echo SESSION_TOUCH_REQUIRES_INTERACTIVE_MODE;exit 113
fi
previous_weread_uid=$(awk '$1=="com.tencent.weread.eink" {print $2}' "$root/data/system/kobo-install-process-allowlist.txt" 2>/dev/null || :)
previous_installed_uid=$(awk '$1=="com.kobo.lab.installed" {print $2}' "$root/data/system/kobo-install-process-allowlist.txt" 2>/dev/null || :)
if [ "${KOBO_WEREAD_INPUT_TEST:-0}" = 1 ];then
 [ "${KOBO_WEREAD_REUSE:-0}" = 1 ] && [ -n "$previous_weread_uid" ] || { echo INPUT_TEST_REQUIRES_KNOWN_PERSISTED_WEREAD;exit 68; }
fi
if [ "${KOBO_WEREAD_LIVE_DISPLAY:-0}" = 1 ];then
 [ "${KOBO_WEREAD_INPUT_TEST:-0}" = 1 ] || { echo LIVE_DISPLAY_REQUIRES_INPUT_TEST;exit 69; }
fi
if [ "${KOBO_WEREAD_TOUCH_TEST:-0}" = 1 ];then
 [ "${KOBO_WEREAD_LIVE_DISPLAY:-0}" = 1 ] || { echo TOUCH_TEST_REQUIRES_LIVE_DISPLAY;exit 74; }
fi
if [ "${KOBO_WEREAD_DIAGNOSTIC_TAP:-0}" = 1 ];then
 [ "${KOBO_WEREAD_REUSE:-0}" = 1 ] && [ "${KOBO_WEREAD_TOUCH_TEST:-0}" != 1 ] && [ "${KOBO_WEREAD_LIVE_DISPLAY:-0}" != 1 ] && [ "${KOBO_WEREAD_INPUT_TEST:-0}" != 1 ] || { echo DIAGNOSTIC_TAP_REQUIRES_SEPARATE_REUSE_MODE;exit 83; }
fi
if [ "${KOBO_WEREAD_HOST_NETWORK:-0}" = 1 ];then
 [ "${KOBO_WEREAD_REUSE:-0}" = 1 ] && { [ "${KOBO_WEREAD_INTERACTIVE:-0}" = 1 ] || { [ "${KOBO_WEREAD_TOUCH_TEST:-0}" != 1 ] && [ "${KOBO_WEREAD_LIVE_DISPLAY:-0}" != 1 ] && [ "${KOBO_WEREAD_INPUT_TEST:-0}" != 1 ]; }; } || { echo HOST_NETWORK_REQUIRES_SEPARATE_REUSE_OR_INTERACTIVE_MODE;exit 84; }
fi
if [ "${KOBO_WEREAD_HOST_NETWORK_STATE:-0}" = 1 ];then
 [ "${KOBO_WEREAD_HOST_NETWORK:-0}" = 1 ] || { echo HOST_NETWORK_STATE_REQUIRES_HOST_NETWORK;exit 106; }
 [ ! -e "$root/lab/network-state" ] && [ ! -L "$root/lab/network-state" ] && [ ! -e "$root/lab/host-default-network-enabled" ] || { echo EXISTING_HOST_NETWORK_STATE;exit 107; }
fi
if [ "${KOBO_WEREAD_AGREEMENT_DIAG:-0}" = 1 ];then
 [ "${KOBO_WEREAD_HOST_NETWORK:-0}" = 1 ] && [ "${KOBO_WEREAD_DIAGNOSTIC_TAP:-0}" != 1 ] || { echo AGREEMENT_DIAG_REQUIRES_SEPARATE_HOST_NETWORK;exit 85; }
fi
# Modules from the per-kernel set (run-resident-session.sh); none: refuse.
kmods=/mnt/onboard/.adds/kobo-android-lab/kernels/$(uname -r)
[ -f "$kmods/SHA256SUMS" ] && [ ! -L "$kmods" ] || exit 2
# Built-in ashmem (Libra Colour, MTK 4.9): the module set has no ashmem_linux.ko.
ashmem_mod=ashmem_linux;[ -f "$kmods/ashmem_linux.ko" ] || { [ -e /sys/class/misc/ashmem ] && ashmem_mod=; }
for m in $ashmem_mod binder_linux kobo_madvise;do
 [ -f "$kmods/$m.ko" ] && [ ! -L "$kmods/$m.ko" ] && [ "$(sha256sum "$kmods/$m.ko" | awk '{print $1}')" = "$(awk -v n="$m.ko" '$2==n {print $1}' "$kmods/SHA256SUMS")" ] || { echo "KERNEL_MODULE_HASH_MISMATCH $m";exit 2; }
done
# With the kernel's own ashmem and binder (protocol 8, unused) the nodes always exist; only our modules mark a running Android.
if { [ -n "$ashmem_mod" ] && { [ -e /dev/binder ] || [ -e /dev/ashmem ]; }; } || grep -qE '^(binder_linux|ashmem_linux|kobo_madvise) ' /proc/modules; then echo 'Existing Android devices; refusing';exit 3;fi
binder_loaded=0;ashmem_loaded=0;vm_loaded=0;manager_pid=;logger_pid=;debugger_pid=;proc_mounted=0;graphics_ram_mounted=0;property_pid=;sf_pid=;sensor_pid=;installer_pid=;vold_pid=;broker_pid=;dms_pid=
audio_pid=;dns_pid=;host_network_pid=;priority_pid=;memory_pid=
bridge_pid=
touch_pid=;touch_java_pid=
# Processes that keep the chroot's proc (or the image) in use: root, cwd or an
# open file under $root/proc. One line each, only on the failure path.
lab_proc_holders(){
 echo "LAB_PROC_BUSY phase=$1 uptime=$(cut -d' ' -f1 /proc/uptime)"
 for hp in /proc/[0-9]*;do
  h_root=$(readlink "$hp/root" 2>/dev/null);h_cwd=$(readlink "$hp/cwd" 2>/dev/null);h_fd=0;h_first=
  for hf in "$hp"/fd/*;do
   h_t=$(readlink "$hf" 2>/dev/null) || continue
   case "$h_t" in "$root/proc"|"$root/proc/"*) h_fd=$((h_fd+1));[ -n "$h_first" ] || h_first=$h_t;;esac
  done
  case "$h_root$h_cwd" in *"$root"*) :;; *) [ "$h_fd" -gt 0 ] || continue;;esac
  h_name=;h_state=;h_ppid=
  while read h_k h_v h_rest;do case "$h_k" in Name:) h_name=$h_v;; State:) h_state=$h_v;; PPid:) h_ppid=$h_v;break;;esac;done 2>/dev/null < "$hp/status"
  echo "LAB_PROC_HOLDER pid=${hp#/proc/} name=$h_name state=$h_state ppid=$h_ppid root=$h_root cwd=$h_cwd proc_fds=$h_fd first=$h_first"
 done
}
cleanup() {
 lab_cleanup_status=$?
 trap - EXIT
 set +e
 if [ "${resident:-0}" = 1 ];then
  # Stopped Android processes would never act on the TERM below.
  ! type android_thaw >/dev/null 2>&1 || android_thaw
  [ -z "${launch_pid:-}" ] || { kill -TERM "$launch_pid" 2>/dev/null;wait "$launch_pid" 2>/dev/null; }
  [ -z "${dns_check_pid:-}" ] || { kill -TERM "$dns_check_pid" 2>/dev/null;wait "$dns_check_pid" 2>/dev/null; }
  [ -z "${readahead_pid:-}" ] || { kill -TERM "$readahead_pid" 2>/dev/null;wait "$readahead_pid" 2>/dev/null; }
  # Normal priority so teardown is not starved; the outer wrapper restores the governor.
  /mnt/onboard/.adds/kobo-android-lab/resident-v197/resident-sched normal
  rm -rf "$root/data/local/tmp/kobo-resident" "$root/lab/resident"
 fi
 if [ -n "$memory_pid" ];then kill -TERM "$memory_pid" 2>/dev/null;wait "$memory_pid" 2>/dev/null;cat "$root/lab/native-resolution/memory.log";fi
 rm -f "$root/lab/weread-heap-headroom-enabled" "$root/lab/display-cadence15-enabled" "$root/lab/framework-jit-enabled" "$root/lab/weread-jit-enabled" "$root/lab/weread-startup-service-grace"
 rm -f "$root/lab/interactive-session-ready"
 rm -f "$root/lab/webview-read-diagnostics-enabled" "$root/lab/webview-software-draw-enabled" "$root/lab/webview-trace-started" "$root/lab/webview-trace-complete"
 if [ -n "$touch_pid" ];then kill -TERM "$touch_pid" 2>/dev/null;wait "$touch_pid" 2>/dev/null;cat "$root/lab/native-resolution/touch-forward.log";fi
 if [ -n "$touch_java_pid" ];then kill -TERM "$touch_java_pid" 2>/dev/null;wait "$touch_java_pid" 2>/dev/null;cat "$root/lab/touch-probe.log";rm -f "$root/dev/socket/kobo_touch_probe";fi
 if [ -n "$bridge_pid" ];then kill -TERM "$bridge_pid" 2>/dev/null;wait "$bridge_pid" 2>/dev/null;cat "$root/lab/native-resolution/live-display.log";fi
 rm -f "$root/lab/interactive-refresh-request"
 if [ -n "$dms_pid" ];then kill "$dms_pid" 2>/dev/null;wait "$dms_pid" 2>/dev/null;cat "$root/lab/display-service.log";fi
 if [ -f "$root/lab/install-processes.pid" ];then
  while read owned_pid;do
   case "$owned_pid" in ''|*[!0-9]*) continue;;esac
   if [ "$(readlink "/proc/$owned_pid/root" 2>/dev/null)" = "$root" ] && [ "$(readlink "/proc/$owned_pid/exe" 2>/dev/null)" = "$root/system/bin/app_process32" ];then kill -KILL "$owned_pid" 2>/dev/null;fi
  done < "$root/lab/install-processes.pid"
  rm -f "$root/lab/install-processes.pid"
 fi
 if [ -f "$root/lab/app-probe.pid" ];then
  read app_pid < "$root/lab/app-probe.pid"
  case "$app_pid" in ''|*[!0-9]*) :;; *)
   app_root=$(readlink "/proc/$app_pid/root" 2>/dev/null)
   app_exe=$(readlink "/proc/$app_pid/exe" 2>/dev/null)
   if [ "$app_root" = "$root" ] && { [ "$app_exe" = "$root/system/bin/app_process32" ] || [ "$app_exe" = "$root/lab/app-uid-exec" ]; };then kill -KILL "$app_pid" 2>/dev/null;fi
  esac
  rm -f "$root/lab/app-probe.pid"
 fi
 if [ -f "$root/lab/apk-process.log" ];then cat "$root/lab/apk-process.log";fi
 if [ -n "$broker_pid" ];then kill "$broker_pid" 2>/dev/null;wait "$broker_pid" 2>/dev/null;cat "$root/lab/process-broker.log";rm -f "$root/dev/socket/zygote";fi
 if [ -n "$dns_pid" ];then kill -TERM "$dns_pid" 2>/dev/null;wait "$dns_pid" 2>/dev/null;cat "$root/lab/dns-proxy.log";rm -f "$root/dev/socket/dnsproxyd";fi
 if [ -n "$host_network_pid" ];then
  kill -TERM "$host_network_pid" 2>/dev/null;wait "$host_network_pid" 2>/dev/null;cat "$root/lab/host-default-network.log"
  rm -f "$root/dev/socket/fwmarkd" "$root/lab/network-state/host-default.properties" "$root/lab/network-state/pending" "$root/lab/host-default-network-enabled"
  rmdir "$root/lab/network-state"
 fi
 if [ -n "$vold_pid" ];then kill "$vold_pid" 2>/dev/null;wait "$vold_pid" 2>/dev/null;cat "$root/lab/vold.log";rm -f "$root/dev/socket/vold" "$root/dev/socket/cryptd";fi
 if [ -n "$sensor_pid" ];then kill "$sensor_pid" 2>/dev/null;wait "$sensor_pid" 2>/dev/null;cat "$root/lab/sensorservice.log";fi
 # Only stop a compiler child owned by this run's installer and private root.
 for owned_proc in /proc/[0-9]*;do
  [ "$(readlink "$owned_proc/exe" 2>/dev/null)" = "$root/system/bin/dex2oat" ] || continue
  [ "$(readlink "$owned_proc/root" 2>/dev/null)" = "$root" ] || continue
  [ "$(awk '$1=="PPid:" {print $2}' "$owned_proc/status" 2>/dev/null)" = "$installer_pid" ] || continue
  kill -KILL "${owned_proc##*/}" 2>/dev/null
 done
 if [ -n "$installer_pid" ];then kill "$installer_pid" 2>/dev/null;wait "$installer_pid" 2>/dev/null;rm -f "$root/dev/socket/installd";cat "$root/lab/installd.log";fi
 if [ -n "$sf_pid" ];then kill "$sf_pid" 2>/dev/null;wait "$sf_pid" 2>/dev/null;cat "$root/lab/surfaceflinger.log";fi
 if [ -n "$audio_pid" ];then kill "$audio_pid" 2>/dev/null;wait "$audio_pid" 2>/dev/null;cat "$root/lab/native-audio.log";fi
 if [ -n "$priority_pid" ];then kill -TERM "$priority_pid" 2>/dev/null;wait "$priority_pid" 2>/dev/null;cat "$root/lab/priority-broker.log";fi
 if [ -n "$property_pid" ];then kill "$property_pid" 2>/dev/null;wait "$property_pid" 2>/dev/null;rm -f "$root/dev/socket/property_service";cat "$root/lab/property-server.log";fi
 if [ -n "$manager_pid" ]; then kill "$manager_pid" 2>/dev/null;wait "$manager_pid" 2>/dev/null;fi
 if [ -n "$debugger_pid" ];then kill "$debugger_pid" 2>/dev/null;wait "$debugger_pid" 2>/dev/null;tail -80 "$root/lab/debuggerd.log";fi
 if [ -n "$logger_pid" ];then kill "$logger_pid" 2>/dev/null;wait "$logger_pid" 2>/dev/null;cat "$root/lab/android.log";fi
 # 2026-11-10: about 1 session in 7 the chroot's proc was still busy here
 # (umount: Device or resource busy), so the image stayed mounted and the next
 # launch was refused. Retry for up to 10 s, logging what holds it the first
 # time and, if still busy, detach it (umount -l; nothing is written through
 # proc). Off with resident-v197/procwait-disabled (single umount as before).
 if [ "$proc_mounted" = 1 ];then
  if umount "$root/proc" 2>/dev/null;then :
  elif [ -e /mnt/onboard/.adds/kobo-android-lab/resident-v197/procwait-disabled ];then umount "$root/proc"
  else
   lab_proc_holders first
   proc_try=0
   while [ "$proc_try" -lt 20 ];do sleep 0.5;proc_try=$((proc_try+1));umount "$root/proc" 2>/dev/null && break;done
   if mountpoint -q "$root/proc";then
    lab_proc_holders final
    umount -l "$root/proc" && echo "LAB_PROC_UMOUNT_LAZY tries=$proc_try" || echo LAB_PROC_UMOUNT_FAILED
   else echo "LAB_PROC_UMOUNT_RETRIED tries=$proc_try uptime=$(cut -d' ' -f1 /proc/uptime)";fi
  fi
 fi
 if [ "$graphics_ram_mounted" = 1 ];then
  for ram_attempt in 1 2 3;do umount "$root/dev/graphics" 2>/dev/null && break;sleep 1;done
  if mountpoint -q "$root/dev/graphics";then echo RAM_FB_BACKING_UNMOUNT_FAILED;[ "$lab_cleanup_status" != 0 ] || lab_cleanup_status=141;else echo RAM_FB_BACKING_UNMOUNTED;fi
 fi
 if [ "$vm_loaded" = 1 ];then lab_unload_module kobo_madvise || { [ "$lab_cleanup_status" != 0 ] || lab_cleanup_status=133; };fi
 if [ "$binder_loaded" = 1 ]; then lab_unload_module binder_linux || { [ "$lab_cleanup_status" != 0 ] || lab_cleanup_status=133; };fi
 if [ "$ashmem_loaded" = 1 ]; then lab_unload_module ashmem_linux || { [ "$lab_cleanup_status" != 0 ] || lab_cleanup_status=133; };fi
 echo 'Remaining test modules:';grep -E '^(binder_linux|ashmem_linux|kobo_madvise) ' /proc/modules || :
 exit "$lab_cleanup_status"
}
[ ! -e "$root/lab/webview-read-diagnostics-enabled" ] || { echo EXISTING_WEBVIEW_DIAGNOSTIC_MARKER;exit 87; }
if [ "${KOBO_WEREAD_WEB_DIAGNOSTICS:-0}" = 1 ];then
 [ "${KOBO_WEREAD_AGREEMENT_DIAG:-0}" = 1 ] || { echo WEB_DIAGNOSTICS_REQUIRES_AGREEMENT_TEST;exit 88; }
 printf 'Public agreement page diagnostics only\n' > "$root/lab/webview-read-diagnostics-enabled"
 chmod 0400 "$root/lab/webview-read-diagnostics-enabled"
fi
if [ "${KOBO_WEREAD_DRAW_DIAGNOSTIC:-0}" = 1 ];then
 [ "${KOBO_WEREAD_WEB_DIAGNOSTICS:-0}" = 1 ] && [ ! -e "$root/lab/webview-software-draw-enabled" ] || { echo DRAW_DIAGNOSTICS_REQUIRES_SEPARATE_WEB_DIAGNOSTICS;exit 89; }
 printf 'Public agreement software rendering comparison\n' > "$root/lab/webview-software-draw-enabled"
 chmod 0400 "$root/lab/webview-software-draw-enabled"
 diagnostic_dir="$root/data/local/tmp/kobo-webview-diagnostic"
 [ ! -L "$diagnostic_dir" ] || exit 90
 mkdir -p "$diagnostic_dir"
 rm -f "$diagnostic_dir/webview-direct-draw.png" "$diagnostic_dir/webview-capture-picture.png" "$diagnostic_dir/rendering-report.txt"
 chown 10007:10007 "$diagnostic_dir"
 chmod 0700 "$diagnostic_dir"
fi
if [ "${KOBO_WEREAD_TRACE_DIAGNOSTIC:-0}" = 1 ];then
 [ "${KOBO_WEREAD_DRAW_DIAGNOSTIC:-0}" = 1 ] && [ ! -e "$root/lab/webview-trace-started" ] && [ ! -e "$root/lab/webview-trace-complete" ] || { echo TRACE_REQUIRES_NEW_DRAW_DIAGNOSTIC;exit 96; }
fi
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "${KOBO_WEREAD_JIT:-0}" = 1 ];then
 [ "${KOBO_WEREAD_REUSE:-0}" = 1 ] && [ -f "$root/lab/libkobo_jit_config.so" ] && [ ! -L "$root/lab/libkobo_jit_config.so" ] || { echo JIT_REQUIRES_FIXED_EXISTING_INSTALLATION_AND_COMPONENT;exit 122; }
 printf 'Fixed WeRead ART JIT configuration\n' > "$root/lab/weread-jit-enabled"
 chmod 0400 "$root/lab/weread-jit-enabled"
fi
if [ "$heap_headroom" = 1 ];then
 printf 'Bounded WeRead heap headroom trial\n' > "$root/lab/weread-heap-headroom-enabled"
 chmod 0400 "$root/lab/weread-heap-headroom-enabled"
 echo WEREAD_HEAP_HEADROOM_REQUESTED_MIN4M_MAX8M
fi
if [ "$display_cadence" = 15 ];then
 printf 'Bounded reading cadence 15 Hz\n' > "$root/lab/display-cadence15-enabled"
 chmod 0400 "$root/lab/display-cadence15-enabled"
 echo WEREAD_DISPLAY_CADENCE_REQUESTED_15
fi
[ -z "$ashmem_mod" ] || { insmod "$kmods/ashmem_linux.ko";ashmem_loaded=1; }
insmod "$kmods/binder_linux.ko";binder_loaded=1
insmod "$kmods/kobo_madvise.ko";vm_loaded=1
mkdir -p "$root/dev" "$root/proc" "$root/sys" "$root/data" "$root/tmp"
for entry in 'null 1 3' 'zero 1 5' 'random 1 8' 'urandom 1 9';do set -- $entry;[ -c "$root/dev/$1" ] || mknod "$root/dev/$1" c "$2" "$3";done
for name in binder ashmem kobo_madvise;do
 # binder_linux registers class binder (Libra 2) or binder32 (Libra Colour, beside the built-in protocol-8 binder).
 if [ "$name" = binder ];then if [ -e /sys/class/binder32/binder32/dev ];then number=$(cat /sys/class/binder32/binder32/dev);else number=$(cat /sys/class/binder/binder/dev);fi;else number=$(cat "/sys/class/misc/$name/dev");fi
 rm -f "$root/dev/$name"
 mknod "$root/dev/$name" c "${number%:*}" "${number#*:}"
done
mount -t proc -o ro proc "$root/proc"
proc_mounted=1
rm -rf "$root/dev/__properties__"
mkdir -p "$root/dev/socket"
if [ "${KOBO_WEREAD_HOST_NETWORK:-0}" = 1 ];then
 [ ! -e "$root/dev/socket/dnsproxyd" ] || { echo EXISTING_DNS_ENDPOINT;exit 86; }
 dns_mode=
 if [ "${KOBO_WEREAD_HOST_NETWORK_STATE:-0}" = 1 ];then
  [ ! -e "$root/dev/socket/fwmarkd" ] || { echo EXISTING_FWMARK_ENDPOINT;exit 108; }
  host_network_mode=
  [ "${KOBO_WEREAD_INTERACTIVE:-0}" != 1 ] || host_network_mode=--session
  [ "$session_seconds" != 1800 ] || host_network_mode=--reading-session
  [ "$resident" != 1 ] || host_network_mode=--resident
: > "$root/lab/host-default-network.log"
  "$root/lab/host-default-network" $host_network_mode > "$root/lab/host-default-network.log" 2>&1 &
  host_network_pid=$!
  if [ "$startup_profile" = reading ];then
   wait_log_ready host_network "$host_network_pid" "$root/lab/host-default-network.log" HOST_DEFAULT_NETWORK_READY file "$root/lab/network-state/host-default.properties" || exit 128
  else sleep 1;fi
  kill -0 "$host_network_pid"
  [ -f "$root/lab/network-state/host-default.properties" ] || exit 109
  cp "$root/lab/network-state/host-default.properties" "$root/lab/host-default-observed.txt"
  printf 'Observed host default network alias\n' > "$root/lab/host-default-network-enabled"
  chmod 0400 "$root/lab/host-default-network-enabled"
  dns_mode=--host-default
  [ "${KOBO_WEREAD_INTERACTIVE:-0}" != 1 ] || dns_mode=--host-default-session
  [ "$session_seconds" != 1800 ] || dns_mode=--host-default-reading-session
 fi
: > "$root/lab/dns-proxy.log"
 if [ "$resident" = 1 ];then
  # Resident proxy: same protocol plus the public-resolver fallback; restarted if it ends.
  ( dns_child=;trap '[ -z "$dns_child" ] || kill -TERM "$dns_child" 2>/dev/null;wait 2>/dev/null;exit 0' TERM INT
    while :;do rm -f "$root/dev/socket/dnsproxyd";/mnt/onboard/.adds/kobo-android-lab/resident-v197/dns-proxy-resident --host-default-resident & dns_child=$!;wait "$dns_child" || :;dns_child=;echo RESIDENT_DNS_PROXY_RESTART;sleep 0.2;done ) > "$root/lab/dns-proxy.log" 2>&1 &
 else
 "$root/lab/dns-proxy" $dns_mode > "$root/lab/dns-proxy.log" 2>&1 &
 fi
 dns_pid=$!
 if [ "$startup_profile" = reading ];then
  wait_log_ready dns "$dns_pid" "$root/lab/dns-proxy.log" HOST_DNS_PROXY_READY socket "$root/dev/socket/dnsproxyd" || exit 128
 else sleep 1;fi
 kill -0 "$dns_pid"
fi
: > "$root/lab/property-server.log"
chroot "$root" /system/bin/sh -c 'export KOBO_PROPERTY_DAEMON=1 LD_PRELOAD=/lab/native-resolution/property-server.so; exec /system/bin/sh -c true' > "$root/lab/property-server.log" 2>&1 &
property_pid=$!
if [ "$startup_profile" = reading ];then
 [ ! -e "$root/dev/socket/lmkd" ] && [ ! -L "$root/dev/socket/lmkd" ] || { echo EXISTING_LMKD_SOCKET;exit 136; }
 "$root/lab/priority-broker" > "$root/lab/priority-broker.log" 2>&1 &
 priority_pid=$!
 wait_log_ready priority "$priority_pid" "$root/lab/priority-broker.log" PRIORITY95_READY socket "$root/dev/socket/lmkd" || exit 136
fi
if [ "$startup_profile" = reading ];then
 wait_log_ready properties "$property_pid" "$root/lab/property-server.log" ANDROID_PROPERTY_SERVER_READY socket "$root/dev/socket/property_service" || exit 128
else sleep 1;fi
kill -0 "$property_pid"
[ -S "$root/dev/socket/property_service" ] || { cat "$root/lab/property-server.log";exit 8; }
mkdir -p "$root/dev/socket"
: > "$root/lab/android.log"
"$root/lab/android-log-capture" "$root/dev/socket/logdw" > "$root/lab/android.log" 2>&1 &
logger_pid=$!
if [ "$startup_profile" = reading ];then
 wait_log_ready logging "$logger_pid" "$root/lab/android.log" ANDROID_LOG_CAPTURE_READY socket "$root/dev/socket/logdw" || exit 128
else sleep 1;fi
mkdir -p "$root/data/tombstones" "$root/data/anr"
chroot "$root" /system/bin/debuggerd > "$root/lab/debuggerd.log" 2>&1 &
debugger_pid=$!
sleep 0.2
printf 'Native Android shell: '
chroot "$root" /system/bin/sh -c 'echo BIONIC_SHELL_OK'
chroot "$root" /system/bin/servicemanager > "$root/lab/servicemanager.log" 2>&1 &
manager_pid=$!
poll_until 30 '[ -e "$root/dev/binder" ] && grep -q "^State:.*S" /proc/$manager_pid/status' || :
if ! kill -0 "$manager_pid" 2>/dev/null;then cat "$root/lab/servicemanager.log";echo 'servicemanager exited';exit 4;fi
printf 'Android service list:\n'
timeout 8 chroot "$root" /system/bin/service list
printf 'PASS: Android native service manager and Binder service-list transaction\n'

export ANDROID_ROOT=/system ANDROID_DATA=/data ANDROID_STORAGE=/storage EXTERNAL_STORAGE=/storage/emulated/legacy
export BOOTCLASSPATH=/system/framework/core-oj.jar:/system/framework/core-libart.jar:/system/framework/conscrypt.jar:/system/framework/okhttp.jar:/system/framework/core-junit.jar:/system/framework/bouncycastle.jar:/system/framework/ext.jar:/system/framework/framework.jar:/system/framework/telephony-common.jar:/system/framework/voip-common.jar:/system/framework/ims-common.jar:/system/framework/apache-xml.jar:/system/framework/org.apache.http.legacy.boot.jar
mkdir -p "$root/data/dalvik-cache/arm"
if [ "$startup_diagnostics" = 1 ];then
 "$root/lab/vm-helper-smoke" "$root/dev/kobo_madvise" "$root/lab/madvise-private-test"
fi
export CLASSPATH=/lab/install-framework-probe.dex:/system/framework/services.jar
mkdir -p "$root/dev/graphics"
# Codex's RAM scanout (ram-display variant): keep the 17 MB virtual framebuffer,
# rewritten every frame, out of the image so fsync no longer has to write it
# back through loop and vfat. Off with fast/ramfb-disabled.
if [ ! -e /mnt/onboard/.adds/kobo-android-lab/fast-v197/ramfb-disabled ];then
 [ ! -L "$root/dev/graphics" ] && [ ! -L "$root/dev/graphics/fb0" ] || exit 140
 ! mountpoint -q "$root/dev/graphics" || exit 140
 # Only the transient virtual scanout is reset. No physical device or app data.
 if [ -e "$root/dev/graphics/fb0" ];then
  [ -f "$root/dev/graphics/fb0" ] && [ "$(stat -c %u "$root/dev/graphics/fb0")" = 0 ] || exit 140
  : > "$root/dev/graphics/fb0"
 fi
 mount -t tmpfs -o size=24m,mode=0755,nosuid,nodev,noexec kobo-ram-scanout "$root/dev/graphics"
 graphics_ram_mounted=1
 case "$(stat -f -c %t "$root/dev/graphics")" in 1021994|01021994) :;; *) echo RAM_FB_WRONG_FILESYSTEM;exit 140;;esac
 echo RAM_FB_BACKING_ACTIVE filesystem=tmpfs limit_mib=24 pixel_buffer_bytes=16988160
fi
# This is a newly created regular file, never a device node or bind mount.
[ ! -e "$root/dev/graphics/fb0" ] || [ -f "$root/dev/graphics/fb0" ] || exit 9
# Sparse (2026-11-08): pages are allocated only where something writes. With
# the single-buffer HWC the second half is never written and costs no memory.
# fast/fbsingle-disabled (the HWC keeps flipping halves) restores the old fill.
if [ -e /mnt/onboard/.adds/kobo-android-lab/fast-v197/fbsingle-disabled ];then
 dd if=/dev/zero of="$root/dev/graphics/fb0" bs=5056 count=3360 2>/dev/null
else
 dd if=/dev/zero of="$root/dev/graphics/fb0" bs=5056 seek=3360 count=0 2>/dev/null
fi
chroot "$root" /system/bin/sh -c 'LD_PRELOAD=/lab/native-resolution/libkobo_fb.so:/lab/native-resolution/virtual-fb-probe.so /system/bin/sh -c true'
if [ "$startup_diagnostics" = 1 ];then
 chroot "$root" /system/bin/sh -c 'LD_PRELOAD=/lab/native-resolution/libkobo_fb.so:/lab/native-resolution/virtual-fb-probe.so /system/bin/sh -c true'
fi
printf 'SurfaceFlinger on the file-backed display:\n'
chroot "$root" /system/bin/sh -c 'LD_PRELOAD=/lab/native-resolution/libkobo_fb.so:/lab/libkobo_vm.so exec /system/bin/surfaceflinger' > "$root/lab/surfaceflinger.log" 2>&1 &
sf_pid=$!
poll_until 50 'service_found SurfaceFlinger || ! kill -0 "$sf_pid" 2>/dev/null' || :
kill -0 "$sf_pid"
mkdir -p "$root/data/misc/user" "$root/data/user" "$root/data/user_de/0" "$root/data/app" "$root/data/app-lib" "$root/data/app-private" "$root/data/app-asec" "$root/data/dalvik-cache" "$root/data/system" "$root/data/local/tmp" "$root/system/app" "$root/system/priv-app"
mkdir -p "$root/data/misc_ce" "$root/data/misc_de" "$root/data/data" "$root/data/system_de/0" "$root/data/system_ce/0" "$root/data/misc/profiles/cur/0" "$root/data/misc/profiles/ref"
if [ -d "$root/data/user/0" ] && [ ! -L "$root/data/user/0" ];then rmdir "$root/data/user/0";fi
[ -L "$root/data/user/0" ] || ln -s /data/data "$root/data/user/0"
# Vold sees only experiment-owned mount records and cannot enumerate host PIDs.
if awk -v p="$root/sys" '$2==p || index($2,p "/")==1 {found=1} END {exit !found}' /proc/mounts;then echo UNEXPECTED_SYS_MOUNT;exit 34;fi
[ -z "$(find "$root/dev" -type b -print)" ] || { echo UNEXPECTED_BLOCK_DEVICES;exit 35; }
mkdir -p "$root/dev/block" "$root/data/media" "$root/data/misc/vold" "$root/mnt/secure/asec" "$root/mnt/asec" "$root/mnt/obb" "$root/storage" "$root/lab/vold-owned-proc"
[ -z "$(ls -A "$root/lab/vold-owned-proc")" ] || { echo NONEMPTY_VOLD_PROCESS_SCOPE;exit 36; }
awk -v root="$root" '$2==root || index($2,root "/")==1 {path=substr($2,length(root)+1);$2=(path==""?"/":path);print}' /proc/mounts > "$root/lab/vold-owned-mounts"
chmod 0444 "$root/lab/vold-owned-mounts"
for hardware in '' goldfish ranchu;do
 printf '# Private existing data; no vold-managed disks.\nnone /data ext4 defaults defaults\n' > "$root/fstab.$hardware"
done
"$root/lab/install-vold-socket-exec" "$root" > "$root/lab/vold.log" 2>&1 &
vold_pid=$!
poll_until 50 '[ -S "$root/dev/socket/vold" ] || ! kill -0 "$vold_pid" 2>/dev/null' || :
kill -0 "$vold_pid" || { cat "$root/lab/vold.log";exit 37; }
"$root/lab/install-android-socket-exec" "$root" > "$root/lab/installd.log" 2>&1 &
installer_pid=$!
if [ "$startup_profile" = reading ];then
 wait_installd_ready "$installer_pid" "$root" || exit 128
else sleep 2;fi
kill -0 "$installer_pid" || { cat "$root/lab/installd.log";exit 13; }
if [ "$startup_diagnostics" = 1 ];then
 "$root/lab/installd-ping" "$root"
fi
[ ! -e "$root/acct" ] && [ ! -L "$root/acct" ] || { echo UNEXPECTED_ACCT_PATH;exit 14; }
mkdir -p "$root/dev/input"
chroot "$root" /system/bin/sh -c 'LD_PRELOAD=/lab/libkobo_vm.so exec /system/bin/sensorservice' > "$root/lab/sensorservice.log" 2>&1 &
sensor_pid=$!
poll_until 30 'service_found sensorservice || ! kill -0 "$sensor_pid" 2>/dev/null' || :
kill -0 "$sensor_pid" || { cat "$root/lab/sensorservice.log";exit 15; }
chmod 0666 "$root/dev/binder" "$root/dev/ashmem" "$root/dev/kobo_madvise" "$root/dev/null" "$root/dev/zero"
if [ "${KOBO_WEREAD_HOST_NETWORK_STATE:-0}" = 1 ] && [ "$startup_diagnostics" = 1 ];then
 timeout 80 "$root/lab/network-uid-exec" "$root" > "$root/lab/host-network-https-probe.log" 2>&1 || { cat "$root/lab/host-network-https-probe.log";exit 110; }
 cat "$root/lab/host-network-https-probe.log"
fi
if [ "${KOBO_WEREAD_NATIVE_AUDIO:-0}" = 1 ];then
 # No host sound/input/block devices are exposed to this original Android daemon.
 [ ! -e "$root/dev/eac" ] && [ ! -e "$root/dev/goldfish_audio" ] && [ ! -e "$root/dev/snd" ] || exit 62
 mkdir -p "$root/data/misc/audioserver"
 chown 1041:1005 "$root/data/misc/audioserver"
 chmod 0700 "$root/data/misc/audioserver"
 "$root/lab/native-audio-exec" "$root" > "$root/lab/native-audio.log" 2>&1 &
 audio_pid=$!
 poll_until 80 '{ service_found media.audio_policy && service_found media.audio_flinger; } || ! kill -0 "$audio_pid" 2>/dev/null' || :
 kill -0 "$audio_pid" || { cat "$root/lab/native-audio.log";exit 63; }
 timeout 8 chroot "$root" /system/bin/service list > "$root/lab/native-audio-services.txt"
 grep -q 'media.audio_policy:' "$root/lab/native-audio-services.txt" || exit 64
 grep -q 'media.audio_flinger:' "$root/lab/native-audio-services.txt" || exit 65
 awk '/^(Name|Uid|Gid|Groups|CapEff):/' "/proc/$audio_pid/status" > "$root/lab/native-audio-identity.txt"
 grep -q '^CapEff:[[:space:]]*0000000000000000$' "$root/lab/native-audio-identity.txt" || exit 66
 echo ANDROID_NATIVE_AUDIO_SERVICES_REGISTERED_NO_HOST_AUDIO_DEVICES
fi
rm -f "$root/lab/install-processes.pid" "$root/lab/install-result.txt" "$root/lab/app-probe.pid" "$root/lab/apk-process.log" "$root/lab/activity-window.png" "$root/lab/activity-returned-home.png" "$root/lab/server-entry-error.txt"
[ ! -e "$root/dev/socket/zygote" ] || { echo EXISTING_ZYGOTE_SOCKET;exit 32; }
: > "$root/lab/process-broker.log"
"$root/lab/install-process-broker" "$root" > "$root/lab/process-broker.log" 2>&1 &
broker_pid=$!
if [ "$startup_profile" = reading ];then
 wait_log_ready processes "$broker_pid" "$root/lab/process-broker.log" KOBO_INSTALL_PACKAGE_PROCESS_BROKER_READY socket "$root/dev/socket/zygote" || exit 128
else sleep 1;fi
kill -0 "$broker_pid" || { cat "$root/lab/process-broker.log";exit 33; }
KOBO_VM_SHIM=1 timeout 20 "$root/lab/legacy-exec" "$root" /system/bin/app_process32 -Xnorelocate -Xnoimage-dex2oat -Xnodex2oat /system/bin FrameworkProbe heap-properties unused
# System metadata changes ownership; app-owned directories keep their UIDs.
mkdir -p "$root/data/resource-cache" "$root/cache"
chown 1000:1000 "$root/data" "$root/data/data" "$root/data/user" "$root/data/user_de" "$root/data/user_de/0" "$root/data/app" "$root/data/app-lib" "$root/data/app-private" "$root/data/app-asec" "$root/data/misc" "$root/data/resource-cache" "$root/cache"
chmod 0771 "$root/data" "$root/data/data" "$root/data/user_de" "$root/data/user_de/0" "$root/data/app"
chown -hR 1000:1000 "$root/data/system" "$root/data/system_ce" "$root/data/system_de" "$root/data/anr" "$root/data/misc/user"
for area in data/data data/user_de/0;do
 for package in android com.android.providers.settings;do
  [ ! -d "$root/$area/$package" ] || chown -hR 1000:1000 "$root/$area/$package"
 done
done
/bin/sh "$root/lab/native-resolution/native-memory-watchdog.sh" "$$" > "$root/lab/native-resolution/memory.log" 2>&1 &
memory_pid=$!
if [ "$resident" = 1 ];then
 # Marker read by the launcher (HOME) when it is created; requests go back
 # through the launcher's own files directory and a root-only host directory.
 case "$(stat -c %u:%a "$root/data/local/tmp")" in 0:755|0:771|2000:771) :;; *) echo RESIDENT_TMP_DIRECTORY_UNEXPECTED;exit 142;;esac
 [ ! -L "$root/data/local/tmp" ] || { echo RESIDENT_TMP_DIRECTORY_UNEXPECTED;exit 142; }
 rm -rf "$root/data/local/tmp/kobo-resident" "$root/lab/resident"
 mkdir -m 0755 "$root/data/local/tmp/kobo-resident";mkdir -m 0700 "$root/lab/resident"
 printf 'resident launcher\n' > "$root/data/local/tmp/kobo-resident/enabled";chmod 0644 "$root/data/local/tmp/kobo-resident/enabled"
 rm -f "$root/data/data/com.kobo.lab.smoke/files/resident-request" "$root/data/data/com.kobo.lab.smoke/files/resident-request.pending"
fi
startup_stage framework_begin
server_mode=install-server
server_execution=-Xint
if [ "$startup_profile" = reading ];then
 server_mode=reading-server;server_execution=-Xusejit:true
 [ ! -e "$root/lab/framework-jit-enabled" ] && [ ! -L "$root/lab/framework-jit-enabled" ] || exit 130
 printf "Fixed reading system server JIT\n" > "$root/lab/framework-jit-enabled"
 chmod 0400 "$root/lab/framework-jit-enabled"
fi
printf 'Android display service bootstrap:\n' 
CLASSPATH=/lab/install-server-launcher.dex KOBO_VM_SHIM=1 "$root/lab/system-server-exec" "$root" /system/bin/app_process32 "$server_execution" -Xnorelocate -Xnoimage-dex2oat -Xnodex2oat -Xms8m -Xmx128m /system/bin ServerLauncher "$server_mode" unused > "$root/lab/display-service.log" 2>&1 &
dms_pid=$!
ready=0
attempt=0
while [ "$attempt" -lt 450 ];do
 attempt=$((attempt+1))
 if grep -q ANDROID_DISPLAY_MANAGER_DEFAULT_READY "$root/lab/display-service.log";then ready=1;break;fi
 kill -0 "$dms_pid" 2>/dev/null || break
 if [ "$attempt" = 250 ];then kill -QUIT "$dms_pid";fi
 sleep 0.2
done
[ "$ready" = 1 ] || { echo DISPLAY_SERVICE_NOT_READY;cat "$root/data/system/kobo-server-entry-error.txt" 2>/dev/null || :;cat "$root/data/anr/traces.txt" 2>/dev/null || :;exit 10; }
timeout 8 chroot "$root" /system/bin/service list
if [ "$startup_profile" = reading ];then
 bootstrap_ready=0
 for attempt in $(seq 1 200);do
  if grep -q APK_READING_APPLICATION_READY "$root/lab/apk-process.log" "$root/lab/android.log" 2>/dev/null && grep -q ANDROID_AMS_SYSTEM_READY_COMPLETED "$root/lab/display-service.log" && grep -q WEREAD_DB_STARTUP_CALLBACK_PROBE_OK "$root/lab/display-service.log";then bootstrap_ready=1;break;fi
  kill -0 "$dms_pid" 2>/dev/null || break
  if grep -q 'FATAL EXCEPTION' "$root/lab/android.log";then break;fi
  sleep 0.2
 done
 [ "$bootstrap_ready" = 1 ] || { echo READING_APPLICATION_BOOTSTRAP_NOT_READY;exit 126; }
 /mnt/onboard/.adds/kobo-android-lab/fast-v197/audit-runtime-fds
 echo ANDROID_READING_BOOTSTRAP_READY_NO_TEST_ACTIVITY
else
printf 'Wait for APK Activity resume:\n'
resumed=0
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30;do
 if grep -q APK_ACTIVITY_ONRESUME "$root/lab/apk-process.log" "$root/lab/android.log" 2>/dev/null;then resumed=1;break;fi
 if grep -q "FATAL EXCEPTION" "$root/lab/android.log";then break;fi
 kill -0 "$dms_pid" 2>/dev/null || break
 sleep 1
done
[ "$resumed" = 1 ] || { echo APK_ACTIVITY_NOT_RESUMED;exit 25; }
sleep 1
if [ "$startup_diagnostics" = 1 ];then
KOBO_VM_SHIM=1 timeout 20 "$root/lab/legacy-exec" "$root" /system/bin/app_process32 -Xnorelocate -Xnoimage-dex2oat -Xnodex2oat /system/bin FrameworkProbe capture-scanout /lab/activity-window.png
fi
/mnt/onboard/.adds/kobo-android-lab/fast-v197/audit-runtime-fds
finished=0
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20;do
 if grep -q APK_ACTIVITY_ONDESTROY "$root/lab/apk-process.log" "$root/lab/android.log" && grep -q APK_ACTIVITY_RETURNED_TO_HOME "$root/lab/apk-process.log" "$root/lab/android.log";then finished=1;break;fi
 sleep 1
done
[ "$finished" = 1 ] || { echo APK_LIFECYCLE_NOT_COMPLETED;exit 26; }
grep -q APK_ACTIVITY_RETURNED_TO_HOME "$root/lab/apk-process.log" "$root/lab/android.log" || { echo APK_HOME_NOT_RESUMED;exit 27; }
sleep 1
if [ "$startup_diagnostics" = 1 ];then
KOBO_VM_SHIM=1 timeout 20 "$root/lab/legacy-exec" "$root" /system/bin/app_process32 -Xnorelocate -Xnoimage-dex2oat -Xnodex2oat /system/bin FrameworkProbe capture-scanout /lab/activity-returned-home.png
fi
echo ANDROID_REAL_APK_ACTIVITY_LIFECYCLE_OK
fi
CLASSPATH=/lab/native-resolution/native-check.dex KOBO_VM_SHIM=1 timeout 30 "$root/lab/legacy-exec" "$root" /system/bin/app_process32 -Xnorelocate -Xnoimage-dex2oat -Xnodex2oat /system/bin NativeResolutionCheck
fast_animation off
startup_stage app_launch_begin
if [ "$resident" = 1 ];then
 . /mnt/onboard/.adds/kobo-android-lab/resident-v197/resident-loop.sh
 resident_rc=0;resident_main || resident_rc=$?
 android_thaw
 resident_state stopping
 "$base/resident-v197/resident-sched" normal
 fast_animation on
 echo "WEREAD_RESIDENT_SESSION_ENDED result=$resident_rc"
 exit "$resident_rc"
fi
if [ "${KOBO_WEREAD_LIVE_DISPLAY:-0}" = 1 ] && [ "${KOBO_WEREAD_TOUCH_TEST:-0}" != 1 ];then
 "$root/lab/native-resolution/live-display" 240 "$display_profile" > "$root/lab/native-resolution/live-display.log" 2>&1 &
 bridge_pid=$!
 sleep 2
 kill -0 "$bridge_pid" || { cat "$root/lab/native-resolution/live-display.log";exit 70; }
fi

printf 'Install the original WeRead APK using a real Session:\n'
if [ "$startup_profile" = reading ];then
 printf 'Finite initial DB service grace\n' > "$root/lab/weread-startup-service-grace"
 chmod 0400 "$root/lab/weread-startup-service-grace"
fi
if [ "${KOBO_WEREAD_REUSE:-0}" = 1 ];then
 [ -n "$previous_weread_uid" ] || { echo NO_PERSISTED_WEREAD_IDENTITY;exit 56; }
 KOBO_VM_SHIM=1 timeout "$existing_launch_timeout" "$root/lab/legacy-exec" "$root" /system/bin/app_process32 -Xnorelocate -Xnoimage-dex2oat -Xnodex2oat /system/bin FrameworkProbe launch-weread "$previous_weread_uid"
else
KOBO_VM_SHIM=1 timeout 250 "$root/lab/legacy-exec" "$root" /system/bin/app_process32 -Xnorelocate -Xnoimage-dex2oat -Xnodex2oat /system/bin FrameworkProbe install-apk /lab/weread.apk
fi
# Observe the real app; no claim of Activity success based only on startActivity's return.
main_display_pattern='Displayed com.tencent.weread.eink/com.tencent.weread.WeReadFragmentActivity'
if [ "${KOBO_WEREAD_INTERACTIVE:-0}" = 1 ];then main_display_pattern='Displayed com.tencent.weread.eink/com.tencent.weread.(WeReadFragmentActivity|ReaderFragmentActivity)';fi
observation_limit=75
if [ "${KOBO_WEREAD_TOUCH_TEST:-0}" = 1 ] || [ "${KOBO_WEREAD_DIAGNOSTIC_TAP:-0}" = 1 ] || [ "${KOBO_WEREAD_AGREEMENT_DIAG:-0}" = 1 ];then observation_limit=60;fi
[ "$startup_profile" != reading ] || observation_limit=120
for observation in $(seq 1 "$observation_limit");do
 if grep -Fq "ANR in com.tencent.weread.eink" "$root/lab/android.log";then echo WEREAD_STARTUP_ANR_DETECTED;exit 129;fi
 if grep -q "FATAL EXCEPTION" "$root/lab/android.log";then sleep 2;break;fi
 if { [ "${KOBO_WEREAD_TOUCH_TEST:-0}" = 1 ] || [ "${KOBO_WEREAD_DIAGNOSTIC_TAP:-0}" = 1 ] || [ "${KOBO_WEREAD_AGREEMENT_DIAG:-0}" = 1 ]; } && grep -Eq "$main_display_pattern" "$root/lab/android.log";then sleep 1;break;fi
 if grep -q 'REJECTED_ARG_.*--nice-name=com.tencent.weread.eink' "$root/lab/process-broker.log";then break;fi
 sleep 1
done
if [ "$startup_diagnostics" = 1 ];then
KOBO_VM_SHIM=1 timeout 20 "$root/lab/legacy-exec" "$root" /system/bin/app_process32 -Xnorelocate -Xnoimage-dex2oat -Xnodex2oat /system/bin FrameworkProbe capture-scanout /lab/weread-first-launch.png
fi
if [ "${KOBO_WEREAD_INTERACTIVE:-0}" = 1 ] && [ -z "$bridge_pid" ] && grep -Eq "$main_display_pattern" "$root/lab/android.log";then
 # Show WeRead as soon as its Activity is drawn; the audits below and touch
 # setup continue afterwards.
 # The common cleanup stops the bridge and restores the screen on any exit.
 "$root/lab/native-resolution/live-display" "$interactive_bridge_seconds" "$display_profile" > "$root/lab/native-resolution/live-display.log" 2>&1 &
 bridge_pid=$!
 poll_until 40 'grep -q LIVE_DISPLAY_STARTED "$root/lab/native-resolution/live-display.log" || ! kill -0 "$bridge_pid" 2>/dev/null' || :
 kill -0 "$bridge_pid" || exit 115
 startup_stage display_visible
fi
/mnt/onboard/.adds/kobo-android-lab/fast-v197/audit-runtime-fds
if grep -Fq "ANR in com.tencent.weread.eink" "$root/lab/android.log";then echo WEREAD_STARTUP_ANR_DETECTED;exit 129;fi
if grep -q 'FATAL EXCEPTION' "$root/lab/android.log";then echo WEREAD_APP_FATAL_DETECTED;exit 57;fi
if ! grep -q 'PROCESS_BROKER_EXEC_OK package=com.tencent.weread.eink ' "$root/lab/process-broker.log";then echo WEREAD_PROCESS_NOT_STARTED;exit 58;fi
if grep -q 'No pending application record for pid' "$root/lab/android.log";then echo WEREAD_PID_ATTACH_MISMATCH;exit 59;fi
if ! grep -Eq "$main_display_pattern" "$root/lab/android.log";then echo WEREAD_MAIN_ACTIVITY_DISPLAY_NOT_CONFIRMED;exit 61;fi
if [ "${KOBO_WEREAD_INTERACTIVE:-0}" = 1 ];then echo WEREAD_REAL_SUPPORTED_ACTIVITY_DISPLAYED;else echo WEREAD_REAL_MAIN_ACTIVITY_DISPLAYED;fi
startup_stage activity_displayed
rm -f "$root/lab/weread-startup-service-grace"
if [ "${KOBO_WEBVIEW_SOFTWARE_SURFACE:-0}" = 1 ];then
 mapped=0;webview_loaded=0
 while read owned_pid;do
  case "$owned_pid" in ''|*[!0-9]*) continue;;esac
  [ "$(readlink "/proc/$owned_pid/root" 2>/dev/null)" = "$root" ] || continue
  [ "$(readlink "/proc/$owned_pid/exe" 2>/dev/null)" = "$root/system/bin/app_process32" ] || continue
  [ "$(awk '/^Uid:/ {print $2}' /proc/$owned_pid/status)" = 10007 ] || continue
  if grep -q 'libwebviewchromium.so' "/proc/$owned_pid/maps";then webview_loaded=1;fi
  if grep -F "$root/system/app/webview/lib/arm/libwebviewchromium.so" "/proc/$owned_pid/maps" > "$root/lab/patched-webview-mapping.txt";then mapped=1;break;fi
 done < "$root/lab/install-processes.pid"
 if [ "$mapped" = 1 ];then
  echo PATCHED_WEBVIEW_NATIVE_MAPPING_AUDITED
 elif [ "$webview_loaded" = 0 ] && [ "${KOBO_WEREAD_INTERACTIVE:-0}" = 1 ] && grep -q 'Displayed com.tencent.weread.eink/com.tencent.weread.ReaderFragmentActivity' "$root/lab/android.log";then
  # Native reader startup need not instantiate WebView. The outer wrapper has
  # hash-checked the selected component for any later lazy WebView loading.
  # Do not claim an actual native mapping when no WebView library is loaded.
  echo WEREAD_NATIVE_READER_WEBVIEW_NOT_LOADED
 else echo PATCHED_WEBVIEW_MAPPING_NOT_FOUND;exit 105
 fi
fi
if [ "${KOBO_WEREAD_TRACE_DIAGNOSTIC:-0}" = 1 ];then
 echo WEREAD_WEBVIEW_TRACE_START_READY
 for trace_wait in $(seq 1 30);do [ ! -f "$root/lab/webview-trace-started" ] || break;sleep 1;done
 [ -f "$root/lab/webview-trace-started" ] || { echo TRACE_CLIENT_NOT_READY;exit 97; }
fi
if [ "${KOBO_WEREAD_AGREEMENT_DIAG:-0}" = 1 ];then
 CLASSPATH=/lab/native-resolution/weread-process-entry.dex:/lab/install-framework-probe.dex KOBO_VM_SHIM=1 timeout 55 "$root/lab/legacy-exec" "$root" /system/bin/app_process32 -Xnorelocate -Xnoimage-dex2oat -Xnodex2oat /system/bin AgreementPageDiagnostic
 kill -0 "$dns_pid"
 if [ "${KOBO_WEREAD_DRAW_DIAGNOSTIC:-0}" = 1 ];then
  report="$root/data/local/tmp/kobo-webview-diagnostic/rendering-report.txt"
  for draw_wait in $(seq 1 30);do [ ! -f "$report" ] || break;sleep 1;done
  [ -f "$report" ] || { echo SOFTWARE_DRAW_REPORT_MISSING;exit 91; }
  cat "$report"
  echo WEREAD_SOFTWARE_DRAW_COMPARISON_SAVED
  if [ "${KOBO_WEREAD_TRACE_DIAGNOSTIC:-0}" = 1 ];then
   for trace_wait in $(seq 1 30);do [ ! -f "$root/lab/webview-trace-complete" ] || break;sleep 1;done
   [ -f "$root/lab/webview-trace-complete" ] || { echo TRACE_CLIENT_NOT_FINISHED;exit 98; }
  fi
 elif [ "${KOBO_WEREAD_WEB_DIAGNOSTICS:-0}" = 1 ];then echo WEREAD_WEBVIEW_READ_DIAGNOSTIC_READY;sleep 90;fi
fi
if [ "${KOBO_WEREAD_DIAGNOSTIC_TAP:-0}" = 1 ];then
 CLASSPATH=/lab/native-resolution/weread-process-entry.dex:/lab/install-framework-probe.dex KOBO_VM_SHIM=1 timeout 50 "$root/lab/legacy-exec" "$root" /system/bin/app_process32 -Xnorelocate -Xnoimage-dex2oat -Xnodex2oat /system/bin LoginTapDiagnostic
fi
if [ "${KOBO_WEREAD_INPUT_TEST:-0}" = 1 ] && [ "${KOBO_WEREAD_TOUCH_TEST:-0}" != 1 ] && [ "${KOBO_WEREAD_DIAGNOSTIC_TAP:-0}" != 1 ];then
 CLASSPATH=/lab/native-resolution/weread-process-entry.dex KOBO_VM_SHIM=1 timeout 25 "$root/lab/legacy-exec" "$root" /system/bin/app_process32 -Xnorelocate -Xnoimage-dex2oat -Xnodex2oat /system/bin WeReadInputProbe back-to-home
if [ "$startup_diagnostics" = 1 ];then
 KOBO_VM_SHIM=1 timeout 20 "$root/lab/legacy-exec" "$root" /system/bin/app_process32 -Xnorelocate -Xnoimage-dex2oat -Xnodex2oat /system/bin FrameworkProbe capture-scanout /lab/weread-input-returned-home.png
fi
 KOBO_VM_SHIM=1 timeout 60 "$root/lab/legacy-exec" "$root" /system/bin/app_process32 -Xnorelocate -Xnoimage-dex2oat -Xnodex2oat /system/bin FrameworkProbe launch-weread "$previous_weread_uid"
 sleep 15
 CLASSPATH=/lab/native-resolution/weread-process-entry.dex KOBO_VM_SHIM=1 timeout 20 "$root/lab/legacy-exec" "$root" /system/bin/app_process32 -Xnorelocate -Xnoimage-dex2oat -Xnodex2oat /system/bin WeReadInputProbe verify-login
if [ "$startup_diagnostics" = 1 ];then
 KOBO_VM_SHIM=1 timeout 20 "$root/lab/legacy-exec" "$root" /system/bin/app_process32 -Xnorelocate -Xnoimage-dex2oat -Xnodex2oat /system/bin FrameworkProbe capture-scanout /lab/weread-input-reopened.png
fi
 if grep -q 'FATAL EXCEPTION' "$root/lab/android.log";then echo WEREAD_INPUT_TEST_APP_FATAL;exit 67;fi
 echo WEREAD_BACK_AND_REOPEN_INPUT_TEST_OK
fi
if [ "${KOBO_WEREAD_INTERACTIVE:-0}" = 1 ];then
 [ ! -e "$root/dev/socket/kobo_touch_probe" ] || { echo EXISTING_TOUCH_ENDPOINT;exit 75; }
 rm -f "$root/lab/interactive-input-result.txt" "$root/lab/interactive-session-finish" "$root/lab/interactive-session-after.png"
 CLASSPATH=/lab/native-resolution/weread-process-entry.dex:/lab/install-framework-probe.dex KOBO_VM_SHIM=1 "$root/lab/legacy-exec" "$root" /system/bin/app_process32 -Xnorelocate -Xnoimage-dex2oat -Xnodex2oat /system/bin WeReadInteractiveInput "$session_seconds" > "$root/lab/touch-probe.log" 2>&1 &
 touch_java_pid=$!
 touch_ready=0
 for attempt in $(seq 1 150);do
  if grep -q ANDROID_TOUCH_PROBE_WINDOW_READY "$root/lab/touch-probe.log";then touch_ready=1;break;fi
  kill -0 "$touch_java_pid" 2>/dev/null || break;sleep 0.2
 done
 [ "$touch_ready" = 1 ] || { echo INTERACTIVE_INPUT_NOT_READY;exit 114; }
 kill -0 "$bridge_pid" || exit 115
 touch_launch_uptime=$(cut -d' ' -f1 /proc/uptime)
 "$root/lab/native-resolution/touch-forward" "$session_seconds" "$interactive_touch_option" > "$root/lab/native-resolution/touch-forward.log" 2>&1 &
 touch_pid=$!
 poll_until 30 'grep -q HOST_TOUCH_FORWARD_READY "$root/lab/native-resolution/touch-forward.log" || ! kill -0 "$touch_pid" 2>/dev/null' || :
 kill -0 "$touch_pid" || exit 116
 {
  echo "duration_seconds=$session_seconds"
  echo "touch_launch_uptime=$touch_launch_uptime"
  echo "ready_uptime=$(cut -d' ' -f1 /proc/uptime)"
  echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
  echo "display_pid=$bridge_pid"
  echo "display_start=$(awk '{print $22}' /proc/$bridge_pid/stat)"
  echo "touch_pid=$touch_pid"
  echo "touch_start=$(awk '{print $22}' /proc/$touch_pid/stat)"
 } > "$root/lab/interactive-session-ready"
 chmod 0400 "$root/lab/interactive-session-ready"
 startup_stage interactive_ready
 echo "WEREAD_INTERACTIVE_SESSION_READY human_input_only=1 max_seconds=$session_seconds exit=top-left-hold-release"
 reader_sampled=0
 for attempt in $(seq 1 "$session_seconds");do
  if [ "${KOBO_WEREAD_CAPTURE_READER_STACKS:-0}" = 1 ] && [ "$reader_sampled" = 0 ] && grep -q 'START u0 {cmp=com.tencent.weread.eink/com.tencent.weread.ReaderFragmentActivity' "$root/lab/android.log";then
   reader_sampled=1;sleep 8
   sh "$root/lab/capture-reader-stacks.sh" || echo READER_PRIVATE_STACK_CAPTURE_FAILED
  fi
  [ ! -e "$root/lab/interactive-session-finish" ] || { echo INTERACTIVE_MANUAL_EXIT_REQUESTED;break; }
  if grep -q 'FATAL EXCEPTION' "$root/lab/android.log";then echo INTERACTIVE_APP_FATAL;exit 117;fi
  if grep -Fq "ANR in com.tencent.weread.eink" "$root/lab/android.log";then echo INTERACTIVE_APP_ANR;exit 129;fi
  kill -0 "$touch_java_pid" 2>/dev/null || { echo INTERACTIVE_INPUT_PROCESS_EXITED;exit 118; }
  kill -0 "$bridge_pid" 2>/dev/null || { echo INTERACTIVE_DISPLAY_PROCESS_EXITED;exit 118; }
  kill -0 "$dns_pid" 2>/dev/null || { echo INTERACTIVE_DNS_PROCESS_EXITED;exit 118; }
  kill -0 "$host_network_pid" 2>/dev/null || { echo INTERACTIVE_HOST_NETWORK_OBSERVER_EXITED;exit 118; }
  kill -0 "$touch_pid" 2>/dev/null || break
  sleep 1
 done
 fast_animation on
 kill -TERM "$touch_pid" 2>/dev/null || :
 touch_result=0;wait "$touch_pid" || touch_result=$?;touch_pid=
 touch_finish_uptime=$(cut -d' ' -f1 /proc/uptime)
 touch_elapsed=$(awk -v start="$touch_launch_uptime" -v finish="$touch_finish_uptime" 'BEGIN {printf "%.2f",finish-start}')
 echo "WEREAD_INTERACTIVE_INPUT_RUNTIME launch_uptime=$touch_launch_uptime finish_uptime=$touch_finish_uptime elapsed_seconds=$touch_elapsed configured_seconds=$session_seconds result=$touch_result"
 cat "$root/lab/native-resolution/touch-forward.log"
 [ "$touch_result" = 0 ] || { echo INTERACTIVE_TOUCH_FORWARD_FAILED;exit 119; }
 kill -TERM "$touch_java_pid";wait "$touch_java_pid" 2>/dev/null || :;touch_java_pid=
 rm -f "$root/dev/socket/kobo_touch_probe" "$root/lab/interactive-session-finish"
 rm -f "$root/lab/interactive-session-ready"
 # Private diagnostic only: this image may contain a login QR or account data.
if [ "$startup_diagnostics" = 1 ];then
 KOBO_VM_SHIM=1 timeout 20 "$root/lab/legacy-exec" "$root" /system/bin/app_process32 -Xnorelocate -Xnoimage-dex2oat -Xnodex2oat /system/bin FrameworkProbe capture-scanout /lab/interactive-session-after.png
fi
 echo WEREAD_INTERACTIVE_SESSION_ENDED login_status=requires_human_confirmation
fi
if [ "${KOBO_WEREAD_TOUCH_TEST:-0}" = 1 ] && [ "${KOBO_WEREAD_INTERACTIVE:-0}" != 1 ];then
 [ ! -e "$root/dev/socket/kobo_touch_probe" ] || { echo EXISTING_TOUCH_ENDPOINT;exit 75; }
 rm -f "$root/lab/touch-probe-result.txt" "$root/lab/touch-test.png"
 touch_entry=WeReadTouchProbe
 [ "$touch_mode" != weread ] || touch_entry=WeReadPageTouchProbe
 CLASSPATH=/lab/native-resolution/weread-process-entry.dex:/lab/install-framework-probe.dex KOBO_VM_SHIM=1 "$root/lab/legacy-exec" "$root" /system/bin/app_process32 -Xnorelocate -Xnoimage-dex2oat -Xnodex2oat /system/bin "$touch_entry" > "$root/lab/touch-probe.log" 2>&1 &
 touch_java_pid=$!
 touch_ready=0
 for attempt in $(seq 1 30);do
  if grep -q ANDROID_TOUCH_PROBE_WINDOW_READY "$root/lab/touch-probe.log";then touch_ready=1;break;fi
  kill -0 "$touch_java_pid" 2>/dev/null || break
  sleep 1
 done
 [ "$touch_ready" = 1 ] || { echo TOUCH_WINDOW_NOT_READY;exit 76; }
 "$root/lab/native-resolution/live-display" 240 "$display_profile" > "$root/lab/native-resolution/live-display.log" 2>&1 &
 bridge_pid=$!
 sleep 2
 kill -0 "$bridge_pid" || { cat "$root/lab/native-resolution/live-display.log";exit 77; }
 if [ "$touch_mode" = weread ];then
  "$root/lab/native-resolution/touch-forward" 150 --one-gesture > "$root/lab/native-resolution/touch-forward.log" 2>&1 &
 else
  "$root/lab/native-resolution/touch-forward" 150 > "$root/lab/native-resolution/touch-forward.log" 2>&1 &
 fi
 touch_pid=$!
 sleep 1
 kill -0 "$touch_pid" || { cat "$root/lab/native-resolution/touch-forward.log";exit 78; }
 echo "WEREAD_PHYSICAL_TOUCH_TEST_READY mode=$touch_mode"
 touch_marker=ANDROID_PHYSICAL_FOUR_TARGETS_CLICKED_IN_ORDER
 [ "$touch_mode" != weread ] || touch_marker=ANDROID_WEREAD_PHYSICAL_GESTURE_DISPATCHED
 touch_done=0
 for attempt in $(seq 1 150);do
  if grep -q "$touch_marker" "$root/lab/touch-probe-result.txt" 2>/dev/null;then touch_done=1;break;fi
  kill -0 "$touch_pid" 2>/dev/null && kill -0 "$touch_java_pid" 2>/dev/null && kill -0 "$bridge_pid" 2>/dev/null || break
  sleep 1
 done
 [ "$touch_done" = 1 ] || { echo PHYSICAL_TOUCH_TEST_NOT_COMPLETED;exit 79; }
 if [ "$touch_mode" = weread ];then sleep 8;else sleep 2;fi
if [ "$startup_diagnostics" = 1 ];then
 KOBO_VM_SHIM=1 timeout 20 "$root/lab/legacy-exec" "$root" /system/bin/app_process32 -Xnorelocate -Xnoimage-dex2oat -Xnodex2oat /system/bin FrameworkProbe capture-scanout /lab/touch-test.png
fi
 if [ "$touch_mode" != weread ];then kill -TERM "$touch_pid" || exit 80;fi
 touch_result=0;wait "$touch_pid" || touch_result=$?;touch_pid=
 cat "$root/lab/native-resolution/touch-forward.log"
 [ "$touch_result" = 0 ] || exit 81
 kill -TERM "$touch_java_pid";wait "$touch_java_pid" 2>/dev/null || :;touch_java_pid=
 cat "$root/lab/touch-probe.log"
 rm -f "$root/dev/socket/kobo_touch_probe"
 sleep 2
 if [ "$touch_mode" = weread ];then echo WEREAD_REAL_PAGE_PHYSICAL_GESTURE_DISPATCH_OK;else echo WEREAD_PHYSICAL_FOUR_TARGET_TOUCH_TEST_OK;fi
fi
if [ -n "$bridge_pid" ];then
 kill -TERM "$bridge_pid" || exit 71
 bridge_result=0
 wait "$bridge_pid" || bridge_result=$?
 bridge_pid=
 cat "$root/lab/native-resolution/live-display.log"
 [ "$bridge_result" = 0 ] || exit 72
 grep -q LIVE_DISPLAY_FRAMEBUFFER_RESTORE_BYTES_MATCH "$root/lab/native-resolution/live-display.log" || exit 73
 echo WEREAD_LIVE_DISPLAY_AND_RESTORE_OK
fi
