import XCTest
@testable import MonitorCore

final class UpdatePreferencesTests: XCTestCase {
    func testNotesRemainAvailableAfterRelaunchOnInstalledVersion() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let release = UpdateRelease(
            version: "0.2.0",
            build: 20,
            notes: "Fixed a crash on launch.",
            downloads: []
        )

        UpdateNotesStore.save(release, defaults: defaults)

        XCTAssertEqual(UpdateNotesStore.load(defaults: defaults, currentBuild: 19)?.text,
                       "Fixed a crash on launch.")
        XCTAssertEqual(UpdateNotesStore.load(defaults: defaults, currentBuild: 20)?.version,
                       "0.2.0")
        XCTAssertNil(UpdateNotesStore.load(defaults: defaults, currentBuild: 21))
    }

    func testMissingNotesClearPreviouslyCachedReleaseNotes() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        UpdateNotesStore.save(
            UpdateRelease(version: "0.2.0", build: 20, notes: "Old notes", downloads: []),
            defaults: defaults
        )

        UpdateNotesStore.save(
            UpdateRelease(version: "0.3.0", build: 30, notes: " \n ", downloads: []),
            defaults: defaults
        )

        XCTAssertNil(UpdateNotesStore.load(defaults: defaults, currentBuild: 20))
    }

    func testAutomaticRestartRequiresBothDownloadAndRestartSwitches() {
        XCTAssertFalse(UpdateAutomation.shouldRestart(autoDownload: false, autoRestart: false))
        XCTAssertFalse(UpdateAutomation.shouldRestart(autoDownload: true, autoRestart: false))
        XCTAssertFalse(UpdateAutomation.shouldRestart(autoDownload: false, autoRestart: true))
        XCTAssertTrue(UpdateAutomation.shouldRestart(autoDownload: true, autoRestart: true))
    }
}
