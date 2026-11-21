import Foundation
import DiarCore
import FluidEngine
import SpeakerKitEngine

// Usage:
//   diar-poc diarize <fluid|speakerkit> <audio> --out <dir> --cache <dir> [--speakers N]
//   diar-poc match <a.json> <b.json>             cosine-distance matrix between speaker centroids of two runs
//   diar-poc dualtrack <mic.wav> <remote.wav> --out <dir> --cache <dir> [--engine fluid|speakerkit]
// Models are cached under --cache (point at .model-cache); never in ~/Library.

func arg(_ name: String, in a: [String]) -> String? { a.firstIndex(of: name).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
func engine(_ n: String, speakers: Int?) -> any DiarizationEngine {
    n == "speakerkit" ? SpeakerKitEngine(numSpeakers: speakers) : FluidOfflineEngine(numSpeakers: speakers)
}
func die(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(2) }

let a = Array(CommandLine.arguments.dropFirst())
guard let cmd = a.first else { die("usage: diar-poc diarize|match|dualtrack ...") }
let cache = URL(fileURLWithPath: arg("--cache", in: a) ?? ".model-cache")
let outDir = URL(fileURLWithPath: arg("--out", in: a) ?? ".")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let speakers = arg("--speakers", in: a).flatMap(Int.init)

switch cmd {
case "diarize":
    guard a.count >= 3 else { die("diarize <engine> <audio>") }
    let url = URL(fileURLWithPath: a[2]); let uri = url.deletingPathExtension().deletingPathExtension().lastPathComponent
    let samples = try Audio.load16kMono(url)
    let out = try await engine(a[1], speakers: speakers).diarize(samples: samples, cacheDir: cache)
    try RTTM.write(out.turns, uri: uri, to: outDir.appendingPathComponent("\(a[1])-\(uri).rttm"))
    try JSONEncoder().encode(out).write(to: outDir.appendingPathComponent("\(a[1])-\(uri).json"))
    print("\(a[1]) \(uri): \(out.turns.count) turns, \(out.embeddings.count) speakers")
case "match":
    guard a.count >= 3 else { die("match a.json b.json") }
    let x = try JSONDecoder().decode(DiarOutput.self, from: Data(contentsOf: URL(fileURLWithPath: a[1])))
    let y = try JSONDecoder().decode(DiarOutput.self, from: Data(contentsOf: URL(fileURLWithPath: a[2])))
    print("A\\B," + y.embeddings.keys.sorted().joined(separator: ","))
    for (ka, va) in x.embeddings.sorted(by: { $0.key < $1.key }) {
        print(ka + "," + y.embeddings.sorted(by: { $0.key < $1.key }).map { String(format: "%.3f", Vec.cosineDistance(va, $0.value)) }.joined(separator: ","))
    }
case "dualtrack":
    // mic = local user ("You"), remote = everyone else. Mic: VAD only. Remote: diarize.
    // NOTE: assumes tracks are already echo-free; with speakers (no headphones) the mic carries remote bleed.
    guard a.count >= 3 else { die("dualtrack <mic> <remote>") }
    let mic = try Audio.load16kMono(URL(fileURLWithPath: a[1]))
    let remote = try Audio.load16kMono(URL(fileURLWithPath: a[2]))
    let you = try await FluidVAD.spans(samples: mic, cacheDir: cache)
    let eng = engine(arg("--engine", in: a) ?? "fluid", speakers: speakers)
    let others = try await eng.diarize(samples: remote, cacheDir: cache)
    // Cross-track gating: drop mic spans that overlap >50% with remote speech (crude bleed guard).
    func overlap(_ s: Turn) -> Double {
        others.turns.reduce(0) { $0 + max(0, min(s.end, $1.end) - max(s.start, $1.start)) } / max(s.end - s.start, 1e-6)
    }
    let gated = you.filter { overlap($0) < 0.5 }
    let merged = (gated + others.turns).sorted { $0.start < $1.start }
    try RTTM.write(merged, uri: "dual", to: outDir.appendingPathComponent("dualtrack.rttm"))
    print("You spans: \(you.count) (\(gated.count) after bleed gate); remote speakers: \(others.embeddings.count)")
case "stream":
    // stream <kind> <audio> --out dir --cache dir [--chunk 0.1] ; kinds: see FluidStreamEngine.run
    guard a.count >= 3 else { die("stream <kind> <audio>") }
    let url = URL(fileURLWithPath: a[2]); let uri = url.deletingPathExtension().deletingPathExtension().lastPathComponent
    let chunk = arg("--chunk", in: a).flatMap(Double.init) ?? (a[1] == "legacy" ? 5.0 : 0.1)
    let samples = try Audio.load16kMono(url)
    let r = try await FluidStreamEngine().run(kind: a[1], samples: samples, cache: cache, chunk: chunk)
    try RTTM.write(r.turns, uri: uri, to: outDir.appendingPathComponent("stream-\(a[1])-\(uri).rttm"))
    try JSONEncoder().encode(r).write(to: outDir.appendingPathComponent("stream-\(a[1])-\(uri).json"))
    print("\(a[1]) \(uri): \(r.turns.count) finalized turns, \(r.updates.count) updates, slots=\(r.maxSlots)")
case "stream-dual":
    // Live dual-track simulation: mic -> streaming VAD ("You"), remote -> streaming diarizer; both fed in lockstep
    // in 100 ms steps (as fast as possible, no pacing). --bleed g mixes g*remote into the mic track (speaker bleed).
    guard a.count >= 3 else { die("stream-dual <mic> <remote>") }
    var mic = try Audio.load16kMono(URL(fileURLWithPath: a[1]))
    var remote = try Audio.load16kMono(URL(fileURLWithPath: a[2]))
    let n = min(mic.count, remote.count); mic = Array(mic.prefix(n)); remote = Array(remote.prefix(n))
    if let g = arg("--bleed", in: a).flatMap(Float.init) { for i in 0..<n { mic[i] += g * remote[i] } }
    let kind = arg("--kind", in: a) ?? "lseend-ami"
    let gate = arg("--gate", in: a) != "off"
    let vad = LiveMicVAD(); try await vad.start(cache: cache)
    // remote diarization runs on its own; mic VAD runs in lockstep. Spans are merged on the fly with the gate.
    let rr = try await FluidStreamEngine().run(kind: kind, samples: remote, cache: cache, chunk: 0.1)
    var youAll: [Turn] = []
    var i = 0
    while i < n { let j = min(i + 1600, n); youAll += try await vad.feed(Array(mic[i..<j])); i = j }
    youAll += await vad.finish()
    func ov(_ s: Turn) -> Double { rr.turns.reduce(0) { $0 + max(0, min(s.end, $1.end) - max(s.start, $1.start)) } / max(s.end - s.start, 1e-6) }
    let you = gate ? youAll.filter { ov($0) < 0.5 } : youAll
    let tag = (arg("--tag", in: a) ?? "dual")
    try RTTM.write(you + rr.turns.map { Turn(speaker: "R" + $0.speaker, start: $0.start, end: $0.end) }, uri: tag, to: outDir.appendingPathComponent("\(tag).rttm"))
    try RTTM.write(youAll, uri: tag, to: outDir.appendingPathComponent("\(tag)-you-raw.rttm"))
    print("\(tag): You spans raw \(youAll.count) kept \(you.count); remote turns \(rr.turns.count)")
default: die("unknown command")
}
