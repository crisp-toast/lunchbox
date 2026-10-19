import Foundation

/// Summon's offer to find files in Desktop, Documents and Downloads. macOS hides those folders'
/// files from Lunchbox, Spotlight's answers included, until you let Lunchbox in, and it only asks
/// when Lunchbox reads one of them. So Lunchbox never reads them on its own: Summon's last row
/// offers it, and only choosing that row brings up macOS's prompts, once.
public enum FolderAccess {
    /// What you did with the offer. Either way, it never shows again.
    public enum Answer: String {
        /// You chose it: Lunchbox read the folders, and macOS asked.
        case chosen
        /// "Don't show this again".
        case dismissed
    }

    /// Whether Summon offers the row: on any query it searches files for, until you've chosen
    /// or dismissed it, and not when Lunchbox can already read every folder (Full Disk Access).
    public static func offers(query: String, answer: Answer?, fullDiskAccess: Bool) -> Bool {
        answer == nil && !fullDiskAccess && FileSearch.searches(query)
    }

    /// The folders Lunchbox reads once you choose the row, each bringing up macOS's own prompt if it
    /// has one: Desktop, Documents and Downloads, then iCloud Drive's Desktop and Documents (where
    /// those files are when they sync to iCloud, or once did). A folder that isn't there is skipped.
    public static func folders(home: String) -> [String] {
        let local = ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 }
        return local + ["Desktop", "Documents"].map { FileSearch.iCloudDrive(home) + "/" + $0 }
    }
}
