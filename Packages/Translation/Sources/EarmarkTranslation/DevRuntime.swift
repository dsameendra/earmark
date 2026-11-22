import AppCore
import Foundation

/// Locates the development-only NLLB runtime (ADR-009).
///
/// Optional Python reference backend for development and parity checks. The shipping app uses
/// ``BundledNLLBRuntime`` and does not require a user's Python installation. Debug builds may
/// explicitly override that backend with `EARMARK_DEV_NLLB_PYTHON=/path/to/python3` or the
/// `dev.nllbPython` setting; the interpreter must provide CTranslate2 and SentencePiece.
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

    /// A runtime for the enabled interpreter, or `nil` (use the bundled runtime).
    public static func runtime(
        environment: [String: String] = ProcessInfo.processInfo.environment, settingValue: String? = nil
    ) -> (any NLLBRuntime)? {
        pythonExecutable(environment: environment, settingValue: settingValue).map { CTranslate2WorkerRuntime(pythonExecutable: $0) }
    }
}
