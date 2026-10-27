import Foundation

/// DMG 挂载与解挂。
///
/// 用 `hdiutil attach -plist` 解析挂载点，而不是从文本输出里抠路径：
/// 卷名里可能有空格、中文，文本解析很容易切错。
public enum DMGMounter {
    public enum Failure: Error, Equatable {
        case attachFailed(String)
        case noMountPoint
        case detachFailed(String)
    }

    /// 挂载 DMG，返回挂载点。
    /// 一律只读 + nobrowse：更新流程不需要写入，也不该在访达里弹出窗口。
    public static func attach(_ dmg: URL) throws -> URL {
        let result = try run("/usr/bin/hdiutil", [
            "attach", dmg.path,
            "-nobrowse", "-readonly", "-noautoopen", "-plist"
        ])
        guard result.status == 0 else {
            throw Failure.attachFailed(trim(result.stderr))
        }
        guard let mountPoint = parseMountPoint(result.stdout) else {
            throw Failure.noMountPoint
        }
        return URL(fileURLWithPath: mountPoint)
    }

    /// 解挂。已经解挂或挂载点消失都视为成功——这步是尽力清理，
    /// 不该因为「已经没了」而让更新流程失败。
    public static func detach(_ mountPoint: URL) {
        _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet", "-force"])
    }

    /// 从 `hdiutil -plist` 的输出里取出挂载点。
    /// 结构是 `system-entities` 数组，里面带 `mount-point` 的那一项才是卷。
    public static func parseMountPoint(_ plistData: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: plistData, options: [], format: nil
        ) as? [String: Any],
        let entities = plist["system-entities"] as? [[String: Any]] else {
            return nil
        }
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String, !mountPoint.isEmpty {
                return mountPoint
            }
        }
        return nil
    }

    /// 在 DMG 里找 .app。只认第一层，避免误取包内嵌套的辅助 App。
    public static func appBundle(in mountPoint: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: mountPoint,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let apps = contents.filter { $0.pathExtension.lowercased() == "app" }
        // 多个 .app 时优先选名字带 v5xs 的，避免拿到更新器之类的辅助程序。
        return apps.first { $0.lastPathComponent.lowercased().contains("v5xs") } ?? apps.first
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw Failure.attachFailed(error.localizedDescription)
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, out, String(data: err, encoding: .utf8) ?? "")
    }

    private static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
