import Foundation
import SwiftUI

/// 运行时语言环境。切换语言时写入 `UserDefaults` 并通过 `objectWillChange` 通知界面重绘，
/// 无需重启进程。
///
/// 为什么不用 `NSLocalizedString` + `Bundle` 方案：那套机制依赖系统语言或应用语言列表，
/// 运行期切换需要重建进程（或仅对部分 API 生效），而 SwiftUI 的 `Text("key")`
/// 一旦取到值就固定了。这里让每个视图都观察 `Localization`，切换时整体刷新。
///
/// 并发说明：本类型刻意**不标注** `@MainActor`——`EnvironmentKey.defaultValue` 是
/// nonisolated 要求，标了会触发 Swift 6 的 ConformanceIsolation 错误。
/// 可变的 `language` 由内部锁保护，读取是线程安全的；写入只会在主线程的设置页发生。
/// `@unchecked Sendable`：可变状态 `current` 由 `lock` 保护，`defaults` 与
/// `ObservableObject` 的发布机制均在主线程访问，因此可安全跨 actor 传递。
public final class Localization: ObservableObject, @unchecked Sendable {
    public static let storageKey = "appLanguage"

    private let lock = NSLock()
    private var current: AppLanguage
    private let defaults: UserDefaults

    /// 当前语言。读取线程安全。
    public var language: AppLanguage {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public init(language: AppLanguage? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let language {
            self.current = language
        } else if let stored = AppLanguage.stored(defaults.string(forKey: Self.storageKey)) {
            self.current = stored
        } else {
            // 首次启动：跟随系统语言，并立刻落盘，之后不再随系统变化（尊重用户选择）。
            let detected = AppLanguage.fromSystem()
            defaults.set(detected.rawValue, forKey: Self.storageKey)
            self.current = detected
        }
    }

    /// 切换界面语言。设置页与所有观察者会立即刷新。
    public func set(_ language: AppLanguage) {
        lock.lock()
        let changed = language != current
        if changed { current = language }
        lock.unlock()
        guard changed else { return }
        defaults.set(language.rawValue, forKey: Self.storageKey)
        objectWillChange.send()
    }

    /// 取文案。
    public func t(_ key: StringKey) -> String {
        Strings.text(key, language)
    }

    /// 取带参数的文案。按顺序替换 `%@` 与 `%d`。
    public func t(_ key: StringKey, _ args: CVarArg...) -> String {
        String(format: Strings.text(key, language), arguments: args)
    }

    /// 当前语言的非隔离快照。领域模型（如 `HealthScore.label`）没有 SwiftUI 环境，
    /// 通过它取当前语言；主线程外访问由内部锁保护。
    public static var currentLanguage: AppLanguage {
        shared.language
    }

    /// 全局共享实例：供 AppDelegate 注入 SwiftUI、以及领域模型取当前语言。
    /// 视图层仍然通过 `@Environment(\.localization)` 取，保证切换时各自刷新。
    public static let shared = Localization()
}

// MARK: - SwiftUI 环境

private struct LocalizationKey: EnvironmentKey {
    static let defaultValue = Localization()
}

public extension EnvironmentValues {
    var localization: Localization {
        get { self[LocalizationKey.self] }
        set { self[LocalizationKey.self] = newValue }
    }
}

public extension View {
    /// 注入语言环境，并让视图在语言变化时重绘。
    func localized(_ localization: Localization) -> some View {
        self
            .environment(\.localization, localization)
            .id(localization.language)   // 语言变化时重建子树，确保所有文案刷新
    }
}
