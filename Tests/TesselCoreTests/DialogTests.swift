import CoreGraphics
import Testing
@testable import TesselCore

@Suite struct DialogsFloat {
    @Test func alertsAndPromptsAreDialogs() {
        #expect(Dialogs.isDialog(subrole: "AXDialog", identifier: nil, hasDefaultButton: true, hasCancelButton: true, modal: false))
        #expect(Dialogs.isDialog(subrole: "AXSystemDialog", identifier: nil, hasDefaultButton: false, hasCancelButton: false, modal: false))
    }

    @Test func openAndSavePanelsAreDialogsThoughTheyLookStandard() {
        #expect(Dialogs.isDialog(subrole: "AXStandardWindow", identifier: "open-panel", hasDefaultButton: false, hasCancelButton: false, modal: false))
        #expect(Dialogs.isDialog(subrole: "AXStandardWindow", identifier: "save-panel", hasDefaultButton: false, hasCancelButton: false, modal: false))
    }

    @Test func okAndCancelMeansAsking() {
        #expect(Dialogs.isDialog(subrole: "AXStandardWindow", identifier: nil, hasDefaultButton: true, hasCancelButton: true, modal: false))
        #expect(Dialogs.isDialog(subrole: "AXStandardWindow", identifier: nil, hasDefaultButton: false, hasCancelButton: false, modal: true))
    }

    @Test func documentWindowsAreNot() {
        #expect(!Dialogs.isDialog(subrole: "AXStandardWindow", identifier: nil, hasDefaultButton: false, hasCancelButton: false, modal: false))
        #expect(!Dialogs.isDialog(subrole: "AXStandardWindow", identifier: "main", hasDefaultButton: true, hasCancelButton: false, modal: false))
    }

    @Test func centeredOnTheScreenAndKeptOnIt() {
        let area = CGRect(x: 0, y: 30, width: 2560, height: 1410)
        #expect(Dialogs.centeredOrigin(for: CGSize(width: 880, height: 448), in: area) == CGPoint(x: 840, y: 511))
        #expect(Dialogs.centeredOrigin(for: CGSize(width: 3000, height: 2000), in: area) == CGPoint(x: 0, y: 30))
    }
}
