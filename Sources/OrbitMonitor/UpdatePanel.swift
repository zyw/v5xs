import AppKit
import MonitorCore
import SwiftUI

/// 设置页里的「更新」分组：显示当前版本、上次检查时间、检查结果与下载入口。
/// 只做检查与跳转下载，不自动下载、不替换安装包。
struct UpdateSection: View {
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        Section("更新") {
            HStack {
                Text("当前版本")
                Spacer()
                Text("\(updates.currentVersionText)（build \(updates.currentBuild)）")
                    .foregroundStyle(.secondary)
            }
            statusRow
            HStack {
                Text("上次检查")
                Spacer()
                Text(lastCheckText).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button(action: { Task { await updates.check(force: true) } }) {
                    Text("检查更新")
                }
                .disabled(!updates.isEnabled || isChecking)
                if isChecking {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if !updates.isEnabled {
                    Text("未配置更新源")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            if case let .available(release, download) = updates.state {
                availableDetail(release: release, download: download)
            }
            Text("检查更新只读取更新清单并提示下载地址；安装仍由你手动完成。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var isChecking: Bool {
        if case .checking = updates.state { return true }
        return false
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 6) {
            switch updates.state {
            case .idle:
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                Text(updates.isEnabled ? "尚未检查" : "更新源未配置，暂不检查")
                    .foregroundStyle(.secondary)
            case .checking:
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                Text("正在检查更新…").foregroundStyle(.secondary)
            case .upToDate:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("已是最新版本")
            case .available(let release, _):
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                Text("发现新版本 v\(release.version)").fontWeight(.semibold)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
    }

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
            Button("下载 DMG") { NSWorkspace.shared.open(download.url) }
        }
        if let notes = release.notes, !notes.isEmpty {
            Text(notes)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lastCheckText: String {
        guard let lastCheck = updates.lastCheck else { return "从未检查" }
        return lastCheck.formatted(date: .abbreviated, time: .shortened)
    }
}
