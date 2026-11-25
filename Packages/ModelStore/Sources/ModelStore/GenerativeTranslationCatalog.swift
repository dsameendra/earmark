import AppCore
import Foundation

/// Hy-MT2 and TranslateGemma Q4_K_M checkpoints for the isolated native text worker.
/// Only the directions that passed the frozen quality screen are advertised; see the generative evidence report.
enum GenerativeTranslationCatalog {
    private static let screened: Set<LanguagePair> = {
        var pairs: Set<LanguagePair> = []
        for other in ["de", "fr", "es"] as [LanguageCode] {
            pairs.insert(LanguagePair(source: "en", target: other))
            pairs.insert(LanguagePair(source: other, target: "en"))
        }
        pairs.insert(LanguagePair(source: "ja", target: "en"))
        pairs.insert(LanguagePair(source: "zh", target: "en"))
        return pairs
    }()

    private static let languages: Set<LanguageCode> = ["en", "de", "fr", "es", "ja", "zh"]
    private static let gemmaTerms = "Gemma is provided under and subject to the Gemma Terms of Use at https://ai.google.dev/gemma/terms and the Gemma Prohibited Use Policy. Use of this model means you accept them."

    private static func hf(_ path: String) -> URL { URL(string: "https://huggingface.co/\(path)")! }

    static let models: [ModelDescriptor] = [
        hymt(
            id: "hymt2/1.8b-gguf-q4-k-m", name: "Hy-MT2 1.8B (Q4)", engine: "hymt2-1.8b", tier: .tier8,
            file: "Hy-MT2-1.8B-Q4_K_M.gguf", repo: "tencent/Hy-MT2-1.8B-GGUF", revision: BuiltInCatalog.Revision.hymt18,
            weights: (1_133_080_448, "dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699"),
            license: (11_639, "a1d52d448f81c584a47c583e19dfab2d3851c7c84431b07baee093c1113ed114"),
            readme: (15_305, "6811073b8b3d20a9a4db959c2b3f36e39e66bdb953cfecbdd8223fc20cc9a05b"),
            extraPairs: [],
            note: "Compact Tencent translation model. Offered for English with German, French and Spanish, and for Japanese and Chinese into English; English into Japanese and Chinese did not pass Earmark's quality screen."),
        hymt(
            id: "hymt2/7b-gguf-q4-k-m", name: "Hy-MT2 7B (Q4)", engine: "hymt2-7b", tier: .tier16,
            file: "Hy-MT2-7B-Q4_K_M.gguf", repo: "tencent/Hy-MT2-7B-GGUF", revision: BuiltInCatalog.Revision.hymt7,
            weights: (4_624_648_896, "9f96256500f3fc1ab4d64336b58f52a949a95ad7516b0c229476eef782f9f77b"),
            license: (11_635, "746750afa6af28fe4f8b326751ad2a40c700d2e5c459c0a1f6a2e76d99ace224"),
            readme: (15_276, "9c9054f91dc86809e5da4d187a16b69ce39ebf02143767b1253bf1f26f1206a1"),
            extraPairs: [LanguagePair(source: "en", target: "ja")],
            note: "Larger Tencent translation model with better quality. Offered for English with German, French, Spanish and Japanese, and for Chinese into English; English into Chinese did not pass Earmark's quality screen."),
        gemma(
            id: "translategemma/4b-it-gguf-q4-k-m", name: "TranslateGemma 4B (Q4)", engine: "translategemma-4b", tier: .tier8,
            file: "translategemma-4b-it.Q4_K_M.gguf", repo: "mradermacher/translategemma-4b-it-GGUF", revision: BuiltInCatalog.Revision.gemma4,
            weights: (2_489_909_760, "81200d03e843d2ec1ece6eeafe7d13cb6e5211e1fcd336ade55790b683a08330"),
            readme: (4_521, "c1461baced83658436805467a57ca738eb668f2b7026783006ece0ae2f8e4357")),
        gemma(
            id: "translategemma/12b-it-gguf-q4-k-m", name: "TranslateGemma 12B (Q4)", engine: "translategemma-12b", tier: .tier16,
            file: "translategemma-12b-it.Q4_K_M.gguf", repo: "mradermacher/translategemma-12b-it-GGUF", revision: BuiltInCatalog.Revision.gemma12,
            weights: (7_300_794_112, "b7aac4b4be7ab0c49b6556c29c4467e74313df7f1e95d9f9676bb2adf0afa528"),
            readme: (4_404, "c967757710fcb5828176db561e4feb549c9fc56e843b8050dda03d5d29b34e05")),
    ]

    private static func hymt(
        id: ModelID, name: String, engine: EngineID, tier: HardwareTier, file: String, repo: String, revision: String,
        weights: (Int64, String), license: (Int64, String), readme: (Int64, String), extraPairs: Set<LanguagePair>, note: String
    ) -> ModelDescriptor {
        descriptor(
            id: id, name: name, engine: engine, tier: tier, file: file, repo: repo, revision: revision, weights: weights,
            files: [("LICENSE.txt", license), ("README.md", readme)],
            license: LicenseInfo(spdx: "Apache-2.0", attribution: "Tencent Hy-MT2 GGUF, Apache 2.0, Copyright (C) 2026 Tencent. Weights were quantized, not retrained."),
            pairs: screened.union(extraPairs), note: note)
    }

    private static func gemma(
        id: ModelID, name: String, engine: EngineID, tier: HardwareTier, file: String, repo: String, revision: String,
        weights: (Int64, String), readme: (Int64, String)
    ) -> ModelDescriptor {
        descriptor(
            id: id, name: name, engine: engine, tier: tier, file: file, repo: repo, revision: revision, weights: weights,
            files: [("README.md", readme)],
            license: LicenseInfo(spdx: "LicenseRef-Gemma", attribution: "Google TranslateGemma, a Gemma model; Q4_K_M quantization by mradermacher. " + gemmaTerms),
            pairs: screened,
            note: "Google translation model. Offered for English with German, French and Spanish, and for Japanese and Chinese into English. English into Japanese and Chinese did not pass Earmark's quality screen. Gemma terms apply.")
    }

    private static func descriptor(
        id: ModelID, name: String, engine: EngineID, tier: HardwareTier, file: String, repo: String, revision: String,
        weights: (Int64, String), files: [(String, (Int64, String))], license: LicenseInfo, pairs: Set<LanguagePair>, note: String
    ) -> ModelDescriptor {
        let size = weights.0 + files.map(\.1.0).reduce(0, +)
        let artifacts = [ModelArtifactDigest(path: file, bytes: weights.0, sha256: weights.1)]
            + files.map { ModelArtifactDigest(path: $0.0, bytes: $0.1.0, sha256: $0.1.1) }
        return ModelDescriptor(
            id: id, displayName: name, kind: .translation, runtime: .other, engine: engine, languages: languages, sizeBytes: size,
            license: license, minTier: tier, sourceURL: hf("\(repo)/tree/\(revision)"), isExperimental: true, notes: note,
            capabilities: ModelCapabilities(
                live: false, file: true, translation: true, translationPairs: pairs, translationLanguageMatching: .primary),
            downloadInclude: [file] + files.map(\.0),
            provenance: ModelProvenance(
                repository: repo, revision: revision, profileID: "text.generative.\(engine.rawValue)", profileVersion: 1,
                artifacts: artifacts, validation: .nativeInferenceChecked))
    }
}
