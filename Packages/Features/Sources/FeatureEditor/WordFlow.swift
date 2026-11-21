import AppCore
import AppKit
import DesignSystem
import SwiftUI

/// Wraps its subviews left to right like text. Used for per-word views so each word is clickable (click-to-seek).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    struct Arrangement {
        var frames: [CGRect] = []
        var size: CGSize = .zero
    }

    func arrange(width: CGFloat, subviews: Subviews) -> Arrangement {
        var result = Arrangement()
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            result.frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        result.size = CGSize(width: min(width, maxX), height: y + rowHeight)
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in arrangement.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }
}

/// One word as displayed: its owning segment, position and visual state.
struct WordItem: Identifiable, Equatable {
    var segmentID: SegmentID
    var index: Int
    var text: String
    var isActive = false
    var isFound = false
    var highlight: String?
    var isLowConfidence = false
    var id: String { "\(segmentID)-\(index)" }
}

/// Typography shared by every transcript row.
struct EditorTypography: Equatable {
    var family: String?
    var size: Double
    var lineSpacing: Double

    init(_ options: ViewOptions) {
        family = options.fontFamily
        size = options.fontSize
        lineSpacing = options.lineSpacing
    }

    /// Sinhala-safe font: the family (or system) with an explicit Sinhala cascade.
    var font: Font { SinhalaFont.font(size: size, family: family) }
}

enum EditorColors {
    static func color(_ spec: SpeakerColorSpec) -> Color {
        switch spec {
        case .slot(let slot): return SpeakerPalette.color(forSlot: slot)
        case .hex(let hex, let fallback):
            if let slot = SpeakerColors.paletteHexes.firstIndex(of: hex.uppercased()) { return SpeakerPalette.color(forSlot: slot) }
            guard let rgb = SpeakerColors.rgb(hex: hex) else { return SpeakerPalette.color(forSlot: fallback) }
            return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        }
    }

    static func highlight(_ name: String) -> Color {
        switch name {
        case "green": .green.opacity(0.35)
        case "blue": .blue.opacity(0.3)
        case "pink": .pink.opacity(0.35)
        default: .yellow.opacity(0.45)
        }
    }

    static let active = Color.accentColor.opacity(0.35)
    static let found = Color.orange.opacity(0.35)
}

/// A clickable word. Single click seeks immediately; there is no competing double-tap on the word itself so no delay
/// is added to the click (EDIT-AC-02).
struct WordView: View, Equatable {
    let item: WordItem
    let typography: EditorTypography
    let onTap: (WordItem) -> Void
    let onSplit: (WordItem) -> Void
    let onBookmark: (WordItem) -> Void
    let onHighlight: (WordItem) -> Void

    nonisolated static func == (l: WordView, r: WordView) -> Bool { l.item == r.item && l.typography == r.typography }

    var body: some View {
        Text(item.text)
            .font(typography.font)
            .underline(item.isLowConfidence, pattern: .dot)
            .padding(.horizontal, 2)
            .background(background, in: RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
            .onTapGesture { onTap(item) }
            .contextMenu {
                Button("Split Segment Before This Word") { onSplit(item) }.disabled(item.index == 0)
                Button("Bookmark Here") { onBookmark(item) }
                Button("Highlight Word") { onHighlight(item) }
            }
            .accessibilityLabel(item.text)
            .accessibilityAddTraits(.isButton)
    }

    private var background: Color {
        if item.isActive { return EditorColors.active }
        if item.isFound { return EditorColors.found }
        if let name = item.highlight { return EditorColors.highlight(name) }
        return .clear
    }
}

/// The flowing words of one segment or paragraph.
struct WordFlowView: View {
    let items: [WordItem]
    let typography: EditorTypography
    let onTap: (WordItem) -> Void
    let onSplit: (WordItem) -> Void
    let onBookmark: (WordItem) -> Void
    let onHighlight: (WordItem) -> Void

    var body: some View {
        FlowLayout(spacing: 3, lineSpacing: typography.lineSpacing) {
            ForEach(items) { item in
                WordView(
                    item: item, typography: typography, onTap: onTap, onSplit: onSplit, onBookmark: onBookmark,
                    onHighlight: onHighlight
                )
                .equatable()
            }
        }
    }
}
