import AppKit
import DesignSystem
import LiveCaptions
import SwiftUI

/// "Display" and "Position" sections of Settings > Live Captions. Native controls on the grouped form; the position
/// picker is a 3x3 grid drawn as a miniature screen. Every change moves the live overlay or a test caption at once.
struct OverlayPlacementSection: View {
    let model: OverlayPlacementSettingsModel

    private var choiceBinding: Binding<DisplayChoice> {
        Binding(get: { model.choice }, set: { value in Task { await model.selectChoice(value) } })
    }

    private var draggingBinding: Binding<Bool> {
        Binding(get: { model.allowsDragging }, set: { value in Task { await model.setAllowsDragging(value) } })
    }

    var body: some View {
        Group {
            displaySection
            positionSection
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            model.refreshDisplays()
        }
    }

    private var displaySection: some View {
        Section {
            Picker("Show captions on", selection: choiceBinding) {
                ForEach(model.choiceOptions) { option in Text(option.title).tag(option.id) }
            }
            .accessibilityIdentifier("liveCaptions.placement.display")
        } header: {
            Text("Display")
        } footer: {
            Text(
                model.isChosenDisplayMissing
                    ? "That display is not connected, so captions are on the main display. They return when it is plugged in again."
                    : "If a display is unplugged, captions move to the main display.")
        }
    }

    private var positionSection: some View {
        Section {
            LabeledContent("Position") {
                VStack(alignment: .trailing, spacing: DSSpacing.sm) {
                    PositionGrid(selection: model.position) { p in Task { await model.selectPosition(p) } }
                    Button("Custom") { Task { await model.selectPosition(.custom) } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(model.position == .custom ? DSColor.accent : nil)
                        .accessibilityLabel(Text("Custom position"))
                        .accessibilityValue(Text(model.position == .custom ? "Selected" : "Not selected"))
                        .accessibilityIdentifier("liveCaptions.placement.custom")
                }
            }
            Toggle("Drag captions without holding Option", isOn: draggingBinding)
                .accessibilityIdentifier("liveCaptions.placement.drag")
            HStack {
                Button("Show test caption") { Task { await model.showTestCaption() } }
                    .disabled(!model.canPreview)
                    .accessibilityIdentifier("liveCaptions.placement.testCaption")
                Button("Reset position") { Task { await model.resetPosition() } }
                    .accessibilityIdentifier("liveCaptions.placement.reset")
            }
        } header: {
            Text("Position")
        } footer: {
            Text(
                "Hold Option and drag the captions, or turn on dragging above, to set a custom position. It is remembered for each display and caption preset.")
        }
    }
}

/// Nine cells (top/middle/bottom by left/centre/right) on a miniature screen.
struct PositionGrid: View {
    let selection: OverlayPosition
    let onSelect: (OverlayPosition) -> Void

    private static let cellSize = CGSize(width: 44, height: 28)

    var body: some View {
        Grid(horizontalSpacing: DSSpacing.xs, verticalSpacing: DSSpacing.xs) {
            ForEach(Array(OverlayPosition.gridRows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row, id: \.self) { position in
                        let selected = selection == position
                        Button {
                            onSelect(position)
                        } label: {
                            RoundedRectangle(cornerRadius: DSRadius.small, style: .continuous)
                                .fill(selected ? DSColor.accent : DSColor.hairline.opacity(0.5))
                                .frame(width: Self.cellSize.width, height: Self.cellSize.height)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(position.title))
                        .accessibilityValue(Text(selected ? "Selected" : "Not selected"))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("liveCaptions.placement.cell.\(position.rawValue)")
                    }
                }
            }
        }
        .padding(DSSpacing.sm)
        .background(DSColor.contentBackground, in: RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous).strokeBorder(DSColor.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Caption position"))
        .accessibilityIdentifier("liveCaptions.placement.grid")
    }
}
