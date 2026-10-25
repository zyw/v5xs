# v5xs 发版与更新清单发布流程

本文说明如何把一个新版本的 v5xs 发布出去，并让已经安装的客户端通过「检查更新」看到它。
配套脚本是 [scripts/make-update-manifest.sh](../scripts/make-update-manifest.sh)，产物是 `dist/update.json`。

> 当前更新模型是**清单 + 跳转下载**：客户端只比对版本、展示发行说明、打开下载链接，
> 不做静默下载与自动替换安装。因此发布流程的目标是「清单正确 + 安装包可下载 + 校验值可信」。

## 一、涉及的文件

| 文件 | 作用 | 是否入库 |
| --- | --- | --- |
| `Resources/Info.plist` | 版本号来源（`CFBundleShortVersionString` / `CFBundleVersion`）与 `V5XSUpdateFeedURL` | 是 |
| `scripts/build-app.sh` | 编译并组装 `dist/v5xs.app` | 是 |
| `scripts/build-dmg.sh` | 打包 `dist/v5xs-<version>-<OS>-<arch>.dmg`（需要 `uv` 与网络） | 是 |
| `scripts/make-update-manifest.sh` | 生成 `dist/update.json` | 是 |
| `dist/v5xs.app`、`dist/*.dmg` | 构建产物 | 否（`dist/` 已被 `.gitignore` 忽略） |
| `dist/update.json` | 更新清单；作为 **GitHub Releases 附件**托管（主方式）。由 `publish-update-feed.yml` 在发版时从 Release 里的真实 DMG 现算并上传 | 否（`dist/` 整体被 `.gitignore` 忽略，不入库） |

## 二、清单格式（客户端契约）

`dist/update.json` 的结构是客户端解析代码的唯一依据，**字段名与层级不可改动**：

```json
{
  "version": "0.2.0",
  "build": 2,
  "minimumSystemVersion": "14.0",
  "publishedAt": "2026-10-25T10:00:00Z",
  "notes": "release notes markdown",
  "downloads": [
    {
      "architecture": "arm64",
      "url": "https://example/v5xs-0.2.0-macOS-26.4-arm64.dmg",
      "size": 12345678,
      "sha256": "hex64"
    }
  ]
}
```

字段说明：

- `version`（string）：面向用户的语义版本号，如 `0.2.0`。
- `build`（integer）：构建号，**必须是整数**，客户端优先用它判断是否有新版。
- `minimumSystemVersion`（string）：最低系统版本，如 `14.0`；低于它的机器不提示下载。
- `publishedAt`（string）：RFC3339 UTC 时间，形如 `2026-10-25T10:00:00Z`（脚本自动生成当前时间）。
- `notes`（string）：发行说明 Markdown，允许 `\n` 换行；没有则输出空字符串。
- `downloads`（array）：至少一项；每项含 `architecture`（`arm64` / `x86_64` / `universal`）、
  `url`（HTTPS 直链）、`size`（字节数，整数）、`sha256`（64 位小写十六进制）。

## 三、发版流程

### 1. 修改版本号

编辑 `Resources/Info.plist`：

```xml
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
```

规则见下文「版本号规范」。两个值要**同时**修改，且 `CFBundleVersion` 必须比上一个发布版本大。

### 2. 构建 .app

```bash
bash scripts/build-app.sh
```

产物为 `dist/v5xs.app`，脚本内部会做 ad-hoc 签名（`codesign --force --deep --sign -`）。

> `dist/v5xs.app` 里的 `Info.plist` 是**构建时拷贝**的，改了 `Resources/Info.plist` 必须重新构建，
> 否则清单会沿用旧版本号。`make-update-manifest.sh` 检测到两者不一致时会在 stderr 给出警告。

### 3. 打包 DMG

```bash
bash scripts/build-dmg.sh
```

产物名形如 `dist/v5xs-0.2.0-macOS-26.4-arm64.dmg`（版本、系统版本、架构都写进文件名）。
这一步依赖 `uv`（dmgbuild）且首次运行需要联网下载工具链；CI/离线环境请预先准备缓存。

> 需要同时支持 Apple 芯片与 Intel 时，请在对应架构的机器上各打一次包，
> 或使用 universal 二进制打包成 `...-universal.dmg`，让 `downloads` 里出现多个架构。

### 4. 生成更新清单

```bash
# 最简单：自动读取 dist/v5xs.app 的版本号，自动收集 dist/*.dmg
bash scripts/make-update-manifest.sh

# 带发行说明 + 指定下载前缀
bash scripts/make-update-manifest.sh \
  --notes docs/release-notes/0.2.0.md \
  --url-base https://github.com/zyw/v5xs/releases/download/v0.2.0
```

常用参数（完整列表见 `bash scripts/make-update-manifest.sh --help`）：

| 参数 | 说明 |
| --- | --- |
| `--dmg <path>` | 指定 DMG，可重复；省略则自动使用 `dist/*.dmg` |
| `--url-base <prefix>` | 下载地址前缀，最终 `url = <prefix>/<dmg 文件名>` |
| `--notes <file>` | 发行说明文件；传 `-` 表示从标准输入读取 |
| `--out <path>` | 清单输出路径，默认 `dist/update.json` |
| `--app <path>` | 指定 .app（默认 `dist/v5xs.app`） |
| `--dmg-dir <path>` | 自动发现 DMG 的目录（默认 `dist`） |
| `--version` / `--build` / `--minimum-system` | 覆盖 plist 中的对应字段 |
| `--architecture <arch>` | 覆盖架构推断结果 |
| `--published-at <time>` | 覆盖发布时间（RFC3339 UTC） |

脚本只使用 macOS 自带工具（`PlistBuddy`、`shasum`、`stat`、`date`、`plutil`），
不依赖 `jq` / `python` / `uv`，也不访问网络，可在 macOS 自带 bash 3.2 下运行。

**架构推断规则**（按顺序匹配 DMG 文件名）：

1. 含 `universal` → `universal`
2. 含 `arm64` / `aarch64` → `arm64`
3. 含 `x86_64` / `amd64` / `intel` / `x64` → `x86_64`
4. 文件名无提示 → 回退到 `uname -m`（其它值记作 `universal`）

若两个 DMG 推断出相同架构，脚本会在 stderr 给出警告——客户端按架构取包，重复项可能取错。

### 5. 上传 DMG 与 update.json

v5xs 的清单地址由 `Resources/Info.plist` 的 `V5XSUpdateFeedURL` 决定，当前配置为：

```
https://github.com/zyw/v5xs/releases/latest/download/update.json
```

即**更新清单作为一个固定名附件 (`update.json`) 托管在 GitHub Releases**（镜像 magpie 的
`releases/latest/download/<file>` 模式），DMG 同样作为该 Release 的附件分发。
`releases/latest/download/update.json` 是一个随「最新 Release」漂移的稳定地址：无论最新
版本号是多少，客户端永远从该地址拉取，指向最新的 update.json。

> **备选：raw.githubusercontent 托管。** 若不想让清单依赖 Release，也可把生成好的
> `update.json` 提交到仓库 `dist/` 并把 `V5XSUpdateFeedURL` 设为
> `https://raw.githubusercontent.com/<owner>/<repo>/main/dist/update.json`。
> 但 raw 有 CDN 缓存、且无法在 Releases 页面一并管理；推荐用附件方式。

发布步骤如下（`tag` 与 `version` 一致，例如 0.2.0 → v0.2.0）。

> **发布目标必须是 GitHub.com 的 `github` 远端。** 本仓库配有两个远端：
>
> `github  https://github.com/zyw/v5xs.git        (fetch/push)`
> `origin  https://onedev.v5ai.xin/v5xs.git       (fetch/push)`
>
> 只有 `github`（GitHub.com）的 Releases 附件才会生成 `releases/latest/download/update.json`
> 供客户端拉取；推到 `origin`（OneDev）**不会**产生该地址。下面所有 git 命令都显式写
> `git push github`，避免推错远端。

```bash
version="0.2.0"; tag="v$version"

# 0) 确认你要发布到 GitHub.com（远程名 github，URL 指向 github.com/zyw/v5xs）
git remote get-url github   # 期望 https://github.com/zyw/v5xs.git

# 1) 生成清单（缺省 url-base 自动按 tag 指向 Releases 的不可变下载地址）
bash scripts/make-update-manifest.sh \
  --notes docs/release-notes/$version.md \
  --out dist/update.json

# 2) 创建 Release，先只上传 DMG 附件
gh release create "$tag" dist/v5xs-*.dmg \
  --title "v5xs $version" --notes-file docs/release-notes/$version.md

# 3) 推 tag（GitHub Actions 只在 github 远端触发）用显式远端：
git push github "$tag"
```

> **清单由 CI 生成，不要手动提交 `dist/update.json`。** `dist/` 整个目录在 `.gitignore` 里，
> 仓库里本来就没有这个文件；而且清单必须与 Release 里真实存在的 DMG 逐字节对应
> （`size` / `sha256` / `url`），每次发版都得重算，提交一份静态清单只会变成过期数据。
>
> [.github/workflows/publish-update-feed.yml](../.github/workflows/publish-update-feed.yml) 会在
> **push `v*` tag / 发布 Release / 手动触发**时执行：解析目标 Release → 下载其中的 DMG 附件 →
> 用 `make-update-manifest.sh` 现算 `update.json`（版本号取自 tag，`build`/`minimumSystemVersion`
> 取自 `Resources/Info.plist`，`notes` 取自 Release 正文）→ 作为附件上传 → 校验线上内容。
>
> 前提：**目标 Release 必须已经挂上该版本的 DMG**。缺 DMG 时工作流会直接失败并提示上传命令，
> 不会写出一个指向 404 的清单。因此顺序是「先建 Release 并上传 DMG，再推 tag」。
>
> **注意**：tag 必须推到 `github`（GitHub.com），不能只推到 `origin`——OneDev 不会运行 GitHub Actions。
> 另外该工作流跑在 `macos-latest` 上：清单脚本依赖 `stat -f%z` / `shasum` / `plutil` 等 macOS 工具，
> 在 ubuntu 上 `stat` 语义不同，会算出错误的文件大小。

要点：

- 清单里的 `url`（默认按 `releases/download/v<version>/<dmg>` 构造）必须与 DMG 实际所在位置一致，
  否则客户端下载 404；不需要手动改 `--url-base`，脚本已按发布 tag 自动生成。
- 顺序很重要：**先上传 DMG 与 update.json 到 Release**，再让客户端检查。反过来会让用户先看到新版、
  点下载却 404。
- `releases/latest/download` 只对「最新 Release」生效；灰度/历史版本需用带 tag 的固定地址，
  并在需要时临时改 `V5XSUpdateFeedURL` 或环境变量 `V5XS_UPDATE_FEED`。

### 6. 校验 feed URL

发布后按下面顺序自检，全部通过才算发版成功：

```bash
feed="https://github.com/zyw/v5xs/releases/latest/download/update.json"

# a. 清单可公开访问、是合法 JSON（plutil 能解析即结构合法）
curl -fsSL "$feed" | plutil -p -

# b. 线上清单的 version / build 与本地构建一致
bash scripts/make-update-manifest.sh --out /tmp/update.local.json >/dev/null
diff <(plutil -p /tmp/update.local.json) <(curl -fsSL "$feed" | plutil -p -)

# c. 每个下载直链真实可下载（HTTP 200），大小与本地一致
for f in dist/*.dmg; do
  echo "$(stat -f%z "$f")  $(basename "$f")"
  curl -fsSI "https://github.com/zyw/v5xs/releases/download/v0.2.0/$(basename "$f")" | head -3
done

# d. 下载后校验 sha256 与清单一致
curl -fsSL -o /tmp/v5xs.dmg "https://github.com/zyw/v5xs/releases/download/v0.2.0/v5xs-0.2.0-macOS-26.4-arm64.dmg"
shasum -a 256 /tmp/v5xs.dmg    # 应与清单 downloads[].sha256 完全相同
```

最后在**旧版本客户端**上实测一次：右键菜单 →「检查更新…」，应显示新版本号、发行说明与「下载 DMG」按钮。

## 四、版本号规范

- `CFBundleShortVersionString`：语义版本 `MAJOR.MINOR.PATCH`，只允许数字与点（脚本会校验）。
  用户可见的版本号，展示在设置页与「发现新版本 vX.Y.Z」文案里。
- `CFBundleVersion`：**单调递增的整数**，只允许数字，且 `>= 1`（脚本会校验）。
  客户端以它为主判据：新清单的 `build` 必须大于本地 `CFBundleVersion` 才会提示更新。
- 两个值必须同时前进：只改 `CFBundleShortVersionString` 而不改 `CFBundleVersion`，
  老客户端会因为 build 相等而不提示（此时只能靠语义版本号比较兜底，属于异常路径，不要依赖）。
- **不要复用**已发布过的 `CFBundleVersion`，即使那次发布被撤回——部分用户可能已经装过它。
- 预发布版本建议用更大的 build 号 + 后缀式版本号（如 `0.2.0-beta.1`）区分通道；
  若希望正式版能被 beta 用户收到，正式版的 `CFBundleVersion` 必须高于 beta。

## 五、注意事项

### HTTPS 与可访问性

- 清单与 DMG 的链接**必须是 HTTPS**：客户端走 `URLSession`，HTTP 直链在 ATS 下会被拒绝。
- 清单地址（`V5XSUpdateFeedURL`）要保证匿名可访问，不要放在需要登录的私有仓库附件里。
- 发布后务必用 `curl -fsSL` 验证一次真实网络路径，不要只看本地文件。

### 签名与公证

- 当前 `build-app.sh` 使用 ad-hoc 签名（`--sign -`），适合内部分发与自用；
  **公开分发**建议改为 Developer ID 签名并做公证（notarization），否则用户首次打开会被 Gatekeeper 拦截。
- 公证流程概要：`codesign --sign "Developer ID Application: ..." --options runtime` →
  `xcrun notarytool submit ... --wait` → `xcrun stapler staple <app>`，再打 DMG。
- 签名/公证在**打包 DMG 之前**完成，保证 DMG 里的 .app 已带公证票据；换签名后 sha256 会变，必须重新生成清单。
- 清单中的 `sha256` 目前仅用于展示与人工校验，客户端尚未强制校验；后续做自动下载时必须校验。

### 回滚

- 清单是「指向最新版」的单一入口，回滚 = 把上一版 `update.json` 与 DMG 重新放回清单地址。
- 回滚时**不要**把 `CFBundleVersion` 调小：客户端只认「更大即更新」，
  正确做法是发一个 `build` 更大的修复版（例如 0.2.1 build 3），而不是退回 0.2.0。
- 若要紧急下架：把清单地址指向一个 `downloads` 为空的清单会让客户端解析失败并提示检查失败，
  更温和的做法是把 `notes` 改为下架说明并保留可用的旧版 DMG 链接。

### 灰度

- 客户端当前从单一 feed 地址拉清单，没有内建灰度能力。需要灰度时，用**不同的 feed 地址**区分通道
  （例如 `update-beta.json` / `update.json`），通过 `V5XSUpdateFeedURL` 或环境变量
  `V5XS_UPDATE_FEED` 指定，先让内部机器指向 beta 通道。
- 灰度发布时两个通道各自维护独立的 `update.json`，并保证 beta 通道的 `build` 始终高于稳定通道。
- 观察期建议至少覆盖一次自动检查周期（客户端启动后距上次检查超过 24 小时会后台检查一次）。

## 六、排错

| 现象 | 排查方向 |
| --- | --- |
| 脚本报「找不到 Info.plist」 | 先跑 `scripts/build-app.sh`，或确认 `--app` 路径 |
| 脚本报「没有找到任何 .dmg」 | 先跑 `scripts/build-dmg.sh`，或用 `--dmg` 显式指定 |
| 脚本报「build 必须是整数」 | `CFBundleVersion` 只能是数字，去掉 `v`、小数点与后缀 |
| 脚本警告「Info.plist 与已构建的 .app 不一致」 | 改完版本号没重新 `build-app.sh`，清单会沿用旧版本号；重新构建即可 |
| 清单里 version 是旧值 | 同上；或确认 `--version` / `--build` 没有被误传 |
| 客户端提示「检查更新失败」 | 清单地址是否 404、是否返回 HTML（登录页/错误页）、是否被缓存 |
| 客户端看不到新版本 | `build` 是否真的比本地大；架构是否匹配（`arm64` 机器是否只上传了 `x86_64` 包） |
| 下载按钮打开 404 | 清单 `url` 与实际 Release 资源名不一致，注意 `--url-base` 与文件名大小写 |
| 下载的 DMG 打不开 | 未签名/未公证被 Gatekeeper 拦截，或上传过程中被截断（对比 `size` 与 `sha256`） |

## 七、脚本自测示例

用现有 `dist/v5xs.app` 与一个临时假 DMG 即可验证脚本（不需要 `uv` 与网络）：

```bash
bash scripts/make-update-manifest.sh --help

head -c 1234567 /dev/urandom > /tmp/v5xs-0.1.0-macOS-26.4-arm64.dmg
printf '# v0.1.0\n\n- 修复菜单栏内存显示\n' > /tmp/notes.md
bash scripts/make-update-manifest.sh \
  --dmg /tmp/v5xs-0.1.0-macOS-26.4-arm64.dmg \
  --notes /tmp/notes.md \
  --url-base https://example.com/downloads \
  --out /tmp/update.json
plutil -p /tmp/update.json
```

预期输出（节选；`publishedAt` / `sha256` 每次都会变，属正常）：

```json
{
  "version": "0.1.0",
  "build": 1,
  "minimumSystemVersion": "14.0",
  "publishedAt": "2026-10-25T06:52:55Z",
  "notes": "# v0.1.0\n\n- 修复菜单栏内存显示",
  "downloads": [
    {
      "architecture": "arm64",
      "url": "https://example.com/downloads/v5xs-0.1.0-macOS-26.4-arm64.dmg",
      "size": 1234567,
      "sha256": "3d61c06c881916b57b798438fa3dbe853248d5c1182f0c00113846acc081d7e1"
    }
  ]
}
```
