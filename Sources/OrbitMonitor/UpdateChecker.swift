import Foundation
import MonitorCore

/// 检查更新的四种结果；文案由界面层决定，错误信息在 checker 里生成。
enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(UpdateRelease, UpdateDownload)
    case failed(String)
}

/// 负责「拉清单、比版本、报结果」，不做下载与安装。
/// 更新源优先读 Info.plist 的 V5XSUpdateFeedURL，其次读环境变量 V5XS_UPDATE_FEED；
/// 两者都没有时保持 idle，不发起任何网络请求。
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var state: UpdateState = .idle
    @Published private(set) var lastCheck: Date?
    @Published private(set) var releaseNotes: UpdateNotes?

    let currentVersion: String
    let currentBuild: Int
    let feedURL: URL?

    /// 自动检查的最小间隔：24 小时。
    private static let checkInterval: TimeInterval = 24 * 3_600
    private static let lastCheckKey = "updateLastCheck"
    private static let requestTimeout: TimeInterval = 15

    private let defaults: UserDefaults
    private let session: URLSession

    init(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        // 测试进程（xctest / 裸可执行文件）没有版本号，用当前发版号兜底。
        currentVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
        currentBuild = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) ?? 1
        feedURL = Self.feedURL(bundle: bundle, environment: environment)
        lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
        releaseNotes = UpdateNotesStore.load(defaults: defaults, currentBuild: currentBuild)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.requestTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    /// 是否配置了更新源；没配置时界面应禁用「检查更新」。
    var isEnabled: Bool { feedURL != nil }

    var currentVersionText: String { "v\(currentVersion)" }

    /// 右键菜单文案：有新版时直接点明版本号，其余情况保持中性。
    var menuTitle: String {
        if case let .available(release, _) = state {
            return Strings.current(.newVersionMenu, release.version)
        }
        return Strings.current(.checkUpdatesEllipsis)
    }

    /// 启动时调用：距上次检查超过 24 小时（或从未检查）就在后台查一次。
    func startAutomaticChecks() {
        guard isEnabled, !isThrottled else { return }
        Task { await check(force: false) }
    }

    /// 手动检查传 force: true 绕过节流；自动检查传 false。
    func check(force: Bool) async {
        guard let url = feedURL else { return }
        if case .checking = state { return }
        if !force, isThrottled { return }
        state = .checking
        do {
            let data = try await fetch(from: url)
            let release = try UpdateFeed.release(from: data)
            markChecked()
            let result = verdict(for: release)
            switch result {
            case .available, .upToDate:
                UpdateNotesStore.save(release, defaults: defaults)
                releaseNotes = UpdateNotesStore.load(defaults: defaults, currentBuild: currentBuild)
            case .idle, .checking, .failed:
                break
            }
            state = result
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    private var isThrottled: Bool {
        guard let lastCheck else { return false }
        return Date().timeIntervalSince(lastCheck) < Self.checkInterval
    }

    private func markChecked() {
        let now = Date()
        lastCheck = now
        defaults.set(now, forKey: Self.lastCheckKey)
    }

    private func fetch(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.requestTimeout
        request.setValue("v5xs/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CheckError.notHTTP }
        guard http.statusCode == 200 else { throw CheckError.badStatus(http.statusCode) }
        return data
    }

    /// 清单可用时才判断系统版本、架构与新版本；不可用就如实说缺什么。
    private func verdict(for release: UpdateRelease) -> UpdateState {
        // 先比版本：已是最新时无需验签——没有要安装的东西，验签只会让
        // 「清单签名出问题」误报成「检查更新失败」，反而干扰用户。
        guard UpdateFeed.isNewer(release, thanBuild: currentBuild, currentVersion: currentVersion) else {
            return .upToDate
        }
        guard UpdateFeed.satisfiesMinimumSystem(release.minimumSystemVersion, currentVersion: systemVersion) else {
            return .failed(Strings.current(.requiresMacOS,
                                           release.minimumSystemVersion ?? Strings.current(.notAvailable)))
        }
        guard let download = UpdateFeed.download(for: release, architecture: architecture) else {
            return .failed(Strings.current(.noDownloadForArch, architecture))
        }

        // 有可安装的新版本时，签名是硬门禁：
        // 清单被劫持的场景下，SHA-256 与清单同源、已经失效，只有这个公钥还在守门。
        if let failure = UpdateSignature.verify(
            release: release,
            signatureBase64: release.signature ?? "",
            publicKeyBase64: UpdateSigningKey.publicKeyBase64
        ) {
            return .failed(Self.message(for: failure))
        }

        // 自更新需要能校验安装包；清单里没有 sha256 就无从校验，宁可拒绝。
        guard let sha = download.sha256, !sha.isEmpty else {
            return .failed(Strings.current(.updateChecksumMissing))
        }
        return .available(release, download)
    }

    /// 把验签失败原因翻译成可执行的提示。
    private static func message(for failure: UpdateSignature.Failure) -> String {
        switch failure {
        case .missing: Strings.current(.updateSignatureMissing)
        case .malformed: Strings.current(.updateSignatureMalformed)
        case .invalidPublicKey: Strings.current(.updateSigningKeyInvalid)
        case .invalid: Strings.current(.updateSignatureInvalid)
        }
    }

    private var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "universal"
        #endif
    }

    private static func feedURL(bundle: Bundle, environment: [String: String]) -> URL? {
        let candidates = [
            bundle.object(forInfoDictionaryKey: "V5XSUpdateFeedURL") as? String,
            environment["V5XS_UPDATE_FEED"]
        ]
        for case let text? in candidates {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  url.host != nil else { continue }
            return url
        }
        return nil
    }

    private static func message(for error: Error) -> String {
        if let feedError = error as? UpdateFeedError {
            return switch feedError {
            case .malformed: Strings.current(.feedMalformed)
            case .missingVersion: Strings.current(.feedMissingVersion)
            case .missingDownloads: Strings.current(.feedMissingDownloads)
            }
        }
        if let checkError = error as? CheckError {
            return switch checkError {
            case .notHTTP: Strings.current(.updateNotHTTP)
            case .badStatus(let code): Strings.current(.updateBadStatus, Int(code))
            }
        }
        return Strings.current(.updateCannotConnect, error.localizedDescription)
    }
}

private enum CheckError: Error {
    case notHTTP
    case badStatus(Int)
}
