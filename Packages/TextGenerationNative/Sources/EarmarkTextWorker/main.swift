import Foundation
import NativeWorkerKit
import TextGenerationNative

struct Request: Decodable {
    let id: Int
    let src: String
    let tgt: String
    let texts: [String]
    let op: String?
}

func reply(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    guard data.count <= WorkerTransport.maximumMessageBytes else { throw NativeTextError(message: "Native translation exceeded the reply limit.") }
    try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count == 4, let threads = Int(arguments[2]), let profile = GenerativeProfile(rawValue: arguments[3]) else {
        throw NativeTextError(message: "Expected a local model folder, thread count and supported generative profile.")
    }
    let model = try NativeTextModel(folder: URL(fileURLWithPath: arguments[1]), profile: profile, threads: threads)
    try reply(["ready": true, "profile": profile.rawValue])
    try WorkerInput.forEachLine { data in
        var id = -1
        do {
            let request = try JSONDecoder().decode(Request.self, from: data)
            id = request.id
            guard id >= 0, !request.texts.isEmpty, request.texts.count <= 8,
                  request.op == nil || request.op == "translate" || request.op == "tokens" else {
                throw NativeTextError(message: "Invalid native translation request.")
            }
            if request.op == "tokens" {
                try reply(["id": id, "tokens": try request.texts.map { try model.tokens(text: $0, source: request.src, target: request.tgt) }])
                return
            }
            let output = try request.texts.map { try model.translate(text: $0, source: request.src, target: request.tgt) }
            try reply(["id": id, "out": output])
        } catch { try reply(["id": id, "error": error.localizedDescription]) }
    }
} catch {
    try? reply(["error": error.localizedDescription])
    exit(1)
}
