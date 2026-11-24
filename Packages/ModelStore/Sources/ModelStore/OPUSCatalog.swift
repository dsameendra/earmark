import AppCore
import Foundation

/// Individually verified bilingual recipes; one direction is one checkpoint.
enum OPUSCatalog {
    static let models: [ModelDescriptor] = [
        ModelDescriptor(
            id: "opus/en-de-ct2-int8", displayName: "English → German (OPUS)", kind: .translation, runtime: .other,
            engine: "opus-mt", languages: ["en", "de"], sizeBytes: 150_989_312,
            license: LicenseInfo(spdx: "Apache-2.0", attribution: "Helsinki-NLP OPUS-MT; native conversion by gaudi. Apache 2.0."),
            sourceURL: URL(string: "https://huggingface.co/gaudi/opus-mt-en-de-ctranslate2/tree/3998844c0d44ff2aa5aaf5a1cf8365b6eb4fd783"),
            isExperimental: true, notes: "English to German only. Add the reverse pack for the other direction. Compact offline translation; quality varies by text.",
            capabilities: ModelCapabilities(file: true, translation: true,
                translationPairs: [LanguagePair(source: "en", target: "de")], translationLanguageMatching: .exact),
            downloadInclude: ["README.md", "config.json", "model.bin", "shared_vocabulary.json", "source.spm", "target.spm"],
            provenance: ModelProvenance(repository: "gaudi/opus-mt-en-de-ctranslate2", revision: "3998844c0d44ff2aa5aaf5a1cf8365b6eb4fd783",
                profileID: "ct2.marian.bilingual", profileVersion: 1, artifacts: [
                    ModelArtifactDigest(path: "README.md", bytes: 6_720, sha256: "c3948c012fe821597ba617ee7eda044cd75ae610568c1459285ab813d8dc6a65"),
                    ModelArtifactDigest(path: "config.json", bytes: 215, sha256: "ce02c0c0d02f285d2ff34c80b0867ccb5c4a3b250a275e6d1d2884f5499a6e46"),
                    ModelArtifactDigest(path: "model.bin", bytes: 148_423_215, sha256: "ef19d4ddfd1d82f75b7469b33f754464c83f04ffb1691e33454561d7b816e8d3"),
                    ModelArtifactDigest(path: "shared_vocabulary.json", bytes: 993_828, sha256: "fa4c8d666c582ad39892a2ae5d4ded1b0ddde4b49dc784a7fcbd73940f9fa13e"),
                    ModelArtifactDigest(path: "source.spm", bytes: 768_489, sha256: "678f2a1177d8389f67b66299762dcc4fc567e89b07e212ba91b0c56daecf47ce"),
                    ModelArtifactDigest(path: "target.spm", bytes: 796_845, sha256: "bbd1f495eea99c8e21ae086d9146e0fa7b096c3dfdd9ba07ab8b631889df5c9b")
                ], validation: .nativeInferenceChecked)),
        ModelDescriptor(
            id: "opus/de-en-ct2-int8", displayName: "German → English (OPUS)", kind: .translation, runtime: .other,
            engine: "opus-mt", languages: ["de", "en"], sizeBytes: 150_989_312,
            license: LicenseInfo(spdx: "Apache-2.0", attribution: "Helsinki-NLP OPUS-MT; native conversion by gaudi. Apache 2.0."),
            sourceURL: URL(string: "https://huggingface.co/gaudi/opus-mt-de-en-ctranslate2/tree/7134d80efb6dbc284567cbeb55a517dc2974f722"),
            isExperimental: true, notes: "German to English only. Add the reverse pack for the other direction. Compact offline translation; quality varies by text.",
            capabilities: ModelCapabilities(file: true, translation: true,
                translationPairs: [LanguagePair(source: "de", target: "en")], translationLanguageMatching: .exact),
            downloadInclude: ["README.md", "config.json", "model.bin", "shared_vocabulary.json", "source.spm", "target.spm"],
            provenance: ModelProvenance(repository: "gaudi/opus-mt-de-en-ctranslate2", revision: "7134d80efb6dbc284567cbeb55a517dc2974f722",
                profileID: "ct2.marian.bilingual", profileVersion: 1, artifacts: [
                    ModelArtifactDigest(path: "README.md", bytes: 6_720, sha256: "b538669212cef113da47b0288c4191ff7ba2f28dc32aacc8902c8710f4f93562"),
                    ModelArtifactDigest(path: "config.json", bytes: 215, sha256: "ce02c0c0d02f285d2ff34c80b0867ccb5c4a3b250a275e6d1d2884f5499a6e46"),
                    ModelArtifactDigest(path: "model.bin", bytes: 148_423_215, sha256: "3dbafb4ab375ba3a6e9057e0cec4910341e0b8aac57f5784508b474e7738d24a"),
                    ModelArtifactDigest(path: "shared_vocabulary.json", bytes: 993_828, sha256: "fa4c8d666c582ad39892a2ae5d4ded1b0ddde4b49dc784a7fcbd73940f9fa13e"),
                    ModelArtifactDigest(path: "source.spm", bytes: 796_845, sha256: "bbd1f495eea99c8e21ae086d9146e0fa7b096c3dfdd9ba07ab8b631889df5c9b"),
                    ModelArtifactDigest(path: "target.spm", bytes: 768_489, sha256: "678f2a1177d8389f67b66299762dcc4fc567e89b07e212ba91b0c56daecf47ce")
                ], validation: .nativeInferenceChecked)),
        ModelDescriptor(
            id: "opus/en-fr-ct2-int8", displayName: "English → French (OPUS)", kind: .translation, runtime: .other,
            engine: "opus-mt", languages: ["en", "fr"], sizeBytes: 152_013_384,
            license: LicenseInfo(spdx: "Apache-2.0", attribution: "Helsinki-NLP OPUS-MT; native conversion by michaelfeil. Apache 2.0."),
            sourceURL: URL(string: "https://huggingface.co/michaelfeil/ct2fast-opus-mt-en-fr/tree/55bcef18761227161433d86b81bbbcd9d813b429"),
            isExperimental: true, notes: "English to French only. Add the reverse pack for the other direction. Compact offline translation; quality varies by text.",
            capabilities: ModelCapabilities(file: true, translation: true,
                translationPairs: [LanguagePair(source: "en", target: "fr")], translationLanguageMatching: .exact),
            downloadInclude: ["README.md", "config.json", "model.bin", "shared_vocabulary.txt", "source.spm", "target.spm"],
            provenance: ModelProvenance(repository: "michaelfeil/ct2fast-opus-mt-en-fr", revision: "55bcef18761227161433d86b81bbbcd9d813b429",
                profileID: "ct2.marian.bilingual", profileVersion: 1, artifacts: [
                    ModelArtifactDigest(path: "README.md", bytes: 2_817, sha256: "b8c2fc296bffdfb2ca8904c49d8639aedc9a083bceb1b2fc46a487d4f3b3fc73"),
                    ModelArtifactDigest(path: "config.json", bytes: 159, sha256: "0c2f6fa2057c7264d052fb4a62ba3476eeae70487acddfa8e779a53a00cbf44c"),
                    ModelArtifactDigest(path: "model.bin", bytes: 149_872_839, sha256: "636d926880a6e6e4b773403a5991b50d4dfdfabe49a230e148676a05e99f2bec"),
                    ModelArtifactDigest(path: "shared_vocabulary.txt", bytes: 556_777, sha256: "e87446c025bbe57cc4f9ef90fa6e28ab303a2e31479b7355c2a2d3a6a3a43a0a"),
                    ModelArtifactDigest(path: "source.spm", bytes: 778_395, sha256: "173e9f493a668fe396d599e28d414a201193094e6ffd7a4678e5aab0f6d3d838"),
                    ModelArtifactDigest(path: "target.spm", bytes: 802_397, sha256: "78d0e717c77053f1c4b856d8661d9cb87c64f083a35418c087b9146300e4f585")
                ], validation: .nativeInferenceChecked)),
        ModelDescriptor(
            id: "opus/fr-en-ct2-int8", displayName: "French → English (OPUS)", kind: .translation, runtime: .other,
            engine: "opus-mt", languages: ["fr", "en"], sizeBytes: 152_513_377,
            license: LicenseInfo(spdx: "Apache-2.0", attribution: "Helsinki-NLP OPUS-MT; native conversion by gaudi. Apache 2.0."),
            sourceURL: URL(string: "https://huggingface.co/gaudi/opus-mt-fr-en-ctranslate2/tree/b88efd065a8720e0beeaba2efd53b1dc9a29cfc0"),
            isExperimental: true, notes: "French to English only. Add the reverse pack for the other direction. Compact offline translation; quality varies by text.",
            capabilities: ModelCapabilities(file: true, translation: true,
                translationPairs: [LanguagePair(source: "fr", target: "en")], translationLanguageMatching: .exact),
            downloadInclude: ["README.md", "config.json", "model.bin", "shared_vocabulary.json", "source.spm", "target.spm"],
            provenance: ModelProvenance(repository: "gaudi/opus-mt-fr-en-ctranslate2", revision: "b88efd065a8720e0beeaba2efd53b1dc9a29cfc0",
                profileID: "ct2.marian.bilingual", profileVersion: 1, artifacts: [
                    ModelArtifactDigest(path: "README.md", bytes: 6_720, sha256: "2c2fa78085bccbe0abc804e3b5d8f87aa76c716ef6d907a8899a11ad1ec6e0c2"),
                    ModelArtifactDigest(path: "config.json", bytes: 215, sha256: "ce02c0c0d02f285d2ff34c80b0867ccb5c4a3b250a275e6d1d2884f5499a6e46"),
                    ModelArtifactDigest(path: "model.bin", bytes: 149_872_953, sha256: "0dbc6d68e18c1b502c920ff57c380d1f89a9a27cc76c32225934640642c99746"),
                    ModelArtifactDigest(path: "shared_vocabulary.json", bytes: 1_052_697, sha256: "a157eb51a42817dd1ae4bc46cecf66e591ab32641df936da292bd09f2728631b"),
                    ModelArtifactDigest(path: "source.spm", bytes: 802_397, sha256: "78d0e717c77053f1c4b856d8661d9cb87c64f083a35418c087b9146300e4f585"),
                    ModelArtifactDigest(path: "target.spm", bytes: 778_395, sha256: "173e9f493a668fe396d599e28d414a201193094e6ffd7a4678e5aab0f6d3d838")
                ], validation: .nativeInferenceChecked)),
        ModelDescriptor(
            id: "opus/en-es-ct2-int8", displayName: "English → Spanish (OPUS)", kind: .translation, runtime: .other,
            engine: "opus-mt", languages: ["en", "es"], sizeBytes: 157_800_682,
            license: LicenseInfo(spdx: "Apache-2.0", attribution: "Helsinki-NLP OPUS-MT; native conversion by michaelfeil. Apache 2.0."),
            sourceURL: URL(string: "https://huggingface.co/michaelfeil/ct2fast-opus-mt-en-es/tree/76ec296588e2234f9b7dfad5254219a0f5ecb7af"),
            isExperimental: true, notes: "English to Spanish only. Add the reverse pack for the other direction. Compact offline translation; quality varies by text.",
            capabilities: ModelCapabilities(file: true, translation: true,
                translationPairs: [LanguagePair(source: "en", target: "es")], translationLanguageMatching: .exact),
            downloadInclude: ["README.md", "config.json", "model.bin", "shared_vocabulary.txt", "source.spm", "target.spm"],
            provenance: ModelProvenance(repository: "michaelfeil/ct2fast-opus-mt-en-es", revision: "76ec296588e2234f9b7dfad5254219a0f5ecb7af",
                profileID: "ct2.marian.bilingual", profileVersion: 1, artifacts: [
                    ModelArtifactDigest(path: "README.md", bytes: 4_027, sha256: "7bfc8b3410f33eb9ded6513f3d16e8471aa50f38e19ef74fe736301c02d6e6cb"),
                    ModelArtifactDigest(path: "config.json", bytes: 159, sha256: "0c2f6fa2057c7264d052fb4a62ba3476eeae70487acddfa8e779a53a00cbf44c"),
                    ModelArtifactDigest(path: "model.bin", bytes: 155_502_501, sha256: "36cd9bcb181fc6d5832deeaf770ce183ff4edbbc5e4fe0f86cec92da4379f3b7"),
                    ModelArtifactDigest(path: "shared_vocabulary.txt", bytes: 666_435, sha256: "77aee99211b7b8e569e0fb5b95dac01aba9f31bca2d1380b1fc6050797825ec6"),
                    ModelArtifactDigest(path: "source.spm", bytes: 801_636, sha256: "4dd547c24816a335e7b0b2e63376a8f1b3cbfc671eda5ab808dd44fdadaa8791"),
                    ModelArtifactDigest(path: "target.spm", bytes: 825_924, sha256: "e236ee6d866b635c0142114f8647f39831f9d92534aa2aad75c942f6a78ad0e3")
                ], validation: .nativeInferenceChecked)),
        ModelDescriptor(
            id: "opus/es-en-ct2-int8", displayName: "Spanish → English (OPUS)", kind: .translation, runtime: .other,
            engine: "opus-mt", languages: ["es", "en"], sizeBytes: 158_413_246,
            license: LicenseInfo(spdx: "Apache-2.0", attribution: "Helsinki-NLP OPUS-MT; native conversion by gaudi. Apache 2.0."),
            sourceURL: URL(string: "https://huggingface.co/gaudi/opus-mt-es-en-ctranslate2/tree/ef459fb7b0511ea2d1ec9279f8d6cf80661bf9f7"),
            isExperimental: true, notes: "Spanish to English only. Add the reverse pack for the other direction. Compact offline translation; quality varies by text.",
            capabilities: ModelCapabilities(file: true, translation: true,
                translationPairs: [LanguagePair(source: "es", target: "en")], translationLanguageMatching: .exact),
            downloadInclude: ["README.md", "config.json", "model.bin", "shared_vocabulary.json", "source.spm", "target.spm"],
            provenance: ModelProvenance(repository: "gaudi/opus-mt-es-en-ctranslate2", revision: "ef459fb7b0511ea2d1ec9279f8d6cf80661bf9f7",
                profileID: "ct2.marian.bilingual", profileVersion: 1, artifacts: [
                    ModelArtifactDigest(path: "README.md", bytes: 6_720, sha256: "3769193c4482ee9f266c292429be07d374f4777434ba20c8e418b0aed9fee70f"),
                    ModelArtifactDigest(path: "config.json", bytes: 215, sha256: "ce02c0c0d02f285d2ff34c80b0867ccb5c4a3b250a275e6d1d2884f5499a6e46"),
                    ModelArtifactDigest(path: "model.bin", bytes: 155_502_615, sha256: "7e3a7b3c8c8b6c6e3a14b154cd5733b3dc543d7acf12371d2f9f6498069701c3"),
                    ModelArtifactDigest(path: "shared_vocabulary.json", bytes: 1_276_136, sha256: "040e48c9d00734f48506e052695837720bd1f6aa01c70636cde83038362baf19"),
                    ModelArtifactDigest(path: "source.spm", bytes: 825_924, sha256: "e236ee6d866b635c0142114f8647f39831f9d92534aa2aad75c942f6a78ad0e3"),
                    ModelArtifactDigest(path: "target.spm", bytes: 801_636, sha256: "4dd547c24816a335e7b0b2e63376a8f1b3cbfc671eda5ab808dd44fdadaa8791")
                ], validation: .nativeInferenceChecked))
    ]
}
