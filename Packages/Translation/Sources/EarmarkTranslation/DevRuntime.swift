import AppCore
import Foundation

/// Locates the development-only NLLB runtime (ADR-009).
///
/// `NLLBEngine` needs CTranslate2 and SentencePiece, which today run through a Python worker (`CTranslate2WorkerRuntime`).
/// That is acceptable for development and non-sandboxed local builds, not for a shippable app: the app must not depend on a
/// user's Python. The worker is therefore **off unless explicitly enabled**:
///
/// - environment `EARMARK_DEV_NLLB_PYTHON=/path/to/python3` (an interpreter with `ctranslate2` and `sentencepiece`), or
/// - the `dev.nllbPython` setting with the same path.
///
/// Without it the router has no NLLB engine and Sinhala translation reports ``TranslationFailure/noEngine(_:)``
/// ("Sinhala translation unavailable in this build").
public enum NLLBDevRuntime {
    public static let environmentKey = "EARMARK_DEV_NLLB_PYTHON"
    public static let settingsKey = "dev.nllbPython"

    /// The interpreter to use, or `nil` when the dev runtime is not enabled or the path is not an executable file.
    public static func pythonExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment, settingValue: String? = nil
    ) -> URL? {
        let candidates = [environment[environmentKey], settingValue].compactMap { $0 }.filter { !$0.isEmpty }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// A runtime for the enabled interpreter, or `nil` (leave NLLB out of the router).
    public static func runtime(
        environment: [String: String] = ProcessInfo.processInfo.environment, settingValue: String? = nil
    ) -> (any NLLBRuntime)? {
        pythonExecutable(environment: environment, settingValue: settingValue).map { CTranslate2WorkerRuntime(pythonExecutable: $0) }
    }
}
