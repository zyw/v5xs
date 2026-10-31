import Foundation

public struct UpdateNotes: Codable, Equatable {
    public let version: String
    public let build: Int
    public let text: String
}

/// Keep the latest release notes across the app restart that installs the update.
public enum UpdateNotesStore {
    private static let key = "updateReleaseNotes"

    public static func load(defaults: UserDefaults, currentBuild: Int) -> UpdateNotes? {
        guard let data = defaults.data(forKey: key),
              let notes = try? JSONDecoder().decode(UpdateNotes.self, from: data),
              notes.build >= currentBuild else { return nil }
        return notes
    }

    public static func save(_ release: UpdateRelease, defaults: UserDefaults) {
        guard let text = release.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        let notes = UpdateNotes(version: release.version, build: release.build, text: text)
        defaults.set(try? JSONEncoder().encode(notes), forKey: key)
    }
}

public enum UpdateAutomation {
    public static func shouldRestart(autoDownload: Bool, autoRestart: Bool) -> Bool {
        autoDownload && autoRestart
    }
}
