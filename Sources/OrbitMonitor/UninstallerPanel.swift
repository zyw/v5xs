import AppKit
import CoreServices
import SwiftUI

private enum UninstallStyle {
    static let background = Color(red: 0.12, green: 0.16, blue: 0.15)
    static let card = Color(red: 0.17, green: 0.22, blue: 0.19)
    static let selected = Color(red: 0.20, green: 0.30, blue: 0.24)
    static let mint = Color(red: 0.57, green: 0.86, blue: 0.72)
    static let muted = Color(red: 0.64, green: 0.71, blue: 0.67)
}

private struct UninstallFile: Identifiable, Sendable {
    let url: URL
    let label: String
    let bytes: Int64
    var id: URL { url }
}

private struct InstalledApp: Identifiable, Sendable {
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

private enum AppInventory {
    static let roots = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    ]

    static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        var found: [InstalledApp] = []
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries where url.pathExtension.lowercased() == "app" {
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
        let appParent = app.url.deletingLastPathComponent().standardizedFileURL
        guard roots.contains(where: { $0.standardizedFileURL == appParent }),
              Bundle(url: app.url)?.bundleIdentifier == app.bundleID else { return false }
        if standardized == app.url.standardizedFileURL { return true }
        guard let identifier = app.bundleID, isBundleIdentifier(identifier) else { return false }
        return removableRemnant(standardized, identifier: identifier, appName: app.name)
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

    func refresh() {
        guard !loading else { return }
        loading = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { AppInventory.scan() }.value
            apps = result
            selected.removeAll()
            chosenFiles.removeAll()
            expanded.removeAll()
            loading = false
        }
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

struct UninstallerPanel: View {
    @StateObject private var model = UninstallerModel()
    @State private var query = ""
    @State private var sort: AppSort = .used
    @State private var ascending = true

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

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("软件卸载").font(.system(size: 26, weight: .bold))
                    Text("选择应用，核对关联文件，然后移到废纸篓")
                        .font(.system(size: 12)).foregroundStyle(UninstallStyle.muted)
                }
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.loading).help("重新扫描")
                TextField("搜索应用名称", text: $query)
                    .textFieldStyle(.roundedBorder).frame(width: 190)
            }
            .padding(22)
            HStack {
                Text("已安装 App \(model.apps.count) 个 · \(formatBytes(model.apps.reduce(0) { $0 + $1.bytes }))")
                if model.loading { ProgressView().controlSize(.small) }
                Spacer()
                ForEach(AppSort.allCases, id: \.self) { option in
                    Button {
                        if sort == option { ascending.toggle() }
                        else {
                            sort = option
                            ascending = option != .size
                        }
                    } label: {
                        Text(option.rawValue + (sort == option ? (ascending ? " ↑" : " ↓") : ""))
                            .foregroundStyle(sort == option ? UninstallStyle.mint : UninstallStyle.muted)
                    }
                    .buttonStyle(.plain).padding(.leading, 14)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 22).padding(.bottom, 12)
            Divider()
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(displayed) { app in appRow(app) }
                    if displayed.isEmpty && !model.loading {
                        Text("没有找到应用").foregroundStyle(UninstallStyle.muted)
                            .padding(40)
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Text("已选择 \(model.selected.count) 个 App · 预计 \(formatBytes(model.apps.filter { model.selected.contains($0.url) }.flatMap(\.files).filter { model.chosenFiles.contains($0.url) }.reduce(0) { $0 + $1.bytes }))")
                    .foregroundStyle(UninstallStyle.muted)
                Spacer()
                Button("取消选择") {
                    model.selected.removeAll()
                    model.chosenFiles.removeAll()
                    model.expanded.removeAll()
                }.disabled(model.selected.isEmpty)
                Button("移到废纸篓") { model.trashSelected() }
                    .disabled(model.chosenFiles.isEmpty)
                    .buttonStyle(.borderedProminent)
                    .tint(UninstallStyle.mint)
            }
            .font(.system(size: 12)).padding(18)
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(UninstallStyle.background)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear { if model.apps.isEmpty { model.refresh() } }
        .alert("部分文件未能移动", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("确定") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private func appRow(_ app: InstalledApp) -> some View {
        let isSelected = model.selected.contains(app.url)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable().frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.system(size: 13, weight: .semibold))
                    Text("v\(app.version) · \(app.url.path)")
                        .font(.system(size: 10)).foregroundStyle(UninstallStyle.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(formatBytes(app.bytes)).frame(width: 85, alignment: .trailing)
                Text(dateText(app.lastUsed)).frame(width: 90, alignment: .trailing)
                Text(dateText(app.installed)).frame(width: 90, alignment: .trailing)
                Toggle("选择 \(app.name)", isOn: Binding(
                    get: { model.selected.contains(app.url) },
                    set: { _ in model.toggle(app) }
                ))
                .labelsHidden().frame(width: 34)
            }
            .font(.system(size: 11))
            .padding(12)
            if isSelected {
                HStack {
                    Text("预计处理 \(formatBytes(app.files.filter { model.chosenFiles.contains($0.url) }.reduce(0) { $0 + $1.bytes }))")
                        .foregroundStyle(UninstallStyle.muted)
                    Spacer()
                    Button(model.expanded.contains(app.url) ? "收起文件 ↑" : "查看关联文件 ↓") {
                        if !model.expanded.insert(app.url).inserted { model.expanded.remove(app.url) }
                    }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UninstallStyle.mint)
                }
                .font(.system(size: 11))
                .padding(.leading, 62).padding(.trailing, 16).padding(.bottom, 10)
                if model.expanded.contains(app.url) {
                    Divider().padding(.horizontal, 14)
                    ForEach(app.files) { file in
                        HStack(spacing: 10) {
                            Toggle(file.label, isOn: Binding(
                                get: { model.chosenFiles.contains(file.url) },
                                set: { chosen in
                                    if chosen { model.chosenFiles.insert(file.url) }
                                    else { model.chosenFiles.remove(file.url) }
                                }
                            ))
                            .frame(width: 115, alignment: .leading)
                            Text(file.url.path.replacingOccurrences(
                                of: FileManager.default.homeDirectoryForCurrentUser.path,
                                with: "~"
                            ))
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                            Spacer(minLength: 4)
                            Text(formatBytes(file.bytes))
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(file.url.path, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.plain).help("复制路径")
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                            } label: { Image(systemName: "folder") }
                            .buttonStyle(.plain).help("在访达中显示")
                        }
                        .font(.system(size: 11)).foregroundStyle(UninstallStyle.muted)
                        .padding(.horizontal, 20).padding(.vertical, 4)
                    }
                    Text("只列出与此应用标识完全匹配的文件；共享文件不会自动选择。")
                        .font(.system(size: 10)).foregroundStyle(UninstallStyle.muted)
                        .padding(.leading, 20).padding(.bottom, 10)
                }
            }
        }
        .background(isSelected ? UninstallStyle.selected : UninstallStyle.card,
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "未知" }
        return date.formatted(date: .numeric, time: .omitted)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
