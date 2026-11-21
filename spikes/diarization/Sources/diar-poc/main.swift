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
default: die("unknown command")
}
