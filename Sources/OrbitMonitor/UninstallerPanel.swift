import AppKit
import CoreServices
import SwiftUI

enum UninstallStyle {
    static let background = Color(red: 0.118, green: 0.157, blue: 0.141)
    static let card = Color(red: 0.150, green: 0.200, blue: 0.173)
    static let cardHi = Color(red: 0.169, green: 0.227, blue: 0.188)
    static let line = Color(red: 0.220, green: 0.290, blue: 0.243)
    static let selected = Color(red: 0.169, green: 0.231, blue: 0.184)
    static let ink = Color(red: 0.929, green: 0.957, blue: 0.933)
    static let mint = Color(red: 0.557, green: 0.847, blue: 0.702)
    static let mintDeep = Color(red: 0.239, green: 0.420, blue: 0.322)
    static let teal = Color(red: 0.247, green: 0.663, blue: 0.627)
    static let amber = Color(red: 0.914, green: 0.784, blue: 0.478)
    static let muted = Color(red: 0.663, green: 0.737, blue: 0.682)
    static let faint = Color(red: 0.486, green: 0.565, blue: 0.510)
    static let danger = Color(red: 0.910, green: 0.604, blue: 0.541)
}

private struct UninstallFile: Identifiable, Sendable, Codable {
    let url: URL
    let label: String
    let bytes: Int64
    var id: URL { url }
}

private struct InstalledApp: Identifiable, Sendable, Codable {
    let url: URL
    let name: String
    let bundleID: String?
    let version: String
    let bytes: Int64
    let lastUsed: Date?
    let installed: Date?
    let files: [UninstallFile]
    var id: URL { url }
}

private struct AppListCache: Codable {
    var savedAt: Date
    var apps: [InstalledApp]
}

/// Duration (days) to keep the installed-app cache before re-scanning.
/// Writes immediately; the uninstaller and settings panel both read this value.
enum AppListCacheSetting {
    static let key = "appListCacheDays"
    static let defaultValue: Double = 30

    static var days: Double {
        let stored = UserDefaults.standard.double(forKey: key)
        return stored > 0 ? stored : defaultValue
    }

    static var seconds: TimeInterval { days * 86_400 }

    static func set(_ value: Double) {
        UserDefaults.standard.set(max(1, min(value, 365)), forKey: key)
    }
}

/// Persists the installed-app inventory so re-opening the uninstaller does not
/// re-scan the whole disk every time. The cache duration is read from settings.
fileprivate enum AppInventoryCache {
    fileprivate static let fileName = "installed-apps.json"

    fileprivate static func load(maxAgeSeconds: TimeInterval) -> [InstalledApp]? {
        guard maxAgeSeconds > 0, let url = fileURL,
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(AppListCache.self, from: data) else { return nil }
        guard Date().timeIntervalSince(entry.savedAt) <= maxAgeSeconds else { return nil }
        return entry.apps
    }

    fileprivate static func save(_ apps: [InstalledApp]) {
        guard let url = fileURL else { return }
        let entry = AppListCache(savedAt: Date(), apps: apps)
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    fileprivate static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Per-user Application Support path so the cache survives app updates.
    private static var fileURL: URL? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return support?.appendingPathComponent(fileName)
    }
}

private enum AppInventory {
    static let roots = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        URL(fileURLWithPath: "/Library/Input Methods", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods", isDirectory: true)
    ]

    static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        var found: [InstalledApp] = []
        var seenPaths = Set<String>()
        for root in roots {
            for url in appBundles(in: root) {
                guard seenPaths.insert(url.standardizedFileURL.path).inserted else { continue }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]),
                      values.isDirectory == true, values.isSymbolicLink != true,
                      let bundle = Bundle(url: url) else { continue }
                let identifier = bundle.bundleIdentifier
                guard identifier != Bundle.main.bundleIdentifier,
                      identifier?.hasPrefix("com.apple.") != true else { continue }
                let name = fm.displayName(atPath: url.path)
                let files = relatedFiles(for: identifier, name: name, appURL: url)
                let metadata = MDItemCreate(kCFAllocatorDefault, url.path as CFString)
                let used = metadata.flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
                let appBytes = size(of: url)
                found.append(InstalledApp(
                    url: url, name: name,
                    bundleID: identifier,
                    version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—",
                    bytes: appBytes, lastUsed: used, installed: values.creationDate,
                    files: [UninstallFile(url: url, label: "应用本体", bytes: appBytes)] + files
                ))
            }
        }
        let identifierCounts = Dictionary(grouping: found.compactMap(\.bundleID), by: { $0 })
            .mapValues(\.count)
        return found.map { app in
            guard let identifier = app.bundleID, identifierCounts[identifier, default: 0] > 1 else { return app }
            return InstalledApp(
                url: app.url, name: app.name, bundleID: app.bundleID, version: app.version,
                bytes: app.bytes, lastUsed: app.lastUsed, installed: app.installed,
                files: Array(app.files.prefix(1))
            )
        }
    }

    /// Lists app bundles up to three levels below a search root, mirroring how
    /// Finder surfaces apps inside folders such as "Chrome Apps.localized".
    /// Hidden folders (updater staging) are skipped, hidden app bundles are kept,
    /// and bundles nested inside another bundle are not descended into.
    private static func appBundles(in root: URL) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        func walk(_ directory: URL, depth: Int) {
            guard depth < 3,
                  let entries = try? fm.contentsOfDirectory(
                      at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                      options: []
                  ) else { return }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if entry.pathExtension.lowercased() == "app" {
                    results.append(entry)
                    continue
                }
                guard !entry.lastPathComponent.hasPrefix("."),
                      let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                walk(entry, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return results
    }

    private static func relatedFiles(for identifier: String?, name: String, appURL: URL) -> [UninstallFile] {
        guard let identifier, isBundleIdentifier(identifier) else { return [] }
        let fm = FileManager.default
        let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        var files: [UninstallFile] = []
        var seen = Set<String>()

        func add(_ url: URL, _ label: String) {
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted,
                  let attributes = try? fm.attributesOfItem(atPath: standardized.path),
                  attributes[.type] as? FileAttributeType != .typeSymbolicLink else { return }
            files.append(UninstallFile(url: standardized, label: label, bytes: size(of: standardized)))
        }

        func addChildren(of folder: URL, label: String, where matches: (String) -> Bool) {
            guard let children = try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]
            ) else { return }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where matches(child.lastPathComponent) {
                add(child, label)
            }
        }

        for (folder, label) in [
            ("Application Support", "App 支持文件"), ("Caches", "缓存"),
            ("Containers", "容器"), ("WebKit", "WebKit"),
            ("HTTPStorages", "HTTP 存储"), ("Application Scripts", "应用脚本"),
            ("Logs", "日志")
        ] {
            add(library.appendingPathComponent(folder).appendingPathComponent(identifier), label)
        }
        add(library.appendingPathComponent("Saved Application State")
                .appendingPathComponent(identifier + ".savedState"), "保存的状态")
        add(library.appendingPathComponent("Preferences")
                .appendingPathComponent(identifier + ".plist"), "偏好设置")
        addChildren(of: library.appendingPathComponent("Preferences/ByHost"), label: "偏好设置") {
            $0.hasPrefix(identifier + ".")
        }
        add(library.appendingPathComponent("Cookies")
                .appendingPathComponent(identifier + ".binarycookies"), "Cookies")
        add(library.appendingPathComponent("LaunchAgents")
                .appendingPathComponent(identifier + ".plist"), "登录项")
        addChildren(of: library.appendingPathComponent("Containers"), label: "容器") {
            $0.hasPrefix(identifier + ".")
        }
        addChildren(of: library.appendingPathComponent("Application Scripts"), label: "应用脚本") {
            $0.hasPrefix(identifier + ".")
        }

        let recentDocuments = library
            .appendingPathComponent("Application Support/com.apple.sharedfilelist")
            .appendingPathComponent("com.apple.LSSharedFileList.ApplicationRecentDocuments")
        for suffix in ["sfl2", "sfl3", "sfl4"] {
            add(recentDocuments.appendingPathComponent(identifier + "." + suffix), "最近使用记录")
        }
        if let cacheRoot = temporaryCacheRoot {
            addChildren(of: cacheRoot, label: "临时缓存") {
                $0 == identifier || $0.hasPrefix(identifier + ".")
            }
        }
        if name.count >= 3, !name.contains("/"), name != identifier {
            add(library.appendingPathComponent("Application Support").appendingPathComponent(name),
                "App 支持文件（按名称）")
            add(library.appendingPathComponent("Caches").appendingPathComponent(name), "缓存（按名称）")
        }
        return files
    }

    private static var temporaryCacheRoot: URL? {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.standardizedFileURL
        let candidates = [
            temp.deletingLastPathComponent().appendingPathComponent("C", isDirectory: true),
            temp.appendingPathComponent("C", isDirectory: true)
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    private static func isBundleIdentifier(_ identifier: String) -> Bool {
        identifier.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#,
                        options: .regularExpression) != nil
    }

    private static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        if let attributes = try? fm.attributesOfItem(atPath: url.path),
           attributes[.type] as? FileAttributeType == .typeRegular {
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    static func canTrash(_ file: URL, of app: InstalledApp) -> Bool {
        let standardized = file.standardizedFileURL
        guard app.files.contains(where: { $0.url.standardizedFileURL == standardized }),
              app.bundleID != Bundle.main.bundleIdentifier,
              app.bundleID?.hasPrefix("com.apple.") != true,
              (try? standardized.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
            return false
        }
        guard isInsideSearchRoot(app.url),
              Bundle(url: app.url)?.bundleIdentifier == app.bundleID else { return false }
        if standardized == app.url.standardizedFileURL { return true }
        guard let identifier = app.bundleID, isBundleIdentifier(identifier) else { return false }
        return removableRemnant(standardized, identifier: identifier, appName: app.name)
    }

    /// A bundle must sit one to three levels below a search root, mirroring the
    /// discovery rule (for example "Applications/Chrome Apps.localized/X.app").
    private static func isInsideSearchRoot(_ bundle: URL) -> Bool {
        let path = bundle.standardizedFileURL.path
        for root in roots {
            let rootPath = root.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let depth = path.dropFirst(rootPath.count + 1).split(separator: "/").count
            if (1...3).contains(depth) { return true }
        }
        return false
    }

    private static func removableRemnant(_ url: URL, identifier: String, appName: String) -> Bool {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true).standardizedFileURL
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let leaf = url.lastPathComponent
        let nameMatches = leaf == identifier || leaf == appName
            || leaf == identifier + ".plist" || leaf == identifier + ".binarycookies"
            || leaf == identifier + ".savedState" || leaf.hasPrefix(identifier + ".")
        let directFolders = [
            "Application Support", "Caches", "Containers", "WebKit", "HTTPStorages",
            "Application Scripts", "Logs", "Cookies", "Preferences", "LaunchAgents",
            "Saved Application State"
        ]
        if directFolders.contains(where: { library.appendingPathComponent($0).standardizedFileURL == parent }) {
            return nameMatches
        }
        if library.appendingPathComponent("Preferences/ByHost").standardizedFileURL == parent {
            return leaf.hasPrefix(identifier + ".")
        }
        if library.appendingPathComponent("Application Support/com.apple.sharedfilelist")
            .appendingPathComponent("com.apple.LSSharedFileList.ApplicationRecentDocuments")
            .standardizedFileURL == parent {
            return leaf.hasPrefix(identifier + ".")
        }
        if let cacheRoot = temporaryCacheRoot?.standardizedFileURL, cacheRoot == parent {
            return leaf == identifier || leaf.hasPrefix(identifier + ".")
        }
        return false
    }
}

private enum AppSort: String, CaseIterable {
    case name = "名称", size = "占用体积", used = "最近使用", installed = "安装时间"
}

@MainActor
private final class UninstallerModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var selected: Set<URL> = []
    @Published var chosenFiles: Set<URL> = []
    @Published var expanded: Set<URL> = []
    @Published var loading = false
    @Published var error: String?

    /// Load apps for display. Prefers a fresh cache; only falls back to a full
    /// scan when the cache is missing or stale.
    func load() {
        guard !loading else { return }
        if let cached = AppInventoryCache.load(maxAgeSeconds: AppListCacheSetting.seconds) {
            replace(with: cached)
            return
        }
        scanAndCache()
    }

    /// Manual refresh: always re-scan and replace the cache with fresh data.
    func refresh() {
        guard !loading else { return }
        scanAndCache()
    }

    private func scanAndCache() {
        loading = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { AppInventory.scan() }.value
            AppInventoryCache.save(result)
            replace(with: result)
        }
    }

    private func replace(with apps: [InstalledApp]) {
        self.apps = apps
        selected.removeAll()
        chosenFiles.removeAll()
        expanded.removeAll()
        loading = false
    }

    func toggle(_ app: InstalledApp) {
        if selected.remove(app.url) != nil {
            for file in app.files { chosenFiles.remove(file.url) }
            expanded.remove(app.url)
        } else {
            selected.insert(app.url)
            for file in app.files { chosenFiles.insert(file.url) }
        }
    }

    func trashSelected() {
        let targets = apps.filter { selected.contains($0.url) }
        guard !targets.isEmpty else { return }
        let files = targets.flatMap { app in
            let chosen = app.files.filter { chosenFiles.contains($0.url) }
            // Keep the bundle in place until its associated files pass ownership checks.
            return (chosen.filter { $0.url != app.url } + chosen.filter { $0.url == app.url })
                .map { (app, $0) }
        }
        guard !files.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "确认移动 \(targets.count) 个应用？"
        alert.informativeText = "将下列 \(files.count) 个文件移到废纸篓，预计 \(ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.1.bytes }, countStyle: .file))。运行中的应用须先退出。"
        let paths = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 150))
        paths.string = files.map { "\($0.1.label) · \($0.1.url.path)" }.joined(separator: "\n")
        paths.isEditable = false
        paths.isSelectable = true
        paths.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let list = NSScrollView(frame: paths.frame)
        list.hasVerticalScroller = true
        list.documentView = paths
        alert.accessoryView = list
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var failures: [String] = []
        for (app, file) in files {
            if NSWorkspace.shared.runningApplications.contains(where: {
                !$0.isTerminated && $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL
            }) {
                failures.append("\(app.name)：请先退出应用")
                continue
            }
            guard AppInventory.canTrash(file.url, of: app) else {
                failures.append("\(file.url.lastPathComponent)：归属无法确认")
                continue
            }
            do { try FileManager.default.trashItem(at: file.url, resultingItemURL: nil) }
            catch { failures.append("\(file.url.lastPathComponent)：\(error.localizedDescription)") }
        }
        error = failures.isEmpty ? nil : failures.joined(separator: "\n")
        refresh()
    }
}


enum UninstallerTab: String, CaseIterable {
    case uninstall
    case startup

    var title: String {
        switch self {
        case .uninstall: return "卸载"
        case .startup: return "启动项"
        }
    }
}

struct UninstallerPanel: View {
    @StateObject private var model = UninstallerModel()
    @State private var query = ""
    @State private var sort: AppSort = .used
    @State private var ascending = true
    @State private var activeTab: UninstallerTab = .uninstall
    @FocusState private var searchFocused: Bool
    @State private var refreshTurns = 0
    @State private var refreshSucceeded = false

    private var displayed: [InstalledApp] {
        model.apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { lhs, rhs in
                if sort == .used || sort == .installed {
                    let left = sort == .used ? lhs.lastUsed : lhs.installed
                    let right = sort == .used ? rhs.lastUsed : rhs.installed
                    if left == nil && right != nil { return false }
                    if left != nil && right == nil { return true }
                }
                let comparison: ComparisonResult
                switch sort {
                case .name: comparison = lhs.name.localizedStandardCompare(rhs.name)
                case .size: comparison = compare(lhs.bytes, rhs.bytes)
                case .used: comparison = compare(lhs.lastUsed, rhs.lastUsed)
                case .installed: comparison = compare(lhs.installed, rhs.installed)
                }
                if comparison == .orderedSame { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
                return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
    }

    private func compare<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (a?, b?): return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
        case (_?, nil): return .orderedDescending
        case (nil, _?): return .orderedAscending
        default: return .orderedSame
        }
    }

    private func compare(_ lhs: Int64, _ rhs: Int64) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
    }

    private var chosenBytes: Int64 {
        model.apps.flatMap(\.files).filter { model.chosenFiles.contains($0.url) }.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Rectangle().fill(UninstallStyle.line).frame(height: 1)
            Group {
                switch activeTab {
                case .uninstall:
                    uninstallContent
                case .startup:
                    StartupItemsPanel()
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(UninstallStyle.background)
        .foregroundStyle(UninstallStyle.ink)
        .preferredColorScheme(.dark)
    }

    /// 统一标题栏：logo + 当前页标题 + 分段 tab（卸载 / 启动项），始终可见。
    private var tabBar: some View {
        HStack(alignment: .center, spacing: 12) {
            if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
               let image = NSImage(named: name) {
                Image(nsImage: image).resizable().frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            Text("v5xs").font(.system(size: 14, weight: .bold)).foregroundStyle(UninstallStyle.ink)
            Text(activeTab == .uninstall ? "软件卸载" : "启动项")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(UninstallStyle.mint)
            Spacer()
            HStack(spacing: 2) {
                ForEach(UninstallerTab.allCases, id: \.self) { tab in
                    // 不用 Button(.plain)：在 macOS 上它的命中区只会缩到文字；
                    // 改用 Text + contentShape + onTapGesture，让整块圆角 pill 都可点。
                    Text(tab.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(activeTab == tab ? Color(red: 0.918, green: 0.969, blue: 0.933) : UninstallStyle.muted)
                        .padding(.horizontal, 18).padding(.vertical, 7)
                        .background(activeTab == tab ? Color(red: 0.210, green: 0.294, blue: 0.247) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                        .onTapGesture { activeTab = tab }
                        .animation(.easeOut(duration: 0.12), value: activeTab)
                }
            }
            .padding(3).background(Color(red: 0.125, green: 0.177, blue: 0.153), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(UninstallStyle.line, lineWidth: 1))
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [Color(red: 0.141, green: 0.200, blue: 0.169), Color(red: 0.125, green: 0.169, blue: 0.149)], startPoint: .top, endPoint: .bottom))
    }

    /// 卸载 tab 的完整内容
    private var uninstallContent: some View {
        VStack(spacing: 0) {
            metricBar
            countLine
            Divider().overlay(UninstallStyle.line)
            list
            Divider().overlay(UninstallStyle.line)
            footer
        }
        .onAppear { if model.apps.isEmpty { model.load() } }
        .alert("部分文件未能移动", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("确定") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    // MARK: - 标题栏
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
               let image = NSImage(named: name) {
                Image(nsImage: image).resizable().frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            Text("v5xs").font(.system(size: 14, weight: .bold)).foregroundStyle(UninstallStyle.ink)
            Text(activeTab == .uninstall ? "软件卸载" : "启动项").font(.system(size: 14, weight: .semibold)).foregroundStyle(UninstallStyle.mint)
            Text(activeTab == .uninstall ? "软件卸载窗口" : "开机自启管理").font(.system(size: 11)).foregroundStyle(UninstallStyle.faint)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [Color(red: 0.141, green: 0.200, blue: 0.169), Color(red: 0.125, green: 0.169, blue: 0.149)],
                                   startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .bottom) { Rectangle().fill(UninstallStyle.line).frame(height: 1) }
    }

    // MARK: - 释放仪表 + 搜索刷新
    private var metricBar: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("本次将释放").font(.system(size: 11)).foregroundStyle(UninstallStyle.faint)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(gaugeText).font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [UninstallStyle.mint, UninstallStyle.teal], startPoint: .leading, endPoint: .trailing))
                    Text("GB").font(.system(size: 14, weight: .semibold)).foregroundStyle(UninstallStyle.muted)
                }
            }
            Text(gaugeBadge)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(red: 0.106, green: 0.23, blue: 0.165))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(UninstallStyle.mint, in: Capsule())
                .padding(.top, 20)
            Spacer()
            searchField
            refreshButton
        }
        .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 8)
    }

    private var gaugeBytes: Int64 {
        model.apps.filter { model.selected.contains($0.url) }
            .flatMap { app in files(of: app) }.filter { model.chosenFiles.contains($0.url) }.reduce(0) { $0 + $1.bytes }
    }

    private var gaugeText: String {
        let bytes = Double(gaugeBytes)
        return String(format: "%.1f", bytes >= 1_073_741_824 ? bytes / 1_073_741_824 : bytes / 1_048_576)
    }

    private var gaugeBadge: String {
        let bytes = gaugeBytes
        if bytes == 0 { return "未选择" }
        return "\(model.selected.count) 个应用 · \(formatBytes(bytes))"
    }

    /// 搜索框：加宽到 280，内部输入区填满，聚焦描边高亮，有内容时可一键清除。
    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(searchFocused ? UninstallStyle.mint : UninstallStyle.faint)
            TextField("搜索应用名称", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(UninstallStyle.ink)
                .focused($searchFocused)
                .frame(maxWidth: .infinity)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(UninstallStyle.faint)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .frame(width: 280)
        .background(Color(red: 0.133, green: 0.192, blue: 0.161), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(searchFocused ? UninstallStyle.mint.opacity(0.75) : UninstallStyle.line, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.15), value: searchFocused)
        .animation(.easeOut(duration: 0.12), value: query.isEmpty)
    }

    /// 刷新按钮：点击后进入 loading 状态（进度指示器），扫描完成恢复。
    /// 区别于旧的"图标旋转"：loading 时用标准的加载指示器表达"正在扫描"。
    private var refreshButton: some View {
        Button {
            refreshTurns += 2
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
                        .transition(.scale.combined(with: .opacity))
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
        .animation(.easeInOut(duration: 0.25), value: refreshSucceeded)
        .onChange(of: model.loading) { _, loading in
            if loading {
                refreshSucceeded = false
            } else if refreshTurns > 0 {
                refreshSucceeded = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    refreshSucceeded = false
                }
            }
        }
        .help(model.loading ? "正在扫描…" : "重新扫描已安装应用")
    }

    // MARK: - 统计行 + 排序
    private var countLine: some View {
        HStack(spacing: 14) {
            Text("已安装 \(model.apps.count) 个应用 · 占用 \(formatBytes(model.apps.reduce(0) { $0 + $1.bytes }))")
                .font(.system(size: 12)).foregroundStyle(UninstallStyle.muted)
            Spacer()
            Text("关联文件 \(model.apps.flatMap(\.files).count) 项")
                .font(.system(size: 12)).foregroundStyle(UninstallStyle.muted)
            Rectangle().fill(UninstallStyle.line).frame(width: 1, height: 16)
            sortButtons
        }
        .padding(.horizontal, 26).padding(.vertical, 8)
    }

    /// 排序按钮组：名称 / 占用体积 / 最近使用 / 安装时间。
    private var sortButtons: some View {
        HStack(spacing: 2) {
            ForEach(AppSort.allCases, id: \.self) { option in
                Button {
                    if sort == option { ascending.toggle() } else { sort = option; ascending = option != .size }
                } label: {
                    VStack(spacing: 1) {
                        Text(option.rawValue + (sort == option ? (ascending ? " ↑" : " ↓") : ""))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(sort == option ? UninstallStyle.mint : UninstallStyle.faint)
                        Rectangle().fill(sort == option ? UninstallStyle.mint : .clear).frame(width: 16, height: 2)
                    }
                }
                .buttonStyle(.plain).padding(.horizontal, 7).padding(.vertical, 2)
            }
        }
    }

    // MARK: - 列表
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(displayed) { app in appRow(app) }
                if displayed.isEmpty && !model.loading {
                    Text("没有找到应用").foregroundStyle(UninstallStyle.muted).padding(40)
                }
            }
            .padding(18)
        }
    }

    private func files(of app: InstalledApp) -> [UninstallFile] { app.files }

    private func appRow(_ app: InstalledApp) -> some View {
        let isSelected = model.selected.contains(app.url)
        let bg = isSelected
            ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.161, green: 0.239, blue: 0.188), Color(red: 0.145, green: 0.204, blue: 0.165)], startPoint: .leading, endPoint: .trailing))
            : AnyShapeStyle(UninstallStyle.card)
        let border = isSelected ? Color(red: 0.267, green: 0.435, blue: 0.341) : UninstallStyle.line
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                appIcon(app)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(UninstallStyle.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Text("v\(app.version) · \(formatBytes(app.bytes)) · \(lastUseText(app))")
                        .font(.system(size: 11.5)).foregroundStyle(UninstallStyle.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatBytes(app.bytes)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(red: 0.878, green: 0.914, blue: 0.882))
                    Text("占用体积").font(.system(size: 10)).foregroundStyle(UninstallStyle.faint)
                }
                .frame(minWidth: 84)
                statusCap(app).frame(minWidth: 66)
                selectButton(app, isOn: isSelected)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            if isSelected {
                foldBar(app)
                if model.expanded.contains(app.url) { fileList(app) }
            }
        }
        .background(bg, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(border, lineWidth: 1))
    }

    private func appIcon(_ app: InstalledApp) -> some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
            .resizable().frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
    }

    private func lastUseText(_ app: InstalledApp) -> String {
        if let d = app.lastUsed {
            if Date().timeIntervalSince(d) < 7 * 86_400 { return relative(d) }
        }
        return app.lastUsed.map(relative) ?? "未知"
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func statusCap(_ app: InstalledApp) -> some View {
        let active = app.lastUsed.map { Date().timeIntervalSince($0) < 7 * 86_400 } ?? true
        let text = active ? "活跃中" : lastUseText(app)
        return Text(text).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(active ? UninstallStyle.mint : UninstallStyle.muted)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background((active ? UninstallStyle.mint : UninstallStyle.muted).opacity(active ? 0.14 : 0.12), in: Capsule())
    }

    private func selectButton(_ app: InstalledApp, isOn: Bool) -> some View {
        Button {
            model.toggle(app)
        } label: {
            Image(systemName: isOn ? "checkmark" : "")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(Color(red: 0.059, green: 0.141, blue: 0.094))
                .frame(width: 20, height: 20)
                .background(isOn ? UninstallStyle.mint : Color(red: 0.110, green: 0.157, blue: 0.129), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(isOn ? UninstallStyle.mint : Color(red: 0.42, green: 0.50, blue: 0.44), lineWidth: 1.5))
        }
        .buttonStyle(.plain).help(isOn ? "取消选择" : "选择应用")
    }

    private func foldBar(_ app: InstalledApp) -> some View {
        let chosen = app.files.filter { model.chosenFiles.contains($0.url) }.reduce(0) { $0 + $1.bytes }
        let isExpanded = model.expanded.contains(app.url)
        return HStack {
            Text("已选 · 预计 \(formatBytes(chosen))")
                .font(.system(size: 12)).foregroundStyle(Color(red: 0.788, green: 0.855, blue: 0.804))
            Spacer()
            Button(isExpanded ? "收起文件 ↑" : "查看关联文件 ↓") {
                if !model.expanded.insert(app.url).inserted { model.expanded.remove(app.url) }
            }
            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(UninstallStyle.mint)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color(red: 0.122, green: 0.173, blue: 0.145), in: RoundedRectangle(cornerRadius: 9))
        .padding(.leading, 66).padding(.trailing, 12).padding(.bottom, 8)
    }

    private func fileList(_ app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("将处理的文件 · \(app.name)").font(.system(size: 12.5, weight: .bold)).foregroundStyle(UninstallStyle.ink)
                Spacer()
                Text("逐项核对后可取消勾选").font(.system(size: 11)).foregroundStyle(UninstallStyle.faint)
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
            ForEach(app.files) { file in fileRow(file, app: app) }
            Text("只列出与该应用标识完全匹配的文件；共享文件不会自动选择。")
                .font(.system(size: 11)).foregroundStyle(UninstallStyle.faint)
                .padding(.leading, 34).padding(.bottom, 8)
        }
        .padding(.bottom, 10)
    }

    private func fileRow(_ file: UninstallFile, app: InstalledApp) -> some View {
        let on = model.chosenFiles.contains(file.url)
        return HStack(spacing: 10) {
            Button {
                if on { model.chosenFiles.remove(file.url) } else { model.chosenFiles.insert(file.url) }
            } label: {
                Image(systemName: on ? "checkmark" : "")
                    .font(.system(size: 10, weight: .heavy)).foregroundStyle(Color(red: 0.059, green: 0.141, blue: 0.094))
                    .frame(width: 16, height: 16)
                    .background(on ? UninstallStyle.mint : Color(red: 0.110, green: 0.157, blue: 0.129), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? UninstallStyle.mint : Color(red: 0.40, green: 0.48, blue: 0.42), lineWidth: 1.2))
            }
            .buttonStyle(.plain)
            Text(file.label).font(.system(size: 12)).foregroundStyle(Color(red: 0.847, green: 0.898, blue: 0.855)).frame(width: 100, alignment: .leading)
            Text(shortPath(file.url))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(UninstallStyle.muted)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer()
            Text(formatBytes(file.bytes)).font(.system(size: 12)).foregroundStyle(Color(red: 0.847, green: 0.898, blue: 0.855)).font(.system(.caption, design: .monospaced))
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.url.path, forType: .string) } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 11))
            }.buttonStyle(.plain).foregroundStyle(UninstallStyle.faint).help("复制路径")
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: {
                Image(systemName: "folder").font(.system(size: 11))
            }.buttonStyle(.plain).foregroundStyle(UninstallStyle.faint).help("在访达中显示")
        }
        .padding(.horizontal, 26).padding(.vertical, 3)
    }

    private func shortPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    // MARK: - 底部
    private var footer: some View {
        HStack {
            if model.selected.isEmpty {
                Text("未选择应用 · 勾选后可展开关联文件，一次移除多个")
                    .font(.system(size: 12.5)).foregroundStyle(Color(red: 0.52, green: 0.596, blue: 0.541))
            } else {
                Text("\(model.selected.count)").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(Color(red: 0.941, green: 0.973, blue: 0.945))
                Text("个应用").font(.system(size: 12)).foregroundStyle(UninstallStyle.faint)
                Text("预计 \(formatBytes(chosenBytes))").font(.system(size: 13)).foregroundStyle(UninstallStyle.faint)
            }
            Spacer()
            if !model.selected.isEmpty {
                Button("取消选择") {
                    model.selected.removeAll(); model.chosenFiles.removeAll(); model.expanded.removeAll()
                }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(UninstallStyle.mint)
            }
            Button {
                model.trashSelected()
            } label: {
                Text(model.selected.isEmpty ? "移到废纸篓" : "移到废纸篓 · \(model.selected.count) 项")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(red: 0.078, green: 0.208, blue: 0.122))
                    .padding(.horizontal, 26).padding(.vertical, 12)
                    .background(UninstallStyle.mint, in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain).disabled(model.selected.isEmpty)
            .opacity(model.selected.isEmpty ? 0.35 : 1)
            .shadow(color: UninstallStyle.mint.opacity(0.18), radius: 12, y: 4)
        }
        .padding(.horizontal, 26).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [Color(red: 0.125, green: 0.173, blue: 0.145), Color(red: 0.114, green: 0.153, blue: 0.133)], startPoint: .top, endPoint: .bottom))
    }


    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
