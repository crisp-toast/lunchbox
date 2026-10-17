import CoreGraphics
import Foundation
import Testing
@testable import TesselCore

private let t0 = 1_800_000_000.0
private let day = 86_400.0

/// A window of a notes app: by default a medium document window with every button.
private func window(_ app: String = "com.example.notes", subrole: String? = "AXStandardWindow", share: Double = 0.3,
                    title: TitleKind = .document,
                    buttons: WindowButtons = [.close, .minimize, .zoom, .fullScreen]) -> FloatFeatures {
    FloatFeatures(app: app, subrole: subrole, resizable: true, buttons: buttons,
                  size: CGSize(width: 900, height: 600), screenShare: share, title: title)
}

/// A small utility window of the same app, the kind people float.
private let palette = window(share: 0.05, title: .utility, buttons: [.close])

private func floated(_ f: FloatFeatures, at time: Double = t0) -> FloatEvent {
    .corrected(f, to: .float, by: .toggle, at: time)
}

private func tiled(_ f: FloatFeatures, at time: Double = t0) -> FloatEvent {
    .corrected(f, to: .tile, by: .toggle, at: time)
}

@Suite struct FloatClassifierLearns {
    @Test func withNothingLearnedTheRulesDecide() {
        let model = FloatClassifier()
        let first = model.decide(window(), rule: .tile)
        #expect(first.choice == .tile && first.source == .rule)
        #expect(abs(first.floatProbability - 0.1) < 1e-9)
        #expect(model.decide(palette, rule: .float).choice == .float)
        #expect(model.decide(palette, rule: .float).source == .rule)
    }

    @Test func oneCorrectionFloatsTheNextWindowOfThatKind() {
        var model = FloatClassifier()
        model.learn(floated(palette), now: t0)
        let next = model.decide(palette, rule: .tile)
        #expect(next.choice == .float)
        #expect(next.source == .learned)
    }

    @Test func aDocumentWindowTakesTwoCorrections() {
        let document = window(share: 0.3, title: .document)
        #expect(document.looksLikeDocument)
        #expect(!palette.looksLikeDocument)
        var model = FloatClassifier()
        model.learn(floated(document, at: t0), now: t0)
        #expect(model.decide(document, rule: .tile).choice == .tile) // once can be a one-off
        model.learn(floated(document, at: t0 + 60), now: t0 + 60)
        #expect(model.decide(document, rule: .tile).choice == .float)
    }

    @Test func otherKindsOfWindowAndOtherAppsAreLeftAlone() {
        var model = FloatClassifier()
        model.learn(floated(palette), now: t0)
        #expect(model.decide(window(share: 0.6), rule: .tile).choice == .tile)
        #expect(model.decide(window(title: .utility), rule: .tile).choice == .tile)
        #expect(model.decide(window("com.example.mail", share: 0.05, title: .utility, buttons: [.close]), rule: .tile).choice == .tile)
    }

    @Test func itNeverGoesAgainstYourLatestCorrection() {
        var model = FloatClassifier()
        for i in 0..<5 { model.learn(floated(palette, at: t0 + Double(i)), now: t0 + 10) }
        #expect(model.decide(palette, rule: .tile).choice == .float)
        model.learn(tiled(palette, at: t0 + 20), now: t0 + 20)
        let after = model.decide(palette, rule: .tile)
        #expect(after.choice == .tile)
        #expect(after.floatProbability > FloatClassifier.threshold) // plenty of evidence, but you said tile last
    }

    @Test func changingYourMindGoesBackToTheRules() {
        var model = FloatClassifier()
        model.learn(floated(palette, at: t0), now: t0)
        model.learn(tiled(palette, at: t0 + 1), now: t0 + 1)
        let d = model.decide(palette, rule: .tile)
        #expect(d.choice == .tile)
        #expect(d.source == .rule)
    }

    @Test func aWindowTheRulesFloatCanBeTaughtToTile() {
        let player = window("com.apple.QuickTimePlayerX")
        var model = FloatClassifier()
        model.learn(tiled(player), now: t0)
        let next = model.decide(player, rule: .float)
        #expect(next.choice == .tile)
        #expect(next.source == .learned)
    }

    @Test func hintsAloneNeverOverrideTheRules() {
        var model = FloatClassifier()
        for i in 0..<200 {
            model.learn(.closed(palette, as: .tile, source: .rule, lifetime: 0.5, at: t0 + Double(i)), now: t0 + 200)
        }
        let d = model.decide(palette, rule: .tile)
        #expect(d.floatProbability > FloatClassifier.threshold) // the hints all say float...
        #expect(d.choice == .tile)                              // ...but you never did
        #expect(d.source == .rule)
    }

    @Test func windowsYouLeftTiledDontHoldBackACorrection() {
        var model = FloatClassifier()
        for i in 0..<30 {
            model.learn(.closed(palette, as: .tile, source: .rule, lifetime: 600, at: t0 + Double(i)), now: t0 + 30)
        }
        #expect(model.bySignature.isEmpty) // putting up with the rules isn't evidence
        model.learn(floated(palette, at: t0 + 40), now: t0 + 40)
        #expect(model.decide(palette, rule: .tile).choice == .float)
    }

    @Test func aLessonYouLiveWithLasts() {
        let lesson = floated(palette, at: t0)
        // Floating windows of that kind, each left open a while, every month since.
        let livedWith = (1...6).map { month in
            FloatEvent.closed(palette, as: .float, source: .learned, lifetime: 900, at: t0 + Double(month) * 30 * day)
        }
        let later = t0 + 200 * day
        #expect(FloatClassifier.replay([lesson] + livedWith, now: later).decide(palette, rule: .tile).choice == .float)
        #expect(FloatClassifier.replay([lesson], now: later).decide(palette, rule: .tile).choice == .tile)
    }

    @Test func onlyClosesThatSaySomethingAreKept() {
        #expect(FloatClassifier.evidence(in: .closed(palette, as: .tile, source: .rule, lifetime: 600, at: t0)) == nil)
        #expect(FloatClassifier.evidence(in: .closed(palette, as: .float, source: .you, lifetime: 600, at: t0)) == nil)
        #expect(FloatClassifier.evidence(in: .closed(palette, as: .float, source: .learned, lifetime: 30, at: t0)) == nil)
        #expect(FloatClassifier.evidence(in: .closed(palette, as: .float, source: .learned, lifetime: 600, at: t0))! == (.float, 0.25))
        #expect(FloatClassifier.evidence(in: .closed(palette, as: .tile, source: .rule, lifetime: 1, at: t0))! == (.float, 0.25))
        #expect(FloatClassifier.evidence(in: floated(palette))! == (.float, 1))
    }

    @Test func windowsYouChoseForAreNotCountedTwice() {
        var model = FloatClassifier()
        model.learn(floated(palette), now: t0)
        let before = model.bySignature
        model.learn(.closed(palette, as: .float, source: .you, lifetime: 900, at: t0 + 900), now: t0 + 900)
        #expect(model.bySignature == before)
    }

    @Test func evidenceFadesOverMonths() {
        let model = FloatClassifier()
        #expect(abs(model.decay(from: t0, to: t0 + 180 * day) - 0.5) < 1e-9)
        #expect(model.decay(from: t0, to: t0) == 1)
        // One correction a year ago no longer outweighs the rules.
        let old = FloatClassifier.replay([floated(palette, at: t0)], now: t0 + 365 * day)
        #expect(old.decide(palette, rule: .tile).choice == .tile)
        let fresh = FloatClassifier.replay([floated(palette, at: t0)], now: t0 + day)
        #expect(fresh.decide(palette, rule: .tile).choice == .float)
    }

    @Test func manyKindsFloatedMakeTheWholeAppFloat() {
        var model = FloatClassifier()
        let kinds = [TitleKind.utility, .empty, .app, .document].flatMap { title in
            [0.05, 0.2].map { window(share: $0, title: title, buttons: [.close]) }
        }
        for (i, kind) in kinds.enumerated() { model.learn(floated(kind, at: t0 + Double(i)), now: t0 + 10) }
        // A kind never corrected, in an app you always float.
        #expect(model.decide(window(share: 0.6), rule: .tile).choice == .float)
        #expect(model.decide(window("com.example.mail", share: 0.6), rule: .tile).choice == .tile)
    }

    @Test func replayingTheLogLearnsTheSameAsLearningAsItHappened() {
        let events: [FloatEvent] = [
            floated(palette, at: t0),
            .closed(window(), as: .tile, source: .rule, lifetime: 120, at: t0 + 5),
            .closed(palette, as: .tile, source: .rule, lifetime: 1, at: t0 + 6),
            tiled(window("com.apple.QuickTimePlayerX"), at: t0 + 7),
        ]
        var live = FloatClassifier()
        for e in events { live.learn(e, now: t0 + 10) }
        let replayed = FloatClassifier.replay(events.reversed(), now: t0 + 10)
        #expect(replayed.bySignature == live.bySignature)
        #expect(replayed.byApp == live.byApp)
    }

    @Test func decidingTakesAboutAMicrosecond() {
        var model = FloatClassifier()
        for i in 0..<1000 { model.learn(floated(window("com.example.app\(i)", share: 0.05, title: .utility)), now: t0) }
        let probe = window("com.example.app500", share: 0.05, title: .utility)
        let clock = ContinuousClock()
        var floats = 0
        let elapsed = clock.measure {
            for _ in 0..<100_000 where model.decide(probe, rule: .tile).choice == .float { floats += 1 }
        }
        #expect(floats == 100_000)
        // Generous, so a busy machine doesn't fail it: 10 µs each at most (the budget is 1 ms).
        #expect(elapsed < .seconds(1))
    }
}

@Suite struct WindowKinds {
    @Test func titlesAreSortedNotKept() {
        #expect(TitleKind(title: nil, appName: "Notes") == .empty)
        #expect(TitleKind(title: "  ", appName: "Notes") == .empty)
        #expect(TitleKind(title: "Notes", appName: "Notes") == .app)
        #expect(TitleKind(title: "Settings — General", appName: "Notes") == .utility)
        #expect(TitleKind(title: "Downloads", appName: "Safari") == .utility)
        #expect(TitleKind(title: "Picture in Picture", appName: "Safari") == .utility)
        #expect(TitleKind(title: "Q3 report.pages", appName: "Pages") == .document)
        // Whole words only: "informational" isn't "info".
        #expect(TitleKind(title: "Informational memo", appName: "Pages") == .document)
    }

    @Test func lessonsInWords() {
        #expect(palette.kindInWords == "small tool windows")
        #expect(window(share: 0.6).kindInWords == "large document windows")
        #expect(window(subrole: "AXFloatingWindow").kindInWords == "medium panels")
        var model = FloatClassifier()
        model.learn(floated(palette), now: t0)
        model.learn(floated(window(share: 0.6), at: t0 + 1), now: t0 + 1) // once isn't a lesson for a document
        let lessons = model.lessons { _ in .tile }
        #expect(lessons.map(\.signature) == [palette.signature])
        #expect(lessons.first?.choice == .float)
    }

    @Test func sizeClassesAndSignatures() {
        #expect(window(share: 0.05).sizeClass == "s")
        #expect(window(share: 0.2).sizeClass == "m")
        #expect(window(share: 0.5).sizeClass == "l")
        #expect(palette.signature == "com.example.notes|std|1|s|utility")
        #expect(window(subrole: "AXFloatingWindow").signature == "com.example.notes|AXFloatingWindow|15|m|document")
        var limited = palette
        limited.sizeLimited = true
        #expect(limited.signature == palette.signature) // only known later, so not part of the kind
    }

    @Test func eventsSurviveTheLog() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tessel-float-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EventLog<FloatEvent>(folder: folder, name: "float")
        let events: [FloatEvent] = [floated(palette), .closed(window(), as: .tile, source: .learned, lifetime: 61.23, at: t0 + 61)]
        for e in events { try log.append(e) }
        let back = log.read(now: t0 + 100)
        #expect(back.count == 2)
        #expect(back[0] == events[0])
        #expect(back[1].lifetime == 61.2)
        // Nothing but the kind of window, the choice and the timing is written down.
        let text = try String(contentsOf: log.current, encoding: .utf8)
        #expect(!text.contains("Notes"))
        #expect(text.contains("\"title\":\"utility\""))
    }
}
