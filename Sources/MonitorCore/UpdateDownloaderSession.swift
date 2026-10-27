import Foundation

/// 下载落盘的命名与清理。
///
/// 放在 MonitorCore 而不是 App 目标里，是为了能在测试中直接断言
/// 文件命名与清理规则——这两条规则一旦出错，
/// 轻则下载到错误的文件名，重则 `cleanup` 误删用户目录里的东西。
public struct UpdateDownloaderSession {
    public let workDirectory: URL

    public init(workDirectory: URL) {
        self.workDirectory = workDirectory
    }

    /// 保留原始文件名（含版本与架构），便于用户和排查者一眼看出这是什么包。
    /// 文件名不像 .dmg 时退化为 update.dmg，避免拼出没有扩展名的怪文件。
    public func destinationURL(for download: UpdateDownload) throws -> URL {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let name = download.url.lastPathComponent
        guard !name.isEmpty, name.hasSuffix(".dmg") else {
            return workDirectory.appendingPathComponent("update.dmg")
        }
        return workDirectory.appendingPathComponent(name)
    }

    /// 只清理 .dmg 下载残留，不碰目录里的其他文件。
    public func cleanup() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: workDirectory, includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url.pathExtension.lowercased() == "dmg" {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
