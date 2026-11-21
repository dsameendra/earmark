import AppCore
import FeatureSupport
import Foundation
import Observation

/// Source choices offered for live captions (NAV-AC-13, MENU-AC-03).
public enum LiveSourceChoice: String, CaseIterable, Identifiable, Sendable {
    case mic, system, micAndSystem
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mic: "Microphone"
        case .system: "System Audio"
        case .micAndSystem: "Mic + System"
        }
    }

    /// The matching capture source (default device for the mic).
    public var captureSource: CaptureSource {
        switch self {
        case .mic: .mic(deviceUID: nil)
        case .system: .system
        case .micAndSystem: .micAndSystem(deviceUID: nil, lanes: true)
        }
    }
}

/// Drives the Live screen from `LiveSessionControlling`.
@MainActor @Observable
public final class LiveModel {
    public private(set) var state: LiveSessionState = .idle
    public private(set) var lines: [CaptionLine] = []
    public var source: LiveSourceChoice = .mic

    @ObservationIgnored private let live: any LiveSessionControlling

    public init(services: AppServices) { live = services.live }

    public var isRunning: Bool { state == .running || state == .starting }

    /// Follows session state until cancelled.
    public func watchState() async {
        for await next in live.state() { state = next }
    }

    /// Follows caption lines until cancelled. Volatile lines finalize in place (same id).
    public func watchLines() async {
        for await next in live.lines() { lines = next }
    }

    public func start() async {
        do {
            try await live.start(LiveSessionConfig(source: source.captureSource))
        } catch {
            state = .failed(String(describing: error))
        }
    }

    public func stop() async { _ = await live.stop() }
}
