import AppCore
import DesignSystem
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

    // MARK: Waveform (owned by the session so the mini-player works with no editor on screen)

    /// Peaks for this session's media; nil while decoding or when there is nothing to draw.
    public private(set) var waveformPeaks: WaveformPeaks?
    public private(set) var waveformPyramid: PeakPyramid?
    public private(set) var waveformState: WaveformLoadState = .loading
    /// Speaker ribbon pieces and bookmark flags, pushed by the editor while it is open and kept after it closes.
    public private(set) var waveformSegments: [WaveformSegment] = []
    public private(set) var waveformSegmentIDs: [SegmentID] = []
    public private(set) var waveformBookmarks: [WaveformBookmark] = []
    @ObservationIgnored private var waveformTask: Task<Void, Never>?
    @ObservationIgnored private var waveformRequested = false

    /// What the scrubber shows: a missing file draws the flat unavailable line whatever the decoder said.
    public var waveformLoadState: WaveformLoadState { playback.mediaState.isUnavailable ? .unavailable : waveformState }

    /// Index into ``waveformSegments`` of the segment being spoken, for the highlighted ribbon piece.
    public var waveformActiveIndex: Int? {
        guard let id = playback.activeRef?.segmentID else { return nil }
        return waveformSegmentIDs.firstIndex(of: id)
    }

    /// Decodes (or reads from the disk cache) the peaks once per session; later callers await the same work.
    public func loadWaveform(service: WaveformService, assetID: String?) async {
        if !waveformRequested {
            waveformRequested = true
            waveformState = .loading
            let url = mediaURL
            waveformTask = Task { [weak self] in
                let result = await service.peaks(for: url, assetID: assetID)
                let pyramid = await Task.detached { result.peaks?.pyramid }.value
                guard !Task.isCancelled, let self else { return }
                waveformPeaks = result.peaks
                waveformPyramid = pyramid
                waveformState = result.peaks == nil ? .unavailable : .ready
            }
        }
        await waveformTask?.value
    }

    func updateRibbon(segments: [WaveformSegment], ids: [SegmentID], bookmarks: [WaveformBookmark]) {
        waveformSegments = segments
        waveformSegmentIDs = ids
        waveformBookmarks = bookmarks
    }

    func cancelWaveform() {
        waveformTask?.cancel()
        waveformTask = nil
    }

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
        current.cancelWaveform()
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
