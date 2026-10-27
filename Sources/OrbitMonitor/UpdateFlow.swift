import AppKit
import Foundation
import MonitorCore

/// 自动更新的编排层：下载 → 校验 → 准备 → 退出并重启。
///
/// 为什么单独一个对象而不是塞进 UpdateChecker：
/// UpdateChecker 只负责「拉清单比版本」，是纯检查逻辑、可安全地在任何时刻跑；
/// 而这里的每一步都涉及磁盘写入、替换应用、终止进程，
/// 混在一起会让检查逻辑也变得难以测试。
@MainActor
public final class UpdateFlow: ObservableObject {
    @Published public private(set) var phase: UpdatePhase = .idle

    /// 已准备好、等待重启安装的结果。`restarting` 阶段时非 nil。
    @Published public private(set) var pendingInstall: UpdateInstaller.Prepared?

    private let session: UpdateDownloaderSession
    private var downloader: UpdateDownloader?

    public init(workDirectory: URL = UpdateFlow.defaultWorkDirectory) {
        self.session = UpdateDownloaderSession(workDirectory: workDirectory)
    }

    /// 下载文件放在 ~/Library/Caches 下：系统可清理，不污染用户目录。
    public static var defaultWorkDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("local.v5xs.app/Updates", isDirectory: true)
    }

    public var isBusy: Bool {
        switch phase {
        case .idle, .failed: return false
        case .downloading, .verifying, .preparing, .restarting: return true
        }
    }

    /// 是否已经下载并校验完成、等待重启。
    public var isReadyToRestart: Bool { phase == .restarting }

    /// 开始下载并安装。`onReadyToRestart` 会在替换脚本就绪后调用，
    /// 由调用方决定何时真正退出（通常是立刻）。
    public func start(
        release: UpdateRelease,
        download: UpdateDownload,
        targetApp: URL,
        onReadyToRestart: @escaping (UpdateInstaller.Prepared) -> Void,
        onFailure: @escaping (UpdateFlowFailure) -> Void
    ) {
        guard !isBusy else { return }
        phase = .downloading(received: 0, total: download.size.map(Int64.init))

        Task { [weak self] in
            guard let self else { return }
            await self.run(release: release, download: download, targetApp: targetApp,
                           onReadyToRestart: onReadyToRestart, onFailure: onFailure)
        }
    }

    /// 用户取消：停下载并清理半成品。
    public func cancel() {
        downloader?.cancel()
        downloader = nil
        session.cleanup()
        phase = .failed(.cancelled)
    }

    /// 重置到 idle（用于用户关掉错误提示后再试）。
    public func reset() {
        guard !isBusy else { return }
        pendingInstall = nil
        phase = .idle
    }

    /// 启动重启脚本失败时的收尾：保留已准备的文件，但让用户知道没能自动重启。
    public func markInstallLaunchFailed() {
        pendingInstall = nil
        phase = .failed(.install(Strings.current(.updateFailureInstall,
                                                 Strings.current(.notAvailable))))
    }

    private func run(
        release: UpdateRelease,
        download: UpdateDownload,
        targetApp: URL,
        onReadyToRestart: @escaping (UpdateInstaller.Prepared) -> Void,
        onFailure: @escaping (UpdateFlowFailure) -> Void
    ) async {
        func fail(_ reason: UpdateFlowFailure) {
            phase = .failed(reason)
            onFailure(reason)
        }

        // 1) 安装前预检：先检查再下载，省得下完 8 MB 才发现写不进去。
        if let problem = UpdatePreflight.validate(
            appBundlePath: targetApp.path,
            installBytes: Int64(download.size ?? 0),
            existingInstanceCount: Self.v5xsInstanceCount()
        ) {
            switch problem {
            case .notInWritableLocation(let path), .directoryNotWritable(let path):
                return fail(.needsManualInstall(path))
            case .insufficientSpace(let required, let available):
                return fail(.insufficientSpace(required: required, available: available))
            case .anotherInstanceRunning:
                return fail(.anotherInstanceRunning)
            }
        }

        // 2) 下载
        let dmgURL: URL
        do {
            dmgURL = try session.destinationURL(for: download)
        } catch {
            return fail(.download(String(describing: error)))
        }
        let downloader = UpdateDownloader(destination: dmgURL)
        self.downloader = downloader
        do {
            try await downloader.download(from: download.url, expectedSize: download.size.map(Int64.init)) { [weak self] received, total in
                Task { @MainActor [weak self] in
                    guard let self, !self.isReadyToRestart else { return }
                    self.phase = .downloading(received: received, total: total)
                }
            }
        } catch {
            self.downloader = nil
            if case UpdateDownloader.Failure.cancelled = error { return fail(.cancelled) }
            return fail(.download(String(describing: error)))
        }
        self.downloader = nil

        // 3) 校验（大小 + SHA-256）
        phase = .verifying
        if let problem = UpdateVerification.verifyDownload(
            fileAt: dmgURL,
            expectedSize: download.size,
            expectedSHA256: download.sha256
        ) {
            try? FileManager.default.removeItem(at: dmgURL)
            switch problem {
            case .sizeMismatch(let expected, let actual):
                return fail(.sizeMismatch(expected: expected, actual: actual))
            case .checksumMissing:
                return fail(.checksumMissing)
            default:
                return fail(.checksumMismatch)
            }
        }

        // 4) 挂载 → 校验包 → 复制 → 生成重启脚本
        phase = .preparing
        let prepared: UpdateInstaller.Prepared
        do {
            let bundleID = Bundle(url: targetApp)?.bundleIdentifier ?? "local.v5xs.app"
            prepared = try UpdateInstaller.prepare(
                dmg: dmgURL,
                targetApp: targetApp,
                expectedBundleID: bundleID,
                pid: Int32(ProcessInfo.processInfo.processIdentifier)
            )
        } catch {
            return fail(.install(String(describing: error)))
        }

        // 5) 就绪：交给调用方决定何时退出（自动安装则立即退出）
        pendingInstall = prepared
        phase = .restarting
        onReadyToRestart(prepared)
    }

    /// 统计同 BundleID 的实例数。多实例同时更新会互相踩踏。
    static func v5xsInstanceCount() -> Int {
        let id = Bundle.main.bundleIdentifier ?? "local.v5xs.app"
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).count
    }
}