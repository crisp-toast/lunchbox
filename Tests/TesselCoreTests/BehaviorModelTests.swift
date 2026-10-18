import Foundation
import Testing
@testable import TesselCore

private let floating = WindowBehavior.floatingApps

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
        // Never asked about: a fixed-size window that can't be minimized is centered like a dialog,
        // and one that isn't window-like keeps floating.
        let about = WindowTraits(app: "com.example.app", title: "Report.pages", resizable: false, minimizable: false,
                                 width: 1200, height: 800, screenShare: 0.5)
        #expect(BehaviorDecision.combine(about, rule: .dialog, model: .document, confidence: 0.99, threshold: 0.5, floatingApps: floating) == .dialog)
        let palette = WindowTraits(app: "com.example.app", subrole: "AXFloatingWindow", title: "Report.pages", buttons: [.close],
                                   width: 1200, height: 800, screenShare: 0.5)
        #expect(BehaviorDecision.combine(palette, rule: .panel, model: .document, confidence: 0.99, threshold: 0.5, floatingApps: floating) == .panel)
        let overlay = WindowTraits(app: "com.apple.screencaptureui", title: "clip.mov", width: 1280, height: 720, screenShare: 0.5)
        #expect(BehaviorDecision.combine(overlay, rule: .panel, model: .document, confidence: 0.99, threshold: 0.5, floatingApps: floating) == .panel)
    }

    @Test func itDecidesWhetherAFixedSizeWindowTiles() {
        // The rules tile Calculator at its own size; the model may float it, or keep it tiled.
        let calculator = WindowTraits(app: "com.apple.calculator", title: "Calculator", resizable: false, minimizable: true,
                                      width: 230, height: 400, screenShare: 0.03)
        #expect(WindowBehavior.hardRule(calculator) == nil)
        #expect(BehaviorDecision.combine(calculator, rule: .document, model: .panel, confidence: 0.9, threshold: 0.5, floatingApps: floating) == .panel)
        #expect(BehaviorDecision.combine(calculator, rule: .document, model: .document, confidence: 0.9, threshold: 0.5, floatingApps: floating) == .document)
        // A resizable floating window with every title-bar button may be tiled.
        let fonts = WindowTraits(app: "com.example.app", subrole: "AXFloatingWindow", title: "Fonts", buttons: [.close, .minimize, .zoom])
        #expect(WindowBehavior.hardRule(fonts) == nil)
        #expect(BehaviorDecision.combine(fonts, rule: .panel, model: .document, confidence: 0.9, threshold: 0.5, floatingApps: floating) == .document)
    }

    @Test func unsureMeansTheRules() {
        let t = WindowTraits(app: "com.example.app", title: "Notes")
        #expect(BehaviorDecision.combine(t, rule: .document, model: .panel, confidence: 0.4, threshold: 0.5, floatingApps: floating) == .document)
        #expect(BehaviorDecision.combine(t, rule: .document, model: .panel, confidence: 0.6, threshold: 0.5, floatingApps: floating) == .panel)
    }

    @Test func todaysRulesInTheSameTerms() {
        func rules(_ t: WindowTraits) -> WindowBehavior { WindowBehavior.byRules(t, floatingApps: floating) }
        #expect(rules(WindowTraits(app: "com.example.app")) == .document)
        #expect(rules(WindowTraits(app: "com.example.app", subrole: "AXFloatingWindow")) == .panel)
        #expect(rules(WindowTraits(app: "com.example.app", hasDefaultButton: true, hasCancelButton: true)) == .dialog)
        #expect(rules(WindowTraits(app: "com.apple.screencaptureui")) == .panel)
        // Only overlays always float: System Settings and Calculator tile, Calculator at its own size.
        #expect(rules(WindowTraits(app: "com.apple.systempreferences", buttons: [.close, .minimize, .zoom])) == .document)
        #expect(rules(WindowTraits(app: "com.apple.calculator", resizable: false, minimizable: true)) == .document)
        // Can't be resized or minimized (an About box, a settings window): centered, like a dialog.
        #expect(rules(WindowTraits(app: "com.example.app", buttons: [.close, .minimize, .zoom], resizable: false, minimizable: false)) == .dialog)
        // Read before Tessel noted whether it can be minimized: a minimize button stands in.
        #expect(rules(WindowTraits(app: "com.example.app", buttons: [.close, .minimize, .zoom], resizable: false)) == .document)
        #expect(rules(WindowTraits(app: "com.example.app", buttons: [.close], resizable: false)) == .dialog)
        // A "dialog" that resizes, has every title-bar button and asks nothing is a window (Little Arc).
        let littleArc = WindowTraits(app: "company.thebrowser.Browser", subrole: "AXSystemDialog", buttons: [.close, .minimize, .zoom])
        #expect(rules(littleArc) == .document)
        #expect(WindowBehavior.hardRule(littleArc) == nil)
        var fixedArc = littleArc
        fixedArc.resizable = false
        #expect(rules(fixedArc) == .dialog)
        var asking = littleArc
        asking.modal = true
        #expect(rules(asking) == .dialog)
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
