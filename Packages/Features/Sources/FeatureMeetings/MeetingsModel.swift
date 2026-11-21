import AppCore
import FeatureSupport
import Foundation
import Observation

/// Drives the Meetings screen: stored meetings plus a live "meeting detected" prompt (NAV-AC-14).
@MainActor @Observable
public final class MeetingsModel {
    public private(set) var meetings: [Meeting] = []
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?
    /// Set while a meeting is detected and not yet dismissed.
    public private(set) var detectedApp: MeetingApp?

    @ObservationIgnored private let repository: any MeetingRepository
    @ObservationIgnored private let detector: any MeetingDetector

    public init(services: AppServices) {
        repository = services.meetings
        detector = services.meetingDetector
    }

    public func load() async {
        do {
            meetings = try await repository.meetings().sorted { $0.startedAt > $1.startedAt }
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
        isLoading = false
    }

    /// Follows detector events until cancelled.
    public func watchDetector() async {
        for await event in detector.events() {
            switch event {
            case .started(let app, _): detectedApp = app
            case .ended: detectedApp = nil
            }
        }
    }

    public func dismissDetection() { detectedApp = nil }
}
