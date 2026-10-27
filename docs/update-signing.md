# 自动更新：清单签名与密钥管理

v5xs 的自动更新依赖 **Ed25519 签名**来确认清单真实来自发版者。
本文说明签名机制、密钥管理和发版操作。

## 为什么需要签名

更新清单里的 `sha256` 和清单本身来自同一个 HTTPS 响应。如果清单源被劫持，
攻击者可以同时替换清单和安装包，SHA-256 校验完全无效——两者一起被换掉了。

Ed25519 把信任收窄到**内嵌在 App 里的那一个公钥**（`UpdateSigningKey.swift`）。
攻击者必须同时拿到私钥才能伪造更新，只劫持网络是不够的。

签名覆盖的字段：

```
version / build / minimumSystemVersion / publishedAt
downloads[].architecture / url / size / sha256
```

`notes`（发行说明）**不参与签名**——它只是展示文本，纳入签名会让「只改文案」
也需要动用私钥，代价大于收益。

## 密钥文件

| 文件 | 位置 | 是否入库 |
| --- | --- | --- |
| 公钥 | `Sources/MonitorCore/UpdateSigningKey.swift`（编译进 App） | 是 |
| 私钥 | `scripts/update-keys/ed25519.key` | **否**（已 gitignore） |

私钥在生成时已自动写入 `.gitignore`，权限设为 `600`。

> **私钥泄露的后果**：任何人都能给所有已安装的 v5xs 推送安装包。
> 请离线备份，不要放进代码仓库、CI 日志或聊天工具。

## 生成新密钥对

**换密钥意味着已发布客户端的自动更新全部失效**（旧客户端只认旧公钥，
会拒绝新密钥签的清单）。除非私钥泄露，否则不要更换。

如果确实需要更换：

```bash
cd /Users/jingyuan-mb01/javaspace/REA/v5xs
swift -e '
import CryptoKit
let k = Curve25519.Signing.PrivateKey()
print("PUBLIC=\(k.publicKey.rawRepresentation.base64EncodedString())")
print("PRIVATE=\(k.rawRepresentation.base64EncodedString())")
'
```

1. 把 `PUBLIC=` 的值写进 `Sources/MonitorCore/UpdateSigningKey.swift`
2. 把 `PRIVATE=` 的值写进 `scripts/update-keys/ed25519.key`（格式 `PRIVATE_KEY_BASE64=...`）
3. 重新构建并发布——**这一步需要用户手动下载一次**（旧版本的自动更新会失败）

## 发版流程

```bash
# 1) 构建签名工具（首次或改了签名逻辑后）
bash scripts/dev-build-tools.sh

# 2) 生成清单（会自动签名）
bash scripts/make-update-manifest.sh \
  --notes docs/release-notes/0.1.3.md \
  --out dist/update.json

# 3) 校验签名（可选，但建议）
#    客户端侧的完整流程见 UpdateSignatureTests
```

脚本会在签名后**自检一次**：用 App 内嵌公钥验证刚生成的签名。
如果私钥与公钥不配对，会直接失败并提示，避免发出去一个全量更新失败的清单。

参数：

| 参数 | 说明 |
| --- | --- |
| `--sign-key <path>` | 指定私钥路径，默认 `scripts/update-keys/ed25519.key` |
| `--no-sign` | 跳过签名（仅用于本地调试） |
| `V5XS_UPDATE_SIGNING_KEY` | 环境变量形式的私钥路径 |

找不到私钥时脚本会**警告但不失败**，产出的清单不带 `signature` 字段。
客户端遇到未签名清单会拒绝自动安装（`UpdateSignature.Failure.missing`），
但手动下载仍然可用。

## 客户端行为

检查到新版本时，客户端按顺序校验：

1. **版本更新**？否则直接报告「已是最新」（不验签，避免误报）
2. **系统版本与架构** 是否满足
3. **清单签名** —— 失败则拒绝，提示具体原因
4. **清单里是否有 sha256** —— 没有则拒绝（无法校验的包不可接受）

失败提示区分三种情况，便于排查：

| 情况 | 提示 |
| --- | --- |
| `missing` | 更新清单缺少签名，已拒绝安装 |
| `malformed` | 更新清单的签名格式不正确 |
| `invalid` | 签名校验失败，可能被篡改 |
| `invalidPublicKey` | 内置公钥无效，请重新安装 |

## CI 配置（必做一次）

自动更新依赖签名，而私钥不能进仓库，因此必须在 GitHub 仓库里配置一个 secret。

### 1. 取出私钥内容

```bash
cd /Users/jingyuan-mb01/javaspace/REA/v5xs
# 只取等号后面那段 base64，不要带 PRIVATE_KEY_BASE64= 前缀和换行
grep '^PRIVATE_KEY_BASE64=' scripts/update-keys/ed25519.key | cut -d= -f2-
```

> 这条命令会把私钥打印到终端。注意不要在录屏、共享屏幕或聊天窗口里执行。

### 2. 写入 Repository secret

**方式 A：网页**

1. 打开 `https://github.com/zyw/v5xs/settings/secrets/actions`
2. 点 **New repository secret**
3. Name 填 `V5XS_UPDATE_SIGNING_KEY`
4. Secret 填上一步输出的 base64（**不要包含 `PRIVATE_KEY_BASE64=` 前缀**）
5. 保存

**方式 B：命令行**

```bash
gh secret set V5XS_UPDATE_SIGNING_KEY --repo zyw/v5xs \
  --body "$(grep '^PRIVATE_KEY_BASE64=' scripts/update-keys/ed25519.key | cut -d= -f2-)"
```

### 3. 验证配置生效

推到 `v*` tag 后，工作流里应能看到：

```
✅ Write signing key
✅ Build signing tool
✅ Generate update.json
   签名已写入清单。
✅ Verify signature with client public key
   签名校验通过：v0.1.3 build 5
✅ Upload update.json to release
```

如果 `Write signing key` 这一步失败，说明 secret 没配好；工作流会**故意失败**
而不是产出一个没有签名的清单——后者会让用户更新时静默失败，更难排查。

### 工作流做了什么

| 步骤 | 作用 |
| --- | --- |
| Write signing key | 从 secret 写私钥到 `scripts/update-keys/`（仅本次 runner） |
| Build signing tool | 编译 `sign-manifest`，复用客户端的规范化逻辑 |
| Generate update.json | 生成清单并自动签名 |
| Verify signature with client public key | 用**仓库里的公钥**复验，确认公私钥配对 |
| Remove signing key | `always()` 清理私钥，即使前面步骤失败也执行 |

**为什么要有「用公钥复验」这一步**：签名工具自己已经自检过，但那是拿「刚写入的私钥」
去验自己。真正要确认的是「这个私钥对应的公钥是不是编译进 App 的那一个」——
只有仓库里的 `UpdateSigningKey.publicKeyBase64` 才是事实标准。两者不配对时，
所有已安装客户端都会拒绝这次更新，必须在发布前拦住。

---

## 本地发版（不走 CI）

```bash
bash scripts/dev-build-tools.sh          # 构建签名工具
bash scripts/make-update-manifest.sh \
  --notes docs/release-notes/0.1.3.md \
  --out dist/update.json                  # 自动使用 scripts/update-keys/ 里的私钥
```

脚本在签名后会自检一次，失败会直接报错并提示公私钥不配对。

## 已知限制

**ad-hoc 签名的应用无法做真正的代码签名验证。** `codesign --verify` 只能确认
包没损坏，确认不了「这个包来自 v5xs 作者」——因为 ad-hoc 签名不绑定身份。

当前的安全保障是：

- HTTPS 传输
- Ed25519 清单签名（内嵌公钥）
- 安装包的 SHA-256 与清单一致

也就是说，安全边界是**「你信任那个私钥」**，而不是「你信任 Apple 的公证体系」。
将来若采用 Developer ID 签名 + 公证，可以叠加完整的 `SecStaticCodeCheckValidity` 校验。
