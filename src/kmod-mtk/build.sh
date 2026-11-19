#!/bin/sh
# Build the Android kernel modules for Kobo's MediaTek MT8113 kernel 4.9.77
# (Libra Colour, firmware 4.42.23303) into kernels/4.9.77/:
#   sh src/kmod-mtk/build.sh
# Needs Docker. Everything runs in a Linux container (the kernel tree has
# file names that differ only in case, which macOS's default filesystem
# cannot hold). Steps (inner.sh):
#   1. Kobo's published kernel source (kobolabs/Kobo-Reader, pinned commit,
#      checked against fixed SHA-256 values) with the device's own
#      /proc/config.gz (kernel.config).
#   2. The kernel objects are compiled (vmlinux itself is not linked: some
#      MediaTek drivers need vendor headers that are not published) and the
#      symbol CRCs are read from them; module_layout must equal the CRC found
#      in Kobo's own wlan modules (0xa81081b3), otherwise nothing is written.
#   3. binder_linux.ko (protocol 7, device/class "binder32", beside the
#      kernel's own protocol-8 binder), kobo_madvise.ko and kobo_pagecache.ko.
# ashmem and zram are built into this kernel and are used as they are.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
top=$(CDPATH= cd -- "$here/../.." && pwd)
command -v docker >/dev/null || { echo "KMOD_MTK_NEEDS_DOCKER" >&2; exit 2; }
image=koboweread-colour-kbuild
volume=${KOBO_KBUILD_VOLUME:-koboweread-colour-kbuild}
docker build -q -t "$image" "$here" >/dev/null
docker volume create "$volume" >/dev/null
out=$top/kernels/4.9.77
mkdir -p "$out"
docker run --rm -v "$volume:/work" -v "$here:/src:ro" -v "$top:/repo:ro" -v "$out:/out" "$image" sh /src/inner.sh
echo "KMOD_MTK_DONE $out"
