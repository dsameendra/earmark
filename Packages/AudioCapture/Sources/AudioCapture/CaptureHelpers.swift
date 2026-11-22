import AppCore
import Foundation

/// Mixes a mic chunk and a remote chunk by host time (AUD-AC-15: alignment within 20 ms).
public enum AudioChunkMixer {
    /// Returns one `.mixed` chunk covering both inputs. Alignment uses `hostTime` when both chunks have one (converted with
    /// `ticksPerSecond`, default the machine's mach timebase), otherwise `startSeconds`. Samples are summed and clamped.
    public static func mix(
        _ first: AudioChunk, _ second: AudioChunk, ticksPerSecond: Double? = nil
    ) -> AudioChunk {
        let rate = AudioChunk.sampleRate
        let offsetSeconds: Double  // second relative to first
        if first.hostTime != 0, second.hostTime != 0 {
            let delta =
                second.hostTime >= first.hostTime
                ? Double(second.hostTime - first.hostTime) : -Double(first.hostTime - second.hostTime)
            offsetSeconds = delta / (ticksPerSecond ?? HostClock.ticksPerSecond)
        } else {
            offsetSeconds = second.startSeconds - first.startSeconds
        }
        let secondOffset = Int((offsetSeconds * rate).rounded())
        let origin = min(0, secondOffset)  // earliest sample index relative to first's start
        let firstStart = -origin
        let secondStart = secondOffset - origin
        let count = max(firstStart + first.samples.count, secondStart + second.samples.count)
        var out = [Float](repeating: 0, count: count)
        for (index, sample) in first.samples.enumerated() { out[firstStart + index] += sample }
        for (index, sample) in second.samples.enumerated() { out[secondStart + index] += sample }
        for index in out.indices { out[index] = max(-1, min(1, out[index])) }
        let earlierIsFirst = secondOffset >= 0
        let earlier = earlierIsFirst ? first : second
        return AudioChunk(samples: out, hostTime: earlier.hostTime, startSeconds: earlier.startSeconds, source: .mixed)
    }
}

/// Pure decision helpers for the capture hints in the UI.
public enum CaptureHints {
    /// AUD-AC-12: show the one-time headphone hint when mic and system audio are captured together on non-headphone output.
    public static func shouldShowHeadphoneHint(capturingMicAndSystem: Bool, outputLooksLikeHeadphones: Bool, alreadyShown: Bool) -> Bool {
        capturingMicAndSystem && !outputLooksLikeHeadphones && !alreadyShown
    }

    /// AUD-AC-13: when the default input is a Bluetooth device (HFP call mode degrades audio), suggest a non-Bluetooth input,
    /// preferring the built-in microphone. Returns nil when no suggestion applies.
    public static func suggestedMicrophone(defaultInput: AudioDevice?, devices: [AudioDevice]) -> AudioDevice? {
        guard let defaultInput, defaultInput.isBluetooth else { return nil }
        let candidates = devices.filter { $0.isInput && !$0.isBluetooth }
        let builtIn = candidates.first {
            $0.name.localizedCaseInsensitiveContains("built-in") || $0.name.localizedCaseInsensitiveContains("macbook")
        }
        return builtIn
            ?? candidates.first
    }
}
