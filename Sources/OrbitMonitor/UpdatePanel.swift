import AppKit
import MonitorCore
import SwiftUI

/// 设置页里的「更新」分组。
///
/// 下载并校验后按用户设置决定等待确认或自动重启安装。
/// 同时保留「手动下载」入口——自动安装失败时（比如应用在只读位置），
/// 用户仍然有路可走，而不是卡死在一个错误提示上。
struct UpdateSection: View {
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var flow: UpdateFlow
    @ObservedObject var store: MonitorStore
    @Environment(\.localization) private var loc
    @State private var showingReleaseNotes = false

    /// 当前可用的更新（如果检查到了）。
    private var available: (UpdateRelease, UpdateDownload)? {
        if case let .available(release, download) = updates.state { return (release, download) }
        return nil
    }

    var body: some View {
        Section(loc.t(.updateSection)) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t(.versionLabel))
                    statusRow
                }
                Spacer(minLength: 8)
                Text(updates.currentVersionText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if flow.isReadyToRestart {
                    Button(loc.t(.updateInstallNow)) { restartNow() }
                } else {
                    Button(loc.t(.checkForUpdates)) {
                        Task { await updates.check(force: true) }
                    }
                    .disabled(!updates.isEnabled || flow.isBusy)
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t(.updateNotesTitle))
                    Text(loc.t(updates.releaseNotes == nil ? .updateNotesUnavailable : .updateNotesSubtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(loc.t(.updateNotesOpen)) { showingReleaseNotes = true }
                    .disabled(updates.releaseNotes == nil)
            }
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
        }
        .sheet(isPresented: $showingReleaseNotes) {
            if let notes = updates.releaseNotes {
                VStack(alignment: .leading, spacing: 14) {
                    Text("\(loc.t(.updateNotesTitle)) · v\(notes.version)")
                        .font(.headline)
                    ScrollView {
                        ReleaseNotesBody(markdown: notes.text)
                    }
                    HStack {
                        Spacer()
                        Button(loc.t(.close)) { showingReleaseNotes = false }
                    }
                }
                .padding(20)
                .frame(minWidth: 420, minHeight: 300)
            }
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
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(loc.t(.updateReadyBanner))
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(failureText(reason)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                idleStatus
            }
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

        if flow.isBusy && !flow.isReadyToRestart {
            // 只有确定总量时才画确定性进度条，否则用不确定态，
            // 避免进度条在 0% 卡住给人「卡死了」的错觉。
            if case let .downloading(received, total) = flow.phase, let total, total > 0 {
                ProgressView(value: Double(received), total: Double(total))
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private func actionButtons(release: UpdateRelease, download: UpdateDownload) -> some View {
        if flow.isReadyToRestart {
            EmptyView()
        } else if flow.isBusy {
            Button(loc.t(.updateCancel)) { flow.cancel() }
        } else {
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
            onReadyToRestart: { _ in
                if UpdateAutomation.shouldRestart(
                    autoDownload: store.autoDownloadUpdates,
                    autoRestart: store.autoInstallUpdates
                ) {
                    restartNow()
                }
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

private struct ReleaseNotesBody: View {
    let blocks: [ReleaseNotesMarkdown.Block]

    init(markdown: String) {
        blocks = ReleaseNotesMarkdown.parse(markdown)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(blocks.indices, id: \.self) { index in
                blockView(blocks[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: ReleaseNotesMarkdown.Block) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.content)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .textSelection(.enabled)
                .padding(.top, 6)
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.secondary.opacity(0.45))
                    .frame(width: 3)
                Text(block.content)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .bullet(let depth):
            listRow("•", content: block.content, depth: depth)
        case .number(let ordinal, let depth):
            listRow("\(ordinal).", content: block.content, depth: depth)
        case .code:
            ScrollView(.horizontal) {
                Text(block.content)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        case .paragraph:
            Text(block.content)
                .textSelection(.enabled)
        }
    }

    private func listRow(_ marker: String, content: AttributedString, depth: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .frame(minWidth: 18, alignment: .trailing)
            Text(content)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(depth) * 16)
    }
}
