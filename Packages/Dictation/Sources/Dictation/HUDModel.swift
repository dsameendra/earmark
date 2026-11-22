import AppCore
import Foundation
import Observation

/// Observable state behind the HUD view. Behaviour lives here, layout in ``DictationHUDView`` (rule A7).
@MainActor @Observable
public final class DictationHUDModel {
    public enum Phase: Equatable {
        case listening
        case processing
        case error(String)

        /// SF Symbol shown for non-listening phases (names live in the model, rule A3).
        public var systemImage: String? {
            switch self {
            case .listening: nil
            case .processing: "ellipsis"
            case .error: "exclamationmark.triangle.fill"
            }
        }
    }

    public static let barCount = 9

    public var phase: Phase = .listening
    public var partialText = ""
    public var hint = ""
    public var isExperimental = false
    /// Most recent input levels (0...1), oldest first; drives the listening bars.
    public private(set) var levels: [Float] = Array(repeating: 0, count: DictationHUDModel.barCount)

    public init() {}

    public func begin(_ info: DictationHUDInfo) {
        phase = .listening
        partialText = ""
        hint = info.hint
        isExperimental = info.isExperimental
        levels = Array(repeating: 0, count: Self.barCount)
    }

    public func push(level: Float) {
        levels.removeFirst()
        levels.append(min(max(level, 0), 1))
    }

    /// Text shown in the capsule: the partial transcript, or a placeholder while nothing was heard yet.
    public var displayText: String {
        switch phase {
        case .listening: partialText.isEmpty ? "Listening…" : partialText
        case .processing: partialText.isEmpty ? "Finishing…" : partialText
        case .error(let message): message
        }
    }

    public var accessibilitySummary: String {
        switch phase {
        case .listening: "Dictation listening. \(partialText)"
        case .processing: "Dictation finishing"
        case .error(let message): "Dictation error. \(message)"
        }
    }
}

/// Pure HUD placement math (DICT-AC-03), in AppKit screen coordinates (origin bottom-left).
public enum DictationHUDPlacement {
    public static let bottomMargin: CGFloat = 72
    public static let caretGap: CGFloat = 10

    public static func frame(size: CGSize, position: DictationHUDPosition, caret: CGRect?, visibleFrame: CGRect) -> CGRect {
        var origin: CGPoint
        if position == .nearCursor, let caret {
            // Prefer just below the caret; flip above when there is no room.
            var y = caret.minY - caretGap - size.height
            if y < visibleFrame.minY { y = caret.maxY + caretGap }
            origin = CGPoint(x: caret.minX, y: y)
        } else {
            origin = CGPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.minY + bottomMargin)
        }
        origin.x = min(max(origin.x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        origin.y = min(max(origin.y, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)
        return CGRect(origin: origin, size: size)
    }
}
