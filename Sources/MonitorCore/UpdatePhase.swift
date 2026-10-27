import Foundation

/// 自动更新的阶段。界面完全由这个状态驱动，避免散落的布尔开关。
public enum UpdatePhase: Equatable, Sendable {
    case idle
    /// 下载中；total 未知时为 nil（服务端没给 Content-Length）。
    case downloading(received: Int64, total: Int64?)
    case verifying
    case preparing
    /// 已就绪，即将重启安装。
    case restarting
    case failed(UpdateFlowFailure)
}

/// 失败原因。与 `StringKey` 一一对应，界面据此显示可执行的提示。
/// 放在核心层是为了让「每个失败都有对应文案」可以在测试里穷举验证。
public enum UpdateFlowFailure: Equatable, Sendable {
    case cancelled
    case download(String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMissing
    case checksumMismatch
    /// 应用不在可写位置（如从 DMG 直接运行、或 /Applications 不可写）。
    case needsManualInstall(String)
    case insufficientSpace(required: Int64, available: Int64)
    case anotherInstanceRunning
    case install(String)

    public var stringKey: StringKey {
        switch self {
        case .cancelled: return .updateFailureCancelled
        case .download: return .updateFailureDownload
        case .sizeMismatch, .checksumMismatch: return .updateFailureChecksum
        case .checksumMissing: return .updateChecksumMissing
        case .needsManualInstall: return .updateFailureManualInstall
        case .insufficientSpace: return .updateFailureNoSpace
        case .anotherInstanceRunning: return .updateFailureMultipleInstances
        case .install: return .updateFailureInstall
        }
    }
}
