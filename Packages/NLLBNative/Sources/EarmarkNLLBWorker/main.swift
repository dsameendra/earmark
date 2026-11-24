import Foundation
import NLLBNative
import NativeWorkerKit

struct Request: Decodable {
    let id: Int
    let src: String?
    let tgt: String?
    let texts: [String]
    let op: String?
}

// One persistent model, serial JSON-lines requests. The app terminates this isolated process on cancellation.
func reply(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    guard data.count <= WorkerTransport.maximumMessageBytes else { throw NativeNLLBError(message: "Translation response exceeded the message limit.") }
    try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
}

guard CommandLine.arguments.count >= 2 else { exit(64) }
do {
    let requestedProfile = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "nllb"
    guard let profile = NativeTranslationProfile(rawValue: requestedProfile) else {
        throw NativeNLLBError(message: "Unsupported translation model profile.")
    }
    let model = try NativeNLLBModel(
        folder: URL(fileURLWithPath: CommandLine.arguments[1]),
        threads: CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 4 : 4,
        profile: profile)
    try reply(["ready": true, "profile": profile.rawValue])
    try WorkerInput.forEachLine { line in
        var id = -1
        do {
            let request = try JSONDecoder().decode(Request.self, from: line)
            id = request.id
            let texts = request.texts
            guard id >= 0, texts.count <= 8, texts.allSatisfy({ $0.utf8.count <= 100_000 }),
                  request.op == nil || request.op == "translate" || request.op == "tokens"
            else {
                throw NativeNLLBError(message: "Invalid translation request.")
            }
            if request.op == "tokens" {
                try reply(["id": id, "tokens": try texts.map { try model.tokens(for: $0) }])
            } else {
                guard let source = request.src, let target = request.tgt,
                    source.utf8.count <= 128, target.utf8.count <= 128
                else {
                    throw NativeNLLBError(message: "Missing language tags or oversized batch.")
                }
                let output = try texts.map { try model.translate($0, source: source, target: target) }
                try reply(["id": id, "out": output])
            }
        } catch { try reply(["id": id, "error": error.localizedDescription]) }
    }
} catch {
    try? reply(["error": error.localizedDescription])
    exit(1)
}
