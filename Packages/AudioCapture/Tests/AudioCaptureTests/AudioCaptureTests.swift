import Testing

@testable import AudioCapture

@Test func moduleLoads() { #expect(AudioCaptureModule.name == "AudioCapture") }
