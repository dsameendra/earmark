import AppCore
import DesignSystem
import SwiftUI

/// Preset controls from the Components board: size step, 1-3 lines, background opacity, plus label toggles.
/// Solid surface (no glass), so it can sit in Settings or the Live view. M8 restyles it.
public struct CaptionPresetControls: View {
    @Binding private var preset: CaptionPreset
    public init(preset: Binding<CaptionPreset>) { _preset = preset }

    private var sizeStep: Binding<CaptionSizeStep> {
        Binding(
            get: { CaptionSizeStep.nearest(to: preset.fontSize) },
            set: { preset.fontSize = $0.fontSize })
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            LabeledContent("Size") {
                Picker("Size", selection: sizeStep) {
                    ForEach(CaptionSizeStep.allCases) { step in Text(step.title).tag(step) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("liveCaptions.preset.size")
            }
            LabeledContent("Lines") {
                Picker("Lines", selection: $preset.visibleLines) {
                    ForEach(1...3, id: \.self) { n in Text("\(n)").tag(n) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("liveCaptions.preset.lines")
            }
            LabeledContent("Opacity") {
                Slider(value: $preset.backgroundOpacity, in: 0.2...1)
                    .accessibilityIdentifier("liveCaptions.preset.opacity")
                    .accessibilityLabel(Text("Background opacity"))
            }
            Toggle("Show speaker labels", isOn: $preset.showSpeakerLabels)
                .accessibilityIdentifier("liveCaptions.preset.speakerLabels")
            Toggle("Show language badge", isOn: $preset.showLanguageBadge)
                .accessibilityIdentifier("liveCaptions.preset.languageBadge")
        }
        .padding(DSSpacing.lg)
        .background(DSColor.contentBackground, in: RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous))
        .disabled(preset.isBuiltIn)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveCaptions.preset.controls")
    }
}
