/// Summon's list, put together.
public enum Summon {
    /// One row in Summon's list.
    public enum Row<App, Window> {
        case app(App)
        case window(Window)
    }

    /// Summon's order: apps whose name matches what you typed (the whole name, its start, a
    /// word's start or the initials), then windows, then apps that only loosely match, like
    /// "lunch" in Launchpad.
    ///
    /// `apps` in the order they should show, each with its `Fuzzy.score` for the name alone.
    public static func order<App, Window>(apps: [(app: App, nameScore: Int)], windows: [Window], limit: Int) -> [Row<App, Window>] {
        let named = apps.filter { Fuzzy.matchesName($0.nameScore) }.map { Row<App, Window>.app($0.app) }
        let loose = apps.filter { !Fuzzy.matchesName($0.nameScore) }.map { Row<App, Window>.app($0.app) }
        return Array((named + windows.map { .window($0) } + loose).prefix(limit))
    }
}

/// Other names people know some apps by: what an app used to be called, or what's inside it now.
public enum AppNames {
    static let aliases: [String: [String]] = [
        "com.apple.dt.Devices": ["Simulator", "iOS Simulator"], // Xcode 27 put Simulator into Device Hub
        "com.apple.systempreferences": ["System Preferences"],
        "com.apple.Music": ["iTunes"],
        "com.apple.iCal": ["iCal"],
        "com.apple.AddressBook": ["Address Book"],
        "com.apple.ActivityMonitor": ["Task Manager"],
        "com.apple.Photos": ["iPhoto"],
    ]

    public static func aliases(forBundleID id: String?) -> [String] { id.flatMap { aliases[$0] } ?? [] }

    /// How well a query matches an app by its name or any other name it goes by.
    public static func score(_ query: String, name: String, bundleID: String?) -> Int? {
        ([name] + aliases(forBundleID: bundleID)).compactMap { Fuzzy.score(query, $0) }.max()
    }
}
