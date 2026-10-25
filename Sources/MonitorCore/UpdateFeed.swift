import Foundation

/// 更新清单里的一个安装包（对应 update.json 的 downloads 数组元素）。
public struct UpdateDownload: Sendable, Equatable {
    public let architecture: String
    public let url: URL
    public let size: Int?
    public let sha256: String?

    public init(architecture: String, url: URL, size: Int? = nil, sha256: String? = nil) {
        self.architecture = architecture
        self.url = url
        self.size = size
        self.sha256 = sha256
    }
}

/// 解析后的更新清单。字段与 scripts/make-update-manifest.sh 的输出一一对应。
public struct UpdateRelease: Sendable, Equatable {
    public let version: String
    public let build: Int
    public let minimumSystemVersion: String?
    public let publishedAt: Date?
    public let notes: String?
    public let downloads: [UpdateDownload]

    public init(
        version: String,
        build: Int,
        minimumSystemVersion: String? = nil,
        publishedAt: Date? = nil,
        notes: String? = nil,
        downloads: [UpdateDownload]
    ) {
        self.version = version
        self.build = build
        self.minimumSystemVersion = minimumSystemVersion
        self.publishedAt = publishedAt
        self.notes = notes
        self.downloads = downloads
    }
}

public enum UpdateFeedError: Error, Equatable {
    /// JSON 结构不对、字段类型不对，或某个安装包缺少架构／下载地址。
    case malformed
    /// 缺少 version，或 version 为空串。
    case missingVersion
    /// 缺少 downloads，或 downloads 为空数组。
    case missingDownloads
}

/// 更新清单的纯解析逻辑：不联网、不读写文件，方便单元测试。
public enum UpdateFeed {
    public static func release(from data: Data) throws -> UpdateRelease {
        let payload: FeedPayload
        do {
            payload = try JSONDecoder().decode(FeedPayload.self, from: data)
        } catch {
            throw UpdateFeedError.malformed
        }
        guard let version = payload.version?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else {
            throw UpdateFeedError.missingVersion
        }
        // build 是版本单调性的主键，缺失时无法判断新旧，按格式错误处理。
        guard let build = payload.build else { throw UpdateFeedError.malformed }
        guard let rawDownloads = payload.downloads, !rawDownloads.isEmpty else {
            throw UpdateFeedError.missingDownloads
        }
        var downloads: [UpdateDownload] = []
        downloads.reserveCapacity(rawDownloads.count)
        for item in rawDownloads {
            guard let architecture = item.architecture?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !architecture.isEmpty,
                  let text = item.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: text),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  url.host != nil else {
                throw UpdateFeedError.malformed
            }
            downloads.append(
                UpdateDownload(architecture: architecture, url: url, size: item.size, sha256: item.sha256)
            )
        }
        return UpdateRelease(
            version: version,
            build: build,
            minimumSystemVersion: payload.minimumSystemVersion.flatMap { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            },
            publishedAt: publishedAt(from: payload.publishedAt),
            notes: payload.notes,
            downloads: downloads
        )
    }

    /// 架构匹配：大小写不敏感，先精确匹配，再回落 universal，都没有就返回 nil。
    public static func download(for release: UpdateRelease, architecture: String) -> UpdateDownload? {
        let wanted = architecture.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        if let exact = release.downloads.first(where: { $0.architecture.lowercased() == wanted }) {
            return exact
        }
        return release.downloads.first { $0.architecture.lowercased() == "universal" }
    }

    /// build 更大即为新版；build 相同再比语义版本号，避免同 build 误报。
    public static func isNewer(_ release: UpdateRelease, thanBuild currentBuild: Int, currentVersion: String) -> Bool {
        if release.build > currentBuild { return true }
        if release.build < currentBuild { return false }
        return compareVersions(release.version, currentVersion) > 0
    }

    /// 按点分数字比较版本号，缺失的段按 0 处理（1.0 与 1.0.0 相等）。
    public static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let left = versionComponents(lhs)
        let right = versionComponents(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let leftPart = index < left.count ? left[index] : 0
            let rightPart = index < right.count ? right[index] : 0
            if leftPart != rightPart { return leftPart > rightPart ? 1 : -1 }
        }
        return 0
    }

    /// minimumSystemVersion 缺省视为不限；否则当前系统版本必须不小于要求值。
    public static func satisfiesMinimumSystem(_ requirement: String?, currentVersion: String) -> Bool {
        guard let requirement = requirement?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requirement.isEmpty else { return true }
        return compareVersions(currentVersion, requirement) >= 0
    }

    private static func versionComponents(_ text: String) -> [Int] {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") { trimmed.removeFirst() }
        return trimmed.split(separator: ".").map { part in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }

    /// ISO8601，带不带小数秒都要能解析；解析不了按「未提供」处理。
    private static func publishedAt(from text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

private struct FeedPayload: Decodable {
    let version: String?
    let build: Int?
    let minimumSystemVersion: String?
    let publishedAt: String?
    let notes: String?
    let downloads: [DownloadPayload]?
}

private struct DownloadPayload: Decodable {
    let architecture: String?
    let url: String?
    let size: Int?
    let sha256: String?
}
