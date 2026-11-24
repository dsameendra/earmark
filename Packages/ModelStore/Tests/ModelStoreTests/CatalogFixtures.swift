import Foundation

// Recorded from the public Hugging Face tree API (`/api/models/<repo>/tree/<sha>?recursive=true`) on 2026-11-22 for the
// pinned revisions in `BuiltInCatalog.Revision`. Only the files each catalog entry downloads are listed; `RepoNoise` adds
// representative files from the same repos that must NEVER be downloaded. CI never touches the network.
enum CatalogFixtures {
    struct Listing {
        var repo: String
        var revision: String
        var files: [(path: String, size: Int64)]
    }

    static let community1 = Listing(
        repo: "FluidInference/speaker-diarization-coreml", revision: "7eab74f3463c736418d0eb10296261ae581146c9",
        files: [
            ("Segmentation.mlmodelc/analytics/coremldata.bin", 243),
            ("Segmentation.mlmodelc/coremldata.bin", 812),
            ("Segmentation.mlmodelc/metadata.json", 3410),
            ("Segmentation.mlmodelc/model.mil", 43063),
            ("Segmentation.mlmodelc/weights/weight.bin", 5959360),
            ("FBank.mlmodelc/analytics/coremldata.bin", 243),
            ("FBank.mlmodelc/coremldata.bin", 853),
            ("FBank.mlmodelc/metadata.json", 3409),
            ("FBank.mlmodelc/model.mil", 15667),
            ("FBank.mlmodelc/weights/weight.bin", 1776896),
            ("Embedding.mlmodelc/analytics/coremldata.bin", 243),
            ("Embedding.mlmodelc/coremldata.bin", 704),
            ("Embedding.mlmodelc/metadata.json", 2818),
            ("Embedding.mlmodelc/model.mil", 78432),
            ("Embedding.mlmodelc/weights/weight.bin", 13412288),
            ("PldaRho.mlmodelc/analytics/coremldata.bin", 243),
            ("PldaRho.mlmodelc/coremldata.bin", 763),
            ("PldaRho.mlmodelc/metadata.json", 2749),
            ("PldaRho.mlmodelc/model.mil", 7613),
            ("PldaRho.mlmodelc/weights/weight.bin", 200192),
            ("plda-parameters.json", 89416),
            ("LICENSE", 19759),
            ("NOTICE.md", 4247),
        ])

    static let lseend = Listing(
        repo: "FluidInference/ls-eend-coreml", revision: "28ce1b1f8ef186729df63b3886fbaae7bc10c4a1",
        files: [
            ("optimized/ami/100ms/ls_eend_ami_100ms.mlmodelc/analytics/coremldata.bin", 243),
            ("optimized/ami/100ms/ls_eend_ami_100ms.mlmodelc/coremldata.bin", 1395),
            ("optimized/ami/100ms/ls_eend_ami_100ms.mlmodelc/metadata.json", 6999),
            ("optimized/ami/100ms/ls_eend_ami_100ms.mlmodelc/model.mil", 207733),
            ("optimized/ami/100ms/ls_eend_ami_100ms.mlmodelc/weights/weight.bin", 44401536),
            ("optimized/ami/100ms/ls_eend_ami_100ms.mlpackage/Data/com.apple.CoreML/model.mlmodel", 175266),
            ("optimized/ami/100ms/ls_eend_ami_100ms.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 44401536),
            ("optimized/ami/100ms/ls_eend_ami_100ms.mlpackage/Manifest.json", 617),
        ])

    static let sortformer = Listing(
        repo: "FluidInference/diar-streaming-sortformer-coreml", revision: "ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1",
        files: [
            ("Sortformer_v2.mlmodelc/analytics/coremldata.bin", 202),
            ("Sortformer_v2.mlmodelc/coremldata.bin", 1093),
            ("Sortformer_v2.mlmodelc/metadata.json", 5171),
            ("Sortformer_v2.mlmodelc/model0/analytics/coremldata.bin", 108),
            ("Sortformer_v2.mlmodelc/model0/coremldata.bin", 640),
            ("Sortformer_v2.mlmodelc/model0/model.mil", 31807),
            ("Sortformer_v2.mlmodelc/model0/weights/0-weight.bin", 8948544),
            ("Sortformer_v2.mlmodelc/model1/analytics/coremldata.bin", 108),
            ("Sortformer_v2.mlmodelc/model1/coremldata.bin", 605),
            ("Sortformer_v2.mlmodelc/model1/model.mil", 1147855),
            ("Sortformer_v2.mlmodelc/model1/weights/1-weight.bin", 230428224),
            ("SortformerNvidiaLow_v2.mlmodelc/analytics/coremldata.bin", 202),
            ("SortformerNvidiaLow_v2.mlmodelc/coremldata.bin", 1094),
            ("SortformerNvidiaLow_v2.mlmodelc/metadata.json", 5182),
            ("SortformerNvidiaLow_v2.mlmodelc/model0/analytics/coremldata.bin", 108),
            ("SortformerNvidiaLow_v2.mlmodelc/model0/coremldata.bin", 641),
            ("SortformerNvidiaLow_v2.mlmodelc/model0/model.mil", 32549),
            ("SortformerNvidiaLow_v2.mlmodelc/model0/weights/0-weight.bin", 8948544),
            ("SortformerNvidiaLow_v2.mlmodelc/model1/analytics/coremldata.bin", 108),
            ("SortformerNvidiaLow_v2.mlmodelc/model1/coremldata.bin", 605),
            ("SortformerNvidiaLow_v2.mlmodelc/model1/model.mil", 1710109),
            ("SortformerNvidiaLow_v2.mlmodelc/model1/weights/1-weight.bin", 235580992),
        ])

    static let qwenGeneral = Listing(
        repo: "mlx-community/Qwen3-ASR-0.6B-4bit", revision: "313d850181767edf09f00a9c289becca70e58cd0",
        files: [
            ("chat_template.json", 1161),
            ("config.json", 7187),
            ("generation_config.json", 142),
            ("merges.txt", 1671853),
            ("model.safetensors", 708236945),
            ("model.safetensors.index.json", 71814),
            ("preprocessor_config.json", 330),
            ("tokenizer_config.json", 12487),
            ("vocab.json", 2776833),
        ])

    static let qwenGeneral17 = Listing(
        repo: "mlx-community/Qwen3-ASR-1.7B-4bit", revision: "78a389c776a5483b2d0d4ea5494e11012e0d6159",
        files: [
            ("README.md", 1008),
            ("chat_template.json", 1161),
            ("config.json", 7188),
            ("generation_config.json", 142),
            ("merges.txt", 1671853),
            ("model.safetensors", 1603081617),
            ("model.safetensors.index.json", 78968),
            ("preprocessor_config.json", 330),
            ("tokenizer_config.json", 12487),
            ("vocab.json", 2776833),
        ])

    static let parakeet = Listing(
        repo: "FluidInference/parakeet-tdt-0.6b-v3-coreml", revision: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
        files: [
            ("Preprocessor.mlmodelc/analytics/coremldata.bin", 243),
            ("Preprocessor.mlmodelc/coremldata.bin", 486),
            ("Preprocessor.mlmodelc/metadata.json", 2841),
            ("Preprocessor.mlmodelc/model.mil", 28181),
            ("Preprocessor.mlmodelc/weights/weight.bin", 491072),
            ("Encoder.mlmodelc/analytics/coremldata.bin", 243),
            ("Encoder.mlmodelc/coremldata.bin", 485),
            ("Encoder.mlmodelc/metadata.json", 2921),
            ("Encoder.mlmodelc/model.mil", 959769),
            ("Encoder.mlmodelc/weights/weight.bin", 445187200),
            ("Decoder.mlmodelc/analytics/coremldata.bin", 243),
            ("Decoder.mlmodelc/coremldata.bin", 554),
            ("Decoder.mlmodelc/metadata.json", 3427),
            ("Decoder.mlmodelc/model.mil", 13110),
            ("Decoder.mlmodelc/weights/weight.bin", 23604992),
            ("JointDecisionv3.mlmodelc/analytics/coremldata.bin", 243),
            ("JointDecisionv3.mlmodelc/coremldata.bin", 521),
            ("JointDecisionv3.mlmodelc/metadata.json", 3453),
            ("JointDecisionv3.mlmodelc/model.mil", 11775),
            ("JointDecisionv3.mlmodelc/weights/weight.bin", 12642764),
            ("parakeet_vocab.json", 151122),
        ])

    static let whisperLarge = Listing(
        repo: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482",
        files: [
            ("openai_whisper-large-v3-v20240930_626MB/AudioEncoder.mlmodelc/analytics/coremldata.bin", 243),
            ("openai_whisper-large-v3-v20240930_626MB/AudioEncoder.mlmodelc/coremldata.bin", 348),
            ("openai_whisper-large-v3-v20240930_626MB/AudioEncoder.mlmodelc/metadata.json", 1922),
            ("openai_whisper-large-v3-v20240930_626MB/AudioEncoder.mlmodelc/model.mil", 934263),
            ("openai_whisper-large-v3-v20240930_626MB/AudioEncoder.mlmodelc/weights/weight.bin", 421968768),
            ("openai_whisper-large-v3-v20240930_626MB/MelSpectrogram.mlmodelc/analytics/coremldata.bin", 243),
            ("openai_whisper-large-v3-v20240930_626MB/MelSpectrogram.mlmodelc/coremldata.bin", 329),
            ("openai_whisper-large-v3-v20240930_626MB/MelSpectrogram.mlmodelc/metadata.json", 1850),
            ("openai_whisper-large-v3-v20240930_626MB/MelSpectrogram.mlmodelc/model.mil", 10143),
            ("openai_whisper-large-v3-v20240930_626MB/MelSpectrogram.mlmodelc/weights/weight.bin", 373376),
            ("openai_whisper-large-v3-v20240930_626MB/TextDecoder.mlmodelc/analytics/coremldata.bin", 243),
            ("openai_whisper-large-v3-v20240930_626MB/TextDecoder.mlmodelc/coremldata.bin", 633),
            ("openai_whisper-large-v3-v20240930_626MB/TextDecoder.mlmodelc/metadata.json", 4924),
            ("openai_whisper-large-v3-v20240930_626MB/TextDecoder.mlmodelc/model.mil", 217177),
            ("openai_whisper-large-v3-v20240930_626MB/TextDecoder.mlmodelc/weights/weight.bin", 203199860),
            ("openai_whisper-large-v3-v20240930_626MB/config.json", 1149),
            ("openai_whisper-large-v3-v20240930_626MB/generation_config.json", 2767),
        ])

    static let whisperTurbo = Listing(
        repo: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482",
        files: [
            ("openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc/analytics/coremldata.bin", 243),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc/coremldata.bin", 348),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc/metadata.json", 1974),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc/model.mil", 7589739),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc/weights/weight.bin", 421968768),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/MelSpectrogram.mlmodelc/analytics/coremldata.bin", 243),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/MelSpectrogram.mlmodelc/coremldata.bin", 329),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/MelSpectrogram.mlmodelc/metadata.json", 1850),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/MelSpectrogram.mlmodelc/model.mil", 10143),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/MelSpectrogram.mlmodelc/weights/weight.bin", 373376),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoder.mlmodelc/analytics/coremldata.bin", 243),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoder.mlmodelc/coremldata.bin", 633),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoder.mlmodelc/metadata.json", 4924),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoder.mlmodelc/model.mil", 217177),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoder.mlmodelc/weights/weight.bin", 203199860),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoderContextPrefill.mlmodelc/analytics/coremldata.bin", 243),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoderContextPrefill.mlmodelc/coremldata.bin", 380),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoderContextPrefill.mlmodelc/metadata.json", 2240),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoderContextPrefill.mlmodelc/model.mil", 4092),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoderContextPrefill.mlmodelc/weights/weight.bin", 12288192),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/config.json", 1149),
            ("openai_whisper-large-v3-v20240930_turbo_632MB/generation_config.json", 2767),
        ])

    static let whisperSmall = Listing(
        repo: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482",
        files: [
            ("openai_whisper-small_216MB/AudioEncoder.mlmodelc/analytics/coremldata.bin", 243),
            ("openai_whisper-small_216MB/AudioEncoder.mlmodelc/coremldata.bin", 347),
            ("openai_whisper-small_216MB/AudioEncoder.mlmodelc/metadata.json", 1942),
            ("openai_whisper-small_216MB/AudioEncoder.mlmodelc/model.mil", 353690),
            ("openai_whisper-small_216MB/AudioEncoder.mlmodelc/model.mlmodel", 293185),
            ("openai_whisper-small_216MB/AudioEncoder.mlmodelc/weights/weight.bin", 62057344),
            ("openai_whisper-small_216MB/MelSpectrogram.mlmodelc/analytics/coremldata.bin", 243),
            ("openai_whisper-small_216MB/MelSpectrogram.mlmodelc/coremldata.bin", 328),
            ("openai_whisper-small_216MB/MelSpectrogram.mlmodelc/metadata.json", 1878),
            ("openai_whisper-small_216MB/MelSpectrogram.mlmodelc/model.mil", 10134),
            ("openai_whisper-small_216MB/MelSpectrogram.mlmodelc/weights/weight.bin", 354080),
            ("openai_whisper-small_216MB/TextDecoder.mlmodelc/analytics/coremldata.bin", 243),
            ("openai_whisper-small_216MB/TextDecoder.mlmodelc/coremldata.bin", 633),
            ("openai_whisper-small_216MB/TextDecoder.mlmodelc/metadata.json", 4935),
            ("openai_whisper-small_216MB/TextDecoder.mlmodelc/model.mil", 618369),
            ("openai_whisper-small_216MB/TextDecoder.mlmodelc/model.mlmodel", 518452),
            ("openai_whisper-small_216MB/TextDecoder.mlmodelc/weights/weight.bin", 153130482),
            ("openai_whisper-small_216MB/config.json", 1456),
            ("openai_whisper-small_216MB/generation_config.json", 2779),
        ])

    static let madladNative = Listing(
        repo: "Nextcloud-AI/madlad400-3b-mt-ct2-int8", revision: "aa32bbdeba7880eff2096ec044cb155a340a9400",
        files: [
            (".gitattributes", 1570),
            ("README.md", 10014),
            ("added_tokens.json", 4),
            ("config.json", 224),
            ("generation_config.json", 142),
            ("model.bin", 2950208329),
            ("shared_vocabulary.json", 5477099),
            ("special_tokens_map.json", 414),
            ("spiece.model", 4427844),
            ("tokenizer.json", 16629031),
            ("tokenizer_config.json", 830),
        ])

    static let opusEnDe = Listing(
        repo: "gaudi/opus-mt-en-de-ctranslate2", revision: "3998844c0d44ff2aa5aaf5a1cf8365b6eb4fd783",
        files: [
            (".gitattributes", 433),
            ("README.md", 6720),
            ("config.json", 215),
            ("generation_config.json", 293),
            ("model.bin", 148423215),
            ("shared_vocabulary.json", 993828),
            ("source.spm", 768489),
            ("target.spm", 796845),
            ("tokenizer_config.json", 42),
            ("vocab.json", 1273232)
        ])

    static let opusDeEn = Listing(
        repo: "gaudi/opus-mt-de-en-ctranslate2", revision: "7134d80efb6dbc284567cbeb55a517dc2974f722",
        files: [
            (".gitattributes", 387),
            ("README.md", 6720),
            ("config.json", 215),
            ("generation_config.json", 293),
            ("model.bin", 148423215),
            ("shared_vocabulary.json", 993828),
            ("source.spm", 796845),
            ("target.spm", 768489),
            ("tokenizer_config.json", 42),
            ("vocab.json", 1273232)
        ])

    static let opusEnFr = Listing(
        repo: "michaelfeil/ct2fast-opus-mt-en-fr", revision: "55bcef18761227161433d86b81bbbcd9d813b429",
        files: [
            (".gitattributes", 391),
            ("README.md", 2817),
            ("config.json", 159),
            ("generation_config.json", 293),
            ("model.bin", 149872839),
            ("shared_vocabulary.txt", 556777),
            ("source.spm", 778395),
            ("target.spm", 802397),
            ("tokenizer_config.json", 42),
            ("vocab.json", 1339166)
        ])

    static let opusFrEn = Listing(
        repo: "gaudi/opus-mt-fr-en-ctranslate2", revision: "b88efd065a8720e0beeaba2efd53b1dc9a29cfc0",
        files: [
            (".gitattributes", 433),
            ("README.md", 6720),
            ("config.json", 215),
            ("generation_config.json", 293),
            ("model.bin", 149872953),
            ("shared_vocabulary.json", 1052697),
            ("source.spm", 802397),
            ("target.spm", 778395),
            ("tokenizer_config.json", 42),
            ("vocab.json", 1339166)
        ])

    static let opusEnEs = Listing(
        repo: "michaelfeil/ct2fast-opus-mt-en-es", revision: "76ec296588e2234f9b7dfad5254219a0f5ecb7af",
        files: [
            (".gitattributes", 391),
            ("README.md", 4027),
            ("config.json", 159),
            ("generation_config.json", 293),
            ("model.bin", 155502501),
            ("shared_vocabulary.txt", 666435),
            ("source.spm", 801636),
            ("target.spm", 825924),
            ("tokenizer_config.json", 44),
            ("vocab.json", 1590040)
        ])

    static let opusEsEn = Listing(
        repo: "gaudi/opus-mt-es-en-ctranslate2", revision: "ef459fb7b0511ea2d1ec9279f8d6cf80661bf9f7",
        files: [
            (".gitattributes", 387),
            ("README.md", 6720),
            ("config.json", 215),
            ("generation_config.json", 293),
            ("model.bin", 155502615),
            ("shared_vocabulary.json", 1276136),
            ("source.spm", 825924),
            ("target.spm", 801636),
            ("tokenizer_config.json", 44),
            ("vocab.json", 1590040)
        ])

    static let nllb = Listing(
        repo: "JustFrederik/nllb-200-distilled-600M-ct2-int8", revision: "302d78f00e6fdb50a1064059df7c392b735e9d05",
        files: [
            (".gitattributes", 1528),
            ("README.md", 3435),
            ("config.json", 159),
            ("model.bin", 622595991),
            ("sentencepiece.bpe.model", 4852054),
            ("shared_vocabulary.txt", 2568098),
            ("special_tokens_map.json", 3548),
            ("tokenizer.json", 17331176),
            ("tokenizer_config.json", 564),
        ])

    static let qwen = Listing(
        repo: "Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit", revision: "047217cb611ad5f51cb2284e4a3617a5eaa9b688",
        files: [
            (".gitattributes", 1519),
            ("LICENSE-APACHE-2.0", 11358),
            ("README.md", 19341),
            ("chat_template.json", 1161),
            ("config.json", 7206),
            ("generation_config.json", 142),
            ("merges.txt", 1671853),
            ("model.safetensors", 1006229436),
            ("model.safetensors.index.json", 68788),
            ("preprocessor_config.json", 330),
            ("tokenizer.json", 4760339),
            ("tokenizer_config.json", 12487),
            ("vocab.json", 2776833),
        ])

    /// Files that live in the same repositories but that no catalog entry may download (whole-repo bug, v2.1 weights).
    static let repoNoise: [String: [(path: String, size: Int64)]] = [
        "FluidInference/ls-eend-coreml": [
            ("optimized/ami/100ms/ls_eend_ami_100ms.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 44_401_536),
            ("optimized/ami/200ms/ls_eend_ami_200ms.mlmodelc/weights/weight.bin", 44_401_536),
            ("optimized/dihard3/100ms/ls_eend_dihard3_100ms.mlmodelc/weights/weight.bin", 44_401_536),
            ("optimized/callhome/100ms/ls_eend_callhome_100ms.mlmodelc/weights/weight.bin", 44_401_536),
        ],
        "FluidInference/diar-streaming-sortformer-coreml": [
            ("Sortformer_v2.1.mlmodelc/weights/weight.bin", 240_000_000),
            ("SortformerNvidiaLow_v2.1.mlmodelc/weights/weight.bin", 246_000_000),
            ("SortformerNvidiaHigh_v2.mlmodelc/weights/weight.bin", 900_000_000),
            ("Sortformer_v2.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 240_000_000),
            ("convert.py", 2656),
        ],
        "FluidInference/speaker-diarization-coreml": [
            ("mlpackages/Embedding.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 53_500_000),
            ("wespeaker.mlmodelc/weights/weight.bin", 26_000_000),
            ("plots/latency_timeseries.png", 406_411),
            ("latency_timeseries.png", 406_411),
        ],
        "FluidInference/parakeet-tdt-0.6b-v3-coreml": [
            ("EncoderInt4.mlmodelc/weights/weight.bin", 300_000_000),
            ("Encoder_v2.mlmodelc/weights/weight.bin", 450_000_000),
            ("mlpackages/Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 450_000_000),
        ],
    ]
}
