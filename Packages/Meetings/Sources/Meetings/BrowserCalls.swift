import AppCore
import Foundation

/// A web browser that can carry a call (Google Meet and other web meetings). Nothing here talks to a web service: Earmark
/// only reads whether the browser's own audio processes have the microphone open and, for Meet, the titles of its windows.
public struct BrowserSignature: Sendable, Equatable, Identifiable {
    public var name: String
    public var bundleIDPrefixes: [String]
    public var executableNames: [String]
    /// The bundle ID the audio tap targets. The tap also captures every `<id>.` helper process.
    public var captureBundleID: String
    /// Whether Meet may be started from this browser without the user's confirmation. Safari plays web audio through shared
    /// WebKit processes, so its microphone signal is not proven to belong to Safari: it is listed for manual choice only.
    public var detectsAutomatically: Bool
    public var id: String { captureBundleID }

    public init(
        name: String, bundleIDPrefixes: [String], executableNames: [String] = [], captureBundleID: String,
        detectsAutomatically: Bool = true
    ) {
        self.name = name
        self.bundleIDPrefixes = bundleIDPrefixes
        self.executableNames = executableNames
        self.captureBundleID = captureBundleID
        self.detectsAutomatically = detectsAutomatically
    }

    public static let defaults: [BrowserSignature] = [
        BrowserSignature(name: "Chrome", bundleIDPrefixes: ["com.google.Chrome"], executableNames: ["Google Chrome"], captureBundleID: "com.google.Chrome"),
        BrowserSignature(name: "Edge", bundleIDPrefixes: ["com.microsoft.edgemac"], executableNames: ["Microsoft Edge"], captureBundleID: "com.microsoft.edgemac"),
        BrowserSignature(name: "Brave", bundleIDPrefixes: ["com.brave.Browser"], executableNames: ["Brave Browser"], captureBundleID: "com.brave.Browser"),
        BrowserSignature(name: "Arc", bundleIDPrefixes: ["company.thebrowser.Browser"], executableNames: ["Arc"], captureBundleID: "company.thebrowser.Browser"),
        BrowserSignature(name: "Vivaldi", bundleIDPrefixes: ["com.vivaldi.Vivaldi"], executableNames: ["Vivaldi"], captureBundleID: "com.vivaldi.Vivaldi"),
        BrowserSignature(name: "Opera", bundleIDPrefixes: ["com.operasoftware.Opera"], executableNames: ["Opera"], captureBundleID: "com.operasoftware.Opera"),
        BrowserSignature(name: "Firefox", bundleIDPrefixes: ["org.mozilla.firefox"], executableNames: ["firefox"], captureBundleID: "org.mozilla.firefox"),
        BrowserSignature(
            name: "Safari", bundleIDPrefixes: ["com.apple.Safari", "com.apple.WebKit."], executableNames: ["Safari"],
            captureBundleID: "com.apple.WebKit", detectsAutomatically: false),
    ]

    func matches(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        return bundleIDPrefixes.contains { lower.hasPrefix($0.lowercased()) }
    }
}

/// Reads window titles of a running browser. The real implementation uses the Accessibility API, which Earmark already asks
/// for (Dictation). No Google account, cookie, page content or network request is involved.
public protocol MeetingContextChecking: Sendable {
    /// Whether titles can be read (Accessibility granted).
    var canReadTitles: Bool { get }
    func windowTitles(bundleIDPrefixes: [String]) async -> [String]
}

/// Used when no reader is supplied: Meet cannot be recognised, manual choice still works.
public struct NoMeetingContext: MeetingContextChecking {
    public init() {}
    public var canReadTitles: Bool { false }
    public func windowTitles(bundleIDPrefixes: [String]) async -> [String] { [] }
}

/// Recognises the window title of a Google Meet call tab ("Meet - abc-defg-hij", with the browser name appended).
public enum MeetTitle {
    /// A Meet title carries the word "Meet" and a meeting code (three, four and three lowercase letters). Matching the code
    /// keeps the Meet landing page and other pages that merely mention "meet" from counting as a call.
    public static func isMeetCall(_ title: String) -> Bool {
        let lower = title.lowercased()
        guard lower.contains("meet") else { return false }
        return lower.range(of: #"(?<![a-z])[a-z]{3}-[a-z]{4}-[a-z]{3}(?![a-z])"#, options: .regularExpression) != nil
    }
}

/// One browser's current state (the injectable detection seam for browsers).
public struct BrowserReading: Sendable, Equatable {
    public var browser: BrowserSignature
    public var isRunning: Bool
    public var micInput: Bool
    public var audioOutput: Bool
    public var deviceMicInUse: Bool
    /// A window of this browser has a Meet call title.
    public var meetWindowOpen: Bool
    public init(
        browser: BrowserSignature, isRunning: Bool = false, micInput: Bool = false, audioOutput: Bool = false,
        deviceMicInUse: Bool = false, meetWindowOpen: Bool = false
    ) {
        self.browser = browser
        self.isRunning = isRunning
        self.micInput = micInput
        self.audioOutput = audioOutput
        self.deviceMicInUse = deviceMicInUse
        self.meetWindowOpen = meetWindowOpen
    }
}

/// One call Earmark can see right now and offer to transcribe.
public struct DetectedCall: Sendable, Equatable, Identifiable {
    public var id: String
    public var app: MeetingApp
    /// "Zoom", "Google Meet in Chrome", "Browser call in Safari".
    public var label: String
    /// The bundle ID whose audio is captured (a browser for Meet and browser calls); nil lets the runtime resolve it.
    public var captureBundleID: String?
    /// Why Earmark thinks this is a call, in plain words.
    public var detail: String
    public init(id: String, app: MeetingApp, label: String, captureBundleID: String?, detail: String) {
        self.id = id
        self.app = app
        self.label = label
        self.captureBundleID = captureBundleID
        self.detail = detail
    }
}

/// The outcome of one scan: the calls found, and what was seen otherwise (shown when nothing was found).
public struct MeetingScan: Sendable, Equatable {
    public var calls: [DetectedCall]
    public var notes: [String]
    /// A browser is using the microphone but window titles cannot be read, so Meet could not be told apart from other calls.
    public var needsAccessibilityForMeet: Bool
    public init(calls: [DetectedCall] = [], notes: [String] = [], needsAccessibilityForMeet: Bool = false) {
        self.calls = calls
        self.notes = notes
        self.needsAccessibilityForMeet = needsAccessibilityForMeet
    }
}
