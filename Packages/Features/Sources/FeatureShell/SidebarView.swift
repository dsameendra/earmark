import AppCore
import DesignSystem
import FeatureLibrary
import FeatureSupport
import SwiftUI

/// How one sidebar row is drawn for a given selection (pure, so tests can pin it without rendering).
public struct SidebarRowAppearance: Equatable, Sendable {
    public var isSelected: Bool
    /// Duotone (ink plus Ember detail) when selected, monochrome at rest (`Icons` board, sidebar states).
    public var symbolStyle: DSSymbolStyle
    public var isBold: Bool

    public init(section: AppSection, selection: AppSection) {
        isSelected = section == selection
        symbolStyle = isSelected ? .duotone : .monochrome
        isBold = isSelected
    }
}

/// The sidebar column: brand, six section rows with one gliding selection pill, folders, model chip and Settings.
///
/// The column itself is the system `NavigationSplitView` sidebar (macOS 26 glass material, glass layer 1 of 3), so
/// no glass modifier is applied here; rows, chip and badges are solid content. The selection pill is a single shape
/// that glides between rows with the `glide` motion token (200-280 ms) and crossfades under Reduce Motion.
struct SidebarView: View {
    @Bindable var model: ShellModel
    @Namespace private var pillSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPolicyOverride) private var policyOverride

    private var motionReduced: Bool { policyOverride?.suppressesMotion ?? reduceMotion }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    brand
                    if model.isRecordingActive { recordingRow }
                    ForEach(AppSection.allCases) { section in row(section) }
                    if !model.sidebar.folders.isEmpty { folders }
                }
            }
            .scrollIndicators(.hidden)
            if let chip = model.sidebar.modelChip { ModelChipView(chip: chip) }
            settingsRow
        }
        .padding(.horizontal, DSSpacing.sm)
        .padding(.bottom, DSSpacing.sm)
        .dsAnimation(.glide, value: model.selection)
        .dsIconContext(.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }

    // MARK: Brand

    private var brand: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text("earmark").font(.system(size: 22, design: .serif)).foregroundStyle(DSColor.primaryText)
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.top, DSSpacing.xs)
        .padding(.bottom, DSSpacing.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Earmark")
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Section rows

    private func row(_ section: AppSection) -> some View {
        let look = SidebarRowAppearance(section: section, selection: model.selection)
        return Button {
            model.select(section)
        } label: {
            HStack(spacing: 11) {
                DSIcon(section.symbol, style: look.symbolStyle).font(.system(size: 17)).frame(width: 22)
                    .foregroundStyle(look.isSelected ? DSColor.primaryText : DSColor.secondaryText)
                Text(section.title).fontWeight(look.isBold ? .semibold : .regular)
                Spacer(minLength: DSSpacing.xs)
                if section == .queue, let badge = model.sidebar.queueBadge { Badge(text: badge) }
            }
            .foregroundStyle(look.isSelected ? DSColor.primaryText : DSColor.secondaryText)
            .padding(.horizontal, 10)
            .frame(minHeight: DSLayout.minControlHeight + 6)
            .background { if look.isSelected { pill } }
            .contentShape(RoundedRectangle(cornerRadius: DSRadius.medium + 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityHint("Command \(section.shortcutNumber)")
        .accessibilityAddTraits(look.isSelected ? .isSelected : [])
        .accessibilityIdentifier(section.accessibilityIdentifier)
    }

    /// The single selection pill. Glides between rows (matched geometry) or crossfades under Reduce Motion.
    @ViewBuilder private var pill: some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.medium + 4, style: .continuous)
        let base = shape.fill(DSColor.selectionPill)
            .overlay(shape.strokeBorder(DSColor.hairline, lineWidth: 0.5))
            .shadow(color: DSColor.shadow.opacity(0.12), radius: 8, y: 3)
        if motionReduced {
            base.transition(.opacity)
        } else {
            base.matchedGeometryEffect(id: "selection-pill", in: pillSpace)
        }
    }

    // MARK: Recording

    private var recordingRow: some View {
        Button {
            model.select(model.recordingSection)
        } label: {
            HStack {
                RecordingIndicator(label: "Recording")
                Spacer(minLength: DSSpacing.xs)
                Text(model.recordingSection.title).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: DSLayout.minControlHeight + 2)
            .background(DSColor.recording.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.bottom, DSSpacing.xs)
        .accessibilityLabel("Recording in progress")
        .accessibilityHint("Opens \(model.recordingSection.title)")
        .accessibilityIdentifier("sidebar.recording")
    }

    // MARK: Folders

    private var folders: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Folders")
                .font(DSTypography.label).textCase(.uppercase).tracking(DSTypography.labelTracking)
                .foregroundStyle(DSColor.tertiaryText)
                .padding(.horizontal, DSSpacing.md).padding(.top, DSSpacing.lg).padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(model.sidebar.folders.enumerated()), id: \.element.id) { index, folder in
                Button {
                    model.openFolder(folder.id)
                } label: {
                    HStack(spacing: 10) {
                        Circle().fill(SpeakerPalette.color(forSlot: index)).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(folder.name).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(DSColor.secondaryText)
                    .padding(.horizontal, DSSpacing.md).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Folder \(folder.name)")
                .accessibilityIdentifier("sidebar.folder.\(folder.id)")
            }
        }
    }

    // MARK: Settings

    private var settingsRow: some View {
        SettingsLink {
            HStack(spacing: 11) {
                DSIcon(.settings).font(.system(size: 17)).frame(width: 22)
                Text("Settings")
                Spacer(minLength: 0)
            }
            .foregroundStyle(DSColor.secondaryText)
            .padding(.horizontal, 14)
            .frame(minHeight: DSLayout.minControlHeight + 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("sidebar.settings")
    }
}

/// Count badge: `accentText` on the Ember tint (4.5:1 in both appearances).
private struct Badge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            .foregroundStyle(DSColor.accentText)
            .frame(minWidth: 18)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(DSColor.accentTint, in: Capsule())
            .accessibilityLabel("\(text) active")
    }
}

/// Footer chip: model name, status, Ember rule and size ("Whisper large-v3 turbo  Ready").
struct ModelChipView: View {
    let chip: SidebarModelChip

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(chip.name).fontWeight(.semibold).foregroundStyle(DSColor.primaryText).lineLimit(1)
                Spacer(minLength: DSSpacing.xs)
                Text(chip.statusText)
                    .foregroundStyle(chip.status == .ready ? DSColor.success : DSColor.secondaryText)
                    .fontWeight(.semibold)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DSColor.primaryText.opacity(0.1))
                    Capsule().fill(DSColor.accent).frame(width: proxy.size.width * chip.fraction)
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
            Text(chip.detail).foregroundStyle(DSColor.secondaryText)
        }
        .font(.system(size: 12))
        .padding(.horizontal, DSSpacing.md).padding(.vertical, 10)
        .dsSolidSurface(.inset, radius: DSRadius.large)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(chip.name), \(chip.statusText)")
        .accessibilityIdentifier("sidebar.modelChip")
    }
}
