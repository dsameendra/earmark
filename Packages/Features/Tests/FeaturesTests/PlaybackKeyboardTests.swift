import AppKit
import SwiftUI
import Testing

@testable import FeatureEditor

@Suite("Playback keyboard ownership") @MainActor
struct PlaybackKeyboardTests {
    @Test func textEditingAndNativeControlsKeepTheirOwnKeys() {
        let text = NSTextView()
        text.isEditable = true
        #expect(!PlaybackKeyboardFocus.permitsPlayback(firstResponder: text))
        text.isEditable = false
        #expect(PlaybackKeyboardFocus.permitsPlayback(firstResponder: text))
        #expect(!PlaybackKeyboardFocus.permitsPlayback(firstResponder: NSSearchField()))
        #expect(!PlaybackKeyboardFocus.permitsPlayback(firstResponder: NSTextField()))
        #expect(!PlaybackKeyboardFocus.permitsPlayback(firstResponder: NSPopUpButton()))
        #expect(PlaybackKeyboardFocus.permitsPlayback(firstResponder: NSButton()))
        #expect(PlaybackKeyboardFocus.permitsPlayback(firstResponder: NSSlider()))
        #expect(PlaybackKeyboardFocus.permitsPlayback(firstResponder: NSView()))
    }

    @Test func nativeEventsMapTheSameWayInEditorAndDetachedPlayer() throws {
        let space = try event(keyCode: 49, characters: " ")
        let left = try event(keyCode: 123, characters: "\u{F702}")
        let right = try event(keyCode: 124, characters: "\u{F703}")
        #expect(PlaybackShortcut.resolve(event: space) == .togglePlay)
        #expect(PlaybackShortcut.resolve(event: left) == .skip(-5))
        #expect(PlaybackShortcut.resolve(event: right) == .skip(5))
        #expect(PlaybackShortcut.resolve(event: try event(keyCode: 124, characters: "\u{F703}", flags: .option)) == .skip(15))
        #expect(PlaybackShortcut.resolve(event: try event(keyCode: 49, characters: " ", flags: .command)) == nil)
    }

    private func event(keyCode: UInt16, characters: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }
}
