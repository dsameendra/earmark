import AppCore

/// A short notice from a running live session (device fallback, silent capture, speaker limit, pause).
public struct LiveNotice: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case paused, resumed, info, warning, problem }
    public var kind: Kind
    public var message: String
    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Live-session capabilities beyond `LiveSessionControlling` (pause, level meter, notices, overlay and caption presets).
/// The app's composition root supplies the real implementation; `AppServices.liveExtras` is `nil` in previews.
/// Kept out of `AppCore` so the AppCore contract is unchanged.
public protocol LiveSessionExtras: Sendable {
    func setPaused(_ paused: Bool) async
    /// Linear 0...1 input level while a session runs.
    func levels() -> AsyncStream<Float>
    func notices() -> AsyncStream<LiveNotice>
    /// Shows or hides the floating caption overlay (the overlay also follows the session automatically when enabled).
    func setOverlayEnabled(_ enabled: Bool) async
    func isOverlayEnabled() async -> Bool
    /// Built-in presets first, then user presets.
    func presets() async -> [CaptionPreset]
    func activePreset() async -> CaptionPreset
    func setActivePreset(_ id: PresetID) async
    /// Persists an edit. Built-in presets are protected, so editing one saves a copy; returns the preset now in effect.
    func commit(_ preset: CaptionPreset) async -> CaptionPreset
}

/// Menu bar "start dictation" control, supplied by the app (the menu bar target does not depend on `Dictation`).
public struct DictationMenuControl: Sendable {
    /// `true` while a dictation session is listening.
    public var isListening: @Sendable () -> AsyncStream<Bool>
    /// Starts dictation, or finishes it when already listening.
    public var toggle: @Sendable () async -> Void
    public init(isListening: @escaping @Sendable () -> AsyncStream<Bool>, toggle: @escaping @Sendable () async -> Void) {
        self.isListening = isListening
        self.toggle = toggle
    }
}
