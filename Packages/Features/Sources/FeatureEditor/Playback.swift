import AVFoundation
import AppCore
import FeatureSupport
import Foundation
import Observation
import SwiftUI

/// The playback surface the editor needs. The production implementation wraps `AVPlayer`; tests use a scripted fake.
@MainActor
public protocol PlayerControlling: AnyObject {
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    /// Called on time updates (about 30 Hz while playing) and after seeks.
    var onTick: (@MainActor (TimeInterval) -> Void)? { get set }
    /// Called when playing/paused changes.
    var onPlayingChanged: (@MainActor (Bool) -> Void)? { get set }
    /// Frame-accurate seek; returns when the player reached the target.
    func seek(to time: TimeInterval) async
    func play()
    func pause()
    /// Playback rate for when playing (0.5...3).
    func setSpeed(_ speed: Double)
    /// Stops audio and frees the underlying player; the controller is unusable afterwards.
    func release()
}

extension PlayerControlling {
    public func release() {}
}

/// Whether the media for a transcript can be played.
public enum MediaState: Sendable, Equatable {
    case loading
    case ready(isVideo: Bool)
    /// No media is associated, or its file cannot be opened (EDIT-AC-19).
    case missing
}

/// Allowed playback speeds (EDIT-AC-05).
public enum PlaybackSpeed {
    public static let steps: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3]
    public static let range: ClosedRange<Double> = 0.5...3
    public static func clamped(_ speed: Double) -> Double { min(range.upperBound, max(range.lowerBound, speed)) }
}

/// Playback keyboard shortcuts (EDIT-AC-05).
public enum PlaybackShortcut: Equatable, Sendable {
    case togglePlay
    case skip(TimeInterval)

    /// Skip distances offered by the transport buttons.
    public static let shortSkip: TimeInterval = 5
    public static let longSkip: TimeInterval = 15

    /// Space and K toggle; J / ← skip back 5 s; L / → skip forward 5 s; ⌥ with an arrow (or ⇧ with J/L) skips 15 s.
    public static func resolve(key: KeyEquivalent, modifiers: EventModifiers) -> PlaybackShortcut? {
        let long = modifiers.contains(.option) || modifiers.contains(.shift)
        let blocked: EventModifiers = [.command, .control]
        guard modifiers.isDisjoint(with: blocked) else { return nil }
        switch key {
        case .space: return .togglePlay
        case .leftArrow: return .skip(-(long ? longSkip : shortSkip))
        case .rightArrow: return .skip(long ? longSkip : shortSkip)
        case KeyEquivalent("k"): return .togglePlay
        case KeyEquivalent("j"): return .skip(-(long ? longSkip : shortSkip))
        case KeyEquivalent("l"): return .skip(long ? longSkip : shortSkip)
        default: return nil
        }
    }
}

/// Playback state shared by the docked and detached player, the transcript (karaoke) and the scrubber (EDIT-AC-17).
@MainActor @Observable
public final class PlaybackModel {
    public private(set) var mediaState: MediaState = .loading
    public private(set) var isPlaying = false
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var speed: Double = 1
    /// The word (or segment) being spoken now; only assigned when it changes so row views re-render rarely.
    public private(set) var activeRef: WordRef?
    /// Where the playhead is, even in gaps between segments (auto-scroll target).
    public private(set) var scrollTargetID: SegmentID?
    /// When false the user scrolled away; auto-scroll is paused until "Return to playhead" (EDIT-AC-04).
    public private(set) var autoFollow = true
    public var isDetached = false
    /// Bumps each time the view should scroll to `scrollTargetID`.
    public private(set) var scrollRequest = 0

    @ObservationIgnored public private(set) var engine: (any PlayerControlling)?
    @ObservationIgnored private var timeline = WordTimeline(segments: [])

    public init() {}

    public var canPlay: Bool { if case .ready = mediaState { true } else { false } }
    public var isVideo: Bool { if case .ready(let video) = mediaState { video } else { false } }

    public func attach(_ engine: any PlayerControlling, isVideo: Bool) {
        self.engine = engine
        duration = engine.duration
        mediaState = .ready(isVideo: isVideo)
        engine.onTick = { [weak self] time in self?.handleTick(time) }
        engine.onPlayingChanged = { [weak self] playing in self?.isPlaying = playing }
        engine.setSpeed(speed)
    }

    public func markMissing() {
        if let engine { Self.tearDown(engine) }
        engine = nil
        mediaState = .missing
        isPlaying = false
    }

    /// Pauses, detaches the callbacks and releases the player; the model stays usable only as a "no media" shell.
    public func stop() {
        if let engine { Self.tearDown(engine) }
        engine = nil
        mediaState = .missing
        isPlaying = false
        isDetached = false
        timeline = WordTimeline(segments: [])
        activeRef = nil
        scrollTargetID = nil
    }

    /// Pauses without releasing (capture started, or the shell asks for silence).
    public func pause() { engine?.pause() }

    /// Drops the transcript timeline so karaoke state does not reference an editor that is gone.
    public func detachTimeline() {
        timeline = WordTimeline(segments: [])
        activeRef = nil
        scrollTargetID = nil
    }

    private static func tearDown(_ engine: any PlayerControlling) {
        engine.pause()
        engine.onTick = nil
        engine.onPlayingChanged = nil
        engine.release()
    }

    public func setTimeline(_ timeline: WordTimeline) {
        self.timeline = timeline
        updateActive(at: currentTime)
    }

    /// Time update from the engine.
    public func handleTick(_ time: TimeInterval) {
        currentTime = time
        if let engine, engine.duration > 0, engine.duration != duration { duration = engine.duration }
        updateActive(at: time)
    }

    private func updateActive(at time: TimeInterval) {
        let ref = timeline.locate(time)
        if ref != activeRef { activeRef = ref }
        let target = timeline.locate(time, holdInGaps: true)?.segmentID
        if target != scrollTargetID {
            scrollTargetID = target
            if autoFollow { scrollRequest += 1 }
        }
    }

    // MARK: Transport

    /// Seeks to `time` (clamped); the displayed time updates immediately, the engine confirms asynchronously.
    @discardableResult
    public func seek(to time: TimeInterval) -> Task<Void, Never> {
        let target = max(0, duration > 0 ? min(duration, time) : time)
        currentTime = target
        updateActive(at: target)
        guard let engine else { return Task {} }
        return Task { await engine.seek(to: target) }
    }

    /// Click-to-seek on a word (EDIT-AC-02); does not change play state.
    @discardableResult
    public func seekToWord(in segment: Segment, wordIndex: Int?) -> Task<Void, Never> {
        seek(to: SeekTarget.time(for: segment, wordIndex: wordIndex))
    }

    /// Double-click on a segment: play from its start (EDIT-AC-03).
    @discardableResult
    public func playFrom(_ segment: Segment) -> Task<Void, Never> {
        let task = seek(to: segment.start)
        engine?.play()
        return task
    }

    public func togglePlay() {
        guard let engine else { return }
        if engine.isPlaying { engine.pause() } else { engine.play() }
    }

    public func skip(by delta: TimeInterval) { seek(to: currentTime + delta) }

    public func setSpeed(_ value: Double) {
        speed = PlaybackSpeed.clamped(value)
        engine?.setSpeed(speed)
    }

    public func perform(_ shortcut: PlaybackShortcut) {
        switch shortcut {
        case .togglePlay: togglePlay()
        case .skip(let delta): skip(by: delta)
        }
    }

    // MARK: Auto-scroll

    /// The user scrolled manually: pause following (EDIT-AC-04).
    public func userDidScroll() {
        guard autoFollow else { return }
        autoFollow = false
    }

    /// "Return to playhead": resume following and scroll there.
    public func returnToPlayhead() {
        autoFollow = true
        scrollRequest += 1
    }

    /// Show the button only while auto-scroll is paused and playback has somewhere to return to.
    public var showsReturnToPlayhead: Bool { !autoFollow && scrollTargetID != nil }
}

/// `AVPlayer` implementation of ``PlayerControlling``.
@MainActor
public final class AVPlayerEngine: PlayerControlling {
    public let player: AVPlayer
    public var onTick: (@MainActor (TimeInterval) -> Void)?
    public var onPlayingChanged: (@MainActor (Bool) -> Void)?
    private var speed: Float = 1
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var lastPlaying = false

    public init(url: URL) {
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        // Local files: start immediately after a seek instead of pre-rolling a stall-avoidance buffer.
        player.automaticallyWaitsToMinimizeStalling = false
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.onTick?(time.seconds) }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.syncPlaying() }
        }
    }

    isolated deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    public func release() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        onTick = nil
        onPlayingChanged = nil
        player.replaceCurrentItem(with: nil)
    }

    private var isSeeking = false

    private func syncPlaying() {
        guard !isSeeking else { return }
        let playing = player.timeControlStatus != .paused
        guard playing != lastPlaying else { return }
        lastPlaying = playing
        onPlayingChanged?(playing)
    }

    public var currentTime: TimeInterval { player.currentTime().seconds }
    public var duration: TimeInterval {
        let value = player.currentItem?.duration.seconds ?? 0
        return value.isFinite ? value : 0
    }
    public var isPlaying: Bool { isSeeking || player.timeControlStatus != .paused }

    /// Whether the item has a video track.
    public func hasVideo() async -> Bool {
        guard let asset = player.currentItem?.asset else { return false }
        return ((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty == false
    }

    /// Waits until the item can play; returns false when it fails or does not become ready within `timeout` seconds.
    public func waitUntilReady(timeout: TimeInterval = 10) async -> Bool {
        guard let item = player.currentItem else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch item.status {
            case .readyToPlay: return true
            case .failed: return false
            default: try? await Task.sleep(for: .milliseconds(10))
            }
        }
        return false
    }

    /// Frame-accurate seek. While playing, the player is paused around the seek so the position is reached without
    /// waiting for the audio pipeline to flush and re-prime (about 100 ms on audio files); playback resumes right after,
    /// and the play/pause state reported to the UI does not flicker.
    public func seek(to time: TimeInterval) async {
        let wasPlaying = isPlaying
        if wasPlaying {
            isSeeking = true
            player.pause()
        }
        _ = await player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        onTick?(player.currentTime().seconds)
        if wasPlaying {
            player.rate = speed
            isSeeking = false
        }
    }

    public func play() {
        player.rate = speed
        player.defaultRate = speed
    }
    public func pause() { player.pause() }
    public func setSpeed(_ speed: Double) {
        self.speed = Float(speed)
        player.defaultRate = self.speed
        if isPlaying { player.rate = self.speed }
    }
}

/// Resolves a transcript's media asset to a readable file URL.
public enum MediaLocator {
    /// The URL for `asset`, or nil when the file is gone. Library-relative paths resolve against `roots` in order
    /// (meeting recordings are relative to the meetings root, see ``MediaFiles``).
    public static func url(for asset: MediaAsset, roots: [URL] = MediaFiles.defaultRoots) -> URL? {
        if let relative = asset.libraryRelativePath, let url = MediaFiles.resolve(relative, roots: roots) { return url }
        if let bookmark = asset.bookmark {
            var stale = false
            let resolved = try? URL(
                resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            if let url = resolved,
                FileManager.default.isReadableFile(atPath: url.path)
            {
                _ = url.startAccessingSecurityScopedResource()
                return url
            }
        }
        return nil
    }
}
