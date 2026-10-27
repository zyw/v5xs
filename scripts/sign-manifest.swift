import CryptoKit
import Foundation
import MonitorCore

/// 发版侧签名工具：给 update.json 加上 Ed25519 签名。
///
/// 为什么用 Swift 而不是在 bash 里拼：待签串的构造逻辑必须与客户端**逐字节一致**
/// （字段顺序、时间格式、下载项排序），任何细微差异都会导致验签失败。
/// 复用 `UpdateSignature.canonicalPayload` 是唯一能保证两边一致的做法。
///
/// 用法：
///   swift run --package-path . sign-manifest <update.json> <private-key-file>
/// 或编译后：
///   .build-local/sign-manifest dist/update.json scripts/update-keys/ed25519.key

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("sign-manifest: " + message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fail("用法: sign-manifest <update.json> <private-key-file>")
}
let manifestPath = arguments[1]
let keyPath = arguments[2]

guard let data = FileManager.default.contents(atPath: manifestPath) else {
    fail("读不到清单: \(manifestPath)")
}

// 解析出 UpdateRelease 以构造规范化串；失败说明清单本身有问题，直接报错。
let release: UpdateRelease
do {
    release = try UpdateFeed.release(from: data)
} catch {
    fail("清单解析失败: \(error)")
}

// 从密钥文件里读出 base64 私钥（支持 KEY=VALUE 或纯 base64 两种写法）。
guard let keyText = try? String(contentsOfFile: keyPath, encoding: .utf8) else {
    fail("读不到密钥文件: \(keyPath)")
}
let privateKeyBase64: String
if let range = keyText.range(of: "PRIVATE_KEY_BASE64=") {
    let rest = keyText[range.upperBound...]
    privateKeyBase64 = String(rest.prefix { !$0.isNewline }).trimmingCharacters(in: .whitespaces)
} else {
    privateKeyBase64 = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
}
guard !privateKeyBase64.isEmpty else { fail("密钥文件为空") }

let payload = UpdateSignature.canonicalPayload(release)
let signature: String
do {
    signature = try UpdateSignature.sign(payload, privateKeyBase64: privateKeyBase64)
} catch {
    fail("签名失败: \(error)")
}

// 用内嵌公钥自检：签出来的东西必须能通过客户端那套校验，
// 否则说明私钥与 App 内嵌公钥不是一对，发出去就是全量更新失败。
if let failure = UpdateSignature.verify(
    release: release,
    signatureBase64: signature,
    publicKeyBase64: UpdateSigningKey.publicKeyBase64
) {
    fail("自检失败：签名无法被客户端内嵌公钥验证（\(failure)）。请确认私钥与 UpdateSigningKey 配对。")
}

// 把 signature 字段写回 JSON。用 JSONSerialization 保持键顺序无关紧要，
// 但要注意：写回后清单的其余字段必须原样保留。
var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
object["signature"] = signature
guard let output = try? JSONSerialization.data(
    withJSONObject: object,
    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
) else {
    fail("无法序列化签名后的清单")
}
try output.write(to: URL(fileURLWithPath: manifestPath))
print("已签名 \(manifestPath)")
print("  signature: \(signature)")
