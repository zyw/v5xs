# 软件卸载原型

从现有系统概览面板顶部的综合评分卡片进入独立窗口：点按“100 极佳”这张评分卡即可打开。评分卡的内容、尺寸与配色不变，仅变为可点击，悬停时出现描边与“软件卸载 ↗”提示。面板其余部分（含底部“设置 / 每秒更新 / 退出”）保持原样。

最终选型：与系统监控面板同款的深绿灰底 + 薄荷绿强调，标题栏内置 v5xs 的“W”logo，“本次将释放”渐变仪表作总览；底部薄荷绿主按钮。视觉语言与图二监控页完全一致。
界面为双 tab：顶部分段【卸载】【启动项】（已去掉不再使用的「更新」）。

## 卸载 tab
卸载页顶部有「本次将释放」渐变仪表总览 + 已安装/已选胶囊；应用按 名称/占用体积/最近使用/安装时间 排序与搜索；选中展开关联文件明细，底部薄荷绿主按钮移入废纸篓。

## 启动项 tab
按来源分组的启动项管理（方向 A）：用户登录项 / 用户代理 / 系统代理 / 守护进程 四组。顶部三张仪表卡（自启项 / 已启用 / 需权限）。每行：应用图标 + 名称 + 路径 + 类型 + 开关 + 访达按钮。
- 数据源真实扫描：登录项（SMAppService/osascript）、~/Library/LaunchAgents、/Library/LaunchAgents、/Library/LaunchDaemons。
- 开关真实生效：用户/系统代理/守护通过移动 plist 到 Disabled 目录；仅本应用（v5xs）的登录项可用 SMAppService 切换；第三方登录项与系统级代理需要权限时给出提示。


原型使用演示数据，可切换以下状态（建议按顺序阅读）：

1. [监控入口](uninstall-entry.png)：点按菜单栏面板顶部的综合评分卡片打开卸载窗口。
2. [应用列表](uninstall-list.png)：标题栏、卸载／更新／启动项分段、刷新、搜索，以及 名称 / 占用体积 / 最近使用 / 安装时间 四个可点击表头；默认“最近使用 ↑”，最久没用的应用排在最前；再次点击同一表头切换方向；表头高亮并显示 ↑／↓。
3. [批量选择](uninstall-selected.png)：每行右侧复选框可同时勾选多个 App。勾选后行内出现“移除 237.3 MB · +27.7 MB”，前半是应用本体，后半是连同勾选的关联文件；点击这一段展开文件明细。底部汇总选中 App 数、总体积与“取消选择”，右侧是“移除 N 项”主按钮。
4. [关联文件](uninstall-files.png)：展开后显示“清除”分组，逐项列出 App、App 支持文件、WebKit、临时缓存、容器、最近使用记录、偏好设置、App 脚本，含路径、体积、复制路径与在访达中显示；取消勾选即从待移除清单剔除，行内体积与底部汇总同步变化。
5. [确认移除](uninstall-confirm.png)：列出将移除的应用与各自体积、文件总数，提示运行中的应用需先退出；确认后才执行。

[打开交互原型](uninstall-prototype.html)；原型不会删除文件。

## 与参考 UI 的对应

- 参考图 1 的列表结构与排序表头：对应状态 2。
- 参考图 2 的选中态与“移除 X · +Y”展开入口：对应状态 3。
- 参考图 3 的“清除”文件清单、路径体积、复制／访达、底部汇总条：对应状态 4。
- 在上面的结构上补齐了批量多选、确认步骤，以及名称／体积／最近使用／安装时间四项排序。

## 实现约定

实际窗口扫描 `/Applications`、`~/Applications`、`/Library/Input Methods` 和 `~/Library/Input Methods`，每个位置向下最多三层，因此能发现 `~/Applications/Chrome Apps.localized/` 这类子目录中的 Web App 与输入法；排除 Apple 系统应用、指向系统路径的符号链接和 v5xs 自身，不扫描外接卷、PlayCover 与 Homebrew Caskroom。体积按文件扫描估算；最近使用来自 Spotlight，缺失时显示“未知”；安装时间取应用目录创建时间，并非购买或首次安装记录。

关联文件按 Bundle ID 扫描当前用户 `~/Library`：Application Support、Caches、Containers（含 `<bundleID>.*` helper 容器）、WebKit、HTTPStorages、Cookies（`<bundleID>.binarycookies`）、Application Scripts（含 helper 脚本）、Saved Application State、Preferences（含 ByHost）、Logs、LaunchAgents（登录项），以及最近使用记录 `sfl2/sfl3/sfl4` 与 `/var/folders/.../C/<bundleID>` 临时缓存；没有 Bundle ID 目录时再按应用名匹配 Application Support 和 Caches，并在行内标注“按名称”。删前校验 `canTrash` 会逐条确认：应用本体位于搜索根下一至三层、路径确实来自该应用的扫描结果、父目录属于上述白名单、文件名匹配 Bundle ID／应用名、且不是符号链接；共享的 Group Containers、系统级 `/Library` 和归属不明路径一律不列入。

卸载前会列出全部路径再次确认，执行时调用系统废纸篓；正在运行的应用会跳过，权限不足的文件逐项报告。此功能不依赖 Mole，也不执行 Mole 命令。

## 已知取舍

- 已安装应用列表带缓存：首次打开卸载窗口扫描并缓存到 `~/Library/Application Support/installed-apps.json`；缓存有效期内再次打开直接读取、不重新扫描。缓存时长默认 30 天，可在“设置 → 应用列表缓存”调整（1–365 天）。点刷新总是重新扫描，并用最新数据重建缓存。全量扫描当前约 10–13 秒，成功前界面显示加载态。
- 运行中的应用只在执行阶段拦截，列表暂不显示“运行中”标记。
- 关联文件只处理当前用户可确认归属的路径：共享的 Group Containers、系统级路径与归属不明的目录不列出；按名称匹配的目录会标注“按名称”。
- 扫描范围比早期版本更全（对齐 Mole 的残留清单与应用发现位置），但仍不读取系统级守护进程、安装包收据、外接卷与 Homebrew Caskroom。
