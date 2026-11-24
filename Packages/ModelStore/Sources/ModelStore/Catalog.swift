import AppCore
import Foundation

/// The built-in model catalog (ADR-004, ADR-006, ADR-007). Sizes marked "approx." in `notes` are estimates, not measurements.
public enum BuiltInCatalog {
    static let whisperLanguages: Set<LanguageCode> = [
        "en", "de", "fr", "es", "it", "pt", "nl", "pl", "ru", "uk", "tr", "ar", "he", "hi", "ta", "te", "bn", "ur", "ja", "ko", "zh",
        "id", "vi", "th", "sv", "da", "no", "fi", "cs", "el", "ro", "hu",
    ]
    static let qwenLanguages: Set<LanguageCode> = [
        "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th", "vi", "ja", "tr", "hi", "ms", "nl", "sv",
        "da", "fi", "pl", "cs", "fil", "fa", "el", "hu", "mk", "ro"
    ]
    static let appleSpeechLanguages: Set<LanguageCode> = [
        "en", "de", "es", "fr", "it", "ja", "ko", "pt", "zh", "yue", "hi", "ta", "te", "ml", "kn", "mr", "gu", "bn", "pa", "ur", "ne",
    ]
    static let parakeetLanguages: Set<LanguageCode> = [
        "en", "de", "fr", "es", "it", "pt", "nl", "pl", "ru", "uk", "cs", "sk", "sl", "hr", "bg", "ro", "hu", "el", "sv", "da", "fi",
        "et", "lv", "lt", "mt",
    ]
    static let appleTranslationLanguages: Set<LanguageCode> = whisperLanguages.subtracting(["he"])

    private static func hf(_ path: String) -> URL { URL(string: "https://huggingface.co/\(path)")! }
    private static let mb: Int64 = 1_000_000

    private static let mit = LicenseInfo(spdx: "MIT")

    /// Pinned Hugging Face commits (SCR-011): a rewritten `main` can never change what a catalog entry downloads.
    enum Revision {
        static let whisperKit = "0f63a7800b00dd0226abd051b906c246e1907482"
        static let nllb = "302d78f00e6fdb50a1064059df7c392b735e9d05"
        static let community1 = "7eab74f3463c736418d0eb10296261ae581146c9"
        static let lseend = "28ce1b1f8ef186729df63b3886fbaae7bc10c4a1"
        static let sortformer = "ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1"
        static let parakeet = "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe"
        static let madlad = "bb45f1851bf13a0b8f4fcd9ecadf2cdb7cf22439"
    }

    public static let models: [ModelDescriptor] = [
        ModelDescriptor(
            id: "apple/speech-analyzer", displayName: "Apple Speech (on-device)", kind: .asr, runtime: .appleAsset,
            engine: "apple.speech", languages: appleSpeechLanguages, sizeBytes: 0,
            license: LicenseInfo(spdx: "LicenseRef-Apple-System"), minTier: .tier8,
            notes: "System locale assets managed by macOS; zero-download default for live and dictation.",
            capabilities: ModelCapabilities(
                live: true, file: true, wordTimestamps: true, autoDetectLanguage: false,
                recommendedUse: [RecommendedUse(.live), RecommendedUse(.dictation)])),
        ModelDescriptor(
            id: "whisperkit/large-v3-v20240930_626MB", displayName: "Whisper large-v3 (626 MB)", kind: .asr, runtime: .coreML,
            engine: "whisperkit", languages: whisperLanguages, sizeBytes: 626 * mb, license: mit, minTier: .tier8,
            sourceURL: hf("argmaxinc/whisperkit-coreml/tree/\(Revision.whisperKit)/openai_whisper-large-v3-v20240930_626MB"),
            notes: "Default file-transcription model; about 13x real-time on M3 Pro.",
            capabilities: ModelCapabilities(
                live: false, file: true, wordTimestamps: true, autoDetectLanguage: true, speed: .balanced,
                recommendedUse: [RecommendedUse(.file, minTier: .tier16)])),
        ModelDescriptor(
            id: "whisperkit/large-v3-v20240930_turbo_632MB", displayName: "Whisper large-v3 turbo (632 MB)", kind: .asr,
            runtime: .coreML, engine: "whisperkit", languages: whisperLanguages, sizeBytes: 632 * mb, license: mit,
            minTier: .tier16,
            sourceURL: hf("argmaxinc/whisperkit-coreml/tree/\(Revision.whisperKit)/openai_whisper-large-v3-v20240930_turbo_632MB"),
            notes: "Speed option. First load is slow while CoreML specializes (about 115 s observed).",
            capabilities: ModelCapabilities(live: false, file: true, wordTimestamps: true, autoDetectLanguage: true)),
        ModelDescriptor(
            id: "whisperkit/small", displayName: "Whisper small (216 MB)", kind: .asr, runtime: .coreML, engine: "whisperkit",
            languages: whisperLanguages, sizeBytes: 216 * mb, license: mit, minTier: .tier8,
            sourceURL: hf("argmaxinc/whisperkit-coreml/tree/\(Revision.whisperKit)/openai_whisper-small_216MB"),
            notes: "Light model for 8 GB Macs.",
            capabilities: ModelCapabilities(
                live: true, file: true, wordTimestamps: true, autoDetectLanguage: true,
                recommendedUse: [
                    RecommendedUse(.file, maxTier: .tier8), RecommendedUse(.live, priority: 1),
                    RecommendedUse(.dictation, priority: 1),
                ])),
        ModelDescriptor(
            id: "mlx/qwen3-asr-0.6b-4bit", displayName: "Qwen3-ASR 0.6B (multilingual)", kind: .asr, runtime: .mlx,
            engine: "qwen3-asr", languages: qwenLanguages, sizeBytes: 712_778_752 + QwenSpeechDetectorFiles.sizeBytes,
            license: LicenseInfo(spdx: "Apache-2.0 AND MIT", attribution: "Qwen3-ASR by Qwen; MLX conversion by mlx-community (Apache 2.0). Includes Silero VAD by the Silero Team, converted by FluidInference (MIT)."),
            minTier: .tier16,
            sourceURL: hf("mlx-community/Qwen3-ASR-0.6B-4bit/tree/313d850181767edf09f00a9c289becca70e58cd0"),
            isExperimental: true,
            notes: "30-language recognition with language detection. Includes a pinned neural speech detector. Buffered Live captions; no word timestamps. Choose the Sinhala specialist for Sinhala.",
            capabilities: ModelCapabilities(live: true, file: true, autoDetectLanguage: true, streaming: .buffered),
            downloadInclude: [
                "chat_template.json", "config.json", "generation_config.json", "merges.txt", "model.safetensors",
                "model.safetensors.index.json", "preprocessor_config.json", "tokenizer_config.json", "vocab.json"
            ]),
        ModelDescriptor(
            id: "mlx/qwen3-asr-0.6b-sinhala-8bit", displayName: "Qwen3-ASR 0.6B Sinhala (8-bit, MLX)", kind: .asr, runtime: .mlx,
            engine: "qwen3-asr", languages: ["si"], sizeBytes: 1_015_560_793,
            license: LicenseInfo(
                spdx: "CC-BY-SA-4.0",
                attribution: "Qwen3-ASR-0.6B-Sinhala-8bit by Nerdstorm, CC BY-SA 4.0. Weights are user-downloaded and unmodified."),
            minTier: .tier16, sourceURL: hf("Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit/tree/047217cb611ad5f51cb2284e4a3617a5eaa9b688"),
            isExperimental: true,
            notes:
                "Default Sinhala model (experimental; CER about 6% read, 21% conversation, 27% code-mixed). Pinned to revision "
                + "047217cb; size is the exact 13-file total from the HF tree API and per-file SHA-256 values come from its LFS "
                + "oids at download time. About 2.3 GB peak memory. Runs in the MLX engine (QwenASR package).",
            capabilities: ModelCapabilities(
                live: true, file: true, wordTimestamps: false, autoDetectLanguage: false, memory: .moderate,
                recommendedUse: [RecommendedUse(.file), RecommendedUse(.live), RecommendedUse(.dictation)])),
        ModelDescriptor(
            id: "coreml/whisper-small-sinhala", displayName: "Whisper small Sinhala (fallback)", kind: .asr, runtime: .coreML,
            engine: "whisperkit", languages: ["si"], sizeBytes: 490 * mb,
            license: LicenseInfo(spdx: "NOASSERTION", isNonCommercial: true, attribution: "SinhaSpeech/whisper-small-sinhala-run12-best"),
            minTier: .tier8, isExperimental: true,
            notes:
                "Upstream is PyTorch and needs CoreML conversion (see spikes/sinhala). "
                + "Import the converted folder. Licence unverified; treated as non-commercial."
        ),
        ModelDescriptor(
            id: "fluidaudio/diarization-community-1", displayName: "Diarization Community-1 (offline)", kind: .diarization,
            runtime: .coreML, engine: "fluidaudio", languages: [], sizeBytes: 21_623_423,
            license: LicenseInfo(spdx: "CC-BY-4.0", attribution: "FluidInference Community-1 diarization models, CC BY 4.0 (scoped)."),
            minTier: .tier8, sourceURL: hf("FluidInference/speaker-diarization-coreml/tree/\(Revision.community1)"),
            notes:
                "Offline speaker diarization. Downloads only the four required .mlmodelc bundles, the PLDA parameters and the licence "
                + "files (21.6 MB), pinned to revision 7eab74f.",
            capabilities: ModelCapabilities(live: false, file: true, speakerLabels: .offline),
            downloadInclude: [
                "Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc", "plda-parameters.json", "LICENSE",
                "NOTICE.md",
            ]),
        ModelDescriptor(
            id: "fluidaudio/ls-eend-ami", displayName: "LS-EEND (AMI, streaming)", kind: .diarization, runtime: .coreML,
            engine: "fluidaudio", languages: [], sizeBytes: 44_617_906,
            license: LicenseInfo(spdx: "MIT", attribution: "FluidInference ls-eend-coreml, MIT."),
            minTier: .tier8, sourceURL: hf("FluidInference/ls-eend-coreml/tree/\(Revision.lseend)"),
            notes: "Live diarization, up to 4 speakers. Downloads only the AMI 100 ms .mlmodelc (44.6 MB), pinned to revision 28ce1b1.",
            capabilities: ModelCapabilities(live: true, file: false, speakerLabels: .streaming),
            downloadInclude: ["optimized/ami/100ms/ls_eend_ami_100ms.mlmodelc"]),
        ModelDescriptor(
            id: "fluidaudio/sortformer-v2", displayName: "Sortformer v2 (streaming)", kind: .diarization, runtime: .coreML,
            engine: "fluidaudio", languages: [], sizeBytes: 486_844_491,
            license: LicenseInfo(spdx: "CC-BY-4.0", attribution: "NVIDIA Sortformer v2 via FluidInference, CC BY 4.0."),
            minTier: .tier16, sourceURL: hf("FluidInference/diar-streaming-sortformer-coreml/tree/\(Revision.sortformer)"),
            isExperimental: true,
            notes:
                "Licence unresolved (NVIDIA Open Model License vs CC-BY-4.0, ADR-006). Downloads only Sortformer_v2 and "
                + "SortformerNvidiaLow_v2 (486.8 MB); the v2.1 weights are never fetched. Pinned to revision ae9a27a.",
            capabilities: ModelCapabilities(live: true, file: false, speakerLabels: .streaming),
            downloadInclude: ["Sortformer_v2.mlmodelc", "SortformerNvidiaLow_v2.mlmodelc"]),
        ModelDescriptor(
            id: "apple/translation", displayName: "Apple Translation", kind: .translation, runtime: .appleAsset,
            engine: "apple.translation", languages: appleTranslationLanguages, sizeBytes: 0,
            license: LicenseInfo(spdx: "LicenseRef-Apple-System"), minTier: .tier8,
            notes: "System language packs; does not support Sinhala.",
            capabilities: ModelCapabilities(live: false, file: true, translation: true)),
        ModelDescriptor(
            id: "nllb/200-distilled-600M", displayName: "NLLB-200 distilled 600M (CTranslate2 int8)", kind: .translation,
            runtime: .other, engine: "nllb", languages: [
                "si", "en", "ta", "hi", "bn", "ur", "te", "ml", "kn", "mr", "gu", "pa", "ne", "de", "fr", "es", "it", "pt", "nl",
                "ja", "ko", "zh", "ar", "ru", "id", "th", "vi"
            ], sizeBytes: 647 * mb,
            license: LicenseInfo(
                spdx: "CC-BY-NC-4.0", isNonCommercial: true,
                attribution:
                    "NLLB-200 by Meta AI, CC BY-NC 4.0 (int8 CTranslate2 conversion by JustFrederik). Non-commercial use only; research model, not for production."
            ),
            minTier: .tier16, sourceURL: hf("JustFrederik/nllb-200-distilled-600M-ct2-int8/tree/\(Revision.nllb)"), isExperimental: true,
            notes:
                "27-language translation for non-commercial use. Download is 647 MB (measured from the repo listing: model.bin 623 MB, "
                + "SentencePiece 4.9 MB, vocab 2.6 MB, tokenizer.json 17 MB). English to Sinhala is low confidence. Pinned to revision 302d78f.",
            capabilities: ModelCapabilities(live: false, file: true, translation: true)),
        ModelDescriptor(
            id: "madlad/400-3b-mt-q4k", displayName: "MADLAD-400 3B (q4k, optional)", kind: .translation, runtime: .gguf,
            engine: "madlad", languages: ["si", "en"], sizeBytes: 1_654_597_280,
            license: LicenseInfo(spdx: "Apache-2.0", attribution: "MADLAD-400 by Google, Apache-2.0."),
            minTier: .tier16, sourceURL: hf("jbochi/madlad400-3b-mt/resolve/\(Revision.madlad)/model-q4k.gguf"),
            sha256: "ea6e5531a3e95213c7f0635988d119e078a655c09306e47851e15d4c0c3f9c37", isExperimental: true,
            notes: "Legacy GGUF download, unavailable in this runtime. Install the separate MADLAD native int8 model to translate.",
            capabilities: ModelCapabilities(live: false, file: false, translation: false)),
        ModelDescriptor(
            id: "madlad/400-3b-mt-ct2-int8", displayName: "MADLAD-400 3B (native int8)", kind: .translation, runtime: .other,
            engine: "madlad", languages: [
                "si", "en", "ta", "hi", "bn", "ur", "te", "ml", "kn", "mr", "gu", "pa", "ne", "de", "fr", "es", "it", "pt", "nl",
                "ja", "ko", "zh", "ar", "ru", "id", "th", "vi"
            ], sizeBytes: 2_960_123_510,
            license: LicenseInfo(spdx: "Apache-2.0", attribution: "Google MADLAD-400, Apache 2.0; CTranslate2 int8 conversion by Nextcloud-AI."),
            minTier: .tier16,
            sourceURL: hf("Nextcloud-AI/madlad400-3b-mt-ct2-int8/tree/aa32bbdeba7880eff2096ec044cb155a340a9400"),
            isExperimental: true,
            notes: "Native T5 translation for 27 mapped base languages. Includes Sinhala, Tamil, Hindi, European and East Asian languages. Other upstream languages and script variants are not enabled here. Quality varies by direction.",
            capabilities: ModelCapabilities(live: false, file: true, translation: true, translationLanguageMatching: .exact),
            downloadInclude: ["model.bin", "config.json", "shared_vocabulary.json", "spiece.model", "README.md"],
            provenance: ModelProvenance(
                repository: "Nextcloud-AI/madlad400-3b-mt-ct2-int8", revision: "aa32bbdeba7880eff2096ec044cb155a340a9400",
                profileID: "ct2.madlad.t5", profileVersion: 1,
                artifacts: [
                    ModelArtifactDigest(path: "model.bin", bytes: 2_950_208_329, sha256: "77b9fd9ab97c1259d07089b5f854393dad81bc5fb5647d3f9a5d101c94f40daa"),
                    ModelArtifactDigest(path: "config.json", bytes: 224, sha256: "90fb54962455a4e0a0bc7235c0f063d7e46d9c1a1ae003af8059809abd6aeece"),
                    ModelArtifactDigest(path: "shared_vocabulary.json", bytes: 5_477_099, sha256: "c327551ce3ca6efc7b437e11a267f79979893332dda8a1d146e2c950815193f8"),
                    ModelArtifactDigest(path: "spiece.model", bytes: 4_427_844, sha256: "ef11ac9a22c7503492f56d48dce53be20e339b63605983e9f27d2cd0e0f3922c"),
                    ModelArtifactDigest(path: "README.md", bytes: 10_014, sha256: "2eff7bccfc46f4d54591fcc34a0bed496407cfc104df5e5b883b4d5332ee62b0"),
                ], validation: .nativeInferenceChecked)),
        ModelDescriptor(
            id: "fluidaudio/parakeet-tdt-v3", displayName: "Parakeet TDT v3", kind: .asr, runtime: .coreML, engine: "fluidaudio.parakeet",
            languages: parakeetLanguages, sizeBytes: 483_105_645,
            license: LicenseInfo(spdx: "CC-BY-4.0", attribution: "NVIDIA Parakeet TDT 0.6B v3 via FluidInference, CC BY 4.0."),
            minTier: .tier8, sourceURL: hf("FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/\(Revision.parakeet)"),
            isExperimental: true,
            notes:
                "Recognition for 25 European languages with word alignment. Buffered Live captions; choose the spoken language explicitly.",
            capabilities: ModelCapabilities(live: true, file: true, wordTimestamps: true, autoDetectLanguage: false, streaming: .buffered),
            downloadInclude: [
                "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_vocab.json",
            ]),
    ] + OPUSCatalog.models
}
