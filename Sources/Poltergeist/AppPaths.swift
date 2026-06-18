import Foundation

/// Filesystem locations for Poltergeist's persisted state, under
/// `~/Library/Application Support/Poltergeist/`.
enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Poltergeist", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var sessionsFile: URL {
        supportDirectory.appendingPathComponent("sessions.json")
    }
}
