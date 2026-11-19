# Kobo Libra Colour 移植（Koboweread-Colour）

本分支在 [Koboweread](https://github.com/scokyfei/Koboweread) 的基础上，把微信读书 1.9.7 的 Android 7 运行环境移植到 **Kobo Libra Colour（N428）**。非官方项目，与腾讯、乐天 Kobo、Google 均无关联。

## 适用范围

| 项目 | Libra 2（原项目） | Libra Colour（本分支） |
|---|---|---|
| 型号 | N418 | N428 |
| 芯片 | NXP i.MX6SLL，单核 | 联发科 MT8113（内核里叫 MT8110 board），双核 Cortex-A53，32 位系统 |
| 内存 | 512 MB | 965 MB |
| 内核 | 4.1.15 | 4.9.77 |
| 已验证固件 | 4.34.20097、4.38.23852 | 4.42.23303 |
| 微信读书 | 1.9.7、1.8.8 | 1.9.7（1.8.8 未移植） |

## 和 Libra 2 的区别以及处理方式

| 部分 | Libra Colour 的情况 | 处理 |
|---|---|---|
| ashmem | 内核自带 | 直接用内核自带的，不加载模块 |
| binder | 内核自带，但是协议 8（64 位）。Google 的 Android 7 ARM 镜像需要协议 7 | 另编一个协议 7 的 `binder_linux.ko`，设备、设备类、debugfs 和跟踪事件都改名为 `binder32`，和内核自带的 binder 并存。启动脚本从 `/sys/class/binder32/binder32/dev` 读设备号，在 chroot 里创建 `/dev/binder` |
| madvise | 内核开了 `CONFIG_ADVISE_SYSCALLS` | 仍然编译 `kobo_madvise.ko`，保持启动脚本和 VM 预加载库不变 |
| pagecache | — | 按 4.9 编译 `kobo_pagecache.ko` |
| zram | 内核自带 `zram0` | 原脚本只在没有 `zram0` 时才加载模块，所以这一段自动跳过 |
| 内核模块版本 | `CONFIG_MODVERSIONS=y`，不要求模块签名 | 用乐天 Kobo 公开的源码和设备上的 `/proc/config.gz` 编译内核目标文件，从中提取 CRC。`module_layout` 的 CRC 必须等于原厂 Wi-Fi 模块里的值 `0xa81081b3` |
| 显示 | 联发科 hwtcon 显示驱动；帧缓冲 1264×1680、32 位色、每行 5056 字节，和 Libra 2 一致 | FBInk 升级到上游最新代码（v1.25.0-544，支持 Libra Colour） |
| 触摸 | Elan Touchscreen，坐标范围 1680×1264，和 Libra 2 一致，但 X 轴方向相反（KOReader 的 Kobo_monza 设了 `touch_mirrored_y`） | `touch-forward.c` 在 N428 上先把原始 X 换算成 `1679 − X` |
| 按键 | 翻页键 193/194 和转屏信号在 `gpio-keys`，电源键 116 在单独的 `bd71828-pwrkey` | `touch-forward.c` 在 `gpio-keys` 没有 116 时，额外打开 `bd71828-pwrkey` |
| 电池 | `bd71827_bat` | 先找 `bd71827_bat`，找不到再用 `mc13892_bat` |
| 前光 | `mxc_msp430.0`（亮度 0–100），`lm3630a_led/color`（色温 0–10） | 和原代码一致 |
| 微信读书 APK | 官方渠道 900 的 1.9.7（渠道信息写在 classes10.dex 里，所以配方自带的启动加速记录对不上，只影响首次启动速度）：大小、原生库和作者用的那份一致，渠道字节不同 | 安装探针和预编译脚本同时接受两个摘要 |
| 前光同步 | 灯关着时读数是 0 | 回到 KOReader 时，读数 0 表示关灯并保留原亮度；如果亮度和打开微信读书时一样，就不动 KOReader 的设置。原插件会把 0 当成亮度，Libra 2 上同样受影响 |
| binder 安全 | anbox 的旧版 binder 驱动 | 补上 CVE-2019-2215（线程退出时用 POLLFREE 摘掉等待队列）和一处空指针检查 |

## 从 Kobo 首页打开

把 `src/resident-v197/device/nickelmenu-weread` 复制到 `/mnt/onboard/.adds/nm/weread`，NickelMenu 里就会多出“微信讀書”。点它会启动 KOReader，联网后自动打开微信读书。菜单名用繁体，是因为界面语言为英文时，Kobo 会用日文字体显示中文，日文字体里没有简体的“读”“书”。

## 构建

```sh
KOBO_ACCEPT_ANDROID_SDK_LICENSE=1 sh bootstrap.sh
sh src/kmod-mtk/build.sh            # 需要 Docker；生成 kernels/4.9.77/
sh src/package/build-package.sh 1.9.7
```

- `src/kmod-mtk/build.sh` 在 Linux 容器里编译，因为内核源码里有只差大小写的同名文件，macOS 默认的文件系统放不下。
- 新版 macOS 上 zig 0.13 的 `objcopy` 无法链接，`src/tools/build-host-tools.sh` 会自动改用 `llvm-objcopy`（例如 `brew install llvm`），也可以用 `KOBO_OBJCOPY` 指定。

## 微信读书 APK

官网 ink.qq.com 只提供最新版。1.9.7 可以从腾讯的官方下载服务器获取：

```
https://download.weread.qq.com/pkg/105/releases/1.9.7.10244588_900.apk
sha256 fae543b19c935024d5f51ac0d42df00bc6ebb5de2fc197b51bb3131e3b16707d
```

命名为 `weread-1.9.7.apk`，放进 `wereadkobo.koplugin` 目录。APK 不随仓库分发。

## 测试工具

- `src/kmod-mtk/test/binder32-smoke.c`：检查 ashmem，以及协议 7 的 binder 能否在两个进程之间完成一次真实收发。
- `src/kmod-mtk/test/hwprobe.c`：只读，列出输入设备的坐标范围和按键码，以及帧缓冲参数。
