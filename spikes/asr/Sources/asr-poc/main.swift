// Earmark Phase 0 ASR spike.
// Usage:
//   asr-poc locales                          # print SpeechTranscriber/DictationTranscriber locales (no permissions needed)
//   asr-poc apple <audio-file> [locale]      # SpeechAnalyzer file transcription (downloads assets if missing)
//   asr-poc whisper <audio-file> <modelFolder|variant> [lang]   # WhisperKit file transcription w/ word timestamps
//   asr-poc detect <audio-file> <modelFolder|variant>           # WhisperKit language detection
// No timing is measured on purpose; wrap with `time` or the orchestrator's harness.
import Foundation
import AVFoundation
import Speech
import WhisperKit

func fmt(_ t: CMTime) -> String { String(format: "%.2f", t.seconds) }

func listLocales() async {
    let st = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
    let dt = await DictationTranscriber.supportedLocales.map(\.identifier).sorted()
    let inst = await SpeechTranscriber.installedLocales.map(\.identifier).sorted()
    print("SpeechTranscriber.isAvailable = \(SpeechTranscriber.isAvailable)")
    print("SpeechTranscriber supported (\(st.count)): \(st.joined(separator: ", "))")
    print("SpeechTranscriber installed (\(inst.count)): \(inst.joined(separator: ", "))")
    print("DictationTranscriber supported (\(dt.count)): \(dt.joined(separator: ", "))")
    for probe in ["si-LK", "si", "ta-IN", "hi-IN", "en-US"] {
        let m = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: probe))
        let d = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: probe))
        print("probe \(probe): speech=\(m?.identifier ?? "nil") dictation=\(d?.identifier ?? "nil")")
    }
}

func appleTranscribe(path: String, localeID: String) async throws {
    let locale = Locale(identifier: localeID)
    guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
        print("Locale \(localeID) NOT supported by SpeechTranscriber"); return
    }
    // Preset gives volatile (progressive) results + audioTimeRange per run.
    let transcriber = SpeechTranscriber(locale: supported, preset: .timeIndexedProgressiveTranscription)
    let status = await AssetInventory.status(forModules: [transcriber])
    print("asset status: \(status)")
    if status < .installed, let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        print("downloading speech assets for \(supported.identifier)...")
        try await req.downloadAndInstall()
    }
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    // Collect results concurrently while the analyzer consumes the file.
    let collector = Task {
        for try await r in transcriber.results {
            let tag = r.isFinal ? "FINAL   " : "volatile"
            print("[\(tag)] \(fmt(r.range.start))-\(fmt(r.range.end)) \(String(r.text.characters))")
            if r.isFinal {
                for run in r.text.runs {
                    if let tr = run.audioTimeRange {
                        print("    word \(fmt(tr.start))-\(fmt(tr.end)) '\(String(r.text[run.range].characters))'")
                    }
                }
            }
        }
    }
    if let last = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: last)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    try await collector.value
}

func makeWhisper(_ modelArg: String) async throws -> WhisperKit {
    var cfg = WhisperKitConfig()
    if modelArg.hasPrefix("/") { cfg.modelFolder = modelArg; cfg.download = false }  // pre-downloaded CoreML folder
    else { cfg.model = modelArg; cfg.downloadBase = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EARMARK_MODEL_CACHE"] ?? "./models") }
    cfg.verbose = false
    return try await WhisperKit(cfg)
}

func whisperTranscribe(path: String, model: String, lang: String?) async throws {
    let pipe = try await makeWhisper(model)
    var opts = DecodingOptions()
    opts.wordTimestamps = true
    opts.skipSpecialTokens = true
    opts.language = lang
    opts.detectLanguage = (lang == nil)
    let results = try await pipe.transcribe(audioPath: path, decodeOptions: opts)
    for r in results {
        print("language=\(r.language)")
        for s in r.segments {
            print(String(format: "[%.2f-%.2f] %@", s.start, s.end, s.text))
            for w in s.words ?? [] { print(String(format: "    %.2f-%.2f %@ (p=%.2f)", w.start, w.end, w.word, w.probability)) }
        }
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: see header"); exit(2) }
do {
    switch args[1] {
    case "locales": await listLocales()
    case "apple": try await appleTranscribe(path: args[2], localeID: args.count > 3 ? args[3] : "en-US")
    case "whisper": try await whisperTranscribe(path: args[2], model: args[3], lang: args.count > 4 ? args[4] : nil)
    case "detect":
        let p = try await makeWhisper(args[3])
        let d = try await p.detectLanguage(audioPath: args[2])
        print("detected=\(d.language)"); for (k, v) in d.langProbs.sorted(by: { $0.value > $1.value }).prefix(5) { print(" \(k) \(v)") }
    default: print("unknown command")
    }
} catch { print("ERROR: \(error)"); exit(1) }
