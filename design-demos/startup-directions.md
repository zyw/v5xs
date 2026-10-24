# 启动项界面 · 三个方向

语境：macOS 开机自启项管理，嵌在软件卸载窗口作为第二个 tab（与「卸载」并列，去掉「更新」）。
风格已确立：深绿灰底 + 薄荷绿强调（与监控面板一致）。

数据来源（本机实测）：
- 用户 LaunchAgents： ~/Library/LaunchAgents/*.plist （TieZ, Google Updater, magpie, Clash Verge, 小旺AI截图 等 8 个）
- 系统 LaunchAgents： /Library/LaunchAgents/*.plist （Sogou 等）
- 系统 LaunchDaemons： /Library/LaunchDaemons/*.plist （Docker, ClashX 等）
- 登录项（SMAppService / 传统 login item）：PixPin, v5xs, uTools, Clash Verge, ApifoxAppAgent, Loop （6 个）

## 方向 A — 来源分组式（默认）
把启动项按「用户代理 / 系统代理 / 守护进程」分组列出，每组一个标题。每行：应用图标 + 名称 + 路径 + 开关 + 是否随登录。最贴合系统管理的直觉，信息完整。

## 方向 B — 应用归属式
每个启动项归属到它的宿主 App，按 App 分组展示（Chrome 的更新代理归到 Google Chrome 下）。突出「哪个应用在偷偷开后门」，面向普通用户。

## 方向 C — 极简开关仪表式
不做冗长列表，顶部一个大概览（多少个自启项、共几个正在运行），下面紧凑列表，每项只有名称 + 开关，路径折叠。轻量、专注"关掉我不想要的"。

三个方向共用：卸载/启动项双 tab、深绿外壳、真实数据、可真实读取系统启动项。
