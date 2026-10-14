import Testing
@testable import TesselCore

@Suite struct FuzzyMatching {
    func rank(_ query: String, _ names: [String]) -> [String] {
        names.compactMap { name in Fuzzy.score(query, name).map { (name, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    @Test func prefixBeatsSubstring() {
        #expect(rank("ar", ["Calendar", "Arc"]) == ["Arc", "Calendar"])
    }

    @Test func wordStartsAndInitials() {
        #expect(Fuzzy.score("code", "Visual Studio Code") != nil)
        #expect(rank("vsc", ["Visual Studio Code", "Voice Memos"]).first == "Visual Studio Code")
        #expect(Fuzzy.score("craft", "PhotoCraft") != nil)
        #expect(rank("pc", ["PhotoCraft", "Podcasts"]).first == "PhotoCraft")
    }

    @Test func lettersInOrder() {
        #expect(Fuzzy.score("xcd", "Xcode") != nil)
        #expect(Fuzzy.score("xdc", "Xcode") == nil)
    }

    @Test func shorterNameWinsATie() {
        #expect(rank("notes", ["Notes Helper", "Notes"]) == ["Notes", "Notes Helper"])
    }

    @Test func spacesAndCaseDoNotMatter() {
        #expect(Fuzzy.score("System Settings", "system settings") == 10_000)
        #expect(Fuzzy.score("sys set", "System Settings") != nil)
        #expect(Fuzzy.score("   ", "Arc") == nil)
    }
}
