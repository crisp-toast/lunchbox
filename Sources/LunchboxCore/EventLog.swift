import Foundation

/// Something that happened, as LunchboxWM writes it down to learn from: when, and nothing it
/// doesn't need. Window titles, keystrokes and file names never go in an event.
public protocol LoggedEvent: Codable, Sendable {
    /// Seconds since 1970.
    var time: Double { get }
}

/// An append-only log of events in a folder on this Mac, one JSON object per line, so
/// anyone can open it and read every word. It never grows past two files of `maxBytes`
/// (the older file is dropped when the newer one fills), and events older than `maxAge`
/// are left out when it's read and erased by `prune`.
///
/// Not thread-safe: the app calls it from one serial queue, off the main thread.
public struct EventLog<Event: LoggedEvent> {
    public let folder: URL
    public let name: String
    public let maxBytes: Int
    public let maxAge: TimeInterval

    public init(folder: URL, name: String, maxBytes: Int = 1 << 20, maxAge: TimeInterval = 90 * 86_400) {
        self.folder = folder
        self.name = name
        self.maxBytes = maxBytes
        self.maxAge = maxAge
    }

    /// The file being written.
    public var current: URL { folder.appendingPathComponent("\(name).jsonl") }
    /// The file before it, until the current one fills too.
    public var previous: URL { folder.appendingPathComponent("\(name).1.jsonl") }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// Adds an event at the end, starting a new file first when this one is full.
    public func append(_ event: Event) throws {
        var line = try Self.encoder.encode(event)
        line.append(0x0A)
        try makeFolder()
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: current.path)[.size] as? Int) ?? 0
        if size > 0, size + line.count > maxBytes {
            try? fm.removeItem(at: previous)
            try fm.moveItem(at: current, to: previous)
        }
        if !fm.fileExists(atPath: current.path) {
            // Readable by you only, like the rest of your Library.
            guard fm.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: current)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Every event still young enough, oldest first. A line that can't be read (cut off
    /// mid-write, or from a newer LunchboxWM) is skipped.
    public func read(now: Double = Date().timeIntervalSince1970) -> [Event] {
        let decoder = JSONDecoder()
        var events: [Event] = []
        for url in [previous, current] {
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                if let event = try? decoder.decode(Event.self, from: line), now - event.time <= maxAge {
                    events.append(event)
                }
            }
        }
        return events
    }

    /// Rewrites the log without the events that are too old to keep.
    public func prune(now: Double = Date().timeIntervalSince1970) throws {
        let fresh = read(now: now)
        let fm = FileManager.default
        guard fm.fileExists(atPath: current.path) || fm.fileExists(atPath: previous.path) else { return }
        var data = Data()
        for event in fresh {
            data.append(try Self.encoder.encode(event))
            data.append(0x0A)
        }
        try? fm.removeItem(at: previous)
        try? fm.removeItem(at: current)
        guard !data.isEmpty else { return }
        try makeFolder()
        guard fm.createFile(atPath: current.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Forgets everything in this log.
    public func erase() {
        try? FileManager.default.removeItem(at: current)
        try? FileManager.default.removeItem(at: previous)
    }

    /// How much room the log takes on disk.
    public var bytes: Int {
        [current, previous].reduce(0) { total, url in
            total + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        }
    }

    private func makeFolder() throws { try PrivateFolder.make(folder) }
}

/// The learning folder is yours alone, and stays out of Time Machine and other backups:
/// what LunchboxWM learns stays on this Mac.
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
