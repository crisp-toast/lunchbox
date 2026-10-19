import Foundation
import Testing
@testable import LunchboxCore

private struct Ping: LoggedEvent, Equatable {
    var time: Double
    var n: Int
}

private func scratchFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("lunchbox-log-\(UUID().uuidString)")
}

@Suite struct EventLogStaysSmallAndLocal {
    @Test func whatGoesInComesBackInOrder() throws {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EventLog<Ping>(folder: folder, name: "ping")
        for n in 0..<3 { try log.append(Ping(time: Double(n), n: n)) }
        #expect(log.read(now: 3) == (0..<3).map { Ping(time: Double($0), n: $0) })
    }

    @Test func onlyYouCanReadItAndBackupsSkipIt() throws {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EventLog<Ping>(folder: folder, name: "ping")
        try log.append(Ping(time: 0, n: 0))
        let fm = FileManager.default
        #expect((try fm.attributesOfItem(atPath: log.current.path)[.posixPermissions] as? Int) == 0o600)
        #expect((try fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int) == 0o700)
        #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func neverMoreThanTwoFiles() throws {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EventLog<Ping>(folder: folder, name: "ping", maxBytes: 200)
        for n in 0..<100 { try log.append(Ping(time: Double(n), n: n)) }
        #expect(log.bytes <= 400)
        let kept = log.read(now: 100)
        #expect(kept.last?.n == 99)
        #expect(kept.map(\.n) == Array(kept.first!.n...99)) // the newest, with no gaps
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(Set(files) == ["ping.jsonl", "ping.1.jsonl"])
    }

    @Test func oldEventsAreLeftOutThenErased() throws {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EventLog<Ping>(folder: folder, name: "ping", maxAge: 10)
        for n in 0...20 { try log.append(Ping(time: Double(n), n: n)) }
        #expect(log.read(now: 20).map(\.n) == Array(10...20))
        let before = log.bytes
        try log.prune(now: 20)
        #expect(log.bytes < before)
        #expect(log.read(now: 0).map(\.n) == Array(10...20)) // gone from the file, not just hidden
        try log.prune(now: 1000)
        #expect(log.bytes == 0)
    }

    @Test func aLineCutOffMidWriteIsSkipped() throws {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EventLog<Ping>(folder: folder, name: "ping")
        try log.append(Ping(time: 1, n: 1))
        let handle = try FileHandle(forWritingTo: log.current)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"time\":2,\"n\"".utf8))
        try handle.close()
        try log.append(Ping(time: 3, n: 3))
        #expect(log.read(now: 3).map(\.n) == [1])
    }

    @Test func eraseForgetsEverything() throws {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EventLog<Ping>(folder: folder, name: "ping", maxBytes: 100)
        for n in 0..<20 { try log.append(Ping(time: Double(n), n: n)) }
        log.erase()
        #expect(log.read(now: 20).isEmpty)
        #expect(log.bytes == 0)
    }
}

/// "Everything it learns stays on your Mac" is checked here: the only code in Lunchbox that
/// opens a network connection itself is the weekly license check. (Sparkle's update check
/// is set up in Info.plist, and Summon's web searches open in your browser.)
@Suite struct NothingLeavesThisMac {
    @Test func onlyTheLicenseCheckGoesOnline() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let networking = ["URLSession", "URLRequest", "NWConnection", "NWBrowser", "import Network",
                          "CFStream", "CFSocket", "socket(", "WebSocket", "URLConnection"]
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if networking.contains(where: text.contains) {
                offenders.append(url.path.replacingOccurrences(of: sources.path + "/", with: ""))
            }
        }
        #expect(offenders == ["Lunchbox/Licensing.swift"])
    }
}
