import Foundation
import Testing

/// Source guard: toolbar hover/pressed highlights must fit the padded button, so horizontal padding lives INSIDE the
/// control's label (`DSToolbarLabel`), never outside via `.padding` after `dsToolbarControl()`.
@Suite("Toolbar control guard") struct ToolbarControlGuardTests {
    @Test func everyToolbarControlPadsInsideItsLabel() {
        var checked = 0
        for file in DesignGuardTests.sourceFiles() where file.code.contains(".dsToolbarControl()") {
            let controls = file.code.components(separatedBy: ".dsToolbarControl()").count - 1
            let labels = file.code.components(separatedBy: "DSToolbarLabel(").count - 1
            let segmented = file.code.components(separatedBy: ".pickerStyle(.segmented)").count - 1
            #expect(labels + segmented >= controls, "\(file.path): \(controls) toolbar controls but \(labels) DSToolbarLabel + \(segmented) segmented")
            checked += controls
        }
        #expect(checked >= 20, "guard found only \(checked) toolbar controls")
    }

    @Test func noPaddingOutsideToolbarControls() {
        for file in DesignGuardTests.sourceFiles() {
            let lines = file.code.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, line) in lines.enumerated() where line.contains(".dsToolbarControl()") {
                let next = lines.dropFirst(i + 1).prefix(1).joined()
                #expect(!next.contains(".padding("), "\(file.path):\(i + 1) pads outside the highlight; pad inside DSToolbarLabel")
                #expect(!line.contains(".padding("), "\(file.path):\(i + 1) pads outside the highlight")
            }
        }
    }
}
