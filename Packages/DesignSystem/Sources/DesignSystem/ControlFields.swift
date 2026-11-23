import SwiftUI

/// A compact segmented control whose selected pill fills the control's full inner height.
///
/// The system segmented control inside a large toolbar draws a pill shorter than its frame. This one insets the pill
/// evenly (concentric with the capsule), animates it with the settle curve and keeps full-segment hit targets.
public struct DSSegmentedControl<Value: Hashable>: View {
    public struct Option: Identifiable {
        public let value: Value
        public let title: String
        /// When set the segment shows only this symbol; `title` is still the accessibility label and tooltip.
        public let systemImage: String?
        public var id: Value { value }
        public init(_ title: String, value: Value, systemImage: String? = nil) {
            self.value = value
            self.title = title
            self.systemImage = systemImage
        }
    }

    private let options: [Option]
    private let identifier: String
    @Binding private var selection: Value
    @Namespace private var pillSpace
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered: Value?

    public init(selection: Binding<Value>, options: [Option], identifier: String) {
        _selection = selection
        self.options = options
        self.identifier = identifier
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Group {
                        if let symbol = option.systemImage {
                            Image(systemName: symbol)  // stock-chrome: layout glyphs
                                .font(DSTypography.body.weight(selected ? .semibold : .regular))
                        } else {
                            Text(option.title).font(DSTypography.body.weight(selected ? .semibold : .regular))
                        }
                    }
                    .foregroundStyle(selected ? DSColor.primaryText : DSColor.secondaryText)
                    .padding(.horizontal, option.systemImage == nil ? DSSpacing.md : DSSpacing.lg)
                    .frame(maxHeight: .infinity)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background {
                    if selected {
                        Capsule().fill(DSColor.selectionPill).matchedGeometryEffect(id: "pill", in: pillSpace)
                    } else if hovered == option.value, isEnabled {
                        // Hover feedback for the segments that are not selected: the same full-height capsule, fainter.
                        Capsule().fill(DSColor.primaryText.opacity(0.08))
                    }
                }
                .onHover { inside in
                    if inside { hovered = option.value } else if hovered == option.value { hovered = nil }
                }
                .help(option.title)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("\(identifier).\(option.id)")
            }
        }
        .padding(DSSpacing.xxs)
        .frame(height: 32)
        .background(Capsule().fill(DSColor.contentBackground.opacity(0.5)))
        .overlay(Capsule().strokeBorder(DSColor.hairline))
        .opacity(isEnabled ? 1 : 0.5)
        .dsAnimation(.settle, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// A full-width, left-aligned menu field: current value on the left, a chevron on the right, filling its container.
public struct DSMenuField<MenuContent: View>: View {
    private let value: String
    private let content: MenuContent
    @Environment(\.isEnabled) private var isEnabled

    public init(value: String, @ViewBuilder content: () -> MenuContent) {
        self.value = value
        self.content = content()
    }

    public var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: DSSpacing.sm) {
                Text(value).font(DSTypography.body).foregroundStyle(DSColor.primaryText).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: DSSpacing.xs)
                Image(systemName: "chevron.up.chevron.down")  // stock-chrome: disclosure indicator
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            .padding(.horizontal, DSSpacing.md)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DSRadius.medium).fill(DSColor.contentBackground))
            .overlay(RoundedRectangle(cornerRadius: DSRadius.medium).strokeBorder(DSColor.hairline))
            .contentShape(RoundedRectangle(cornerRadius: DSRadius.medium))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .opacity(isEnabled ? 1 : 0.5)
    }
}
