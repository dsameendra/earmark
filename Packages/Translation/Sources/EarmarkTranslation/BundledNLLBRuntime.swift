import Foundation

/// The self-contained, signed native helper. It loads user-downloaded NLLB weights with no Python installation.
/// Isolation allows cancellation to terminate CPU inference and release its model memory promptly.
public enum BundledNLLBRuntime {
    public static func executable(in bundle: Bundle = .main) -> URL? {
        let candidate = bundle.bundleURL.appendingPathComponent("Contents/Helpers/EarmarkNLLBWorker")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    public static func runtime(in bundle: Bundle = .main) -> (any NLLBRuntime)? {
        executable(in: bundle).map { CTranslate2WorkerRuntime(nativeExecutable: $0) }
    }

    public static func pool(in bundle: Bundle = .main) -> CTranslate2RuntimePool? {
        executable(in: bundle).map { CTranslate2RuntimePool(nativeExecutable: $0) }
    }
}
