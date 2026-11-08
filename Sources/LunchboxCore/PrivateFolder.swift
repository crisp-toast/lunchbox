import Foundation

/// LunchboxWM's own folder (the time-back counts) is yours alone, and stays out of Time Machine
/// and other backups.
enum PrivateFolder {
    static func make(_ folder: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { return }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
