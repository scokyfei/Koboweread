#!/bin/sh
# Build the WeRead 1.9.7 resident-launcher artifacts (sh src/resident-v197/build.sh; set KOBO_BUILD_OUT
# to an empty directory, KOBO_PROBE_STORE_PASSWORD only for the launcher APK). Same toolchain and flags as the
# verified Libra 2 native-resolution builds; only the resident changes differ.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
tools=${KOBO_TOOLS:-$root/tools}  # toolchain directory (bootstrap.sh)
jdk_home=$tools/jdk17/Contents/Home;[ -d "$jdk_home" ] || jdk_home=$tools/jdk17  # macOS bundle or Linux layout
# Everything comes from this repository: Codex's prototype tree is the
# snapshot in upstream/, tools and the lab test key are in tools/.
o=$root/upstream/codex-kobo-android
zig=$tools/ziglang/zig
fbink=$tools/fbink
jdk=$jdk_home
jar=$tools/android/android.jar
d8=$tools/android/d8.jar
aapt2=$tools/android/aapt2
keystore=${KOBO_KEYSTORE:-$tools/keys/activity-test-key.jks}  # KOBO_KEYSTORE: your own (alias lab), see public/README
export ZIG_GLOBAL_CACHE_DIR=$root/build/zig-cache ZIG_LOCAL_CACHE_DIR=$root/build/zig-cache
# Outputs never go into the source tree: KOBO_BUILD_OUT is a fresh directory.
: "${KOBO_BUILD_OUT:?Set an empty intermediate build directory}"
[ ! -e "$KOBO_BUILD_OUT" ] || [ -z "$(ls -A "$KOBO_BUILD_OUT")" ] || { echo "KOBO_BUILD_OUT is not empty" >&2;exit 2; }
out=$KOBO_BUILD_OUT/artifacts;t=$KOBO_BUILD_OUT/tmp
mkdir -p "$out" "$t"
n=$here/native

# Native helpers. Includes resolve against the original prototype tree.
"$zig" cc -DKOBO_LIBRA2_NATIVE -target arm-linux-musleabi -mcpu=cortex_a9 -static -O2 -Wall -Wextra -DKOBO_TARGET_LIBRA2 \
 -I"$o/display-bridge-prototype" "$n/touch-forward.c" -o "$out/touch-forward-resident"
"$zig" cc -DKOBO_LIBRA2_NATIVE -target arm-linux-musleabi -mcpu=cortex_a9 -static -O2 -Wall -Wextra -Wno-sign-compare -DKOBO_TARGET_LIBRA2 \
 -I"$o/network-prototype" "$n/host-default-network.c" -o "$out/host-default-network-resident"
"$zig" cc -DKOBO_LIBRA2_NATIVE -target arm-linux-musleabi -mcpu=cortex_a9 -static -O2 -DKOBO_TARGET_LIBRA2 -DFBINK_FOR_KOBO -DFBINK_MINIMAL -DFBINK_WITH_IMAGE -DFBINK_WITH_DRAW -DFBINK_WITH_BITMAP \
 -I"$o/display-bridge-prototype" -I"$fbink" -I"$fbink/i2c-tools/include" "$n/live-display-fast.c" "$fbink/fbink.c" "$fbink/cutef8/dfa.c" "$fbink/cutef8/utf8.c" "$fbink/qimagescale/qimagescale.c" "$fbink/i2c-tools/lib/smbus.c" -lm -o "$out/live-display-resident"
"$zig" cc -target arm-linux-musleabi -mcpu=cortex_a9 -static -O2 -Wall -Wextra "$n/resident-sched.c" -o "$out/resident-sched"
"$zig" cc -target arm-linux-musleabi -mcpu=cortex_a9 -static -O2 -Wall -Wextra "$n/resident-dns-check.c" -o "$out/resident-dns-check"
"$zig" cc -target arm-linux-musleabi -mcpu=cortex_a9 -static -O2 -Wall -Wextra -I"$o/network-prototype" "$n/dns-proxy.c" -o "$out/dns-proxy-resident"

# System-server side: verified baseline94 framework probe with the launcher focus kind.
mkdir -p "$t/fw/source" "$t/fw/classes" "$t/fw/dex"
sed 's/captureVirtualFramebuffer(720,960)/captureVirtualFramebuffer(632,840)/' "$o/launcher-prototype/verified-system96/FrameworkProbe-before96.java" > "$t/fw/source/FrameworkProbe.java"
f=$o/framework-prototype
sed 's/eth0/wlan0/g' "$f/HostDefaultConnectivityService.java" > "$t/fw/source/HostDefaultConnectivityService.java"
"$jdk/bin/javac" -nowarn -encoding UTF-8 -source 8 -target 8 -bootclasspath "$jar" -d "$t/fw/classes" "$t/fw/source/FrameworkProbe.java" "$o/libra2-prototype/Libra2RuntimeCheck.java" "$f/SurfaceProbe.java" "$o/window-prototype/WindowClient.java" "$f/ActivityLauncher.java" "$f/OfflineSyncAdapterQueries.java" "$f/OfflineConnectivityService.java" "$t/fw/source/HostDefaultConnectivityService.java" "$f/HostWifiQueries.java" "$f/NoOutputAudioQueries.java" "$f/WebViewBootstrap.java" "$f/InstallProbe.java" "$f/ApkIdentityCache.java" "$here/framework/LiveFocusService.java" "$f/AccessibilityBootstrap.java" "$f/StartupServiceGrace.java" "$f/StartupServiceGracePolicy.java" "$f/PackageProcessRegistry.java" 2>"$t/fw.log"
"$jdk/bin/java" -cp "$d8" com.android.tools.r8.D8 --min-api 24 --lib "$jar" --output "$t/fw/dex" "$t/fw/classes/"*.class
cp "$t/fw/dex/classes.dex" "$out/install-framework-probe-resident.dex"

# WeRead 1.9.7 (graphics-v197.img): the same probe with that APK's digest and
# the downgrade flag, as Codex's apk-version-comparison/v198-install-probe.patch did for 1.9.8.
mkdir -p "$t/fw198/classes" "$t/fw198/dex"
sed -e 's/04d86bcdc1bbd77cab4ecc4d1c04e869d76dbabc79c60c52a707c64fc3e4b75f/351105bda1ac58bc037c2d604982635a24018eb0f9b9964abeb5b84647565f1c/' \
 -e 's/installFlags.getInt(params)|16|2)/installFlags.getInt(params)|16|2|128)/' "$f/InstallProbe.java" > "$t/fw/source/InstallProbe.java"
grep -q 351105bda1ac58bc037c2d604982635a24018eb0f9b9964abeb5b84647565f1c "$t/fw/source/InstallProbe.java" && grep -q '|16|2|128)' "$t/fw/source/InstallProbe.java"
# Koboweread-Colour: also accept the official channel-900 build of 1.9.7
# (download.weread.qq.com/pkg/105/releases/1.9.7.10244588_900.apk): same size,
# same 20 native libraries, different channel bytes. Same package and signer.
perl -0pi -e 's/(private static final String WEREAD_SHA="[0-9a-f]{64}";)/$1\n private static boolean wereadDigestOk(String d){return WEREAD_SHA.equals(d)||"fae543b19c935024d5f51ac0d42df00bc6ebb5de2fc197b51bb3131e3b16707d".equals(d);}/; s/!WEREAD_SHA\.equals\(digest\(path\)\)/!wereadDigestOk(digest(path))/; s/!WEREAD_SHA\.equals\(source\)/!wereadDigestOk(source)/' "$t/fw/source/InstallProbe.java"
[ "$(grep -c wereadDigestOk "$t/fw/source/InstallProbe.java")" = 3 ]
# The 1.9.7 launcher is no longer persistent (2026-11-08, ended while WeRead is
# on screen): framework/ActivityLauncher.java accepts a system package without
# FLAG_PERSISTENT and lets systemReady start it once, for HOME (2026-11-10).
mkdir -p "$t/fw198/source"
sed 's/"com.android.defcontainer","com.kobo.lab.installed"/"com.android.defcontainer","com.android.inputmethod.pinyin","com.kobo.lab.installed"/' "$f/PackageProcessRegistry.java" > "$t/fw198/source/PackageProcessRegistry.java"
install=$o/installation-prototype
sed 's/if(strcmp(name,"com.kobo.lab.smoke")/if(strcmp(name,"com.android.inputmethod.pinyin") \&\& strcmp(name,"com.kobo.lab.smoke")/' "$install/process-broker.c" > "$t/fw198/source/process-broker.c"
"$zig" cc -target arm-linux-musleabi -mcpu=cortex_a9 -static -O2 -I"$install" "$t/fw198/source/process-broker.c" -o "$out/pinyin-process-broker"
cp "$here/framework/ActivityLauncher.java" "$t/fw198/source/ActivityLauncher.java"
"$jdk/bin/javac" -nowarn -encoding UTF-8 -source 8 -target 8 -bootclasspath "$jar" -d "$t/fw198/classes" "$t/fw/source/FrameworkProbe.java" "$o/libra2-prototype/Libra2RuntimeCheck.java" "$f/SurfaceProbe.java" "$o/window-prototype/WindowClient.java" "$t/fw198/source/ActivityLauncher.java" "$f/OfflineSyncAdapterQueries.java" "$f/OfflineConnectivityService.java" "$t/fw/source/HostDefaultConnectivityService.java" "$f/HostWifiQueries.java" "$f/NoOutputAudioQueries.java" "$f/WebViewBootstrap.java" "$t/fw/source/InstallProbe.java" "$f/ApkIdentityCache.java" "$here/framework/LiveFocusService.java" "$f/AccessibilityBootstrap.java" "$f/StartupServiceGrace.java" "$f/StartupServiceGracePolicy.java" "$t/fw198/source/PackageProcessRegistry.java" 2>"$t/fw198.log"
"$jdk/bin/java" -cp "$d8" com.android.tools.r8.D8 --min-api 24 --lib "$jar" --output "$t/fw198/dex" "$t/fw198/classes/"*.class
cp "$t/fw198/dex/classes.dex" "$out/install-framework-probe-resident-v197.dex"

# Input helper: the fast variant plus resident mode.
e=$here/entry/weread-prototype
mkdir -p "$t/entry/classes" "$t/entry/dex"
"$jdk/bin/javac" -nowarn -encoding UTF-8 -source 8 -target 8 -bootclasspath "$jar" -d "$t/entry/classes" "$e/WeReadProcessEntry.java" "$e/ReaderPageRelease.java" "$e/MemoryTrim.java" "$e/HeapDumpRequest.java" "$e/SegDictRelease.java" "$e/FontSizeCache.java" "$e/PoolPriority.java" "$e/SyncThrottle.java" "$e/ChapterPrefetch.java" "$e/MarkUsersCache.java" "$e/WeReadInputProbe.java" "$e/WeReadTouchProbe.java" "$e/WeReadPageTouchProbe.java" "$e/WeReadInteractiveInput.java" "$e/LiveFocusClient.java" "$e/TouchLeasePolicy.java" "$e/WindowOwnership.java" "$e/SegPrestart.java" "$e/TouchEvents.java" "$e/LoginTapDiagnostic.java" "$e/AgreementPageDiagnostic.java" "$e/../network-prototype/WebViewReadDiagnostics.java" "$e/../network-prototype/WebViewRenderingDiagnostic.java" 2>"$t/entry.log"
"$jdk/bin/java" -cp "$d8" com.android.tools.r8.D8 --min-api 24 --lib "$jar" --output "$t/entry/dex" "$t/entry/classes/"*.class
cp "$t/entry/dex/classes.dex" "$out/weread-process-entry-resident.dex"
# WeRead's own process entry (bound over the image's /lab/weread-process-entry.dex):
# the same WeReadProcessEntry and diagnostics plus ReaderPageRelease.
mkdir -p "$t/appentry/classes" "$t/appentry/dex"
"$jdk/bin/javac" -nowarn -encoding UTF-8 -source 8 -target 8 -bootclasspath "$jar" -d "$t/appentry/classes" "$e/WeReadProcessEntry.java" "$e/ReaderPageRelease.java" "$e/MemoryTrim.java" "$e/HeapDumpRequest.java" "$e/SegDictRelease.java" "$e/FontSizeCache.java" "$e/PoolPriority.java" "$e/SyncThrottle.java" "$e/ChapterPrefetch.java" "$e/MarkUsersCache.java" "$e/../network-prototype/WebViewReadDiagnostics.java" "$e/../network-prototype/WebViewRenderingDiagnostic.java" 2>"$t/appentry.log"
"$jdk/bin/java" -cp "$d8" com.android.tools.r8.D8 --min-api 24 --lib "$jar" --output "$t/appentry/dex" "$t/appentry/classes/"*.class
cp "$t/appentry/dex/classes.dex" "$out/weread-app-entry-resident.dex"

# Launcher: the lab HOME package, signed with the lab's existing test key.
# Skipped when KOBO_PROBE_STORE_PASSWORD is unset (the deployed APK stays valid).
if [ -n "${KOBO_PROBE_STORE_PASSWORD:-}" ];then
l=$here/launcher
mkdir -p "$t/apk/classes" "$t/apk/dex"
"$jdk/bin/javac" -nowarn -encoding UTF-8 -source 8 -target 8 -bootclasspath "$jar" -d "$t/apk/classes" "$l/src/com/kobo/lab/smoke/"*.java 2>"$t/apk.log"
"$jdk/bin/java" -cp "$d8" com.android.tools.r8.D8 --min-api 24 --lib "$jar" --output "$t/apk/dex" "$t/apk/classes/com/kobo/lab/smoke/"*.class
"$aapt2" link -I "$jar" --manifest "$l/AndroidManifest.xml" --min-sdk-version 24 --target-sdk-version 24 -o "$t/apk/unsigned.apk"
(cd "$t/apk/dex" && zip -q ../unsigned.apk classes.dex)
"$jdk/bin/jarsigner" -keystore "$keystore" -storepass:env KOBO_PROBE_STORE_PASSWORD -keypass:env KOBO_PROBE_STORE_PASSWORD -signedjar "$out/KoboProbe-resident.apk" "$t/apk/unsigned.apk" lab >/dev/null
"$jdk/bin/jarsigner" -verify "$out/KoboProbe-resident.apk" >/dev/null
else echo "KOBO_PROBE_STORE_PASSWORD unset: launcher APK skipped" >&2;fi

(cd "$out" && for f in *;do shasum -a 256 "$f" | awk '{print $1}' > "$f.sha256";done)
(cd "$out" && shasum -a 256 $(ls | grep -v '\.sha256$'))
