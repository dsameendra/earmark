import AppCore
import DesignSystem
import Foundation
import SwiftUI

// The one "several languages" selector, shared by the add-flow Transcribe sheet and the editor's Re-transcribe popover so both
// behave identically: a search field, the chosen languages as removable chips, a Recent / Suggested section first, then every
// other language. Languages a chosen model cannot handle are greyed out and say why.

/// Pure logic behind ``LanguageMultiSelectView``: what is listed, in which section, what a search keeps and why a row is greyed.
public struct LanguageSelectorModel: Sendable, Equatable {
    public enum SectionKind: String, Sendable, Equatable { case results, recent, suggested, other, all }

    public struct Section: Identifiable, Sendable, Equatable {
        public var kind: SectionKind
        public var title: String
        public var codes: [LanguageCode]
        public var id: String { kind.rawValue }
    }

    /// Every language that can be offered (already includes any language that is currently chosen).
    public let options: [LanguageCode]
    /// Most recently used first.
    public let recents: [LanguageCode]
    /// Languages worth offering up front, such as the Mac's preferred languages.
    public let suggested: [LanguageCode]
    /// Languages that cannot be chosen, with the one-line reason shown under the name.
    public let unsupportedReasons: [LanguageCode: String]
    /// How many languages a Recent or Suggested section may list.
    public let topLimit: Int

    public init(
        options: [LanguageCode], recents: [LanguageCode] = [], suggested: [LanguageCode] = [],
        unsupportedReasons: [LanguageCode: String] = [:], topLimit: Int = 5
    ) {
        self.options = options
        self.recents = recents
        self.suggested = suggested
        self.unsupportedReasons = unsupportedReasons
        self.topLimit = topLimit
    }

    // MARK: Names and search

    public static func name(of code: LanguageCode) -> String {
        Locale.current.localizedString(forLanguageCode: code.rawValue) ?? code.rawValue
    }

    /// The language's name in itself ("Español", "සිංහල"), shown beside the localized name when it differs.
    public static func nativeName(of code: LanguageCode) -> String? {
        guard let native = Locale(identifier: code.rawValue).localizedString(forLanguageCode: code.rawValue),
            native.caseInsensitiveCompare(name(of: code)) != .orderedSame
        else { return nil }
        return native
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// `true` when `query` (ignoring case, accents and surrounding space) occurs in the language's name, native name or code.
    public func matches(_ code: LanguageCode, query: String) -> Bool {
        let needle = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        if needle.isEmpty { return true }
        let haystacks = [Self.name(of: code), Self.nativeName(of: code) ?? "", code.rawValue]
        return haystacks.contains { Self.fold($0).contains(needle) }
    }

    private func sortedByName(_ codes: some Sequence<LanguageCode>) -> [LanguageCode] {
        codes.sorted { Self.name(of: $0).localizedStandardCompare(Self.name(of: $1)) == .orderedAscending }
    }

    // MARK: Sections

    /// Recent (used before) and Suggested sections first, then the rest. A non-empty search collapses to one "Results" section.
    public func sections(query: String = "") -> [Section] {
        let available = Set(options)
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let found = sortedByName(options.filter { matches($0, query: query) })
            return found.isEmpty ? [] : [Section(kind: .results, title: "Results", codes: found)]
        }
        var used = Set<LanguageCode>()
        var result: [Section] = []
        let recent = Array(Self.unique(recents.filter(available.contains)).prefix(topLimit))
        if !recent.isEmpty {
            result.append(Section(kind: .recent, title: "Recent", codes: recent))
            used.formUnion(recent)
        }
        let suggestions = Array(Self.unique(suggested.filter { available.contains($0) && !used.contains($0) }).prefix(topLimit))
        if !suggestions.isEmpty {
            result.append(Section(kind: .suggested, title: "Suggested", codes: suggestions))
            used.formUnion(suggestions)
        }
        let rest = sortedByName(options.filter { !used.contains($0) })
        if !rest.isEmpty {
            result.append(Section(kind: result.isEmpty ? .all : .other, title: result.isEmpty ? "All languages" : "Other languages", codes: rest))
        }
        return result
    }

    private static func unique(_ codes: [LanguageCode]) -> [LanguageCode] {
        var seen = Set<LanguageCode>()
        return codes.filter { seen.insert($0).inserted }
    }

    /// Every language shown for `query`, top to bottom: the order the arrow keys walk.
    public func visibleCodes(query: String = "") -> [LanguageCode] { sections(query: query).flatMap(\.codes) }

    // MARK: Support

    public func reason(for code: LanguageCode) -> String? { unsupportedReasons[code] }
    public func isSupported(_ code: LanguageCode) -> Bool { unsupportedReasons[code] == nil }

    /// A language that is already chosen can always be removed, even when it became unsupported.
    public func isSelectable(_ code: LanguageCode, selection: Set<LanguageCode>) -> Bool {
        isSupported(code) || selection.contains(code)
    }

    /// Why each language is unavailable for `model` (`nil` model = Automatic: everything the catalog supports is allowed).
    public static func unsupportedReasons(for model: ModelDescriptor?, options: [LanguageCode]) -> [LanguageCode: String] {
        guard let model else { return [:] }
        var reasons: [LanguageCode: String] = [:]
        for code in options where !model.covers(code) {
            reasons[code] = "\(model.displayName) does not support it. Choose Automatic to use it."
        }
        return reasons
    }

    /// The Mac's preferred languages that can be offered, in the user's order.
    public static func suggestions(
        from options: [LanguageCode], preferred: [String] = Locale.preferredLanguages
    ) -> [LanguageCode] {
        var out: [LanguageCode] = []
        for identifier in preferred {
            let primary = LanguageCode(identifier).primary
            if let match = options.first(where: { $0 == LanguageCode(identifier) }) ?? options.first(where: { $0.primary == primary }),
                !out.contains(match)
            { out.append(match) }
        }
        return out
    }

    // MARK: Selection

    public static func toggled(_ code: LanguageCode, in selection: Set<LanguageCode>) -> Set<LanguageCode> {
        var copy = selection
        if copy.contains(code) { copy.remove(code) } else { copy.insert(code) }
        return copy
    }

    /// The chosen languages, by name: the chips.
    public func chips(for selection: Set<LanguageCode>) -> [LanguageCode] { sortedByName(selection) }

    /// "None chosen", "English", "English and Sinhala", "English, Sinhala and 2 more".
    public func summary(for selection: Set<LanguageCode>) -> String {
        let names = chips(for: selection).map(Self.name(of:))
        switch names.count {
        case 0: return "No languages chosen"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    /// The next language to highlight when an arrow key is pressed, skipping rows that cannot be chosen.
    public func step(
        from current: LanguageCode?, by delta: Int, query: String = "", selection: Set<LanguageCode> = []
    ) -> LanguageCode? {
        let codes = visibleCodes(query: query).filter { isSelectable($0, selection: selection) }
        guard !codes.isEmpty else { return nil }
        guard let current, let index = codes.firstIndex(of: current) else { return delta >= 0 ? codes.first : codes.last }
        return codes[min(max(index + delta, 0), codes.count - 1)]
    }
}

// MARK: - View

/// Size of the selector's list: roomy enough to read and pick from without scrolling a sliver.
public enum LanguageSelectorLayout {
    public static let minListHeight: CGFloat = 280
    public static let idealListHeight: CGFloat = 320
    public static let maxListHeight: CGFloat = 360
    /// A popover that hosts the selector is never narrower than this.
    public static let minPopoverWidth: CGFloat = 380
}

/// A searchable multi-select of languages with removable chips for the current choice.
public struct LanguageMultiSelectView: View {
    private let selector: LanguageSelectorModel
    private let selection: Set<LanguageCode>
    private let onToggle: (LanguageCode) -> Void
    private let onClear: (() -> Void)?
    private let scrolls: Bool
    private let idPrefix: String

    @State private var query: String
    @State private var highlighted: LanguageCode?
    private enum Field { case search, list }
    @FocusState private var focus: Field?

    /// - Parameters:
    ///   - scrolls: `false` lays the rows out in a plain stack (image tests, since `ImageRenderer` cannot draw a scroll view).
    ///   - initialQuery: the starting search text (previews and tests).
    public init(
        selector: LanguageSelectorModel, selection: Set<LanguageCode>, idPrefix: String = "language",
        onToggle: @escaping (LanguageCode) -> Void, onClear: (() -> Void)? = nil, scrolls: Bool = true, initialQuery: String = ""
    ) {
        self.selector = selector
        self.selection = selection
        self.idPrefix = idPrefix
        self.onToggle = onToggle
        self.onClear = onClear
        self.scrolls = scrolls
        _query = State(initialValue: initialQuery)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            searchField
            chipsRow
            listBox
        }
        .frame(minWidth: LanguageSelectorLayout.minPopoverWidth - 2 * DSSpacing.lg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Languages")
        .accessibilityIdentifier("\(idPrefix).multiselect")
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: DSSpacing.xs) {
            DSIcon(.search).dsIconContext(.menu).foregroundStyle(DSColor.secondaryText).accessibilityHidden(true)
            TextField("Search languages", text: $query)
                .textFieldStyle(.plain)
                .focused($focus, equals: .search)
                .onSubmit { toggleFirstMatch() }
                .onKeyPress(.downArrow) {
                    focus = .list
                    highlighted = selector.step(from: nil, by: 1, query: query, selection: selection)
                    return .handled
                }
                .accessibilityLabel("Search languages")
                .accessibilityIdentifier("\(idPrefix).search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(DSColor.secondaryText)  // stock-chrome: clear-field glyph
                }
                .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DSSpacing.sm)
        .frame(minHeight: DSLayout.minControlHeight)
        .background(DSColor.insetBackground, in: RoundedRectangle(cornerRadius: DSRadius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.small, style: .continuous).stroke(DSColor.hairline))
    }

    private func toggleFirstMatch() {
        guard let first = selector.visibleCodes(query: query).first(where: { selector.isSelectable($0, selection: selection) })
        else { return }
        onToggle(first)
    }

    // MARK: Chips

    @ViewBuilder private var chipsRow: some View {
        let chips = selector.chips(for: selection)
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack {
                Text(chips.isEmpty ? "No languages chosen" : "\(chips.count) chosen")
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    .accessibilityIdentifier("\(idPrefix).count")
                Spacer()
                if let onClear, !chips.isEmpty {
                    Button("Clear", action: onClear).buttonStyle(.link).font(DSTypography.caption)
                        .accessibilityIdentifier("\(idPrefix).clear")
                }
            }
            if !chips.isEmpty {
                let flow = FlowChips(spacing: DSSpacing.xs) {
                    ForEach(chips, id: \.self) { code in
                        LanguageChip(name: LanguageSelectorModel.name(of: code)) { onToggle(code) }
                    }
                }
                if scrolls {
                    ScrollView { flow.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 72)
                } else {
                    flow.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: List

    @ViewBuilder private var listBox: some View {
        let sections = selector.sections(query: query)
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(sections) { section in
                Text(section.title).font(DSTypography.label).tracking(DSTypography.labelTracking).textCase(.uppercase)
                    .foregroundStyle(DSColor.secondaryText)
                    .padding(.horizontal, DSSpacing.sm).padding(.top, DSSpacing.sm).padding(.bottom, DSSpacing.xs)
                    .accessibilityAddTraits(.isHeader)
                ForEach(section.codes, id: \.self) { code in row(for: code) }
            }
        }
        .padding(.vertical, DSSpacing.xs)
        Group {
            if sections.isEmpty {
                VStack(spacing: DSSpacing.xs) {
                    Text("No language matches \u{201C}\(query)\u{201D}").font(DSTypography.body)
                    Text("Try the language's name, or its code such as \u{201C}es\u{201D}.")
                        .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                }
                .multilineTextAlignment(.center).frame(maxWidth: .infinity, maxHeight: .infinity).padding(DSSpacing.lg)
                .accessibilityIdentifier("\(idPrefix).empty")
            } else if scrolls {
                ScrollViewReader { proxy in
                    ScrollView { rows }
                        .onChange(of: highlighted) { _, code in if let code { proxy.scrollTo(code, anchor: nil) } }
                }
            } else {
                rows
            }
        }
        .frame(
            minHeight: LanguageSelectorLayout.minListHeight, idealHeight: LanguageSelectorLayout.idealListHeight,
            maxHeight: LanguageSelectorLayout.maxListHeight, alignment: .top
        )
        .background(DSColor.insetBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous).stroke(DSColor.hairline))
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous))
        .focusable()
        .focused($focus, equals: .list)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.space) { activateHighlighted() }
        .onKeyPress(.return) { activateHighlighted() }
        .accessibilityIdentifier("\(idPrefix).list")
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        highlighted = selector.step(from: highlighted, by: delta, query: query, selection: selection)
        return .handled
    }

    private func activateHighlighted() -> KeyPress.Result {
        guard let highlighted, selector.isSelectable(highlighted, selection: selection) else { return .ignored }
        onToggle(highlighted)
        return .handled
    }

    private func row(for code: LanguageCode) -> some View {
        let chosen = selection.contains(code)
        let selectable = selector.isSelectable(code, selection: selection)
        let name = LanguageSelectorModel.name(of: code)
        let reason = selector.reason(for: code)
        return Button {
            highlighted = code
            onToggle(code)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
                Image(systemName: "checkmark").font(.body.weight(.semibold))  // stock-chrome: selection checkmark
                    .foregroundStyle(DSColor.accent).opacity(chosen ? 1 : 0).frame(width: 16)
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    HStack(spacing: DSSpacing.xs) {
                        Text(name).lineLimit(1)
                        if let native = LanguageSelectorModel.nativeName(of: code) {
                            Text(native).foregroundStyle(DSColor.secondaryText).lineLimit(1)
                        }
                    }
                    if let reason {
                        Text(reason).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, DSSpacing.xs)
            .opacity(selectable ? 1 : 0.5)
        }
        .buttonStyle(LanguageRowStyle(isHighlighted: highlighted == code && focus == .list))
        .disabled(!selectable)
        .id(code)
        .accessibilityLabel(reason.map { "\(name), unavailable. \($0)" } ?? name)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityHint(selectable ? (chosen ? "Chosen. Activate to remove" : "Activate to choose") : "")
        .accessibilityIdentifier("\(idPrefix).row.\(code.rawValue)")
    }
}

/// A chosen language with an x to remove it.
private struct LanguageChip: View {
    let name: String
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: DSSpacing.xs) {
                Text(name).lineLimit(1)
                Image(systemName: "xmark").font(.caption2.weight(.bold)).accessibilityHidden(true)  // stock-chrome: remove glyph
            }
            .font(DSTypography.caption)
            .foregroundStyle(DSColor.accentText)
            .padding(.horizontal, DSSpacing.sm).padding(.vertical, DSSpacing.xs)
            .background(DSColor.accentTint, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Remove \(name)")
        .accessibilityLabel("\(name), chosen")
        .accessibilityHint("Activate to remove")
        .accessibilityAddTraits(.isButton)
    }
}

/// Row highlight for hover, the keyboard cursor and press, with the full row as the hit area.
private struct LanguageRowStyle: ButtonStyle {
    var isHighlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, isHighlighted: isHighlighted)
    }

    struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        let isHighlighted: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let fill: Double = !isEnabled ? 0 : configuration.isPressed ? 0.16 : (hovering || isHighlighted) ? 0.08 : 0
            configuration.label
                .padding(.horizontal, DSSpacing.sm)
                .background(DSColor.primaryText.opacity(fill), in: RoundedRectangle(cornerRadius: DSRadius.small, style: .continuous))
                .padding(.horizontal, DSSpacing.xs)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Wraps its subviews left to right (chips).
private struct FlowChips: Layout {
    var spacing: CGFloat

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.init(width: width.isFinite ? width : nil, height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (frames, CGSize(width: min(width, maxX), height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }
}
