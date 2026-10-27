import CryptoKit
import Foundation

/// 更新包下载、完整性校验与安装前预检。
///
/// 安全边界（按顺序，任何一步失败都不得继续）：
/// 1. 清单签名（Ed25519）—— 确认清单本身来自 v5xs 作者；
/// 2. 下载体积与 SHA-256 —— 确认安装包与清单描述逐字节一致；
/// 3. 安装前预检 —— 确认有权限、有空间、不是从只读卷运行。
///
/// 这三层是递进的：清单被劫持时第 2 层失效（两者同源），
/// 所以第 1 层不能用第 2 层替代。
public enum UpdateVerification {
    public enum Failure: Error, Equatable {
        case sizeMismatch(expected: Int64, actual: Int64)
        case checksumMissing
        case checksumMismatch(expected: String, actual: String)
        case signatureMissing
        case signatureInvalid
        case signatureMalformed
        case emptyFile
    }

    /// 流式计算文件的 SHA-256，避免把大 DMG 整个读进内存。
    public static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 校验下载结果。全部通过返回 nil，否则返回第一个失败原因。
    ///
    /// - 期望的 sha256 缺失时视为失败（`checksumMissing`）：自更新必须能校验，
    ///   清单缺字段说明发版流程有问题，宁可拒绝也不要装一个无法验证的包。
    public static func verifyDownload(
        fileAt url: URL,
        expectedSize: Int?,
        expectedSHA256: String?
    ) -> Failure? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let actualSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        if actualSize == 0 { return .emptyFile }
        if let expectedSize, Int64(expectedSize) != actualSize {
            return .sizeMismatch(expected: Int64(expectedSize), actual: actualSize)
        }
        guard let expectedSHA256, !expectedSHA256.isEmpty else { return .checksumMissing }
        guard let actual = try? sha256(ofFileAt: url) else { return .checksumMismatch(expected: expectedSHA256, actual: "") }
        let normalized = expectedSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard actual == normalized else {
            return .checksumMismatch(expected: normalized, actual: actual)
        }
        return nil
    }
}

/// 安装前预检：这些是「在用户机器上必然踩到」的现实条件，
/// 提前检查比下载完 8 MB 之后才失败体验好得多。
public enum UpdatePreflight {
    public enum Failure: Error, Equatable {
        /// 应用不在可写的目录（如直接在 DMG 内运行、或只读卷）。
        case notInWritableLocation(String)
        /// 应用目录写不进去（权限不足）。
        case directoryNotWritable(String)
        /// 磁盘剩余空间不足。
        case insufficientSpace(required: Int64, available: Int64)
        /// 同一个 BundleID 还有别的实例在跑，并发更新会互相踩踏。
        case anotherInstanceRunning(String)
    }

    /// 安装一个 size 字节的更新大致需要 `size * 3` 的余量：
    /// 下载的 DMG + 解压出的 .app + 旧版本备份同时存在。
    public static let spaceMultiplier: Int64 = 3

    /// 预检入口。`appBundlePath` 是**当前运行**的 .app 路径。
    public static func validate(
        appBundlePath: String,
        installBytes: Int64,
        existingInstanceCount: Int
    ) -> Failure? {
        let url = URL(fileURLWithPath: appBundlePath).resolvingSymlinksInPath()
        let parent = url.deletingLastPathComponent()

        // 从 DMG 挂载点（/Volumes/...）里运行时无法替换自身。
        if url.path.hasPrefix("/Volumes/") {
            return .notInWritableLocation(url.path)
        }
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            return .directoryNotWritable(parent.path)
        }
        if existingInstanceCount > 1 {
            return .anotherInstanceRunning(url.lastPathComponent)
        }
        if let available = availableBytes(at: parent), installBytes > 0 {
            // 必须用溢出安全乘法：清单来自网络，size 字段是攻击者可控的输入。
            // 直接写 `installBytes * spaceMultiplier` 会在极端值下触发 Swift 的
            // 整数溢出陷阱，让整个应用崩溃——这正是自动更新最不该出现的行为。
            let (required, overflow) = installBytes.multipliedReportingOverflow(by: spaceMultiplier)
            let need = overflow ? Int64.max : required
            if available < need {
                return .insufficientSpace(required: need, available: available)
            }
        }
        return nil
    }

    /// 目标卷的可用空间。
    public static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage, capacity > 0 {
            return capacity
        }
        return nil
    }
}
