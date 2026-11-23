import AppCore
import Foundation

/// Small, pinned neural detector installed atomically inside each general Qwen model.
/// This is an explicit curated recipe, not an inference-time network fallback.
/// Keeping its 1 MB payload model-owned avoids cross-model deletion/unload ownership.
enum QwenSpeechDetectorFiles {
    static let relativeFolder = "EarmarkSupport/silero-vad-v6.2.1.mlmodelc"
    static let repository = "FluidInference/silero-vad-coreml"
    static let revision = "b419383c55c110e2c9271fa6ee0ea83d03c70d96"
    static let artifacts: [(path: String, bytes: Int64, sha256: String)] = [
        ("analytics/coremldata.bin", 243, "8067594eb3126ab8318af507f0c00cabfed40d5fedb8a0ee5075dd02e903d909"),
        ("coremldata.bin", 625, "7db35a4fd995222a7fb0129713473b15d1462572ab4a2e5e4d56bcaad9e40f41"),
        ("metadata.json", 3_335, "2740be542c611e1ba358e1849b4e265c65cdf0b17192767e1e5de86a31ac94d6"),
        ("model.mil", 176_918, "c6a9d1bf22d413265da0a07a1d14151c3ea2fad296b3aa5859275b33ef1c3270"),
        ("weights/weight.bin", 882_304, "53ecc8b5081146140ab654c89109cf001f2183abddd7a2411c5081feeffff063")
    ]
    static var sizeBytes: Int64 { artifacts.reduce(0) { $0 + $1.bytes } }
    static func files(for model: ModelID) -> [RemoteFile] {
        guard model == "mlx/qwen3-asr-0.6b-4bit" || model == "mlx/qwen3-asr-1.7b-4bit" else { return [] }
        return artifacts.map { artifact in
            RemoteFile(
                relativePath: relativeFolder + "/" + artifact.path,
                url: URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/silero-vad-unified-256ms-v6.2.1.mlmodelc/\(artifact.path)")!,
                sizeBytes: artifact.bytes, sha256: artifact.sha256)
        }
    }
}
