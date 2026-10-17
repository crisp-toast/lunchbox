import Foundation
import Testing
@testable import TesselCore

private let floating: Set<String> = ["com.apple.QuickTimePlayerX", "com.apple.systempreferences", "com.apple.calculator"]

private struct Labeled: Decodable {
    var id: Int
    var label: WindowBehavior
    var traits: WindowTraits
}

/// The labeled windows the base model was trained on (Training/windows.jsonl).
private func labeled() throws -> [Labeled] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Training/windows.jsonl")
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        .map { try JSONDecoder().decode(Labeled.self, from: Data($0.utf8)) }
}

@Suite struct WindowClassifier {
    @Test func theBaseModelShipsAndLoads() throws {
        let model = try #require(BehaviorModel.base)
        #expect(model.classes == WindowBehavior.allCases)
        #expect(model.trainedOn > 50)
        #expect((0.5...0.95).contains(model.threshold))
    }

    @Test func itRecognizesTheWindowsItLearnedFrom() throws {
        let model = try #require(BehaviorModel.base)
        let windows = try labeled()
        let right = windows.filter { w in
            BehaviorDecision.decide(w.traits, model: model, meaning: TitleMeaning.shared.vector(w.traits.title),
                                    floatingApps: floating).behavior == w.label
        }
        // In-sample, as a check that the weights and the code agree; held-out numbers are in docs/window-classifier.md.
        #expect(Double(right.count) / Double(windows.count) > 0.85)
    }

    @Test func aDialogByTheRulesIsAlwaysADialog() throws {
        let model = try #require(BehaviorModel.base)
        let alert = WindowTraits(app: "com.example.app", subrole: "AXDialog", title: "Untitled document.txt", buttons: [])
        #expect(BehaviorDecision.decide(alert, model: model, meaning: [], floatingApps: floating).behavior == .dialog)
        let panel = WindowTraits(app: "com.example.app", identifier: "open-panel", title: "Open")
        #expect(BehaviorDecision.decide(panel, model: model, meaning: [], floatingApps: floating).behavior == .dialog)
    }

    @Test func itNeverTilesWhatCantOrMustntTile() {
        let fixed = WindowTraits(app: "com.example.app", title: "Report.pages", resizable: false, width: 1200, height: 800, screenShare: 0.5)
        #expect(BehaviorDecision.combine(fixed, rule: .panel, model: .document, confidence: 0.99, threshold: 0.5, floatingApps: floating) == .panel)
        let movie = WindowTraits(app: "com.apple.QuickTimePlayerX", title: "clip.mp4", width: 1280, height: 720, screenShare: 0.5)
        #expect(BehaviorDecision.combine(movie, rule: .panel, model: .document, confidence: 0.99, threshold: 0.5, floatingApps: floating) == .panel)
    }

    @Test func unsureMeansTheRules() {
        let t = WindowTraits(app: "com.example.app", title: "Notes")
        #expect(BehaviorDecision.combine(t, rule: .document, model: .panel, confidence: 0.4, threshold: 0.5, floatingApps: floating) == .document)
        #expect(BehaviorDecision.combine(t, rule: .document, model: .panel, confidence: 0.6, threshold: 0.5, floatingApps: floating) == .panel)
    }

    @Test func todaysRulesInTheSameTerms() {
        #expect(WindowBehavior.byRules(WindowTraits(app: "com.example.app"), floatingApps: floating) == .document)
        #expect(WindowBehavior.byRules(WindowTraits(app: "com.apple.calculator"), floatingApps: floating) == .panel)
        #expect(WindowBehavior.byRules(WindowTraits(app: "com.example.app", subrole: "AXFloatingWindow"), floatingApps: floating) == .panel)
        #expect(WindowBehavior.byRules(WindowTraits(app: "com.example.app", hasDefaultButton: true, hasCancelButton: true), floatingApps: floating) == .dialog)
    }

    @Test func titlesAreReadNotKept() {
        let t = WindowTraits(app: "com.example.app", title: "Secret plans.pages")
        #expect(t.withoutTitle.title == nil)
        let features = BehaviorFeatures.title(t)
        #expect(features.count == BehaviorFeatures.titleNames.count)
        #expect(BehaviorFeatures.structure(t).count == BehaviorFeatures.structureNames.count)
    }

    @Test func aDecisionTakesWellUnderAMillisecond() throws {
        let model = try #require(BehaviorModel.base)
        let windows = try labeled()
        let clock = ContinuousClock()
        var tiled = 0
        let elapsed = clock.measure {
            for _ in 0..<20 {
                for w in windows {
                    let meaning = TitleMeaning.shared.vector(w.traits.title)
                    if BehaviorDecision.decide(w.traits, model: model, meaning: meaning, floatingApps: floating).behavior.tiles { tiled += 1 }
                }
            }
        }
        #expect(tiled > 0)
        // 20 × the labeled set; generous for a debug build on a busy machine (about 0.05 ms each in release).
        #expect(elapsed < .milliseconds(Double(20 * windows.count)))
    }
}
