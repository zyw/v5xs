import Foundation

/// 应用界面语言。
///
/// 为什么不用 `.strings` / `NSLocalizedString`：本项目的界面文案大量以字符串插值和
/// 计算属性形式出现（如 `"已运行 \(uptime)"`），走 .strings 需要把每处都改造成
/// 带占位符的键，且 SwiftUI 的 `Text` 在运行期切换语言需要重启进程。
/// 这里改用「一张表 + 一个当前语言单例」，配合 `Localized` 环境值，
/// 切换语言时整个界面立即重绘，无需重启。
public enum AppLanguage: String, CaseIterable, Sendable, Identifiable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en = "en"

    public var id: String { rawValue }

    /// 语言名称按**该语言自身**书写，便于用户在自己的语言界面里认出自己的语言。
    public var nativeName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        }
    }

    /// 从持久化值还原；无法识别时回落到系统语言推断结果。
    public static func stored(_ raw: String?) -> AppLanguage? {
        guard let raw, let value = AppLanguage(rawValue: raw) else { return nil }
        return value
    }

    /// 依据系统偏好推断初始语言。
    /// 注意：`Locale.preferredLanguages` 的首项可能是 `zh-Hant-TW` 这类带地区的标签，
    /// 必须先判断繁体（Hant / TW / HK / MO），否则会被 `zh` 前缀误判成简体。
    public static func fromSystem() -> AppLanguage {
        let candidates = Locale.preferredLanguages + [
            Locale.current.language.languageCode?.identifier ?? ""
        ]
        for tag in candidates {
            let lower = tag.lowercased()
            if lower.hasPrefix("zh") {
                if lower.contains("hant") || lower.contains("tw")
                    || lower.contains("hk") || lower.contains("mo") {
                    return .zhHant
                }
                return .zhHans
            }
            if lower.hasPrefix("en") { return .en }
        }
        return .zhHans
    }
}
