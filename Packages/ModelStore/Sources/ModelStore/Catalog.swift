import AppCore
import Foundation

/// The built-in model catalog (ADR-004, ADR-006, ADR-007). Sizes marked "approx." in `notes` are estimates, not measurements.
public enum BuiltInCatalog {
    static let whisperLanguages: Set<LanguageCode> = [
        "en", "de", "fr", "es", "it", "pt", "nl", "pl", "ru", "uk", "tr", "ar", "he", "hi", "ta", "te", "bn", "ur", "ja", "ko", "zh",
        "id", "vi", "th", "sv", "da", "no", "fi", "cs", "el", "ro", "hu",
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
            runtime: .other, engine: "nllb", languages: ["si", "en", "ta", "hi", "bn", "ur"], sizeBytes: 647 * mb,
            license: LicenseInfo(
                spdx: "CC-BY-NC-4.0", isNonCommercial: true,
                attribution:
                    "NLLB-200 by Meta AI, CC BY-NC 4.0 (int8 CTranslate2 conversion by JustFrederik). Non-commercial use only; research model, not for production."
            ),
            minTier: .tier16, sourceURL: hf("JustFrederik/nllb-200-distilled-600M-ct2-int8/tree/\(Revision.nllb)"), isExperimental: true,
            notes:
                "Sinhala translation for non-commercial builds. Download is 647 MB (measured from the repo listing: model.bin 623 MB, "
                + "SentencePiece 4.9 MB, vocab 2.6 MB, tokenizer.json 17 MB). English to Sinhala is low confidence. Pinned to revision 302d78f.",
            capabilities: ModelCapabilities(live: false, file: true, translation: true)),
        ModelDescriptor(
            id: "madlad/400-3b-mt-q4k", displayName: "MADLAD-400 3B (q4k, optional)", kind: .translation, runtime: .gguf,
            engine: "madlad", languages: ["si", "en"], sizeBytes: 1_654_597_280,
            license: LicenseInfo(spdx: "Apache-2.0", attribution: "MADLAD-400 by Google, Apache-2.0."),
            minTier: .tier16, sourceURL: hf("jbochi/madlad400-3b-mt/resolve/\(Revision.madlad)/model-q4k.gguf"),
            sha256: "ea6e5531a3e95213c7f0635988d119e078a655c09306e47851e15d4c0c3f9c37", isExperimental: true,
            notes: "Commercial-safe Sinhala translation option. Sinhala quality unmeasured. Pinned and checksummed.",
            capabilities: ModelCapabilities(live: false, file: true, translation: true)),
        ModelDescriptor(
            id: "fluidaudio/parakeet-tdt-v3", displayName: "Parakeet TDT v3", kind: .asr, runtime: .coreML, engine: "fluidaudio",
            languages: parakeetLanguages, sizeBytes: 483_105_645,
            license: LicenseInfo(spdx: "CC-BY-4.0", attribution: "NVIDIA Parakeet TDT 0.6B v3 via FluidInference, CC BY 4.0."),
            minTier: .tier8, sourceURL: hf("FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/\(Revision.parakeet)"),
            isExperimental: true,
            notes:
                "Planned fast engine for 25 European languages. NOT RUNNABLE YET: no `fluidaudio` ASR engine is registered, so it is "
                + "hidden from language pickers and never recommended (capabilities.live and .file are false). Download is limited "
                + "to the v3 preprocessor, encoder, decoder, joint and vocabulary (483 MB).",
            capabilities: ModelCapabilities(live: false, file: false, wordTimestamps: false, autoDetectLanguage: true),
            downloadInclude: [
                "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_v3_vocab.json",
            ]),
    ]
}
