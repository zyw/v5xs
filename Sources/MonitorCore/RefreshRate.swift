import Foundation

/// 监测页面（菜单栏面板）的采样刷新频率。
///
/// 为什么做成枚举而不是直接存秒数：采样周期同时决定了 CPU 开销与曲线平滑度，
/// 让用户在几个语义明确的档位里选，比让他填一个任意秒数更不容易选出无意义的值
/// （例如 0.01 秒会直接把 CPU 打满）。持久化时只存原始值，便于将来增删档位。
public enum RefreshRate: String, CaseIterable, Sendable {
    /// 0.5 秒：最高精度，适合观察瞬时峰值与录音/编译等短时负载。
    case high = "0.5"
    /// 1 秒：默认档，与原行为一致。
    case normal = "1"
    /// 2 秒：降低开销，指标变化较平缓时足够。
    case relaxed = "2"
    /// 5 秒：最省电，适合只看趋势。
    case low = "5"

    public static let `default` = RefreshRate.normal

    /// 采样间隔（秒）。
    public var interval: TimeInterval {
        switch self {
        case .high: return 0.5
        case .normal: return 1
        case .relaxed: return 2
        case .low: return 5
        }
    }

    /// 设置页里展示的名称。
    public var title: String {
        switch self {
        case .high: return "极快（0.5 秒）"
        case .normal: return "标准（1 秒）"
        case .relaxed: return "平稳（2 秒）"
        case .low: return "省电（5 秒）"
        }
    }

    /// 面板底部状态栏用的简短描述，需与 `interval` 保持一致。
    /// 单独提供而不是从 title 截取，是为了让底部文案能独立调整措辞。
    public var shortDescription: String {
        switch self {
        case .high: return "每 0.5 秒更新"
        case .normal: return "每秒更新"
        case .relaxed: return "每 2 秒更新"
        case .low: return "每 5 秒更新"
        }
    }

    /// 说明该档位的取舍，显示在设置页的说明文字里。
    public var detail: String {
        switch self {
        case .high: return "每 0.5 秒采样，曲线最细腻，CPU 开销最高。"
        case .normal: return "每秒采样，兼顾精度与开销。"
        case .relaxed: return "每 2 秒采样，开销更低，适合日常查看。"
        case .low: return "每 5 秒采样，最省电，只反映趋势。"
        }
    }

    /// 从持久化值还原；无法识别时回落到默认档，避免旧数据或手改 plist 让采样停摆。
    public static func stored(_ raw: String?) -> RefreshRate {
        guard let raw, let value = RefreshRate(rawValue: raw) else { return .default }
        return value
    }

    /// 兼容旧的 `lowLatencyMode` 布尔设置：开=极快，关=标准。
    public static func migratingFromLowLatency(_ lowLatency: Bool) -> RefreshRate {
        lowLatency ? .high : .normal
    }
}
