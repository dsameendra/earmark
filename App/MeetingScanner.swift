import ApplicationServices
import AppKit
import FeatureSupport
import Foundation
import Meetings

/// Reads browser window titles through the Accessibility API (the permission Dictation already asks for). It is how Earmark
/// tells a Google Meet tab from any other call in a browser. No account, cookie, page content or network request is involved.
struct AccessibilityMeetingContext: MeetingContextChecking {
    var canReadTitles: Bool { AXIsProcessTrusted() }

    func windowTitles(bundleIDPrefixes: [String]) async -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        let prefixes = bundleIDPrefixes.map { $0.lowercased() }
        var titles: [String] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier?.lowercased(), prefixes.contains(where: { id.hasPrefix($0) }) else { continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.5)  // a hung browser must not stall detection
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                let windows = value as? [AXUIElement]
            else { continue }
            for window in windows {
                var title: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success, let text = title as? String {
                    titles.append(text)
                }
            }
        }
        return titles
    }
}

/// Adapts the detector's scan to the Meetings page seam (`MeetingScanning`).
struct MeetingScanner: MeetingScanning {
    let detector: ProbeMeetingDetector

    func scan() async -> MeetingScanResult { Self.map(await detector.scan()) }

    func results() -> AsyncStream<MeetingScanResult> {
        let source = detector.scans()
        return AsyncStream { continuation in
            let task = Task {
                for await scan in source { continuation.yield(Self.map(scan)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func map(_ scan: MeetingScan) -> MeetingScanResult {
        MeetingScanResult(
            candidates: scan.calls.map {
                LiveMeetingCandidate(id: $0.id, app: $0.app, label: $0.label, detail: $0.detail, targetBundleID: $0.captureBundleID)
            },
            notes: scan.notes, needsAccessibilityForMeet: scan.needsAccessibilityForMeet)
    }
}
