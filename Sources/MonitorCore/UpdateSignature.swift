import CryptoKit
import Foundation

/// 更新清单的 Ed25519 签名校验。
///
/// 为什么需要它：清单里的 `sha256` 和清单本身来自同一个 HTTPS 响应，
/// 一旦清单源被劫持，攻击者可以同时替换清单和安装包，SHA-256 校验毫无意义。
/// Ed25519 把信任收窄到「内嵌在 App 里的那一个公钥」——攻击者必须同时拿到私钥，
/// 只劫持网络是不够的。
///
/// 签名覆盖的内容是**规范化后的待签串**（`canonicalPayload`），
/// 而不是原始 JSON 文本：JSON 的键顺序、空白、数字写法都可能变化，
/// 签原文会导致轻微格式变动就验签失败。
public enum UpdateSignature {
    /// 清单里承载签名的字段名。
    public static let fieldName = "signature"

    /// 验签失败的各类原因。区分开是为了给用户可执行的提示，
    /// 而不是笼统的「更新失败」。
    public enum Failure: Error, Equatable {
        /// 清单里没有签名（旧版本清单）。
        case missing
        /// 签名不是合法的 base64 或长度不为 64 字节。
        case malformed
        /// 内嵌公钥不是合法的 32 字节。
        case invalidPublicKey
        /// 验签不通过：内容被篡改，或签名不是用对应私钥生成的。
        case invalid
    }

    /// 构造待签串。
    ///
    /// 参与签名的字段：version / build / minimumSystemVersion / publishedAt /
    /// 以及每个 download 的 architecture / url / size / sha256。
    /// `notes` **不参与**签名——发行说明只是展示文本，把它纳入签名会让
    /// 「只改文案」也需要重新签一次私钥，代价大于收益。
    ///
    /// 用 `\n` 分隔、字段顺序固定，避免拼接歧义（如 version="1" build="23"
    /// 与 version="12" build="3" 拼出同一个串）。
    public static func canonicalPayload(_ release: UpdateRelease) -> Data {
        var lines: [String] = []
        lines.append("v5xs-update-v1")
        lines.append("version=\(release.version)")
        lines.append("build=\(release.build)")
        lines.append("minimumSystemVersion=\(release.minimumSystemVersion ?? "")")
        // publishedAt 统一成 UTC 秒精度，避免毫秒/时区写法差异导致验签失败。
        lines.append("publishedAt=\(publishedAtString(release.publishedAt))")
        // 下载项按架构排序，消除清单里数组顺序的影响。
        for download in release.downloads.sorted(by: { $0.architecture < $1.architecture }) {
            lines.append("download.architecture=\(download.architecture)")
            lines.append("download.url=\(download.url.absoluteString)")
            lines.append("download.size=\(download.size.map(String.init) ?? "")")
            lines.append("download.sha256=\(download.sha256?.lowercased() ?? "")")
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// 用给定的 base64 公钥验证签名。
    /// - Parameters:
    ///   - signatureBase64: 清单里 `signature` 字段的内容。
    ///   - publicKeyBase64: 内嵌在 App 里的 Ed25519 公钥（32 字节的 base64）。
    public static func verify(
        release: UpdateRelease,
        signatureBase64: String,
        publicKeyBase64: String
    ) -> Failure? {
        guard !signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .missing
        }
        guard let keyData = Data(base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              keyData.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            // 公钥有问题属于开发/发版配置错误，不是用户能处理的，单独区分便于排错。
            return .invalidPublicKey
        }
        guard let signature = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              signature.count == 64 else {
            return .malformed
        }
        let payload = canonicalPayload(release)
        return publicKey.isValidSignature(signature, for: payload) ? nil : .invalid
    }

    // MARK: - 发版侧辅助

    /// 生成密钥对（发版机器上执行一次，私钥务必离线保存）。
    public static func generateKeyPair() -> (publicKeyBase64: String, privateKeyBase64: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (key.publicKey.rawRepresentation.base64EncodedString(),
                key.rawRepresentation.base64EncodedString())
    }

    /// 对待签串签名，返回 base64。供发版脚本 / 测试使用。
    public static func sign(_ payload: Data, privateKeyBase64: String) throws -> String {
        guard let raw = Data(base64Encoded: privateKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
            throw Failure.invalidPublicKey
        }
        return try key.signature(for: payload).base64EncodedString()
    }

    private static func publishedAtString(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
