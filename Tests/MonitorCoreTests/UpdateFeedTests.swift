import XCTest
@testable import MonitorCore

final class UpdateFeedTests: XCTestCase {
    private let sample = """
    {
      "version": "0.2.0",
      "build": 2,
      "minimumSystemVersion": "14.0",
      "publishedAt": "2026-10-25T10:00:00Z",
      "notes": "修复若干问题",
      "downloads": [
        {
          "architecture": "arm64",
          "url": "https://example.com/v5xs-0.2.0-macOS-26.4-arm64.dmg",
          "size": 12345678,
          "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        },
        {
          "architecture": "universal",
          "url": "https://example.com/v5xs-0.2.0-universal.dmg"
        }
      ]
    }
    """

    func testParsesManifestWithAllFields() throws {
        let release = try UpdateFeed.release(from: Data(sample.utf8))
        XCTAssertEqual(release.version, "0.2.0")
        XCTAssertEqual(release.build, 2)
        XCTAssertEqual(release.minimumSystemVersion, "14.0")
        XCTAssertEqual(release.notes, "修复若干问题")
        XCTAssertEqual(release.downloads.count, 2)
        XCTAssertEqual(release.downloads.first?.architecture, "arm64")
        XCTAssertEqual(release.downloads.first?.size, 12_345_678)
        XCTAssertEqual(release.downloads.first?.sha256?.count, 64)
        XCTAssertEqual(release.downloads.first?.url.host, "example.com")
        XCTAssertNil(release.downloads.last?.size)
    }

    func testRejectsMissingVersion() {
        let json = #"{"build": 2, "downloads": [{"architecture": "arm64", "url": "https://example.com/a.dmg"}]}"#
        XCTAssertThrowsError(try UpdateFeed.release(from: Data(json.utf8))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .missingVersion)
        }
        let blank = #"{"version": "  ", "build": 2, "downloads": [{"architecture": "arm64", "url": "https://example.com/a.dmg"}]}"#
        XCTAssertThrowsError(try UpdateFeed.release(from: Data(blank.utf8))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .missingVersion)
        }
    }

    func testRejectsMissingOrEmptyDownloads() {
        let missing = #"{"version": "0.2.0", "build": 2}"#
        XCTAssertThrowsError(try UpdateFeed.release(from: Data(missing.utf8))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .missingDownloads)
        }
        let empty = #"{"version": "0.2.0", "build": 2, "downloads": []}"#
        XCTAssertThrowsError(try UpdateFeed.release(from: Data(empty.utf8))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .missingDownloads)
        }
    }

    func testRejectsMalformedJSONAndBrokenDownloads() {
        XCTAssertThrowsError(try UpdateFeed.release(from: Data("not json".utf8))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .malformed)
        }
        XCTAssertThrowsError(try UpdateFeed.release(from: Data("[]".utf8))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .malformed)
        }
        let noBuild = #"{"version": "0.2.0", "downloads": [{"architecture": "arm64", "url": "https://example.com/a.dmg"}]}"#
        XCTAssertThrowsError(try UpdateFeed.release(from: Data(noBuild.utf8))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .malformed)
        }
        let noURL = #"{"version": "0.2.0", "build": 2, "downloads": [{"architecture": "arm64"}]}"#
        XCTAssertThrowsError(try UpdateFeed.release(from: Data(noURL.utf8))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .malformed)
        }
        let notHTTP = #"{"version": "0.2.0", "build": 2, "downloads": [{"architecture": "arm64", "url": "file:///tmp/a.dmg"}]}"#
        XCTAssertThrowsError(try UpdateFeed.release(from: Data(notHTTP.utf8))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .malformed)
        }
    }

    func testArchitectureMatchingIsCaseInsensitiveWithUniversalFallback() throws {
        let release = try UpdateFeed.release(from: Data(sample.utf8))
        XCTAssertEqual(UpdateFeed.download(for: release, architecture: "arm64")?.architecture, "arm64")
        XCTAssertEqual(UpdateFeed.download(for: release, architecture: "ARM64")?.architecture, "arm64")
        // 精确匹配优先于 universal。
        XCTAssertEqual(UpdateFeed.download(for: release, architecture: "x86_64")?.architecture, "universal")
        XCTAssertEqual(UpdateFeed.download(for: release, architecture: "Universal")?.architecture, "universal")
        let onlyARM = UpdateRelease(
            version: "0.2.0",
            build: 2,
            downloads: [UpdateDownload(architecture: "arm64", url: URL(string: "https://example.com/a.dmg")!)]
        )
        XCTAssertNil(UpdateFeed.download(for: onlyARM, architecture: "x86_64"))
        XCTAssertNil(UpdateFeed.download(for: release, architecture: "  "))
    }

    func testNewerVersionPrefersBuildThenSemanticVersion() throws {
        let release = try UpdateFeed.release(from: Data(sample.utf8))
        XCTAssertTrue(UpdateFeed.isNewer(release, thanBuild: 1, currentVersion: "0.1.0"))
        XCTAssertFalse(UpdateFeed.isNewer(release, thanBuild: 2, currentVersion: "0.2.0"))
        XCTAssertFalse(UpdateFeed.isNewer(release, thanBuild: 3, currentVersion: "0.1.0"))
        // build 相同但版本号更高，仍视为更新。
        XCTAssertTrue(UpdateFeed.isNewer(release, thanBuild: 2, currentVersion: "0.1.9"))
        XCTAssertTrue(UpdateFeed.isNewer(release, thanBuild: 2, currentVersion: "0.1"))
        XCTAssertFalse(UpdateFeed.isNewer(release, thanBuild: 2, currentVersion: "0.10.0"))
    }

    func testVersionComparisonTreatsMissingComponentsAsZero() {
        XCTAssertEqual(UpdateFeed.compareVersions("0.2.0", "0.2"), 0)
        XCTAssertEqual(UpdateFeed.compareVersions("1.0.0", "0.9.9"), 1)
        XCTAssertEqual(UpdateFeed.compareVersions("0.9.9", "1.0.0"), -1)
        XCTAssertEqual(UpdateFeed.compareVersions("v1.2.3", "1.2.3"), 0)
        XCTAssertEqual(UpdateFeed.compareVersions("1.2.10", "1.2.9"), 1)
    }

    func testMinimumSystemRequirement() {
        XCTAssertTrue(UpdateFeed.satisfiesMinimumSystem(nil, currentVersion: "14.0.0"))
        XCTAssertTrue(UpdateFeed.satisfiesMinimumSystem("14.0", currentVersion: "26.4.0"))
        XCTAssertTrue(UpdateFeed.satisfiesMinimumSystem("14.0", currentVersion: "14.0.0"))
        XCTAssertFalse(UpdateFeed.satisfiesMinimumSystem("15.0", currentVersion: "14.6.1"))
    }

    func testPublishedAtAcceptsFractionalAndPlainISO8601() throws {
        let release = try UpdateFeed.release(from: Data(sample.utf8))
        XCTAssertNotNil(release.publishedAt)
        let expected = ISO8601DateFormatter().date(from: "2026-10-25T10:00:00Z")
        XCTAssertEqual(release.publishedAt, expected)

        let fractional = sample.replacingOccurrences(of: "2026-10-25T10:00:00Z", with: "2026-10-25T10:00:00.250Z")
        XCTAssertNotNil(try UpdateFeed.release(from: Data(fractional.utf8)).publishedAt)

        let invalid = sample.replacingOccurrences(of: "2026-10-25T10:00:00Z", with: "昨天")
        XCTAssertNil(try UpdateFeed.release(from: Data(invalid.utf8)).publishedAt)
    }

    func testOptionalFieldsAreReportedAsUnavailable() throws {
        let json = #"{"version": "0.3.0", "build": 3, "downloads": [{"architecture": "universal", "url": "https://example.com/a.dmg"}]}"#
        let release = try UpdateFeed.release(from: Data(json.utf8))
        XCTAssertNil(release.minimumSystemVersion)
        XCTAssertNil(release.publishedAt)
        XCTAssertNil(release.notes)
    }
}
