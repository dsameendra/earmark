import AVFoundation
import CoreMedia

/// Crash-safe-ish AAC writer. MPEG-4 (mp4/mov) with movieFragmentInterval: moov info is written in fragments so a crash
/// loses at most one interval. (Plain .m4a does not support fragments - UNVERIFIED on 27; see report.)
final class AACTrackWriter {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    private var started = false
    private let asbd: AudioStreamBasicDescription
    private var framesWritten: Int64 = 0

    init(url: URL, sampleRate: Double, channels: Int, bitrate: Int = 64_000) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: bitrate,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    /// Append interleaved Float32 frames. PTS derived from running frame count (gap-free file; real gaps need silence-fill).
    func append(interleaved p: UnsafePointer<Float>, frames: Int) {
        if !started { writer.startWriting(); writer.startSession(atSourceTime: .zero); started = true }
        guard input.isReadyForMoreMediaData, frames > 0 else { return }
        var a = asbd
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &a, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        var sb: CMSampleBuffer?
        let pts = CMTime(value: framesWritten, timescale: CMTimeScale(a.mSampleRate))
        guard CMAudioSampleBufferCreateWithPacketDescriptions(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: fd!, sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb) == noErr, let sb else { return }
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: a.mChannelsPerFrame,
            mDataByteSize: UInt32(frames * Int(a.mBytesPerFrame)), mData: UnsafeMutableRawPointer(mutating: p)))
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: &abl) == noErr else { return }
        input.append(sb)
        framesWritten += Int64(frames)
    }

    func finish() async { input.markAsFinished(); await writer.finishWriting(); if writer.status == .failed { print("[writer] failed: \(String(describing: writer.error))") } }
}

/// Post-hoc mix of two tracks into one m4a (AVMutableComposition + export). Realtime mixing is deferred to the app's mixer.
func mixTracks(_ urls: [URL], to out: URL) async throws {
    let comp = AVMutableComposition()
    for u in urls {
        let a = AVURLAsset(url: u)
        guard let src = try await a.loadTracks(withMediaType: .audio).first else { continue }
        let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        try t?.insertTimeRange(CMTimeRange(start: .zero, duration: try await a.load(.duration)), of: src, at: .zero)
    }
    try? FileManager.default.removeItem(at: out)
    guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else { return }
    try await ex.export(to: out, as: .m4a)
}
