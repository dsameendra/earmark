import AppCore
import Foundation

/// Provisions the Whisper tokenizer files next to the model downloads (ENG-AC-14).
///
/// WhisperKit resolves its tokenizer from `<tokenizerFolder>/models/<hub repo id>/tokenizer.json` and silently downloads it
/// from the Hugging Face hub when that file is missing. The ``ModelManager`` therefore fetches the (small) tokenizer files
/// together with the model, from the same allow-listed host and only after a user-initiated download, and the engine is
/// pointed at ``ModelManager/tokenizerFolder`` so it never needs the network at transcription time.
public enum WhisperTokenizerFiles {
    /// Files `AutoTokenizer.from(modelFolder:)` reads.
    public static let fileNames = ["tokenizer.json", "tokenizer_config.json"]

    /// Hub repository holding the tokenizer for a built-in Whisper model, or `nil` for models that need none
    /// (non-Whisper engines) or whose tokenizer is unknown (custom imports).
    public static func repo(for model: ModelID) -> String? {
        let id = model.rawValue
        if id.hasPrefix("whisperkit/large-v3") { return "openai/whisper-large-v3" }
        if id == "whisperkit/small" || id == "coreml/whisper-small-sinhala" { return "openai/whisper-small" }
        return nil
    }

    static func remoteFiles(repo: String) -> [RemoteFile] {
        fileNames.compactMap { name in
            URL(string: "https://huggingface.co/\(repo)/resolve/main/\(name)").map { RemoteFile(relativePath: name, url: $0) }
        }
    }

    /// Folder WhisperKit searches for `repo` under `tokenizerFolder` (the Hub cache layout).
    public static func folder(repo: String, under tokenizerFolder: URL) -> URL {
        tokenizerFolder.appendingPathComponent("models", isDirectory: true).appendingPathComponent(repo, isDirectory: true)
    }
}
