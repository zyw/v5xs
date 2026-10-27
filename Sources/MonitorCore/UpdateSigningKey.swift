import Foundation

/// 内嵌的更新清单验证公钥（Ed25519，32 字节 base64）。
///
/// 这把公钥是自动更新的**唯一信任根**：清单必须带着用对应私钥签出的签名，
/// 否则客户端拒绝安装。私钥保存在发版机器上（见 scripts/update-keys/），
/// 绝不进入仓库、绝不进入安装包。
///
/// 换密钥意味着所有已发布客户端的自动更新会失效（旧客户端只认旧公钥），
/// 因此除非私钥泄露，否则不要更换。
public enum UpdateSigningKey {
    public static let publicKeyBase64 = "guDhXYdsE8QOYf+CU69nZS8WxTjttVzUiZgI0b4HCTo="
}
