import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI

/// Symbol names for speaker editing surfaces (rule A3).
enum EditorSymbol {
    static let relabeled = "arrow.triangle.2.circlepath"
}

/// Inline, solid notice that the final speaker pass relabelled live labels. Shown once per transcript (DIA-AC-06): the
/// report is marked acknowledged on dismiss or when the editor closes, so labels never flip or flag again.
struct ReconciliationBanner: View {
    let report: ReconciliationReport
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            Image(systemName: EditorSymbol.relabeled).foregroundStyle(DSColor.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text("Speaker labels were refined").font(DSTypography.headline)
                Text(
                    "The final pass relabelled \(report.relabeledSegmentIDs.count) of \(report.totalSegments) segments. They are marked in the speaker column."
                )
                .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            Spacer()
            Button("Dismiss", action: onDismiss).accessibilityIdentifier("editor.reconciliation.dismiss")
        }
        .padding(DSSpacing.md)
        .background(DSColor.contentBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(DSColor.hairline).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Speaker labels were refined")
        .accessibilityIdentifier("editor.reconciliation")
    }
}
