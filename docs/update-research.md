# v5xs 软件在线更新机制调研

> 面向：v5xs（macOS 菜单栏监控应用，SwiftUI + AppKit，Swift 6）
> 日期：2026-10-25　·　作者：update-researcher
> 范围：开源软件在线更新的主流实现方式，重点深挖 macOS Sparkle 2，并给出针对 v5xs 现实约束的选型结论。
> 所有论断均标注一手来源链接；无法从一手来源确认的内容标注「未核实」。

---

## 1. 通用更新流程

无论哪个框架，**「在线自动更新」本质上都围绕同一条流水线展开**：

1. **清单（Feed / Manifest）**：客户端从固定 URL 拉取描述「有哪些可用版本、各自下载地址」的清单（RSS appcast、JSON，或包管理器 repo 元数据）。
2. **下载（Download）**：按清单里的 url 拉取更新包。
3. **校验（Verify）**：对下载内容做完整性 / 来源校验：常见的是**对清单或安装包做签名验证**（EdDSA 公钥、App Code Signing、GPG、minisign），以及可选的对安装包做 SHA-256 哈希比对。
4. **替换（Replace / Install）**：把旧应用换成新应用。可靠方案是**原子替换**（先写新副本、再一次性 swap），避免中途崩溃留下半成品。
5. **重启（Relaunch）**：让新版本进程接管（退出当前进程并重新拉起，或回调系统安装器接管）。

> 各框架的区别主要落在：①清单格式与「谁是权威版本比较器」；②校验强度（是否强制签名）；③替换是否原子；④是否由系统/包管理器代为完成审批与安装。

---

## 2. 主流方案对比

| 方案 | 平台 | 清单格式 | 校验 | 替换方式 | 是否独立可自动更新 |
|---|---|---|---|---|---|
| **Sparkle 2** | macOS 原生 | RSS appcast.xml（SUFeedURL） | EdDSA(ed25519) + Apple Code Signing | 进程内原子 swap（rename + RENAME_SWAP） | 是，进程内自带更新器，无需系统权限 |
| **Electron autoUpdater**（macOS 基于 Squirrel.Mac） | macOS / Windows | macOS：releases.json；Windows：NuGet RELEASES | 依赖 Apple Code Signing（必须签名）；可选 sha256/size/delta | quitAndInstall() 重启后替换 | 是（但 macOS 要求应用已签名） |
| **Tauri updater 插件** | Windows / Linux / macOS | 动态 JSON 或静态 latest.json | **minisign**（不可关闭） | install()/installMode | 是（签名强制，无法禁用） |
| **Homebrew Cask** | macOS（第三方包管理） | Cask Ruby 定义（url+sha256）+ livecheck | 依赖 sha256 与上游 HTTPS | brew upgrade 重装 cask | 否：是「清单+跳转重装」，且需用户装 Homebrew |
| **Windows winget** | Windows | 清单仓库（Microsoft Store / 社区源） | 依赖清单 HTTPS 与安装程序自带签名/UAC | 调用安装器 | 否（需用户装 winget 并手动/配合调度升级） |
| **Windows MSIX + App Installer** | Windows 10(1709)/11 | .appinstaller XML（UpdateSettings） | MSIX 包签名（受信任根链接到 Store / 企业） | 系统 App Installer 后台/按需安装 | 是（系统级，OnLaunch 或 AutomaticBackgroundTask） |
| **Linux AppImage + zsync** | Linux | .zsync（内含更新信息） | zsync + AppImage 更新信息;签名可选 | AppImageUpdate / appimageupdatetool 重写 .AppImage | 外部工具；更新信息内嵌于 AppImage |
| **Linux Flatpak** | Linux | 仓库 OSTree commit（GPG 签名） | 仓库 GPG 签名 + 内容寻址 | OSTree 事务式更新（只拉 delta） | 是（软件中心/GNOME Software） |
| **GitHub Releases 裸分发 + 自研清单** | 跨平台 | 自定义 JSON/XML（如 v5xs 现在的 update.json） | **取决于实现** | **取决于实现**（现在 v5xs 不做替换） | 部分（可做到「检查+跳转」，也可自造替换） |

> 上表为「各框架默认/推荐模式」的概括；每格的具体依据见下文各节与来源链接。

---

## 3. Sparkle 2 深挖

> v5xs 是纯原生 macOS 应用，**Sparkle 是与 v5xs 最相关的候选方案**，所以深挖这一节。
> 主要一手来源：[sparkle-project.org/documentation](https://sparkle-project.org/documentation/)（基本安装 / Publishing an update / programmatic-setup / customization / delta-updates），[GitHub: sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle)。

### 3.1 整体模型

- Sparkle 是一个**内嵌到你 App 里的框架（framework）**，自带下载器、校验器、Installer（XPC Service）与标准 UI。官方定位为 “Secure and reliable software update framework for macOS”。[README.markdown](https://github.com/sparkle-project/Sparkle/blob/2.x/README.markdown)
- 官方推荐「只把 .app 装进 dmg/zip/tar/aar 放在静态 HTTPS 站点，客户端自己完成下载、校验、替换、重启」，**不需要**服务端动态逻辑，也不需要 App 内写太多代码（“requires no code in your app”）。[getting started](https://sparkle-project.org/documentation/)、[README.markdown](https://github.com/sparkle-project/Sparkle/blob/2.x/README.markdown)
- 2.x 要求运行时 **macOS 12.0+**（2.9.6 为 macOS 10.13+），构建周期跟随最新 Xcode。[README.markdown](https://github.com/sparkle-project/Sparkle/blob/2.x/README.markdown)；[Package.swift](https://github.com/sparkle-project/Sparkle/blob/2.x/Package.swift) 部署目标 .macOS(.v12)，2.10.0。

### 3.2 appcast.xml 结构（清单）

清单是 **RSS 2.0 扩展**，命名空间 xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"。每个 item 描述一个版本。官方示例 [Resources/SampleAppcast.xml](https://github.com/sparkle-project/Sparkle/blob/2.x/Resources/SampleAppcast.xml)：

```xml
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Your Great App's Changelog</title>
    <item>
      <title>Version 2.0 (2 bugs fixed; 3 new features)</title>
      <link>https://sparkle-project.org</link>
      <sparkle:version>2.0</sparkle:version>
      <sparkle:releaseNotesLink>https://you.com/app/2.0.html</sparkle:releaseNotesLink>
      <sparkle:fullReleaseNotesLink>https://you.com/app/changelog.php</sparkle:fullReleaseNotesLink>
      <pubDate>Wed, 09 Jan 2006 19:20:11 +0000</pubDate>
      <enclosure url="https://you.com/app/app.zip" length="1623481" type="application/octet-stream" sparkle:edSignature="WVyVJp...BA==" />
      <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
```

关键字段（均来自 [publishing](https://sparkle-project.org/documentation/publishing/) 与 [SampleAppcast.xml](https://github.com/sparkle-project/Sparkle/blob/2.x/Resources/SampleAppcast.xml)）：

- enclosure url / length / type / sparkle:edSignature：下载包地址、字节数、application/octet-stream、**EdDSA 签名**。这是让 Sparkle 能校验下载内容完整性与来源的核心。
- sparkle:version：机器可读版本号，用于版本比较（与 App 的 CFBundleVersion 对应）。
- sparkle:shortVersionString：可选，「人类可读」版本号（如 2.0b1）；与 version 分离后可对用户隐藏内部构建号。
- sparkle:releaseNotesLink / 内嵌 description CDATA：发行说明。
- pubDate：发布日期；**phased rollout 依赖它**。
- 官方推荐用 generate_appcast 工具**自动**生成 appcast、签名与 delta 文件；手写被列为 not recommended。[publishing](https://sparkle-project.org/documentation/publishing/)

### 3.3 EdDSA 签名与工具链

- Sparkle 用 **EdDSA (ed25519)** 对**更新包**（dmg/zip/tar/aar/安装包）做签名，防止篡改与 MITM。[publishing](https://sparkle-project.org/documentation/publishing/)
- 工具（位于 Sparkle distribution 的 bin/）：
  - ./bin/generate_keys：只跑一次，生成私钥并存入**登录钥匙串（Keychain）**，打印 base64 公钥。[getting started](https://sparkle-project.org/documentation/)
  - ./bin/sign_update <file>：对单个更新包 / 发行说明文件生成签名片段（输出 sparkle:edSignature / length）。[publishing](https://sparkle-project.org/documentation/publishing/)
  - ./bin/generate_appcast <dir>：扫描目录里的更新包，自动生成 appcast、签名，并生成 *.delta 增量包。[publishing](https://sparkle-project.org/documentation/publishing/)
- **公钥嵌入 App**：把公钥作为 SUPublicEDKey 写进 Info.plist，Sparkle 用它校验 appcast 里的 edSignature。[getting started](https://sparkle-project.org/documentation/)、[customization](https://sparkle-project.org/documentation/customization/)
- 私钥安全：私钥存 Keychain；服务端被攻破时不应在托管机上可读；私钥丢失时，对 Developer ID 签名的应用可经 key rotation 恢复。[getting started](https://sparkle-project.org/documentation/)

### 3.4 SUFeedURL

- 在 Info.plist 用 SUFeedURL（字符串）指定 appcast 地址；官方建议**优先在 Info.plist 配置**，即使之后想动态改也在运行时指定。[customization](https://sparkle-project.org/documentation/customization/)、[publishing#setting-the-feed-programmatically](https://sparkle-project.org/documentation/publishing/)
- 动态改 feed（如 beta/夜间版）推荐实现 -[SPUUpdaterDelegate feedURLStringForUpdater:]；旧 -setFeedURL: 被标记 deprecated（有竞态与 NSUserDefaults 持久化问题）。[publishing#setting-the-feed-programmatically](https://sparkle-project.org/documentation/publishing/)
- 每个 App 的 CFBundleVersion 必须**单调递增**且格式正确，Sparkle 用它比较版本。[getting started](https://sparkle-project.org/documentation/)

### 3.5 SPUStandardUpdaterController（接入点）

- 2.x 核心接入 API 是 SPUStandardUpdaterController（标准 UI）或更底层、可自接 UI 的 SPUUpdater。[programmatic-setup](https://sparkle-project.org/documentation/programmatic-setup)
- 用法（SwiftUI / Cocoa 均可）：初始化 SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)，把「Check for Updates…」菜单项 target/action 设为 checkForUpdates(_:)，即可获得自动检查能力；通过 updater.canCheckForUpdates（KVO）控制菜单可用态。[programmatic-setup](https://sparkle-project.org/documentation/programmatic-setup)
- 相关 API：startUpdater、checkForUpdates、canCheckForUpdates（KVO 可观察）。[programmatic-setup#core-apis](https://sparkle-project.org/documentation/programmatic-setup)
- 默认**每 24 小时**后台检查一次；SUScheduledCheckInterval 可改（下限 1 小时，防止打爆服务器）。[customization](https://sparkle-project.org/documentation/customization/)

### 3.6 常用 Info.plist 设置

摘自 [customization](https://sparkle-project.org/documentation/customization/)：

| 键 | 默认 | 说明 |
|---|---|---|
| SUFeedURL | — | appcast URL |
| SUPublicEDKey | — | base64 公钥（generate_keys 输出） |
| SUEnableAutomaticChecks | 未设 | 是否默认开启自动检查；未设时二次启动会询问用户 |
| SUScheduledCheckInterval | 86400s | 自动检查间隔（下限 1 小时） |
| SUAutomaticallyUpdate | NO | 是否默认后台静默下载并安装 |
| SUAllowsAutomaticUpdates | — | 是否允许用户开启「自动安装」 |
| SUEnableSystemProfiling | NO | 匿名系统画像（可选上报） |
| SUShowReleaseNotes | YES | 是否在更新弹窗展示发行说明 |

### 3.7 minimumSystemVersion（系统版本门槛）

- appcast item 里加 sparkle:minimumSystemVersion（要求**三段式 major.minor.patch**），Sparkle 据此只给满足最低系统版本的设备推送该更新；不满足时标准弹窗提示不兼容并可跳官网。[publishing](https://sparkle-project.org/documentation/publishing/)
- 反向用 sparkle:maximumSystemVersion 可限制最高系统版本。
- 2.9 起还有 sparkle:hardwareRequirements（如 arm64）指定仅 Apple Silicon。[publishing](https://sparkle-project.org/documentation/publishing/)

### 3.8 Channels（通道，2 起）

- 支持 beta/灰度通道：item 里 sparkle:channel 表示只在某通道发布；默认通道之外，只有允许该通道的更新器才能看到。[publishing#channels](https://sparkle-project.org/documentation/publishing/)
- 客户端在 -[SPUUpdaterDelegate allowedChannelsForUpdater:] 返回 Set 开放指定通道（默认通道始终可见）。[publishing#channels](https://sparkle-project.org/documentation/publishing/)
- 官方说明通道**不适合**做并行长期分支（如「1.0」与「1.0 demo」），而是用于 beta→正式这种短时分支；2.0 于 2021-06-27 加入通道支持。[publishing#channels](https://sparkle-project.org/documentation/publishing/)

### 3.9 Phased rollout（分阶段灰度）

- item 里加 sparkle:phasedRolloutInterval（秒）指定**各群组之间的推送间隔**，并依赖合法 pubDate。[publishing#phased-group-rollouts](https://sparkle-project.org/documentation/publishing/)
- **群组数被 Sparkle 硬编码为 7**；例：phasedRolloutInterval=86400 表示每天推一个新群组，7 天推完。[publishing#phased-group-rollouts](https://sparkle-project.org/documentation/publishing/)
- Sparkle 用 SUUpdateGroupIdentifier 在用户 defaults 里生成随机群组 ID（下载更新时会重新生成，不上传服务器）。[publishing#phased-group-rollouts](https://sparkle-project.org/documentation/publishing/)
- **critical 更新、以及用户手动检查时，不受 phased rollout 影响**。[publishing#phased-group-rollouts](https://sparkle-project.org/documentation/publishing/)

### 3.10 Delta 更新（增量包）

- 支持 delta：用户只下载「从旧版本变到新版本」的变更内容。generate_appcast 会自动生成并签名 delta。[delta-updates](https://sparkle-project.org/documentation/delta-updates/)、[publishing](https://sparkle-project.org/documentation/publishing/)
- 手动生成：./bin/BinaryDelta create --version=<FORMAT_VERSION> path/to/old/MyApp.app path/to/new/MyApp.app patch.delta。[delta-updates](https://sparkle-project.org/documentation/delta-updates/)
- 每个 delta 在 appcast item 里以 sparkle:deltas > enclosure（sparkle:deltaFrom、sparkle:edSignature）形式出现，需单独签名。[delta-updates](https://sparkle-project.org/documentation/delta-updates/)
- **兼容性按格式版本表**：delta format 4 → Sparkle 2.7；3 → 2.1；2 → 1.10；1 → 1.5。老格式建议尽快迁移。[delta-updates#compatibility](https://sparkle-project.org/documentation/delta-updates/)
- 若没有对应用户版本的 delta、或 patch 应用失败，Sparkle **回退到全量更新**；打补丁后校验 checksum 保证结果正确。[delta-updates](https://sparkle-project.org/documentation/delta-updates/)
- delta 不支持：新旧 bundle 里的 ACL、含代码签名信息的扩展属性；要求 mach-o/binaries 的代码签名放在 bundle 里正确位置。[delta-updates#metadata-specification](https://sparkle-project.org/documentation/delta-updates/)

### 3.11 校验与安全模型（关键）

- **双通道校验**：对更新包，Sparkle 同时/或任一看 **EdDSA 签名** 与 **Apple Code Signing**。官方裸流程「用 EdDSA 签名防篡改 + 用 App Code Signing 验证来源与你一致」。[getting started#segue-for-security](https://sparkle-project.org/documentation/)、[SUUpdateValidator.m](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUUpdateValidator.m)
- **信任迁移（trust transfer）**：校验旧 App 的 EdDSA 公钥（老键）或旧 App 的 Code Signing 身份，二者**至少一个通过**即接受，从而允许在「换 EdDSA 键」或「换签名证书」之间选择一轮时不断链（源码注释：“old and new (Ed)DSA public keys same & valid，或 old and new Code Signing identity same & valid”）。[SUUpdateValidator.m](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUUpdateValidator.m)
- **绝对不允许降级/删键**：旧版有 EdDSA 公钥、新版删掉；或旧版已 Code Sign、新版未签——都会**拒绝**（“Sparkle only supports rotation, but not removal”）。[SUUpdateValidator.m](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUUpdateValidator.m)
- 可选更强设置：SUVerifyUpdateBeforeExtraction（解压前强制验证，2.7.3+）、SURequireSignedFeed（连 appcast 与发行说明也签名，2.9+，需先开前者）、SUSignedFeedFailureExpirationInterval（20 天失败回退）。[customization#security-settings](https://sparkle-project.org/documentation/customization/)
- **安装器与更新器分离**：下载由 Framework 负责（可静默、可放 XPC 后台）；提取、校验、安装由 Installer（XPC/launchd）负责，且强调「校验与安装必须在同一进程完成」，通过 XPC Services / launchd 做权限分离；不再用 AuthorizationExecuteWithPrivileges。[Security.md](https://github.com/sparkle-project/Sparkle/blob/2.x/Documentation/Security.md)
- **原子替换**：优先用 Filesystem atomic swap——源码 swapItemAtURL:... 走 renameFile(…, RENAME_SWAP, …)（renameat 原子交换），失败退回 legacy 路径（把旧 app 移到临时目录）。[SUPlainInstaller.m](https://github.com/sparkle-project/Sparkle/blob/2.x/Autoupdate/SUPlainInstaller.m)、[SUFileManager.m](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUFileManager.m)

### 3.12 会不会要硬性签名/证书？

- 源码明确写了 ad-hoc 签名可用（passesBasicUpdatePolicyWithHostIsCodeSigned:... 里：“If no Apple Code Signing certificate is available, adhoc signing can be used at minimum.”）。[SUUpdateValidator.m](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUUpdateValidator.m)
- **但仍有两个实际门槛**：
  1. **Library Validation（Hardened Runtime 的一部分，notarization 要求开启）**：若开启，需用 Apple Development 证书签名，否则系统会拦截加载 Sparkle.framework——文档明确「Debug 配置关闭 Library Validation 或改签名证书；ad-hoc 本地运行时可能加载不了 Sparkle」。[getting started](https://sparkle-project.org/documentation/)
  2. **分发时代码签名一致性**：notarized/Developer ID 下要求新旧签名身份一致，否则更新被拒。ad-hoc 的 designated requirement 为空，codeSignatureIsValidAtBundleURL:andMatchesSignatureAtBundleURL:（SecStaticCodeCheckValidityWithErrors + kSecCSCheckAllArchitectures）对 ad-hoc 通常能「匹配」，**技术上可走通**，但这不是官方推荐的发布姿态。[SUCodeSigningVerifier.m](https://github.com/sparkle-project/Sparkle/blob/2.x/Autoupdate/SUCodeSigningVerifier.m)
- 简言之：**ad-hoc 是「能跑」的边角路径，不是「推荐」的生产路径**；Sparkle 完整安全模型默认假设你有 Developer ID + notarization。

---

## 4. 各框架/Source 细节依据

### 4.1 Electron autoUpdater / Squirrel

- 官方：macOS 上 autoUpdater 基于 **Squirrel.Mac**，Windows 基于 Squirrel.Windows / MSIX；**Linux 不支持内置 autoUpdater**（建议用发行版包管理器）。[auto-updater](https://www.electronjs.org/docs/latest/api/auto-updater)
- **macOS 自动更新要求应用已签名**（Squirrel.Mac 硬性要求）。[auto-updater](https://www.electronjs.org/docs/latest/api/auto-updater)
- 更新入口可带 sha256、size，甚至 delta（from_version + BinaryDelta 生成）——与 Sparkle delta 同源。[auto-updater](https://www.electronjs.org/docs/latest/api/auto-updater)
- API 表面：setFeedURL / checkForUpdates / quitAndInstall；事件 update-downloaded、before-quit-for-update 等。更新下载自动，重启才替换。[auto-updater](https://www.electronjs.org/docs/latest/api/auto-updater)
- 服务端：macOS 用 releases.json（currentRelease + releases[].updateTo），Windows 用 RELEASES（NuGet nupkg）。update.electronjs.org 是官方免费服务，要求 macOS 应用已签名 + 发布到 GitHub Releases。[updates](https://www.electronjs.org/docs/latest/tutorial/updates)

### 4.2 Tauri updater

- 支持 Windows / Linux / macOS（Android/iOS 不支持）。[updater.mdx](https://v2.tauri.app/plugin/updater/)
- **签名强制、不可关闭**：tauri signer generate 产密钥；构建产物带 .sig；公钥写进 tauri.conf.json 的 plugins.updater.pubkey；签名无法绕过（“This cannot be disabled”）。[updater.mdx#signing-updates](https://v2.tauri.app/plugin/updater/)
- 底层用 minisign-verify（ed25519 的 minisign 格式）。[plugin Cargo.toml](https://github.com/tauri-apps/plugins-workspace/blob/v2/plugins/updater/Cargo.toml)
- 清单：tauri.conf.json 配 endpoints（可含 {{current_version}}/{target}/{arch} 变量）；或静态 latest.json（version + platforms.<OS-ARCH>.{url,signature}），version 用 SemVer。[updater.mdx#server-support](https://v2.tauri.app/plugin/updater/)
- 安装：macOS 打 .tar.gz，Windows installMode（passive/basicUi/quiet），安装后 app.restart()。[updater.mdx](https://v2.tauri.app/plugin/updater/)

### 4.3 Homebrew Cask

- Cask 是**声明式 Ruby 文件**，核心是 url + sha256 + 若干 artifact 声明；brew upgrade（或带 --greedy）负责重装。[Cask-Cookbook](https://docs.brew.sh/Cask-Cookbook)
- 校验主要靠 Cask 里写的 sha256 与上游 HTTPS；不涉及强签名框架。[Cask-Cookbook](https://docs.brew.sh/Cask-Cookbook)
- auto_updates 语义：断言 cask 的应用自带更新机制——**仅当应用菜单里有「Check for Updates…」这种能真的下载并安装的入口**时才标 true；若只是打开网页让你手动下载，则**不算**自动更新。[Cask-Cookbook#auto_updates](https://docs.brew.sh/Cask-Cookbook)
- brew upgrade --greedy / --greedy-latest / --greedy-auto-updates 会额外纳入 version :latest 与 auto_updates true 的 cask。[Manpage#upgrade](https://docs.brew.sh/Manpage)
- 对 v5xs：Cask 属「用户已装 Homebrew」前提下的**包管理型更新**，不是应用内自更新；与 v5xs 现在的「应用内检查 + 打开下载页」互补而非替代。

### 4.4 Windows winget

- winget upgrade 按包 ID 精确升级，可选 --interactive/--silent；来源包括 Microsoft Store 与社区清单仓库。[winget upgrade](https://learn.microsoft.com/en-us/windows/package-manager/winget/upgrade)
- 属包管理器驱动更新，校验依赖清单 HTTPS 与安装程序签名/UAC，不是应用内自更新。

### 4.5 Windows MSIX + App Installer

- .appinstaller XML 描述应用来源与更新方式；用户首次点击安装后应用与该文件关联，之后只更新 .appinstaller 即可向用户推送新版。[App Installer file overview](https://learn.microsoft.com/en-us/windows/msix/app-installer/app-installer-file-overview)
- UpdateSettings 元素：OnLaunch（启动时检查）、HoursBetweenUpdateChecks（1–255，默认 24）、AutomaticBackgroundTask（每 8 小时后台静默检查，不可显示 UI）、ShowPrompt/UpdateBlocksActivation（1903+）、ForceUpdateFromAnyVersion（1903+，允许降级）。[Configure update settings](https://learn.microsoft.com/en-us/windows/msix/app-installer/update-settings)
- 校验：MSIX 包签名链接到受信任根；更新由系统 App Installer 代做。
- 注意：MS 文档提醒 ms-appinstaller: URI 默认自 2023-12 起禁用，需直接链接 .appinstaller 文件。[App Installer file overview](https://learn.microsoft.com/en-us/windows/msix/app-installer/app-installer-file-overview)

### 4.6 Linux AppImage

- AppImage 更新两条路径：外部工具（AppImageUpdate / appimageupdatetool）、或 appimagetool -u 把 **update information**（如 zsync|https://…/x.AppImage.zsync）内嵌进 AppImage，再生成 .zsync。[Making AppImages updateable](https://docs.appimage.org/packaging-guide/optional/updates.html)
- zsync 让增量只拉变化块，更新信息始终跟随 AppImage，用户无需维护 repo 描述文件。[docs.appimage.org](https://docs.appimage.org/packaging-guide/optional/updates.html)
- 说明：electron-builder 的 AppImage 用其自有更新方案，不兼容 zsync 这套。[docs.appimage.org](https://docs.appimage.org/packaging-guide/optional/updates.html)

### 4.7 Linux Flatpak

- 仓库用 **OSTree** 保存每个版本并记录版本间差异；**更新时只拉 delta**，效率高。[Repositories](https://docs.flatpak.org/en/latest/repositories.html)
- 仓库绑定 **GPG 签名**；软件中心可自动检查并安装，命令行用 flatpak update。[Repositories](https://docs.flatpak.org/en/latest/repositories.html)、[Command Reference](https://docs.flatpak.org/en/latest/flatpak-command-reference.html)

---

## 5. v5xs 现状梳理（一手核对，非假设）

以下来自对仓库的实读（scripts/、Resources/Info.plist、README.md、make-update-manifest.sh）：

- **构建**：纯 swiftc -swift-version 6 手工构建（scripts/build-app.sh），用 -framework AppKit/SwiftUI/Charts/ServiceManagement/IOKit/CoreBluetooth，再手工 install_name_tool 处理动态库路径，最后 codesign --force --deep --sign - 打 **ad-hoc 签名**。无 Developer ID，无 notarization。
- **签名实况**（本机 codesign -dv 输出）：Signature=adhoc、flags=0x2(adhoc)、TeamIdentifier=not set、Internal requirements count=0。
- **分发**：scripts/build-dmg.sh 用 dmgbuild 生成 dist/v5xs-<ver>-macOS-<osver>-<arch>.dmg；git remote 指向 github.com/zyw/v5xs；README 说明「从 GitHub Releases 下载 DMG」。
- **版本**：CFBundleShortVersionString=0.2.0、CFBundleVersion=2（Resources/Info.plist）。
- **已进行的自动更新雏形**（同仓库其他成员在排期）：客户端用 URLSession 拉 Info.plist 的 V5XSUpdateFeedURL → https://raw.githubusercontent.com/zyw/v5xs/main/dist/update.json；update.json 字段 version/build/minimumSystemVersion/publishedAt/notes/downloads[{architecture,url,size,sha256}]（见 make-update-manifest.sh 注释）；发布侧 make-update-manifest.sh 用系统自带工具（PlistBuddy/shasum/stat）算 sha256 并生成清单。
- **当前边界（README 明示）**：只做「检查 + 打开下载页」，不下载、不替换、不重启；清单与安装包走 HTTPS；sha256 字段已预留但**尚未做安装包签名校验**。

---

## 6. 针对 v5xs 的选型结论

### 6.1 两条路对比

#### A. 自研轻量更新器（延续现方向：清单 + 校验 + 跳转/可选替换）

优点：
- **贴合 v5xs 现实**：纯 swiftc 手工构建 + ad-hoc 签名 + DMG + GitHub Releases，不引入 framework / XPC Service，不改打包流水线，make-update-manifest.sh 已能纯系统工具生成 sha256。
- **可控**：代码量小、逻辑透明，符合「菜单栏小工具 + 手动构建」的极简运维。
- **无需 Developer ID/notarization**：绕开 Sparkle 默认假设的开发签名门槛。

代价/风险：
- **替换与重启要自己写**（现在是只跳转）：要自己处理下载后校验、落盘、替身（NSTask + codesign/ditto，或 POSIX rename 原子换）与拉起新版；这是更新器最易出错、最影响安全的部分。
- **签名安全要自己设计**：目前只靠 HTTPS + sha256。若引入安装包签名（如对 update.json 或 DMG 做 EdDSA/minisign 并内置公钥），相当于**自己造轮子复刻 Sparkle 的一个子集**——要自己管密钥、签名口令、Keychain 或环境变量，出错即不可更新。
- 没有成熟的 phased rollout / channels / delta / release-notes UI——对个人小工具未必需要。

#### B. 接入 Sparkle 2

优点：
- **最成熟的 macOS 原生方案**：自动处理下载、校验（EdDSA+Code Signing 双通道）、**原子替换**、重启、权限分离（XPC/launchd）、delta、channels、phased rollout、critical/major 语义。
- 官方「无需在 app 写多少代码」；对 SwiftUI App 有 SPUStandardUpdaterController 示例。

代价/风险（针对 v5xs 现实，最重要）：
1. **默认假设 Developer ID + notarization**。v5xs 现在是 ad-hoc 签名、不 notarize。源码虽写 ad-hoc 可用，但：若未来开 Hardened Runtime（notarization 必开），Library Validation 会拦掉加载 Sparkle.framework，要么买证书，要么 Debug 关 LV（不能用于发布）；ad-hoc 是边角路径而非推荐姿态。
2. **构建/打包要改**：Sparkle.framework + XPC Services 要嵌入 .app 并正确签名；纯 swiftc 手工打包要额外维护 framework 嵌入与签名、@loader_path rpath、symlink、XPC 服务代码签名。
3. **清单格式要改**：Sparkle 吃 RSS appcast，现 update.json 不兼容，要么并行维护两份清单，要么整体迁 generate_appcast。
4. **最低版本**：Sparkle 2.x 要求 macOS 12+（v5xs 已是 macOS 14+，无碍）。

#### 结论建议（供 lead 决策）

- **短期（贴合现状）**：**自研轻量更新器**，沿用 update.json + 校验 + 跳转下载——已满足 v5xs「菜单栏小工具、手动构建、不打开发者签名交钥匙」的现实，几乎零额外依赖。
- **中期若想把「检查+跳转」升级为「静默自更新」**：优先补两块，而不是整体引入 Sparkle：
  1. **安装包签名**：对 update.json 或 DMG 做 **EdDSA/minisign**（参考 Tauri）并把公钥内置 App；downloads[].sha256 已在，再叠一个签名校验即可基本对齐 Sparkle 防篡改诉求。[updater.mdx](https://v2.tauri.app/plugin/updater/)
  2. **可靠的原子替换 + 重启**：用 NSTask 触发 helper 一次执行 rename 替换并 open 新版（参考 Sparkle RENAME_SWAP 拆法）。
- **只有 v5xs 决定走「正式签名 + notarization + 多分支灰度」的产品化路线时，才真正值得切 Sparkle 2**——那时 channels/phased rollout/delta 与官方维护价值才回本。

> 一句话：**v5xs 当前「ad-hoc + 手工构建 + DMG + GitHub Releases」约束下，自研轻量的「清单 + 校验 + 跳转」性价比最高；Sparkle 2 的能力要吃满几乎强制 Developer ID + notarization + framework 打包改造，现阶段收益不划来。**

---

## 7. 来源清单（本轮实际核验的一手来源，共 24 个）

1. [Sparkle: Documentation（基本安装 / 加入 framework）](https://sparkle-project.org/documentation/)
2. [Sparkle: Publishing an update](https://sparkle-project.org/documentation/publishing/)
3. [Sparkle: Programmatic setup](https://sparkle-project.org/documentation/programmatic-setup)
4. [Sparkle: Customizing Sparkle](https://sparkle-project.org/documentation/customization/)
5. [Sparkle: Delta Updates](https://sparkle-project.org/documentation/delta-updates/)
6. [Sparkle GitHub: README.markdown](https://github.com/sparkle-project/Sparkle/blob/2.x/README.markdown)
7. [Sparkle GitHub: Package.swift](https://github.com/sparkle-project/Sparkle/blob/2.x/Package.swift)
8. [Sparkle GitHub: Resources/SampleAppcast.xml](https://github.com/sparkle-project/Sparkle/blob/2.x/Resources/SampleAppcast.xml)
9. [Sparkle GitHub: SUUpdateValidator.m](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUUpdateValidator.m)
10. [Sparkle GitHub: SUCodeSigningVerifier.m](https://github.com/sparkle-project/Sparkle/blob/2.x/Autoupdate/SUCodeSigningVerifier.m)
11. [Sparkle GitHub: SUPlainInstaller.m / SUFileManager.m](https://github.com/sparkle-project/Sparkle/blob/2.x/Autoupdate/SUPlainInstaller.m)
12. [Sparkle GitHub: Documentation/Security.md](https://github.com/sparkle-project/Sparkle/blob/2.x/Documentation/Security.md)
13. [Electron: autoUpdater API](https://www.electronjs.org/docs/latest/api/auto-updater)
14. [Electron: Updating Applications](https://www.electronjs.org/docs/latest/tutorial/updates)
15. [Tauri: Updater 插件文档](https://v2.tauri.app/plugin/updater/)
16. [Tauri updater 插件 Cargo.toml（minisign-verify）](https://github.com/tauri-apps/plugins-workspace/blob/v2/plugins/updater/Cargo.toml)
17. [Homebrew: Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)
18. [Homebrew: Manpage — upgrade](https://docs.brew.sh/Manpage)
19. [Microsoft: App Installer file overview](https://learn.microsoft.com/en-us/windows/msix/app-installer/app-installer-file-overview)
20. [Microsoft: Configure update settings in App Installer file](https://learn.microsoft.com/en-us/windows/msix/app-installer/update-settings)
21. [Microsoft: winget upgrade](https://learn.microsoft.com/en-us/windows/package-manager/winget/upgrade)
22. [AppImage: Making AppImages updateable](https://docs.appimage.org/packaging-guide/optional/updates.html)
23. [Flatpak: Repositories → Publishing updates](https://docs.flatpak.org/en/latest/repositories.html)
24. [Flatpak: Command Reference](https://docs.flatpak.org/en/latest/flatpak-command-reference.html)

> 上述共 **24 个**一手来源页面/文件。无法从一手来源确认之处均以「未核实」标注或未写入本文。
