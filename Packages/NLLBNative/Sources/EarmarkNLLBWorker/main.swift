import Foundation
import NLLBNative
import NativeWorkerKit

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
            guard let request = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                let requestID = request["id"] as? Int, requestID >= 0, let texts = request["texts"] as? [String],
                texts.count <= 8, texts.allSatisfy({ $0.utf8.count <= 100_000 })
            else {
                throw NativeNLLBError(message: "Invalid translation request.")
            }
            id = requestID
            if request["op"] as? String == "tokens" {
                try reply(["id": id, "tokens": try texts.map { try model.tokens(for: $0) }])
            } else {
                guard let source = request["src"] as? String, let target = request["tgt"] as? String,
                    texts.count <= 8, texts.allSatisfy({ $0.utf8.count <= 100_000 })
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
