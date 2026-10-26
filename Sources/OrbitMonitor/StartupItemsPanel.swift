import AppKit
import CoreServices
import MonitorCore
import ServiceManagement
import SwiftUI

// MARK: - 启动项模型

/// 一个开机自启项：登录项、LaunchAgent 或 LaunchDaemon。
struct StartupItem: Identifiable, Sendable {
    enum Source: Sendable {
        case loginItem      // 传统登录项 / SMAppService
        case userAgent      // ~/Library/LaunchAgents
        case systemAgent    // /Library/LaunchAgents
        case daemon         // /Library/LaunchDaemons
    }

    let id: String          // 唯一标识（路径或 SMAppService 标识）
    let name: String        // 展示名
    let detail: String      // 描述（宿主 App / Executable）
    let path: String        // 完整路径（登录项为 "登录项"）
    let bundleIdentifier: String?
    let source: Source
    let enabled: Bool
    let executablePath: String

    var appURL: URL? {
        guard let appPath = bundleAppPath else { return nil }
        return URL(fileURLWithPath: appPath)
    }

    /// 从 ProgramArguments 的第一个可执行路径推导宿主 App
    private var bundleAppPath: String? {
        let execPath = executablePath
        // /Applications/X.app/Contents/MacOS/x  ->  /Applications/X.app
        let parts = execPath.split(separator: "/").map(String.init)
        if let appIdx = parts.firstIndex(where: { $0.hasSuffix(".app") }),
           appIdx >= 1 {
            return "/" + parts[0...appIdx].joined(separator: "/")
        }
        // 已知 bundle identifier 的 app
        if let bundleID = bundleIdentifier,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return appURL.path
        }
        return nil
    }
}

/// 扫描本机启动项：登录项 + LaunchAgents + LaunchDaemons。
enum StartupScanner {
    static func scan() -> [StartupItem] {
        var items: [StartupItem] = []
        items += scanLoginItems()
        items += scanPlistDirectory("~/Library/LaunchAgents", source: .userAgent)
        items += scanPlistDirectory("/Library/LaunchAgents", source: .systemAgent)
        items += scanPlistDirectory("/Library/LaunchDaemons", source: .daemon)
        return items
    }

    private static let agentDirs: [(String, StartupItem.Source)] = [
        ("~/Library/LaunchAgents", .userAgent),
        ("/Library/LaunchAgents", .systemAgent),
        ("/Library/LaunchDaemons", .daemon)
    ]

    private static func scanPlistDirectory(_ dir: String, source: StartupItem.Source) -> [StartupItem] {
        let path = NSString(string: dir).expandingTildeInPath
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return entries.compactMap { entry in
            let plistPath = (path as NSString).appendingPathComponent(entry)
            guard (entry as NSString).pathExtension.lowercased() == "plist" else { return nil }
            guard let plist = readPlist(plistPath) else { return nil }
            let label = plist["Label"] as? String ?? (entry as NSString).deletingPathExtension
            let programArgs = plist["ProgramArguments"] as? [String] ?? []
            let exec = programArgs.first ?? ""
            let bundleID = (plist["AssociatedBundleIdentifiers"] as? [String])?.first
                ?? (plist["Label"] as? String)
            let runAtLoad = plist["RunAtLoad"] as? Bool ?? false
            return StartupItem(
                id: plistPath,
                name: label,
                detail: exec,
                path: plistPath,
                bundleIdentifier: bundleID,
                source: source,
                enabled: runAtLoad,
                executablePath: exec
            )
        }
    }

    private static func readPlist(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        // 优先 XML，回到老式 binary/NSDictionary
        let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        return plist ?? nil
    }

    private static func scanLoginItems() -> [StartupItem] {
        // 传统登录项通过 System Events（osascript）读取；失败时静默跳过，
        // 仍会列出 LaunchAgents / LaunchDaemons 的启动项。
        var items: [StartupItem] = []
        let script = "tell application \"System Events\" to get the name of every login item"
        guard let out = runOSAScript(script), !out.isEmpty else { return items }
        let names = out.split(separator: ",").map(String.init).map { $0.trimmingCharacters(in: .whitespaces) }
        for name in names where !name.isEmpty {
            let appURL = resolveAppURL(named: name)
            items.append(StartupItem(
                id: "login-\(name)",
                name: name,
                detail: appURL?.lastPathComponent ?? Strings.current(.startupLoginItemAuto),
                path: Strings.current(.startupLoginItemGeneric),
                bundleIdentifier: nil,
                source: .loginItem,
                enabled: true,
                executablePath: appURL?.path ?? ""
            ))
        }
        return items
    }

    /// 用启动服务查找给定显示名对应的应用；找不到时返回 nil。
    private static func resolveAppURL(named name: String) -> URL? {
        let fm = FileManager.default
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let appName = (entry as NSString).deletingPathExtension
                if appName.localizedCaseInsensitiveCompare(name) == .orderedSame {
                    return URL(fileURLWithPath: (root as NSString).appendingPathComponent(entry))
                }
            }
        }
        return NSWorkspace.shared.runningApplications
            .first { $0.bundleURL?.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveCompare(name) == .orderedSame }?.bundleURL
    }

    private static func runOSAScript(_ script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = nil
        do { try p.run(); p.waitUntilExit() }
        catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// 设置启动项的启用状态。
    /// - 用户代理 / 系统代理 / 守护进程：通过移动 plist 到 Disabled 目录（系统级需要权限）。
    /// - 登录项：仅当该登录项属于当前 App（v5xs）时用 SMAppService 切换。
    static func setEnabled(_ item: StartupItem, enabled: Bool) -> Bool {
        switch item.source {
        case .userAgent, .systemAgent, .daemon:
            return togglePlist(itemPath: item.path, enabled: enabled)
        case .loginItem:
            // 只允许切换当前应用自身的登录项；第三方登录项建议在系统设置处理
            if item.name == "v5xs" {
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    return true
                } catch {
                    return false
                }
            }
            return false
        }
    }

    private static func togglePlist(itemPath: String, enabled: Bool) -> Bool {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: itemPath)
        let dir = url.deletingLastPathComponent()
        let disabledDir = dir.appendingPathComponent("LaunchAgents-Disabled", isDirectory: true)
        // 目标是移动到 Disabled 目录（禁用）或移回来（启用）
        do {
            if !enabled {
                if !fm.fileExists(atPath: disabledDir.path) { try fm.createDirectory(at: disabledDir, withIntermediateDirectories: true) }
                let dest = disabledDir.appendingPathComponent(url.lastPathComponent)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.moveItem(at: url, to: dest)
            } else {
                let dest = dir.appendingPathComponent(url.lastPathComponent)
                let src = disabledDir.appendingPathComponent(url.lastPathComponent)
                if fm.fileExists(atPath: src.path) {
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    try fm.moveItem(at: src, to: dest)
                }
            }
            return true
        } catch {
            return false
        }
    }
}


// MARK: - 启动项缓存（与卸载页逻辑一致：读缓存，无缓存才自动扫描）

/// 启动项缓存条目：与 StartupItem 对应的可编码数据。
private struct StartupEntry: Codable {
    var id: String
    var name: String
    var detail: String
    var path: String
    var bundleIdentifier: String?
    var source: String
    var enabled: Bool
    var executablePath: String

    init(_ item: StartupItem) {
        id = item.id; name = item.name; detail = item.detail; path = item.path
        bundleIdentifier = item.bundleIdentifier
        switch item.source {
        case .loginItem: source = "loginItem"
        case .userAgent: source = "userAgent"
        case .systemAgent: source = "systemAgent"
        case .daemon: source = "daemon"
        }
        enabled = item.enabled; executablePath = item.executablePath
    }

    var startupItem: StartupItem {
        let src: StartupItem.Source
        switch source {
        case "userAgent": src = .userAgent
        case "systemAgent": src = .systemAgent
        case "daemon": src = .daemon
        default: src = .loginItem
        }
        return StartupItem(id: id, name: name, detail: detail, path: path,
                           bundleIdentifier: bundleIdentifier, source: src,
                           enabled: enabled, executablePath: executablePath)
    }
}

private struct StartupCacheEntry: Codable {
    var savedAt: Date
    var items: [StartupEntry]
}

private enum StartupCache {
    private static let fileName = "startup-items.json"

    private static var fileURL: URL? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return support?.appendingPathComponent(fileName)
    }

    static func load() -> [StartupItem]? {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(StartupCacheEntry.self, from: data) else { return nil }
        guard Date().timeIntervalSince(entry.savedAt) <= AppListCacheSetting.seconds else { return nil }
        return entry.items.map { $0.startupItem }
    }

    static func save(_ items: [StartupItem]) {
        guard let url = fileURL else { return }
        let entry = StartupCacheEntry(savedAt: Date(), items: items.map(StartupEntry.init))
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: url, options: [.atomic])
        }
    }
}

@MainActor
private final class StartupModel: ObservableObject {
    @Published var items: [StartupItem] = []
    @Published var loading = false
    @Published var error: String?

    /// 加载启动项：与卸载页一致——优先读缓存，只有无缓存时才自动重新扫描。
    func load() {
        guard !loading else { return }
        if let cached = StartupCache.load(), !cached.isEmpty {
            items = cached
            return
        }
        scanAndCache()
    }

    /// 手动刷新：总是重新扫描并更新缓存。
    func refresh() {
        guard !loading else { return }
        scanAndCache()
    }

    private func scanAndCache() {
        loading = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { StartupScanner.scan() }.value
            StartupCache.save(result)
            items = result
            loading = false
        }
    }

    /// 该条目是否支持在此修改。
    func canToggle(_ item: StartupItem) -> Bool {
        switch item.source {
        case .userAgent, .systemAgent, .daemon: return true
        case .loginItem: return item.name == "v5xs"
        }
    }

    func toggle(_ item: StartupItem) {
        let newEnabled = !item.enabled
        let ok = StartupScanner.setEnabled(item, enabled: newEnabled)
        if ok {
            load()
        } else {
            error = canToggle(item)
                ? Strings.current(.startupCannotToggle, item.name)
                : Strings.current(.startupThirdPartyHint)
        }
    }

    /// 按来源分组
    func grouped() -> [(String, [StartupItem])] {
        let order: [StartupItem.Source] = [.loginItem, .userAgent, .systemAgent, .daemon]
        let labels: [StartupItem.Source: String] = [
            .loginItem: Strings.current(.startupKindLoginItem),
            .userAgent: Strings.current(.startupKindUserAgent),
            .systemAgent: Strings.current(.startupKindSystemAgent),
            .daemon: Strings.current(.startupKindDaemon)
        ]
        var result: [(String, [StartupItem])] = []
        for src in order {
            let group = items.filter { $0.source == src }
            if !group.isEmpty {
                result.append((labels[src] ?? "", group))
            }
        }
        return result
    }
}


// MARK: - 启动项面板（来源分组式）

/// 启动项界面：按来源分组（用户登录项 / 用户代理 / 系统代理 / 守护进程）。
struct StartupItemsPanel: View {
    @StateObject private var model = StartupModel()
    @State private var query = ""
    @State private var refreshSucceeded = false

    var body: some View {
        VStack(spacing: 0) {
            dashboard
            list
            footer
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(UninstallStyle.background)
        .foregroundStyle(UninstallStyle.ink)
        .preferredColorScheme(.dark)
        .onAppear { if model.items.isEmpty { model.load() } }
        .alert(Strings.current(.operationFailed), isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button(Strings.current(.ok)) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var dashboard: some View {
        HStack(spacing: 10) {
            if model.loading { ProgressView().controlSize(.small) }
            statCard(title: Strings.current(.startupItems), value: "\(model.items.count)",
                     unit: Strings.current(.startupTotal), color: .gray)
            statCard(title: Strings.current(.enabled), value: "\(enabledCount)",
                     unit: Strings.current(.startupEnabledAtBoot), color: .mint)
            statCard(title: Strings.current(.startupNeedsPermission), value: "\(systemCount)",
                     unit: Strings.current(.startupSystemAgentDaemon), color: .amber)
            Spacer()
            searchField
            refreshButton
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    /// 启动项刷新按钮：loading 时显示加载指示器；点击重新扫描（手动刷新绕过节流）。
    private var refreshButton: some View {
        Button {
            model.refresh()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(UninstallStyle.card)
                RoundedRectangle(cornerRadius: 9)
                    .stroke(model.loading ? UninstallStyle.mint.opacity(0.6) : UninstallStyle.line, lineWidth: 1)
                if model.loading {
                    ProgressView().controlSize(.small)
                        .tint(UninstallStyle.mint)
                } else if refreshSucceeded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(UninstallStyle.mint)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(UninstallStyle.faint)
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(model.loading)
        .onChange(of: model.loading) { _, loading in
            if loading {
                refreshSucceeded = false
            } else if model.items.count > 0 {
                refreshSucceeded = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    refreshSucceeded = false
                }
            }
        }
        .help(model.loading ? Strings.current(.scanInProgress) : Strings.current(.rescanStartupItems))
    }

    private var enabledCount: Int { model.items.filter { $0.enabled }.count }
    private var systemCount: Int {
        model.items.filter { $0.source == .systemAgent || $0.source == .daemon }.count
    }

    private func statCard(title: String, value: String, unit: String, color: StatColor) -> some View {
        let fg: Color
        switch color {
        case .mint: fg = UninstallStyle.mint
        case .amber: fg = UninstallStyle.amber
        default: fg = UninstallStyle.ink
        }
        return VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(UninstallStyle.faint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 28, weight: .bold)).foregroundStyle(fg)
                Text(unit).font(.system(size: 11)).foregroundStyle(UninstallStyle.muted)
            }
        }
        .frame(minWidth: 120, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(UninstallStyle.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(UninstallStyle.line, lineWidth: 1))
    }

    private enum StatColor { case gray, mint, amber }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(UninstallStyle.faint)
            TextField(Strings.current(.searchStartupPlaceholder), text: $query)
                .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(UninstallStyle.ink)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color(red: 0.133, green: 0.192, blue: 0.161), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(UninstallStyle.mintDeep.opacity(0.6), lineWidth: 1))
        .frame(minWidth: 160)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(displayedGroups, id: \.0) { group in
                    groupSection(group.0, items: group.1)
                }
                if displayedGroups.isEmpty && !model.loading {
                    Text(Strings.current(.noMatchingStartupItems)).foregroundStyle(UninstallStyle.muted).padding(40)
                }
            }
            .padding(18)
        }
    }

    private var displayedGroups: [(String, [StartupItem])] {
        let groups = model.grouped()
        guard !query.isEmpty else { return groups }
        return groups.map { (name, items) in
            (name, items.filter { $0.name.localizedCaseInsensitiveContains(query) })
        }.filter { !$0.1.isEmpty }
    }

    private func groupSection(_ title: String, items: [StartupItem]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title.uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(UninstallStyle.muted).tracking(0.5)
                Spacer()
                Text(Strings.current(.itemsCount, items.count)).font(.system(size: 10)).foregroundStyle(UninstallStyle.faint)
            }
            .padding(.horizontal, 4)
            ForEach(items) { item in itemRow(item) }
        }
    }

    private func itemRow(_ item: StartupItem) -> some View {
        HStack(spacing: 12) {
            iconView(for: item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(UninstallStyle.ink)
                Text("\(item.detail)").font(.system(size: 11)).foregroundStyle(UninstallStyle.faint).lineLimit(1)
            }
            Spacer()
            Text(sourceLabel(item.source)).font(.system(size: 10.5)).foregroundStyle(UninstallStyle.faint)
            toggleView(item)
            infoButton(item)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(UninstallStyle.card, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(UninstallStyle.line, lineWidth: 1))
    }

    private func iconView(for item: StartupItem) -> some View {
        Group {
            if let url = item.appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 36, height: 36)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.62, blue: 0.5), Color(red: 0.2, green: 0.4, blue: 0.33)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 36, height: 36)
                    .overlay(Text(String(item.name.prefix(1))).font(.system(size: 15, weight: .bold)).foregroundStyle(.white))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sourceLabel(_ source: StartupItem.Source) -> String {
        switch source {
        case .loginItem: return Strings.current(.startupKindLoginItem)
        case .userAgent: return Strings.current(.startupKindUserAgent)
        case .systemAgent: return Strings.current(.startupKindSystemAgent)
        case .daemon: return Strings.current(.startupKindDaemon)
        }
    }

    private func toggleView(_ item: StartupItem) -> some View {
        let toggleable = model.canToggle(item)
        return Toggle("", isOn: Binding(
            get: { item.enabled },
            set: { _ in model.toggle(item) }
        ))
        .labelsHidden()
        .toggleStyle(SwitchToggleStyle(tint: UninstallStyle.mint))
        .disabled(!toggleable)
        .opacity(toggleable ? 1 : 0.4)
        .help(toggleable ? Strings.current(.clickToToggle) : Strings.current(.startupThirdPartyHint))
    }

    private func infoButton(_ item: StartupItem) -> some View {
        Button {
            revealInFinder(item)
        } label: {
            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(UninstallStyle.faint)
        }
        .buttonStyle(.plain).help(Strings.current(.revealInFinder))
    }

    private func revealInFinder(_ item: StartupItem) {
        let url = NSURL(fileURLWithPath: item.path)
        NSWorkspace.shared.activateFileViewerSelecting([url as URL])
    }

    private var footer: some View {
        HStack {
            Text(Strings.current(.startupFooterNote))
                .font(.system(size: 11.5)).foregroundStyle(UninstallStyle.faint)
            Spacer()
            Text(Strings.current(.startupToggleWarning)).font(.system(size: 11)).foregroundStyle(UninstallStyle.amber)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [Color(red: 0.125, green: 0.173, blue: 0.145), Color(red: 0.114, green: 0.153, blue: 0.133)], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(UninstallStyle.line).frame(height: 1) }
    }
}

