# v5xs

基于 SwiftUI 与 AppKit 的 macOS 菜单栏系统监控软件。菜单栏只显示动物动画，CPU 越忙播放越快；低负载仍保持连贯的动作。左键打开面板，右键更换猫、兔、狐、狗、马、恐龙、青蛙、鸡、鸭、鱼等形象，或暂停动画、设置登录启动和退出。动物剪影资源位于 `Resources/Animals/`，狐狸使用矢量动画。

应用图标来自 `Resources/AppIcon.png`，打包时使用 `Resources/AppIcon.icns`；菜单栏动物动画独立于应用图标。

设计参考：`docs/prototype.svg`。当前界面使用实时系统数据，因此不显示原型中的示例数值。

## 构建与运行

需要 macOS 14+、Swift 6 与 macOS SDK。推荐使用匹配版本的完整 Xcode：

```bash
swift test
swift build
./scripts/build-app.sh
open dist/v5xs.app
```

当前机器的 Command Line Tools 编译器和 SwiftPM 库版本不匹配。仓库提供直接编译脚本作为替代：

```bash
bash scripts/test-local.sh
bash scripts/build-app.sh
open dist/v5xs.app
```

制作带 Applications 拖拽入口的 DMG：

```bash
bash scripts/build-dmg.sh
```

DMG 打包脚本使用 `uv` 获取 `dmgbuild`，并按 `scripts/dmg-settings.py` 配置安装窗口。

如需使用不同的 SDK，设置 `MACOS_SDK=/path/to/MacOSX.sdk`。本机的直接构建脚本优先使用已安装的 macOS 15.4 SDK，以规避本机 26.4 SDK 与 Swift 编译器的补丁版本冲突。

## 数据与限制

- CPU 使用率、内存、磁盘、网络、本机电量和进程来自实时系统数据。
- CPU 核数来自 `ProcessInfo`，性能／能效核拓扑在可读时来自系统 `sysctl`；GPU 核数来自 System Profiler，GPU 活跃度来自支持该字段的 `IOAccelerator` 注册表。
- CPU／GPU 摄氏度通过本机验证的 `Mac14,2` SMC 键读取；其他机型或读取失败时显示“—”，并继续展示系统热状态。GPU 注册表字段和 SMC 键不保证跨机型可用。
- 可用空间来自系统磁盘容量，蓝色进度条表示已用比例；磁盘读写速率来自设备累计字节数的差值，设备不可读时显示“—”。
- 顶部状态评分由热状态、CPU 使用率和内存占用估算，不代表硬件诊断结果；缺少必要数据时显示“—”。芯片、内存、macOS 版本和运行时长来自本机信息。
- 网络与温度在同一行显示；网络卡片展示最近 1 分钟的下载／上传曲线。低延迟模式将采样间隔由 1 秒调整为 0.5 秒。
- 鼠标和键盘电量优先从已连接设备的标准 BLE 电池服务读取，每 15 秒更新；系统蓝牙报告与 HID 电量字段作为回退。按系统报告的设备类型匹配鼠标或键盘；设备不公开电量时显示空环和“—”。
- 进程终止依赖应用权限；仅对当前仍可确认身份的 GUI 应用执行。强制退出须再次确认，未保存的数据可能丢失。沙盒分发不能使用这些跨应用终止操作。
- 点按面板顶部的综合评分卡片打开独立的“软件卸载”窗口，可搜索、按名称／占用体积／最近使用／安装时间排序，批量选择应用并逐项核对关联文件。最近使用来自 Spotlight（不可读时显示“未知”），安装时间取应用目录创建时间；大小为扫描估算。只扫描 `/Applications` 与用户的 `~/Applications` 顶层应用，跳过 Apple 系统应用和 v5xs 自身。关联文件会按 Bundle ID 扫描当前用户 Library 下的 Application Support、Caches、Containers（含 helper 容器）、WebKit、HTTPStorages、Cookies（binarycookies）、Application Scripts（含 helper 脚本）、Saved Application State、Preferences（含 ByHost）、Logs、LaunchAgents，以及最近使用记录（sfl3／sfl4）和系统临时缓存目录；找不到 Bundle ID 对应目录时，再按应用名匹配 Application Support／Caches 并标注“按名称”。共享的 Group Containers、系统级 /Library 路径与归属不明的文件不会列入。运行中的应用、已失效的归属校验路径不会被移走。确认后使用系统废纸篓，操作可能受文件权限限制。
- 卸载界面的五个静态状态（入口、列表、批量选择、关联文件、确认移除）和可点击的原型见 `docs/uninstall-design.md` 与 `docs/uninstall-prototype.html`；HTML 使用演示数据，不会移动文件。
- 尚未接入持久历史记录、其他机型的温度传感器适配或发布签名。`dist/` 下为本机临时签名构建。
