import Foundation

/// 安装编排：把「挂载 DMG → 校验 → 复制到暂存区 → 生成重启脚本」串起来。
///
/// 刻意不在这里执行替换：那必须发生在 App 退出之后，由独立脚本完成。
/// 本类型只负责**准备好一切**，然后交还给调用方去决定何时退出。
public enum UpdateInstaller {
    public enum Failure: Error, Equatable {
        case mount(String)
        case noAppBundle
        /// 挂载包里没有可执行文件，多半是下载/解包损坏。
        case missingExecutable
        /// 包的 BundleID 与当前 App 不一致：防止被替换成别的应用。
        case bundleIdentifierMismatch(expected: String, actual: String)
        case stageFailed(String)
        case scriptFailed(String)
    }

    /// 已完成准备、可以退出的状态。
    public struct Prepared: Equatable {
        /// 重启脚本路径（已写入并 chmod +x）。
        public let scriptURL: URL
        /// 需要解挂的挂载点，脚本执行时会自动解挂。
        public let mountPoint: URL
        public let stagedApp: URL
    }

    /// 准备安装。
    /// - Parameters:
    ///   - dmg: 已下载并通过 SHA-256 校验的 DMG。
    ///   - targetApp: 当前运行的 .app 路径（通常是 /Applications/v5xs.app）。
    ///   - expectedBundleID: 期望的 BundleID，用于防止替换成别的应用。
    ///   - pid: 当前进程 pid。
    public static func prepare(
        dmg: URL,
        targetApp: URL,
        expectedBundleID: String,
        pid: Int32
    ) throws -> Prepared {
        let mountPoint: URL
        do {
            mountPoint = try DMGMounter.attach(dmg)
        } catch {
            throw Failure.mount(String(describing: error))
        }

        // 任何后续失败都要解挂，否则会残留一个 /Volumes 挂载点。
        func cleanupOnFailure() { DMGMounter.detach(mountPoint) }

        guard let app = DMGMounter.appBundle(in: mountPoint) else {
            cleanupOnFailure()
            throw Failure.noAppBundle
        }
        let executable = app.appendingPathComponent("Contents/MacOS/v5xs")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            cleanupOnFailure()
            throw Failure.missingExecutable
        }
        // BundleID 校验：防止清单被指向一个完全不同的应用。
        // 注意这里读的是**挂载后**的包，而不是刚下载的文件。
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let actualID = (NSDictionary(contentsOf: plist)?["CFBundleIdentifier"] as? String) ?? ""
        guard actualID == expectedBundleID else {
            cleanupOnFailure()
            throw Failure.bundleIdentifierMismatch(expected: expectedBundleID, actual: actualID)
        }

        // 复制到与目标同卷的暂存目录：同卷 rename 才是原子的，
        // 跨卷（/Volumes → /Applications）只能拷贝，中途失败会留下半个应用。
        let stagedRoot = targetApp.deletingLastPathComponent()
            .appendingPathComponent(".v5xs-staging-\(pid)")
        let staged = stagedRoot.appendingPathComponent(app.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: stagedRoot)
            try FileManager.default.createDirectory(at: stagedRoot, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: app, to: staged)
        } catch {
            cleanupOnFailure()
            throw Failure.stageFailed(error.localizedDescription)
        }

        // 复制完成即可解挂 DMG，让脚本少一步、也少一个失败点。
        DMGMounter.detach(mountPoint)

        let script = UpdateInstallScript.make(
            pid: pid,
            stagedApp: staged.path,
            targetApp: targetApp.path,
            mountPoint: nil   // 已在上面解挂
        )
        let scriptURL = UpdateInstallScript.scriptURL(pid: pid)
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path
            )
        } catch {
            throw Failure.scriptFailed(error.localizedDescription)
        }
        return Prepared(scriptURL: scriptURL, mountPoint: mountPoint, stagedApp: staged)
    }

    /// 启动重启脚本并让调用方退出应用。
    /// 用 `launchPath` + detached 进程，确保脚本不随 App 一起被杀。
    @discardableResult
    public static func launch(_ prepared: Prepared) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [prepared.scriptURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }
}
