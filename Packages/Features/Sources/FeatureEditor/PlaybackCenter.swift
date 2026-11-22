import AppCore
import Foundation
import Observation

/// Builds a player for a media file; `nil` when the file cannot be played.
public typealias PlayerEngineFactory = @MainActor @Sendable (URL) async -> (engine: any PlayerControlling, isVideo: Bool)?

/// The one active playback session: a transcript, its media and the player that plays it.
@MainActor @Observable
public final class PlaybackSession {
    public let transcriptID: TranscriptID
    public internal(set) var title: String
    public let mediaURL: URL
    public let playback: PlaybackModel

    init(transcriptID: TranscriptID, title: String, mediaURL: URL, playback: PlaybackModel) {
        self.transcriptID = transcriptID
        self.title = title
        self.mediaURL = mediaURL
        self.playback = playback
    }
}

/// App-wide playback owner (triage A item 3). At most one session, and so one player, exists at a time.
///
/// - Reopening the transcript that owns the session reuses it, so position, speed and play state carry over.
/// - Opening a different transcript replaces the session and stops the old audio.
/// - Leaving the editor keeps the session alive; the shell shows a mini-player while ``session`` is non-nil.
/// - ``stop()`` pauses and releases the player.
@MainActor @Observable
public final class PlaybackCenter {
    public private(set) var session: PlaybackSession?
    /// Bumped by every replace/stop so a slow player build for a stale request discards itself.
    @ObservationIgnored private var generation = 0

    public init() {}

    /// The session when it belongs to `id`.
    public func session(for id: TranscriptID) -> PlaybackSession? {
        session?.transcriptID == id ? session : nil
    }

    /// Returns the session for `id`, reusing the live one or building a new one (which stops any other session first).
    /// Returns nil when the media cannot be opened, or when a newer request superseded this one while the player loaded.
    public func open(
        transcriptID id: TranscriptID, title: String, mediaURL: URL, speed: Double = 1, factory: PlayerEngineFactory
    ) async -> PlaybackSession? {
        if let existing = session(for: id), existing.mediaURL == mediaURL, existing.playback.engine != nil {
            existing.title = title
            return existing
        }
        stop()
        let ticket = generation
        guard let made = await factory(mediaURL) else { return nil }
        guard ticket == generation else {
            // Superseded (another transcript opened, or stop() ran) while the player was loading.
            made.engine.pause()
            made.engine.release()
            return nil
        }
        let playback = PlaybackModel()
        playback.setSpeed(speed)
        playback.attach(made.engine, isVideo: made.isVideo)
        let new = PlaybackSession(transcriptID: id, title: title, mediaURL: mediaURL, playback: playback)
        session = new
        return new
    }

    /// Pauses the audio and keeps the session (capture started, or the app asks for silence).
    public func pause() { session?.playback.pause() }

    /// Stops and releases the active session, and invalidates any player still loading.
    public func stop() {
        generation &+= 1
        guard let current = session else { return }
        session = nil
        current.playback.stop()
    }

    /// Stops the session only when it plays `id` (transcript deleted, media relinked or unavailable).
    public func stop(transcriptID id: TranscriptID) {
        if session?.transcriptID == id { stop() }
    }

    /// Stops the session unless it belongs to `id`; used when a different transcript is opened.
    public func replace(keeping id: TranscriptID) {
        if let current = session, current.transcriptID != id { stop() }
    }

    /// Live captions, dictation or a meeting recording started: playback must not leak into the microphone.
    public func captureDidStart() { pause() }
}
