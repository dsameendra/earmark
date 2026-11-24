import AppCore
import Foundation

/// Larger general checkpoint, kept separate from the Sinhala specialist and from performance recommendations.
enum QwenCatalog {
    static let models: [ModelDescriptor] = [
        ModelDescriptor(
            id: "mlx/qwen3-asr-1.7b-4bit", displayName: "Qwen3-ASR 1.7B (multilingual)", kind: .asr, runtime: .mlx,
            engine: "qwen3-asr", languages: BuiltInCatalog.qwenLanguages, sizeBytes: 1_607_631_587 + QwenSpeechDetectorFiles.sizeBytes,
            license: LicenseInfo(spdx: "Apache-2.0 AND MIT", attribution: "Qwen3-ASR by Qwen; MLX conversion by mlx-community (Apache 2.0). Includes Silero VAD by the Silero Team, converted by FluidInference (MIT)."),
            minTier: .tier16,
            sourceURL: URL(string: "https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-4bit/tree/78a389c776a5483b2d0d4ea5494e11012e0d6159"),
            isExperimental: true,
            notes: "Larger 30-language model with language detection. Buffered Live captions; no word timestamps. Memory and sustained speed remain under review. Choose the Sinhala specialist for Sinhala.",
            capabilities: ModelCapabilities(live: true, file: true, autoDetectLanguage: true, streaming: .buffered),
            downloadInclude: ["README.md", "chat_template.json", "config.json", "generation_config.json", "merges.txt", "model.safetensors", "model.safetensors.index.json", "preprocessor_config.json", "tokenizer_config.json", "vocab.json"],
            provenance: ModelProvenance(repository: "mlx-community/Qwen3-ASR-1.7B-4bit", revision: "78a389c776a5483b2d0d4ea5494e11012e0d6159",
                profileID: "mlx.qwen3-asr.multilingual", profileVersion: 1,
                artifacts: [
                    ModelArtifactDigest(path: "README.md", bytes: 1_008, sha256: "4d7f16d0a01cd626a3d5291b77249f135eeedd9b1b259d17716cc6b3ef7365cb"),
                    ModelArtifactDigest(path: "chat_template.json", bytes: 1_161, sha256: "75a8cfca24f00de72d796fbfed6858fc9614ef3dabd8696684cc3bc03a9c58ff"),
                    ModelArtifactDigest(path: "config.json", bytes: 7_188, sha256: "539c6c9d482349066e2e740241e39896f3bf4de0866c245f6539c85dbb19d93c"),
                    ModelArtifactDigest(path: "generation_config.json", bytes: 142, sha256: "1da527824d81e07118facff437e03f2e24a23311e3bdeb2368973fe77e5f275c"),
                    ModelArtifactDigest(path: "merges.txt", bytes: 1_671_853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
                    ModelArtifactDigest(path: "model.safetensors", bytes: 1_603_081_617, sha256: "9848eaf7a5c1589c671b35035ac27b72e248dd0c604eacae547e7e403d29db45"),
                    ModelArtifactDigest(path: "model.safetensors.index.json", bytes: 78_968, sha256: "2612ab715223843b3dec0742737bc85f50914ca1484ade45955f99b4e012f2bb"),
                    ModelArtifactDigest(path: "preprocessor_config.json", bytes: 330, sha256: "45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d"),
                    ModelArtifactDigest(path: "tokenizer_config.json", bytes: 12_487, sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
                    ModelArtifactDigest(path: "vocab.json", bytes: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
                ] + detectorArtifacts, validation: .nativeInferenceChecked))
    ]

    private static var detectorArtifacts: [ModelArtifactDigest] {
        QwenSpeechDetectorFiles.artifacts.map {
            ModelArtifactDigest(path: QwenSpeechDetectorFiles.relativeFolder + "/" + $0.path, bytes: $0.bytes, sha256: $0.sha256)
        }
    }
}
