import Testing
@testable import TesselCore

@Suite struct FileSearching {
    static let home = "/Users/tyler"
    static let cloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"

    @Test func desktopFilesInICloudAreShown() {
        // With Desktop & Documents in iCloud, Spotlight reports them under Library.
        #expect(!FileSearch.isHidden(Self.cloud + "/Desktop/CommuterRail.pdf", home: Self.home))
        #expect(!FileSearch.isHidden(Self.cloud + "/Documents/Budget.numbers", home: Self.home))
        #expect(!FileSearch.isHidden(Self.home + "/Library/CloudStorage/Dropbox/Taxes.pdf", home: Self.home))
        #expect(!FileSearch.isHidden(Self.home + "/Desktop/Lunch.txt", home: Self.home))
        #expect(!FileSearch.isHidden("/Volumes/Master Storage/Projects/tessel/demo.mp4", home: Self.home))
    }

    @Test func libraryCachesAndAppsAreNot() {
        #expect(FileSearch.isHidden(Self.home + "/Library/Preferences/com.apple.finder.plist", home: Self.home))
        #expect(FileSearch.isHidden(Self.home + "/Library/Application Support/Code/notes.json", home: Self.home))
        #expect(FileSearch.isHidden(Self.cloud + "/.Trash/old.pdf", home: Self.home))
        #expect(FileSearch.isHidden(Self.home + "/code/tessel/.build/debug/Tessel", home: Self.home))
        #expect(FileSearch.isHidden(Self.home + "/code/site/node_modules/react/index.js", home: Self.home))
        #expect(FileSearch.isHidden("/Applications/Notes.app", home: Self.home))
        #expect(FileSearch.isHidden("/Applications/Xcode.app/Contents/Info.plist", home: Self.home))
    }

    @Test func iCloudDriveIsNamed() {
        #expect(FileSearch.folder(of: Self.cloud + "/Desktop/CommuterRail.pdf", home: Self.home) == "iCloud Drive/Desktop")
        #expect(FileSearch.folder(of: Self.cloud + "/Group 1286.pdf", home: Self.home) == "iCloud Drive")
        #expect(FileSearch.folder(of: Self.home + "/Downloads/a.zip", home: Self.home) == "~/Downloads")
        #expect(FileSearch.folder(of: "/Volumes/Master Storage/Inbox/b.zip", home: Self.home) == "/Volumes/Master Storage/Inbox")
    }

    @Test func theNameItselfThenItsStartThenItsWords() {
        let paths = [
            Self.home + "/Desktop/old budget notes.txt",   // a word starts "budget"
            Self.home + "/Desktop/rebudgeting.txt",        // only inside a word
            Self.home + "/Desktop/Budget 2026.numbers",    // starts with it
            Self.home + "/Desktop/Budget.numbers",         // is it
        ]
        #expect(FileSearch.rank(paths, query: "budget", home: Self.home) == [
            Self.home + "/Desktop/Budget.numbers", Self.home + "/Desktop/Budget 2026.numbers",
            Self.home + "/Desktop/old budget notes.txt", Self.home + "/Desktop/rebudgeting.txt",
        ])
    }

    @Test func desktopDocumentsAndDownloadsBeforeDeepPaths() {
        let deep = Self.home + "/code/archive/2024/clients/acme/invoice.pdf"
        let shallow = Self.home + "/code/invoice.pdf"
        let desktop = Self.cloud + "/Desktop/invoice.pdf"
        let downloads = Self.home + "/Downloads/invoice.pdf"
        #expect(FileSearch.rank([deep, shallow, desktop, downloads], query: "invoice", home: Self.home)
            == [desktop, downloads, shallow, deep])
        // A better name still wins over a better place.
        let named = Self.home + "/code/archive/2024/clients/acme/Invoice.pdf"
        let wordy = Self.home + "/Desktop/march invoice.pdf"
        #expect(FileSearch.rank([wordy, named], query: "invoice", home: Self.home) == [named, wordy])
    }

    @Test func tiesKeepSpotlightsOrder() {
        let a = Self.home + "/Documents/notes a.txt", b = Self.home + "/Documents/notes b.txt"
        #expect(FileSearch.rank([a, b], query: "notes", home: Self.home) == [a, b])
        #expect(FileSearch.rank([b, a], query: "notes", home: Self.home) == [b, a])
    }

    @Test func places() {
        #expect(FileSearch.place(of: Self.home + "/Desktop/x.txt", home: Self.home) == 2)
        #expect(FileSearch.place(of: Self.home + "/Documents/a/b/x.txt", home: Self.home) == 2)
        #expect(FileSearch.place(of: Self.home + "/Documents/a/b/c/x.txt", home: Self.home) == 0)
        #expect(FileSearch.place(of: Self.cloud + "/Desktop/A&M Info/A&M Info.pages", home: Self.home) == 2)
        #expect(FileSearch.place(of: Self.cloud + "/Group 1286.pdf", home: Self.home) == 1)
        #expect(FileSearch.place(of: "/Volumes/Master Storage/Projects/tessel/demo.mp4", home: Self.home) == 1)
        #expect(FileSearch.place(of: Self.home + "/code/tessel/Sources/Tessel/Launcher.swift", home: Self.home) == 0)
    }

    @Test func termsAndMatching() {
        #expect(FileSearch.terms(in: " lunch  *plans? ") == ["lunch", "plans"])
        #expect(FileSearch.matches(["plans", "lunch"], name: "Lunch plans.txt"))
        #expect(FileSearch.matches(["cafe"], name: "Café.pdf"))
        #expect(!FileSearch.matches(["lunch", "dinner"], name: "Lunch plans.txt"))
        #expect(!FileSearch.matches([], name: "anything"))
    }

    @Test func mdfindAsksForEveryWord() {
        #expect(FileSearch.mdfindQuery(["lunch"]) == #"kMDItemFSName == "*lunch*"cd"#)
        #expect(FileSearch.mdfindQuery(FileSearch.terms(in: "lunch \"plans\"")) ==
            #"kMDItemFSName == "*lunch*"cd && kMDItemFSName == "*plans*"cd"#)
    }

    @Test func twoAnswersMergeWithoutRepeats() {
        let desktop = Self.home + "/Desktop/Lunch.txt", projects = Self.home + "/Projects/Lunch plan.txt"
        let hidden = Self.home + "/Desktop/.Lunch.swp"
        #expect(FileSearch.merge([projects], [desktop, projects, hidden], home: Self.home) == [projects, desktop])
        #expect(FileSearch.merge([], [desktop], home: Self.home) == [desktop])
    }

    @Test func filesAreSearchedFromTwoLetters() {
        #expect(!FileSearch.searches(""))
        #expect(!FileSearch.searches("b"))
        #expect(!FileSearch.searches(" b  "))
        #expect(!FileSearch.searches("**"))
        #expect(FileSearch.searches("bu"))
        #expect(FileSearch.searches("lunch plans"))
    }
}

@Suite struct FolderAccessOffer {
    @Test func offeredOnFileSearchesUntilAnswered() {
        #expect(FolderAccess.offers(query: "budget", answer: nil, fullDiskAccess: false))
        #expect(!FolderAccess.offers(query: "budget", answer: .chosen, fullDiskAccess: false))
        #expect(!FolderAccess.offers(query: "budget", answer: .dismissed, fullDiskAccess: false))
    }

    @Test func notWhileNoFilesAreSearched() {
        // An empty field or one letter searches no files, so the row never shows on its own.
        #expect(!FolderAccess.offers(query: "", answer: nil, fullDiskAccess: false))
        #expect(!FolderAccess.offers(query: "b", answer: nil, fullDiskAccess: false))
    }

    @Test func notWithFullDiskAccess() {
        // Tessel can already read Desktop, Documents and Downloads: nothing to ask.
        #expect(!FolderAccess.offers(query: "budget", answer: nil, fullDiskAccess: true))
    }

    @Test func answersAreKeptByName() {
        // UserDefaults keeps the raw value; a value Tessel doesn't know means not answered.
        #expect(FolderAccess.Answer(rawValue: "chosen") == .chosen)
        #expect(FolderAccess.Answer(rawValue: "dismissed") == .dismissed)
        #expect(FolderAccess.Answer(rawValue: "later") == nil)
    }

    @Test func foldersRead() {
        let home = "/Users/tyler", cloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        #expect(FolderAccess.folders(home: home) == [
            home + "/Desktop", home + "/Documents", home + "/Downloads", cloud + "/Desktop", cloud + "/Documents",
        ])
    }

    @Test func onlyWhatYoudLookForWhereYouKeepYourThings() {
        let home = "/Users/t"
        let shown = { (p: String, folder: Bool) in FileSearch.isWorthShowing(p, isFolder: folder, home: home) }
        // Documents, pictures and downloads in Desktop, Documents and Downloads, and in iCloud Drive.
        #expect(shown("/Users/t/Documents/Taxes/2026 return.pdf", false))
        #expect(shown("/Users/t/Desktop/Screenshot 2026-10-18.png", false))
        #expect(shown("/Users/t/Downloads/Tessel.dmg", false))
        #expect(shown("/Users/t/Library/Mobile Documents/com~apple~CloudDocs/Desktop/Plan.pages", false))
        #expect(shown("/Users/t/Library/CloudStorage/Dropbox/Contracts/lease.docx", false))
        #expect(shown("/Users/t/Documents/Taxes", true))
        // Not what programs and agents leave behind (the "simulator" search that showed only these).
        #expect(!shown("/Users/t/Storage Audit 2026-09-13/simulator-cleanup.json", false))
        #expect(!shown("/Volumes/Master Storage/Code/nellia-stuff/nellia/simulator-aliases.sh", false))
        #expect(!shown("/Users/t/Library/Mobile Documents/com~apple~CloudDocs/Documents/Codex/2026-09-07/my-macbook-is-out-of-space/outputs/simulator-review.json", false))
        #expect(!shown("/Users/t/code.pre-move-2026-10-13/deltabinder/build/testflight-1.0-12/image-regression/simulator-settled.png", false))
        #expect(!shown("/Users/t/Documents/Codex/2026-09-17/use-x20/work/simulator-devices.json", false))
        // Too deep, even a document; code and data, even on the Desktop.
        #expect(!shown("/Users/t/Documents/a/b/c/d/notes.pdf", false))
        #expect(!shown("/Users/t/Desktop/server.py", false))
        #expect(!shown("/Users/t/Desktop/config.json", false))
    }
}
