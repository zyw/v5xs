import AppKit
import MonitorCore
import SwiftUI

/// 设置页里的「更新」分组。
///
/// 现在它会真正下载并安装：下载 → 校验 → 替换 → 自动重启。
/// 同时保留「手动下载」入口——自动安装失败时（比如应用在只读位置），
/// 用户仍然有路可走，而不是卡死在一个错误提示上。
struct UpdateSection: View {
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var flow: UpdateFlow
    @ObservedObject var store: MonitorStore
    @Environment(\.localization) private var loc

    /// 当前可用的更新（如果检查到了）。
    private var available: (UpdateRelease, UpdateDownload)? {
        if case let .available(release, download) = updates.state { return (release, download) }
        return nil
    }

    var body: some View {
        Section(loc.t(.updateSection)) {
            HStack {
                Text(loc.t(.currentVersion))
                Spacer()
                Text("\(updates.currentVersionText) (build \(updates.currentBuild))")
                    .foregroundStyle(.secondary)
            }
            statusRow
            HStack {
                Text(loc.t(.lastChecked))
                Spacer()
                Text(lastCheckText).foregroundStyle(.secondary)
            }

            if let (release, download) = available {
                availableDetail(release: release, download: download)
            }

            // 自动更新的三档开关
            Toggle(loc.t(.updateSettingsAutoCheck), isOn: $store.autoCheckUpdates)
            Toggle(loc.t(.updateSettingsAutoDownload), isOn: $store.autoDownloadUpdates)
                .disabled(!store.autoCheckUpdates)
            Toggle(loc.t(.updateSettingsAutoInstall), isOn: $store.autoInstallUpdates)
                .disabled(!store.autoDownloadUpdates)
            Text(loc.t(.updateSettingsAutoInstallHint))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(loc.t(.updateFailedHint))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 状态行

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 6) {
            switch flow.phase {
            case .downloading(let received, let total):
                Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
                Text(progressText(received: received, total: total))
            case .verifying:
                Image(systemName: "checkmark.shield").foregroundStyle(.tint)
                Text(loc.t(.updateVerifying))
            case .preparing:
                Image(systemName: "gearshape").foregroundStyle(.tint)
                Text(loc.t(.updatePreparing))
            case .restarting:
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.green)
                Text(loc.t(.updateRestarting))
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(failureText(reason)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                idleStatus
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
    }

    @ViewBuilder
    private var idleStatus: some View {
        switch updates.state {
        case .idle:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            Text(updates.isEnabled ? loc.t(.updateIdle) : loc.t(.updateNotConfigured))
                .foregroundStyle(.secondary)
        case .checking:
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
            Text(loc.t(.updateChecking)).foregroundStyle(.secondary)
        case .upToDate:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(loc.t(.updateUpToDate))
        case .available(let release, _):
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
            Text(loc.t(.updateAvailable, release.version)).fontWeight(.semibold)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 下载进度：能算出百分比就给百分比，算不出就显示已下载量。
    private func progressText(received: Int64, total: Int64?) -> String {
        let receivedText = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        guard let total, total > 0 else {
            return loc.t(.updateDownloading, receivedText)
        }
        let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return loc.t(.updateDownloading, "\(receivedText) / \(totalText)")
    }

    private func failureText(_ reason: UpdateFlowFailure) -> String {
        switch reason {
        case .needsManualInstall(let path):
            return loc.t(reason.stringKey, path)
        case .insufficientSpace(let required, let available):
            return loc.t(reason.stringKey,
                         ByteCountFormatter.string(fromByteCount: required, countStyle: .file),
                         ByteCountFormatter.string(fromByteCount: available, countStyle: .file))
        case .install(let detail), .download(let detail):
            return loc.t(reason.stringKey, detail)
        case .sizeMismatch(let expected, let actual):
            return loc.t(reason.stringKey) + " "
                + ByteCountFormatter.string(fromByteCount: expected, countStyle: .file) + " / "
                + ByteCountFormatter.string(fromByteCount: actual, countStyle: .file)
        case .cancelled, .checksumMissing, .checksumMismatch, .anotherInstanceRunning:
            return loc.t(reason.stringKey)
        }
    }

    // MARK: - 可用更新的详情与操作

    @ViewBuilder
    private func availableDetail(release: UpdateRelease, download: UpdateDownload) -> some View {
        HStack(spacing: 6) {
            Text(download.architecture)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            if let size = download.size {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actionButtons(release: release, download: download)
        }

        if flow.isBusy {
            // 只有确定总量时才画确定性进度条，否则用不确定态，
            // 避免进度条在 0% 卡住给人「卡死了」的错觉。
            if case let .downloading(received, total) = flow.phase, let total, total > 0 {
                ProgressView(value: Double(received), total: Double(total))
            } else {
                ProgressView()
            }
        } else if flow.isReadyToRestart {
            Button(loc.t(.updateInstallNow)) { restartNow() }
                .buttonStyle(.borderedProminent)
        }

        if let notes = release.notes, !notes.isEmpty {
            Text(notes)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func actionButtons(release: UpdateRelease, download: UpdateDownload) -> some View {
        if flow.isBusy {
            Button(loc.t(.updateCancel)) { flow.cancel() }
        } else if !flow.isReadyToRestart {
            Button(loc.t(.updateDownloadAndInstall)) {
                startInstall(release: release, download: download)
            }
            // 手动下载始终保留：自动安装因权限/位置失败时，这是用户的退路。
            Button(loc.t(.updateManualFallback)) { NSWorkspace.shared.open(download.url) }
                .buttonStyle(.link)
                .font(.system(size: 10))
        }
    }

    private func startInstall(release: UpdateRelease, download: UpdateDownload) {
        guard let target = Bundle.main.bundleURL as URL? else { return }
        flow.start(
            release: release,
            download: download,
            targetApp: target,
            onReadyToRestart: { prepared in
                if store.autoInstallUpdates {
                    restartNow()
                }
                // 等待用户点「立即安装并重启」
                _ = prepared
            },
            onFailure: { _ in }
        )
    }

    private func restartNow() {
        guard let prepared = flow.pendingInstall else { return }
        guard UpdateInstaller.launch(prepared) else {
            flow.markInstallLaunchFailed()
            return
        }
        // 脚本已在后台等待本进程退出；这里主动退出让出文件句柄。
        NSApp.terminate(nil)
    }

    private var lastCheckText: String {
        guard let lastCheck = updates.lastCheck else { return loc.t(.neverChecked) }
        return lastCheck.formatted(date: .abbreviated, time: .shortened)
    }
}
