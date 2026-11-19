微信读书 1.8.8 安装包（Kobo Libra 2 / Libra Colour + KOReader）

适用：Kobo Libra 2（固件 4.34.20097 或 4.38.23852），或 Kobo Libra Colour（固件 4.42.23303）；KOReader 装在 .adds/koreader。
需要：约 2.3 GB 可用空间；Wi-Fi；一个微信账号（扫码登录）。

安装
1. 用 USB 连接电脑，把整个 wereadkobo.koplugin 文件夹复制到
   .adds/koreader/plugins/ 下，然后安全弹出。
2. 在 KOReader 里重启（菜单 → 退出 → 重启 KOReader）。
3. 菜单 → 工具（扳手）→ 微信读书 1.8.8（安装）→ 安装微信读书 1.8.8。
   安装约 5–10 分钟，屏幕显示进度条；期间接上电源，不要连接 USB、不要关机。
   点按进度条可隐藏，安装继续；菜单里“查看安装进度”可重新显示。
4. 完成后按提示重启 KOReader，菜单变为“微信读书 1.8.8（安装版）”：
   “Android 启动器”→ 在启动器里打开微信读书 → 同意协议 → 微信扫码登录。

安装位置：.adds/kobo-weread-home（含 2 GB 镜像 graphics-v188.img）。
安装后可在菜单里“删除安装包”释放约 250 MB；“卸载”会删除安装位置的全部内容。

注意
- 实测同一账号在同一台 Kobo 的两个微信读书版本之间只能保持一边登录；登录新安装会让另一边退出。
- Android 所需的内核模块按固件内核分别提供；安装包里没有当前内核的模块时安装会停止。4.34.20097 与 4.38.23852 都在实机上验证过；Libra Colour 4.42.23303 由 Koboweread-Colour 移植。
