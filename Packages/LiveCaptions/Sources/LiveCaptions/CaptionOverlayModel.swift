import AppCore
import Foundation
import Observation

/// Symbols used by the overlay, named through a model property (design rule A3) so M8 can swap in `DSSymbol`.
public enum CaptionOverlaySymbol {
    case paused, lowConfidence
    public var systemName: String {
        switch self {
        case .paused: "pause.fill"
        case .lowConfidence: "exclamationmark.triangle"
        }
    }
}

/// Observable state behind the overlay view: current preset, caption lines, fade and pause state.
/// Behaviour lives here; appearance lives in `CaptionOverlayView` (rule A7).
@MainActor
@Observable
public final class CaptionOverlayModel {
    public var preset: CaptionPreset
    public private(set) var lines: [CaptionLine] = []
    /// Captioning is active (drives the persistent recording dot, LIVE-AC-18).
    public var isCaptioning = false
    public var isPaused = false
    public var clickThrough = true
    /// `true` after `autoHideAfterSilence` elapsed without new speech (LIVE-AC-09); the view fades out.
    public private(set) var isFaded = false

    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var lastSignature: [String] = []

    public init(preset: CaptionPreset = CaptionPresetCatalog.defaultPreset) { self.preset = preset }

    /// The last `visibleLines` lines (1...6), most recent at the bottom.
    public var visibleLines: [CaptionLine] {
        Array(lines.suffix(min(6, max(1, preset.visibleLines))))
    }

    /// Splits the low-confidence marker off a translation string.
    public static func parseTranslation(_ translation: String?) -> (text: String, isLowConfidence: Bool)? {
        guard let translation, !translation.isEmpty else { return nil }
        let marker = LiveCaptionMarkers.lowConfidenceTranslationPrefix
        if translation.hasPrefix(marker) { return (String(translation.dropFirst(marker.count)), true) }
        return (translation, false)
    }

    public func ingest(_ newLines: [CaptionLine]) {
        lines = newLines
        let signature = newLines.suffix(8).map { "\($0.id)|\($0.text)|\($0.isVolatile)" }
        if signature != lastSignature {
            lastSignature = signature
            noteSpeechActivity()
        }
    }

    /// Un-fades and re-arms the auto-hide timer.
    public func noteSpeechActivity() {
        isFaded = false
        fadeTask?.cancel()
        guard let delay = preset.autoHideAfterSilence, delay > 0, isCaptioning else { return }
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.isFaded = true
        }
    }

    public func reset() {
        fadeTask?.cancel()
        lines = []
        lastSignature = []
        isFaded = false
    }
}
