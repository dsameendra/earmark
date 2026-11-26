import AVFoundation
import AppCore
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import os

public enum VideoRecordingError: Error, Equatable, Sendable {
    case noMeetingWindow
    case writerFailed(String)
}

/// Opt-in meeting-window video (MTG-AC-09): `SCStream` of the app's largest on-screen window encoded to HEVC `.mov` with
/// `AVAssetWriter` (10 s movie fragments so an interrupted file stays playable). The first `start` triggers the Screen
/// Recording permission prompt: the permission is needed only at that moment, never at launch.
///
/// Compile-checked only: ScreenCaptureKit behaviour, the TCC prompt and HEVC output are unverified on a real meeting.
public final class ScreenCaptureVideoRecorder: MeetingVideoRecording, @unchecked Sendable {
    private let signatures: [MeetingAppSignature]
    private let framesPerSecond: Int
    private let bitRate: Int
    private let lock = OSAllocatedUnfairLock()
    private var stream: SCStream?
    private var output: FrameWriter?

    public init(signatures: [MeetingAppSignature] = MeetingAppSignature.defaults, framesPerSecond: Int = 10, bitRate: Int = 1_500_000) {
        self.signatures = signatures
        self.framesPerSecond = framesPerSecond
        self.bitRate = bitRate
    }

    public func start(app: MeetingApp, to url: URL) async throws {
        // Meet and browser calls live in a browser window: any known browser counts, and a window titled like a Meet call wins.
        let isBrowserCall = app == .meet || app == .browser
        let signature: MeetingAppSignature
        if isBrowserCall {
            signature = MeetingAppSignature(app: app, bundleIDPrefixes: BrowserSignature.defaults.flatMap(\.bundleIDPrefixes))
        } else if let found = signatures.first(where: { $0.app == app }) {
            signature = found
        } else {
            throw VideoRecordingError.noMeetingWindow
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var windows = content.windows.filter { window in
            window.isOnScreen && window.frame.width >= 200 && window.frame.height >= 150
                && (window.owningApplication?.bundleIdentifier).map(signature.matches) == true
        }
        if isBrowserCall {
            let meetWindows = windows.filter { MeetTitle.isMeetCall($0.title ?? "") }
            if !meetWindows.isEmpty { windows = meetWindows }
        }
        guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw VideoRecordingError.noMeetingWindow
        }
        let width = Int(window.frame.width) / 2 * 2
        let height = Int(window.frame.height) / 2 * 2
        let writer = try FrameWriter(url: url, width: width, height: height, bitRate: bitRate)

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = false
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: nil)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        try await stream.startCapture()
        lock.withLock {
            self.stream = stream
            self.output = writer
        }
    }

    public func stop() async throws {
        let (stream, writer) = lock.withLock { () -> (SCStream?, FrameWriter?) in
            defer {
                self.stream = nil
                self.output = nil
            }
            return (self.stream, self.output)
        }
        try? await stream?.stopCapture()
        try await writer?.finish()
    }
}

/// Receives screen frames and appends them to an HEVC `AVAssetWriter`.
private final class FrameWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "lk.dumindu.earmark.meetings.video")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var sessionStarted = false

    init(url: URL, width: Int, height: Int, bitRate: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate],
            ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw VideoRecordingError.writerFailed("cannot add video input") }
        writer.add(input)
        guard writer.startWriting() else { throw VideoRecordingError.writerFailed(writer.error?.localizedDescription ?? "startWriting") }
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, writer.status == .writing else { return }
        // Only complete frames carry pixel data (idle/blank frames are status-only).
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete
        else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData { input.append(sampleBuffer) }
    }

    func finish() async throws {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
        guard sessionStarted else {
            writer.cancelWriting()
            throw VideoRecordingError.noMeetingWindow
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed { throw VideoRecordingError.writerFailed(writer.error?.localizedDescription ?? "failed") }
    }
}
