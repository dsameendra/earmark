import AppCore
import Foundation
import Testing

@testable import Meetings

@Suite("Recording names and language")
struct RecordingNamingTests {
    @Test("the recording folder and the transcript title name the service, not just Zoom or Teams", arguments: [
        (MeetingApp.zoom, "Zoom"), (.teams, "Microsoft Teams"), (.meet, "Google Meet"), (.discord, "Discord"), (.browser, "Browser call"),
    ])
    func names(app: MeetingApp, name: String) {
        let id = MeetingID()
        let folder = MeetingSessionController.recordingFolderName(app: app, startedAt: Date(timeIntervalSince1970: 1_700_000_000), meetingID: id)
        #expect(folder.contains(" \(name) "))
        #expect(folder.hasSuffix(String(id.rawValue.uuidString.prefix(8))))
        let title = MeetingFinalizer.title(for: Meeting(app: app, startedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(title.hasPrefix(name))
        #expect(app == .meet || app == .browser || title.hasPrefix("\(name) meeting, "))
        #expect(!title.contains("meeting meeting") && !title.hasPrefix("Browser call meeting") && !title.hasPrefix("Google Meet meeting"))
    }

    @Test("auto-detect follows the one language the live pass heard")
    func autoDetectFollowsLive() {
        let en = LanguageCode("en")
        #expect(MeetingFinalizer.resolvedLanguageMode(.autoDetect, liveLanguages: [en, en, nil]) == .single(en))
    }

    @Test("auto-detect stays when live heard several languages or none; explicit settings are untouched")
    func autoDetectOtherwise() {
        let en = LanguageCode("en")
        let si = LanguageCode("si")
        #expect(MeetingFinalizer.resolvedLanguageMode(.autoDetect, liveLanguages: [en, si]) == .autoDetect)
        #expect(MeetingFinalizer.resolvedLanguageMode(.autoDetect, liveLanguages: []) == .autoDetect)
        #expect(MeetingFinalizer.resolvedLanguageMode(.single(si), liveLanguages: [en]) == .single(si))
        #expect(MeetingFinalizer.resolvedLanguageMode(.multilingual([en, si]), liveLanguages: [en]) == .multilingual([en, si]))
    }
}
